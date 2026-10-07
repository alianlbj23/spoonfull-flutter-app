import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/app_constants.dart';
import '../core/utils/logger.dart';
import '../data/api/api_client.dart';

/// server 推來的「資料變動」事件 (ARCHITECTURE.md §6.6)。
class DataChangedEvent {
  const DataChangedEvent(this.datasets, this.timestamp);

  /// `rooms` / `beds` / `meals` 的子集。
  final Set<String> datasets;
  final int timestamp;
}

/// 一條已建立的 WebSocket 連線;抽象出來讓測試能用假連線。
abstract class RealtimeChannel {
  Stream<dynamic> get messages;
  void send(String text);
  Future<void> close();

  /// 連線關閉後的 close code (server 以 4401 表示 token 無效)。
  int? get closeCode;
}

typedef RealtimeConnector =
    Future<RealtimeChannel> Function(Uri uri, Map<String, String> headers);

class _IoChannel implements RealtimeChannel {
  _IoChannel(this._socket);
  final WebSocket _socket;

  @override
  Stream<dynamic> get messages => _socket;
  @override
  void send(String text) => _socket.add(text);
  @override
  Future<void> close() => _socket.close();
  @override
  int? get closeCode => _socket.closeCode;
}

/// 以 dart:io 建立連線 (Linux 機台與 Android 都可用,不支援 web)。
Future<RealtimeChannel> ioConnector(Uri uri, Map<String, String> headers) async {
  final socket = await WebSocket.connect(
    uri.toString(),
    headers: headers,
  ).timeout(AppConstants.requestTimeout);
  return _IoChannel(socket);
}

/// server 推播通道 `ws/machine/` (ARCHITECTURE.md §6.6)。
///
/// 已配對時維持一條 WebSocket;server 的住民、用餐時段或菜單一變動就送
/// `data_changed`,由 [SyncService] 立刻重抓對應資料。斷線依
/// [AppConstants.realtimeReconnectDelays] 退避重連;收到 close code 4401
/// (token 無效) 則停止重連並通知上層重新配對。
class RealtimeService {
  RealtimeService({
    required this.baseUrlProvider,
    required this.tokenProvider,
    RealtimeConnector connector = ioConnector,
    this.reconnectDelays = AppConstants.realtimeReconnectDelays,
  }) : _connector = connector;

  /// server 以 4401 關閉連線 = REST 的 401。
  static const int closeUnauthorized = 4401;

  final BaseUrlProvider baseUrlProvider;
  final TokenProvider tokenProvider;
  final RealtimeConnector _connector;
  final List<Duration> reconnectDelays;

  /// token 無效 (4401) 時呼叫;由 SyncService 接到 ErrorHandlingService。
  void Function()? onUnauthorized;

  final _events = StreamController<DataChangedEvent>.broadcast();
  final _connections = StreamController<bool>.broadcast();

  Stream<DataChangedEvent> get events => _events.stream;

  /// 連線建立 (true) / 中斷 (false)。
  Stream<bool> get connectionChanges => _connections.stream;

  bool get isConnected => _channel != null;

  bool _enabled = false;
  bool _connecting = false;
  RealtimeChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnect;
  int _attempt = 0;

  /// 開始維持連線 (配對成功或啟動時已配對)。重複呼叫只會立即重試。
  void start() {
    _enabled = true;
    _reconnect?.cancel();
    _reconnect = null;
    _attempt = 0;
    unawaited(_connect());
  }

  /// 關閉連線並停止重連 (解除配對)。
  Future<void> stop() async {
    _enabled = false;
    _reconnect?.cancel();
    _reconnect = null;
    await _drop();
  }

  /// 網路恢復時立即重試,不等退避。
  void retryNow() {
    if (!_enabled || _channel != null) return;
    _reconnect?.cancel();
    _reconnect = null;
    _attempt = 0;
    unawaited(_connect());
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
    await _connections.close();
  }

  Uri? _uri() {
    final base = baseUrlProvider();
    if (base == null || base.isEmpty) return null;
    final http = Uri.parse(base).resolve(AppConstants.machineEventsPath);
    return http.replace(scheme: http.scheme == 'https' ? 'wss' : 'ws');
  }

  Future<void> _connect() async {
    if (!_enabled || _connecting || _channel != null) return;
    final uri = _uri();
    final token = await tokenProvider();
    if (uri == null || token == null || token.isEmpty) {
      _scheduleReconnect();
      return;
    }
    _connecting = true;
    try {
      final channel = await _connector(uri, {'Authorization': 'Bearer $token'});
      if (!_enabled) {
        await channel.close();
        return;
      }
      _channel = channel;
      _attempt = 0;
      _sub = channel.messages.listen(
        _onMessage,
        onError: (Object e) => _onClosed(channel, error: e),
        onDone: () => _onClosed(channel),
        cancelOnError: true,
      );
      Log.i('realtime connected: $uri');
      _connections.add(true);
    } on Object catch (e) {
      Log.i('realtime connect failed: $e');
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _onMessage(dynamic raw) {
    Map<String, Object?> body;
    try {
      final decoded = jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>));
      if (decoded is! Map) return;
      body = decoded.cast<String, Object?>();
    } catch (e) {
      Log.i('realtime: ignoring malformed message: $e');
      return;
    }
    switch (body['event']) {
      case 'data_changed':
        final list = body['datasets'];
        final datasets = list is List
            ? list.map((d) => d.toString()).toSet()
            : <String>{};
        if (datasets.isEmpty) return;
        final ts = body['timestamp'];
        _events.add(DataChangedEvent(datasets, ts is int ? ts : 0));
      case 'connected':
        Log.d('realtime: server acknowledged ${body['device_id']}');
      default:
        break;
    }
  }

  void _onClosed(RealtimeChannel channel, {Object? error}) {
    if (!identical(channel, _channel)) return;
    final code = channel.closeCode;
    _channel = null;
    _sub = null;
    Log.i('realtime closed (code $code${error == null ? '' : ', $error'})');
    _connections.add(false);
    if (code == closeUnauthorized) {
      _enabled = false;
      onUnauthorized?.call();
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_enabled || _reconnect != null) return;
    final delay =
        reconnectDelays[_attempt.clamp(0, reconnectDelays.length - 1)];
    _attempt++;
    _reconnect = Timer(delay, () {
      _reconnect = null;
      unawaited(_connect());
    });
  }

  Future<void> _drop() async {
    final channel = _channel;
    _channel = null;
    await _sub?.cancel();
    _sub = null;
    if (channel != null) {
      try {
        await channel.close();
      } catch (_) {}
      if (!_connections.isClosed) _connections.add(false);
    }
  }
}

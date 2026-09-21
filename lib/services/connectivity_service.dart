import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../core/utils/logger.dart';

/// 網路狀態監聽 (規格 9.1-3)。
abstract class ConnectivityService {
  Future<bool> isOnline();
  Stream<bool> get onStatusChange;
}

class PlusConnectivityService implements ConnectivityService {
  PlusConnectivityService([Connectivity? connectivity])
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  static bool _online(List<ConnectivityResult> r) =>
      r.any((c) => c != ConnectivityResult.none);

  @override
  Future<bool> isOnline() async {
    try {
      return _online(await _connectivity.checkConnectivity());
    } catch (e) {
      // 部分 Linux 環境沒有 NetworkManager,無法判斷時視為在線,由 API 錯誤決定。
      Log.i('connectivity check unavailable: $e');
      return true;
    }
  }

  @override
  Stream<bool> get onStatusChange => _connectivity.onConnectivityChanged
      .map(_online)
      .handleError((Object e) => Log.i('connectivity stream error: $e'))
      .distinct();
}

/// 測試用:手動控制連線狀態。
class FakeConnectivityService implements ConnectivityService {
  FakeConnectivityService({bool online = true}) : _isOnline = online;

  bool _isOnline;
  final _controller = StreamController<bool>.broadcast();

  set online(bool value) {
    _isOnline = value;
    _controller.add(value);
  }

  @override
  Future<bool> isOnline() async => _isOnline;

  @override
  Stream<bool> get onStatusChange => _controller.stream;
}

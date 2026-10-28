import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/app_constants.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/logger.dart';
import '../data/models/api_models.dart';
import '../data/models/device_config.dart';
import '../services/app_services.dart';

/// 配對狀態機 (規格 5.1)。
enum PairingStatus { initializing, notPaired, pairing, paired }

/// 配對流程 (Device Authorization Flow,README §4.1) 的時序控制:
/// 取碼 → 每 `interval` 秒輪詢 → 核准 / 過期換碼 / 被拒停止。
///
/// `device_code` 只放在這個物件的記憶體裡 ([_deviceCode]),配對完成、過期、
/// 被拒或離開配對畫面 ([stopPairing]) 就丟掉;不寫 log、不顯示。
class DeviceState extends ChangeNotifier {
  DeviceState(this._services) {
    _unauthSub = _services.errors.onUnauthorized.listen(
      (_) => _handleUnauthorized(),
    );
  }

  final AppServices _services;
  StreamSubscription<void>? _unauthSub;
  bool _handlingUnauthorized = false;

  PairingStatus status = PairingStatus.initializing;
  bool serverReachable = false;
  bool databaseReady = false;

  /// 配對失敗的提示 (中文);沒有錯誤時為 null。
  String? pairingError;

  /// 管理員拒絕了這次配對:不自動重試,等使用者按「重新取得配對碼」。
  bool pairingDenied = false;

  /// 顯示給管理員輸入的配對碼 (例如 `K7QM42XP`);還沒取得或已結束為 null。
  String? pairingCode;

  /// 配對碼到期時間;到期後 server 會回 EXPIRED,機台自動換新碼。
  DateTime? pairingExpiresAt;

  /// 目前的輪詢間隔 (SLOW_DOWN 會加長)。
  Duration pollInterval = AppConstants.pairingDefaultInterval;

  /// 下一次自動動作 (輪詢或重新取碼) 的時間;沒有排程時為 null。
  DateTime? nextAttemptAt;

  String? _deviceCode;
  Timer? _pairingTimer;
  int _failures = 0;
  bool _disposed = false;

  /// 最近一次健康檢查結果 (含 server 時間)。
  ServerHealth? serverHealth;

  /// 機台時鐘與 server 差太多時的警告 (中文);正常時為 null。
  String? get clockSkewWarning => serverHealth?.clockSkewWarning;

  /// 因 401 被強制解除配對時的提示,UI 顯示後清除。
  String? forcedLogoutMessage;

  DeviceConfig get config => _services.storage.deviceConfig;
  ServerSettings get serverSettings => _services.storage.serverSettings;
  bool get isPaired => status == PairingStatus.paired;
  bool get isConfigured => serverSettings.isComplete;

  /// 有可連線的伺服器位址 (預設位址也算);配對與同步另外還需要場域。
  bool get hasServer => serverSettings.baseUrl != null;

  /// 距離下一次自動動作還要多久;沒有排程或已到時間為 null。
  Duration? pairingRetryIn([DateTime? now]) {
    final at = nextAttemptAt;
    if (at == null) return null;
    final left = at.difference(now ?? DateTime.now());
    return left > Duration.zero ? left : null;
  }

  /// 配對碼剩餘有效時間;沒有配對碼或已過期為 null。
  Duration? pairingTimeLeft([DateTime? now]) {
    final at = pairingExpiresAt;
    if (at == null) return null;
    final left = at.difference(now ?? DateTime.now());
    return left > Duration.zero ? left : null;
  }

  /// 啟動流程 (規格 9.1)。
  Future<void> initialize() async {
    databaseReady = true;
    bool valid;
    try {
      valid = await _services.pairing.hasValidToken();
    } on Object catch (e) {
      // 讀不到 token 時當成未配對,不要讓歡迎畫面永遠停在載入中。
      Log.e('cannot read pairing state', e);
      valid = false;
    }
    status = valid ? PairingStatus.paired : PairingStatus.notPaired;
    notifyListeners();
    try {
      await _services.sync.start();
    } on Object catch (e) {
      Log.e('sync start failed', e);
    }
    unawaited(checkServer());
    if (valid) {
      unawaited(refreshIdentity());
      unawaited(_services.sync.syncAll());
    }
  }

  /// `GET api/machine/me/`:確認 token 仍有效並更新機台名稱。連不上 server
  /// 不影響啟動;401 由 UnauthorizedInterceptor 走 [_handleUnauthorized]。
  Future<void> refreshIdentity() async {
    try {
      await _services.pairing.refreshIdentity();
      notifyListeners();
    } on Object catch (e) {
      Log.i('cannot refresh device identity: $e');
    }
  }

  /// 測試連線:呼叫 `api/machine/health/` (舊版 server 退回舊做法),
  /// 順便檢查機台時鐘。只要有位址就檢查,還沒填場域的新機台也能看到伺服器燈號。
  Future<void> checkServer() async {
    if (!hasServer) {
      serverReachable = false;
      serverHealth = null;
      notifyListeners();
      return;
    }
    final health = await _services.api.checkHealth();
    serverHealth = health;
    serverReachable = health.reachable;
    final warning = health.clockSkewWarning;
    if (warning != null) Log.i('clock skew warning: $warning');
    notifyListeners();
  }

  /// 儲存伺服器設定;位址或場域變更時需要重新配對。
  Future<bool> saveServerSettings(ServerSettings settings) async {
    final previous = serverSettings;
    await _services.storage.saveServerSettings(settings);
    final changed =
        previous.host != settings.host ||
        previous.port != settings.port ||
        previous.placeId != settings.placeId;
    if (changed && isPaired) {
      await _services.sync.setPaired(false);
      await _services.pairing.unpair();
      await _services.storage.clearCache();
      status = PairingStatus.notPaired;
    }
    notifyListeners();
    unawaited(checkServer());
    return changed;
  }

  // ---------------- 配對流程 ----------------

  /// 取得新的配對碼並開始輪詢。被拒 / 使用者按「重新取得配對碼」也走這裡。
  Future<void> startPairing() async {
    if (isPaired) return;
    _cancelTimer();
    _deviceCode = null;
    pairingCode = null;
    pairingExpiresAt = null;
    pairingDenied = false;
    pairingError = null;
    _failures = 0;
    if (!isConfigured) {
      pairingError = '請先完成伺服器設定';
      status = PairingStatus.notPaired;
      notifyListeners();
      return;
    }
    status = PairingStatus.pairing;
    notifyListeners();
    await _requestCode();
  }

  /// 離開配對畫面或 App 進背景:停止輪詢並丟掉 device_code。
  ///
  /// 配對畫面在 dispose 時呼叫,那時 widget tree 是鎖住的,所以通知延後到
  /// 下一個 microtask。
  void stopPairing() {
    _cancelTimer();
    _deviceCode = null;
    pairingCode = null;
    pairingExpiresAt = null;
    if (status == PairingStatus.pairing) status = PairingStatus.notPaired;
    scheduleMicrotask(() {
      if (!_disposed) notifyListeners();
    });
  }

  /// 回到配對畫面 / App 回前景:碼還有效就繼續輪詢,否則重新取碼。
  Future<void> resumePairing() async {
    if (isPaired) return;
    if (_deviceCode != null && pairingTimeLeft() != null && !pairingDenied) {
      status = PairingStatus.pairing;
      notifyListeners();
      await pollPairingNow();
      return;
    }
    await startPairing();
  }

  Future<void> _requestCode() async {
    final PairingStart start;
    try {
      start = await _services.pairing.startPairing();
    } on Object catch (e) {
      _onStartFailed(e);
      return;
    }
    _deviceCode = start.deviceCode;
    pairingCode = start.pairingCode;
    pairingExpiresAt = DateTime.now().add(Duration(seconds: start.expiresIn));
    pollInterval = Duration(seconds: start.interval);
    _failures = 0;
    pairingError = null;
    Log.i(
      'pairing code ${start.pairingCode} issued, '
      'expires in ${start.expiresIn}s, poll every ${start.interval}s',
    );
    _schedule(pollInterval, pollPairingNow);
  }

  void _onStartFailed(Object error) {
    final e = _services.errors.normalize(error);
    if (status != PairingStatus.pairing) return;
    if (e.code == 'THROTTLED') {
      // 照 Retry-After 等,沒給就用輪詢間隔。
      pairingError = _services.errors.pairingMessage(e);
      _schedule(e.retryAfter ?? pollInterval, _requestCode);
      notifyListeners();
      return;
    }
    if (e.isRetryable) {
      // 網路 / 5xx:照既有重試策略。
      pairingError = _services.errors.pairingMessage(e);
      _schedule(_nextRetryDelay(), _requestCode);
      notifyListeners();
      return;
    }
    _fail(e);
  }

  /// 立刻輪詢一次 (由排程或回前景時呼叫)。
  Future<void> pollPairingNow() async {
    final code = _deviceCode;
    if (code == null || status != PairingStatus.pairing) return;
    _cancelTimer();
    final PairingPoll result;
    try {
      result = await _services.pairing.pollPairing(code);
    } on Object catch (e) {
      _onPollFailed(e);
      return;
    }
    // 回來時使用者可能已離開畫面或換了碼。
    if (_deviceCode != code || status != PairingStatus.pairing) return;
    _failures = 0;
    if (!result.approved) {
      _schedule(pollInterval, pollPairingNow);
      notifyListeners();
      return;
    }
    await _approved(result);
  }

  Future<void> _approved(PairingPoll result) async {
    try {
      await _services.pairing.completePairing(result);
    } on Object catch (e) {
      // token 存不進去:這個碼已用掉,只能重新取碼。
      Log.e('cannot store pairing result', e);
      pairingError = _services.errors.pairingMessage(e);
      await startPairing();
      return;
    }
    _deviceCode = null;
    pairingCode = null;
    pairingExpiresAt = null;
    nextAttemptAt = null;
    pairingError = null;
    status = PairingStatus.paired;
    Log.i(
      'paired as "${config.deviceName}" (server id ${config.serverDeviceId})',
    );
    notifyListeners();
    unawaited(checkServer());
    // 佇列裡因 401 而等待的紀錄立刻補傳,不等退避。
    unawaited(_services.sync.afterPaired());
    unawaited(_services.sync.setPaired(true));
  }

  void _onPollFailed(Object error) {
    final e = _services.errors.normalize(error);
    if (status != PairingStatus.pairing) return;
    switch (e.code) {
      case 'EXPIRED':
        // 碼過期:自動換新碼,不需要使用者操作。
        Log.i('pairing code expired, requesting a new one');
        _deviceCode = null;
        pairingCode = null;
        pairingExpiresAt = null;
        pairingError = null;
        unawaited(_requestCode());
        return;
      case 'DENIED':
        _deviceCode = null;
        pairingCode = null;
        pairingExpiresAt = null;
        nextAttemptAt = null;
        pairingDenied = true;
        pairingError = _services.errors.pairingMessage(e);
        status = PairingStatus.notPaired;
        notifyListeners();
        return;
      case 'SLOW_DOWN':
        pollInterval += AppConstants.pairingSlowDownStep;
        _schedule(pollInterval, pollPairingNow);
        notifyListeners();
        return;
    }
    if (e.isRetryable) {
      // 網路 / 5xx:照既有重試策略,不換新碼 (過期時 server 會回 EXPIRED)。
      pairingError = _services.errors.pairingMessage(e);
      _schedule(_nextRetryDelay(), pollPairingNow);
      notifyListeners();
      return;
    }
    _fail(e);
  }

  /// 不可重試的錯誤:停止流程並顯示訊息。
  void _fail(AppException e) {
    _cancelTimer();
    _deviceCode = null;
    pairingCode = null;
    pairingExpiresAt = null;
    nextAttemptAt = null;
    pairingError = _services.errors.pairingMessage(e);
    status = PairingStatus.notPaired;
    notifyListeners();
  }

  Duration _nextRetryDelay() {
    final delays = AppConstants.retryDelays;
    final d = delays[_failures.clamp(0, delays.length - 1)];
    _failures++;
    return d;
  }

  void _schedule(Duration delay, Future<void> Function() action) {
    _cancelTimer();
    nextAttemptAt = DateTime.now().add(delay);
    _pairingTimer = Timer(delay, () {
      _pairingTimer = null;
      nextAttemptAt = null;
      unawaited(action());
    });
  }

  void _cancelTimer() {
    _pairingTimer?.cancel();
    _pairingTimer = null;
    nextAttemptAt = null;
  }

  Future<void> unpair() async {
    await _services.sync.setPaired(false);
    await _services.pairing.unpair();
    status = PairingStatus.notPaired;
    notifyListeners();
  }

  /// 401 (管理員撤銷或重新配對) / WebSocket 4401:清掉 token,回到配對畫面。
  /// 一次 401 可能從 API 與同步兩處各通知一次;處理中的重複通知直接略過。
  Future<void> _handleUnauthorized() async {
    if (!isPaired || _handlingUnauthorized) return;
    _handlingUnauthorized = true;
    try {
      forcedLogoutMessage = '認證失敗,需要重新配對';
      await unpair();
    } finally {
      _handlingUnauthorized = false;
    }
  }

  String errorMessage(Object e) => _services.errors.userMessage(e);

  void consumeForcedLogout() => forcedLogoutMessage = null;

  @override
  void dispose() {
    _disposed = true;
    _cancelTimer();
    _unauthSub?.cancel();
    super.dispose();
  }
}

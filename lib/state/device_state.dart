import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../core/utils/logger.dart';
import '../data/models/device_config.dart';
import '../services/app_services.dart';

/// 配對狀態機 (規格 5.1)。
enum PairingStatus { initializing, notPaired, pairing, paired }

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
  String? pairingError;

  /// 因 401 被強制解除配對時的提示,UI 顯示後清除。
  String? forcedLogoutMessage;

  DeviceConfig get config => _services.storage.deviceConfig;
  ServerSettings get serverSettings => _services.storage.serverSettings;
  bool get isPaired => status == PairingStatus.paired;
  bool get isConfigured => serverSettings.isComplete;

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
      unawaited(_services.sync.syncAll());
    } else {
      unawaited(autoPair());
    }
  }

  /// 有 `--dart-define=PAIRING_CODE` 且已填伺服器設定時自動配對 (開發 / 測試用)。
  /// 回傳是否配對成功;沒有設定固定碼時直接回 false。
  Future<bool> autoPair() async {
    if (!AppConfig.hasAutoPairingCode || isPaired || !isConfigured) {
      return false;
    }
    if (status == PairingStatus.pairing) return false;
    Log.i('auto pairing with PAIRING_CODE');
    return pair(AppConfig.autoPairingCode);
  }

  Future<void> checkServer() async {
    serverReachable = isConfigured && await _services.api.ping();
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

  Future<bool> pair(String code) async {
    status = PairingStatus.pairing;
    pairingError = null;
    notifyListeners();
    try {
      await _services.pairing.pair(code);
      status = PairingStatus.paired;
      notifyListeners();
      unawaited(checkServer());
      unawaited(_services.sync.syncAll(forceCache: true));
      unawaited(_services.sync.setPaired(true));
      return true;
    } on Object catch (e) {
      pairingError = _services.errors.userMessage(e);
      status = PairingStatus.notPaired;
      notifyListeners();
      return false;
    }
  }

  Future<void> unpair() async {
    await _services.sync.setPaired(false);
    await _services.pairing.unpair();
    status = PairingStatus.notPaired;
    notifyListeners();
  }

  /// 一次 401 可能從 API 與同步兩處各通知一次;處理中的重複通知直接略過。
  Future<void> _handleUnauthorized() async {
    if (!isPaired || _handlingUnauthorized) return;
    _handlingUnauthorized = true;
    try {
      forcedLogoutMessage = '認證失敗,需要重新配對';
      await unpair();
      // 固定配對碼模式:被踢掉就自動重配,不用人工介入。
      if (await autoPair()) forcedLogoutMessage = null;
    } finally {
      _handlingUnauthorized = false;
    }
  }

  String errorMessage(Object e) => _services.errors.userMessage(e);

  void consumeForcedLogout() => forcedLogoutMessage = null;

  @override
  void dispose() {
    _unauthSub?.cancel();
    super.dispose();
  }
}

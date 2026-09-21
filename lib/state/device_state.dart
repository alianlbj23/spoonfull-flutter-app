import 'dart:async';

import 'package:flutter/foundation.dart';

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
    final valid = await _services.pairing.hasValidToken();
    status = valid ? PairingStatus.paired : PairingStatus.notPaired;
    notifyListeners();
    await _services.sync.start();
    unawaited(checkServer());
    if (valid) unawaited(_services.sync.syncAll());
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
      return true;
    } on Object catch (e) {
      pairingError = _services.errors.userMessage(e);
      status = PairingStatus.notPaired;
      notifyListeners();
      return false;
    }
  }

  Future<void> unpair() async {
    await _services.pairing.unpair();
    status = PairingStatus.notPaired;
    notifyListeners();
  }

  Future<void> _handleUnauthorized() async {
    if (!isPaired) return;
    forcedLogoutMessage = '認證失敗,需要重新配對';
    await unpair();
  }

  void consumeForcedLogout() => forcedLogoutMessage = null;

  @override
  void dispose() {
    _unauthSub?.cancel();
    super.dispose();
  }
}

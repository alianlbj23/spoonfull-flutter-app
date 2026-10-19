import '../config/app_config.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/time_utils.dart';
import '../core/utils/validators.dart';
import '../data/api/api_repository.dart';
import '../data/models/api_models.dart';
import '../data/models/auth_token.dart';
import '../data/models/device_config.dart';
import 'local_storage_service.dart';

/// 機台配對與身分驗證 (規格 4.1、5.1、8.1)。
///
/// Device Authorization Flow:[startPairing] 取得配對碼 → 管理員在網頁核准 →
/// [pollPairing] 拿到 token → [completePairing] 存起來。輪詢的時序 (間隔、過期、
/// 重試) 由 `DeviceState` 控制,這裡只做單次呼叫與儲存。
class DevicePairingService {
  DevicePairingService(this._api, this._storage);

  final ApiRepository _api;
  final LocalStorageService _storage;

  /// 啟動時檢查本機 token:存在且有效 → true;過期 → 清除後 false。
  Future<bool> hasValidToken() async {
    final token = await _storage.readToken();
    if (token == null || token.deviceToken.isEmpty) return false;
    if (token.isExpired) {
      await unpair();
      return false;
    }
    return true;
  }

  Future<String?> currentToken() async {
    final token = await _storage.readToken();
    return token?.deviceToken;
  }

  /// `POST pair/start/`:`hardware_id` 沿用 App 的 UUID。
  Future<PairingStart> startPairing() {
    final settings = _storage.serverSettings;
    if (!settings.isComplete) {
      throw const AppException(AppErrorType.localValidation, '請先完成伺服器設定');
    }
    final hardwareId = _storage.deviceConfig.deviceId;
    Validators.hardwareId(hardwareId);
    return _api.startPairing(
      hardwareId: hardwareId,
      appVersion: AppConfig.appVersion,
    );
  }

  /// `POST pair/poll/`。
  Future<PairingPoll> pollPairing(String deviceCode) =>
      _api.pollPairing(deviceCode);

  /// 核准後:先存 token (只會回這一次),再更新設備配置。
  ///
  /// server 的整數 id 存到 [DeviceConfig.serverDeviceId],不覆蓋 App 的 UUID。
  Future<DeviceConfig> completePairing(PairingPoll approved) async {
    if (!approved.approved || approved.deviceToken.isEmpty) {
      throw const AppException(AppErrorType.parse, '伺服器未回傳 token');
    }
    final now = nowUnix();
    await _storage.saveToken(
      AuthToken(deviceToken: approved.deviceToken, tokenAcquiredAt: now),
    );
    final config = _storage.deviceConfig;
    final updated = config.copyWith(
      deviceName: approved.deviceName.isNotEmpty
          ? approved.deviceName
          : config.deviceName,
      location: _storage.serverSettings.placeId,
      paired: true,
      pairingTime: now,
      serverDeviceId: approved.serverDeviceId,
    );
    await _storage.saveDeviceConfig(updated);
    return updated;
  }

  /// `GET api/machine/me/`:確認 token 仍有效,並把管理員改過的名稱更新到本機。
  /// token 失效時與其他 API 一樣丟 401 (由 UnauthorizedInterceptor 處理)。
  Future<DeviceConfig> refreshIdentity() async {
    final me = await _api.fetchMe();
    final config = _storage.deviceConfig;
    final updated = config.copyWith(
      deviceName: me.deviceName.isNotEmpty ? me.deviceName : config.deviceName,
      serverDeviceId: me.serverDeviceId,
    );
    if (updated.deviceName != config.deviceName ||
        updated.serverDeviceId != config.serverDeviceId) {
      await _storage.saveDeviceConfig(updated);
    }
    return updated;
  }

  Future<void> unpair() async {
    await _storage.clearToken();
    final config = _storage.deviceConfig;
    await _storage.saveDeviceConfig(
      DeviceConfig(
        deviceId: config.deviceId,
        deviceName: config.deviceName,
        location: config.location,
        paired: false,
        lastSync: config.lastSync,
        serverDeviceId: config.serverDeviceId,
      ),
    );
  }
}

import '../core/errors/app_exception.dart';
import '../core/utils/time_utils.dart';
import '../core/utils/validators.dart';
import '../data/api/api_repository.dart';
import '../data/models/auth_token.dart';
import '../data/models/device_config.dart';
import 'local_storage_service.dart';

/// 機台配對與身分驗證 (規格 4.1、5.1、8.1)。
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

  Future<DeviceConfig> pair(String pairingCode) async {
    Validators.pairingCode(pairingCode);
    final settings = _storage.serverSettings;
    if (!settings.isComplete) {
      throw const AppException(
        AppErrorType.localValidation,
        '請先完成伺服器設定',
      );
    }
    final config = _storage.deviceConfig;
    final deviceName = config.deviceName.isNotEmpty
        ? config.deviceName
        : 'Spoonfull-${settings.placeId}-${config.deviceId.substring(0, 4)}';

    final result = await _api.pairDevice(
      deviceId: config.deviceId,
      deviceName: deviceName,
      location: settings.placeId,
      pairingCode: pairingCode,
    );
    if (result.deviceToken.isEmpty) {
      throw const AppException(AppErrorType.parse, '伺服器未回傳 token');
    }

    final now = nowUnix();
    await _storage.saveToken(
      AuthToken(
        deviceToken: result.deviceToken,
        tokenAcquiredAt: now,
        tokenExpiresAt: result.expiresIn == null
            ? null
            : now + result.expiresIn!,
      ),
    );
    final updated = config.copyWith(
      deviceName: deviceName,
      location: settings.placeId,
      paired: true,
      pairingTime: now,
    );
    await _storage.saveDeviceConfig(updated);
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
      ),
    );
  }
}

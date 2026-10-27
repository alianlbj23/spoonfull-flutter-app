import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../config/app_config.dart';
import '../models/device_config.dart';
import '../models/hardware_config.dart';

/// 設備配置、同步時間戳與硬體設定,保存於 SharedPreferences。
class PreferencesStorage {
  PreferencesStorage(this._prefs);

  final SharedPreferences _prefs;

  static const _deviceId = 'device_config.device_id';
  static const _deviceName = 'device_config.device_name';
  static const _location = 'device_config.location';
  static const _paired = 'device_config.paired';
  static const _pairingTime = 'device_config.pairing_time';
  static const _lastSync = 'device_config.last_sync';
  static const _serverDeviceId = 'device_config.server_device_id';
  static const _serverHost = 'server.host';
  static const _serverPort = 'server.port';

  /// 伺服器設定格式版本。v1 (沒有這個 key):host + port,沒寫協定一律 http。
  /// v2:host 可為完整網址,port 可省略,公開網域預設 https。
  static const _serverConfigVersion = 'server.config_version';
  static const _syncPrefix = 'sync.last_updated.';
  static const _currentSlot = 'meals.current_slot';
  static const _currentSlotAt = 'meals.current_slot_at';
  static const _hardware = 'hardware.config';

  static Future<PreferencesStorage> create() async =>
      PreferencesStorage(await SharedPreferences.getInstance());

  DeviceConfig readDeviceConfig() {
    var id = _prefs.getString(_deviceId);
    if (id == null) {
      id = const Uuid().v4();
      _prefs.setString(_deviceId, id);
    }
    return DeviceConfig(
      deviceId: id,
      deviceName: _prefs.getString(_deviceName) ?? '',
      location: _prefs.getString(_location) ?? '',
      paired: _prefs.getBool(_paired) ?? false,
      pairingTime: _prefs.getInt(_pairingTime),
      lastSync: _prefs.getInt(_lastSync),
      serverDeviceId: _prefs.getInt(_serverDeviceId),
    );
  }

  Future<void> writeDeviceConfig(DeviceConfig c) async {
    await _prefs.setString(_deviceId, c.deviceId);
    await _prefs.setString(_deviceName, c.deviceName);
    await _prefs.setString(_location, c.location);
    await _prefs.setBool(_paired, c.paired);
    await _setOrRemoveInt(_pairingTime, c.pairingTime);
    await _setOrRemoveInt(_lastSync, c.lastSync);
    await _setOrRemoveInt(_serverDeviceId, c.serverDeviceId);
  }

  /// 從沒存過伺服器設定的機台 (沒有 host 這個 key) 預設連到
  /// [AppConfig.defaultServerHost];預設值不寫進偏好,存過一次就以存的為準。
  ServerSettings readServerSettings() {
    final stored = _prefs.getString(_serverHost);
    var host = stored ?? '';
    var port = _prefs.getString(_serverPort) ?? '';
    if ((_prefs.getInt(_serverConfigVersion) ?? 1) < 2) {
      final legacy = legacyBaseUrl(host, port);
      if (legacy != null) {
        // 把舊格式換成完整網址 (保留原本的 http 與埠),升級後連到同一個位址。
        host = legacy.endsWith('/')
            ? legacy.substring(0, legacy.length - 1)
            : legacy;
        port = '';
        _prefs.setString(_serverHost, host);
        _prefs.setString(_serverPort, port);
      }
      _prefs.setInt(_serverConfigVersion, 2);
    }
    if (stored == null) host = AppConfig.defaultServerHost;
    return ServerSettings(
      host: host,
      port: port,
      placeId: _prefs.getString(_location) ?? '',
    );
  }

  Future<void> writeServerSettings(ServerSettings s) async {
    await _prefs.setString(_serverHost, s.host.trim());
    await _prefs.setString(_serverPort, s.port.trim());
    await _prefs.setString(_location, s.placeId.trim());
    await _prefs.setInt(_serverConfigVersion, 2);
  }

  /// v1 的 BASE_URL 組法:沒寫協定時預設 http,[port] 覆蓋網址裡的埠。
  static String? legacyBaseUrl(String host, String port) {
    var h = host.trim();
    if (h.isEmpty) return null;
    if (!h.startsWith('http://') && !h.startsWith('https://')) {
      h = 'http://$h';
    }
    final uri = Uri.tryParse(h);
    if (uri == null || uri.host.isEmpty) return null;
    final p = int.tryParse(port.trim());
    final withPort = p == null ? uri : uri.replace(port: p);
    final path = withPort.path.endsWith('/')
        ? withPort.path
        : '${withPort.path}/';
    return withPort.replace(path: path).toString();
  }

  /// 硬體設定 (相機 / 秤 / 參考照),以 JSON 保存。
  HardwareConfig readHardwareConfig() {
    final raw = _prefs.getString(_hardware);
    // 沒存過設定:相機來源依平台 (Linux 機台 RealSense,桌面選擇圖片)。
    final fresh = HardwareConfig(camera: CameraSettings.platformDefault());
    if (raw == null) return fresh;
    try {
      return HardwareConfig.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      return fresh;
    }
  }

  Future<void> writeHardwareConfig(HardwareConfig c) =>
      _prefs.setString(_hardware, jsonEncode(c.toJson()));

  /// 各資料集最後同步時間 (rooms / beds / meals),用於增量同步與快取有效期。
  int? lastUpdated(String dataset) => _prefs.getInt('$_syncPrefix$dataset');

  Future<void> setLastUpdated(String dataset, int? ts) =>
      _setOrRemoveInt('$_syncPrefix$dataset', ts);

  /// server 在 meals 回應附的 `current_slot`,與收到時的機台時間 (unix 秒)。
  (String?, int?) readCurrentSlot() =>
      (_prefs.getString(_currentSlot), _prefs.getInt(_currentSlotAt));

  Future<void> writeCurrentSlot(String? slot, int at) async {
    if (slot == null) {
      await _prefs.remove(_currentSlot);
    } else {
      await _prefs.setString(_currentSlot, slot);
    }
    await _prefs.setInt(_currentSlotAt, at);
  }

  Future<void> clearSyncTimestamps() async {
    for (final k in _prefs.getKeys().where((k) => k.startsWith(_syncPrefix))) {
      await _prefs.remove(k);
    }
  }

  Future<void> _setOrRemoveInt(String key, int? value) =>
      value == null ? _prefs.remove(key) : _prefs.setInt(key, value);
}

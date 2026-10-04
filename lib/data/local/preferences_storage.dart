import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

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
  static const _serverHost = 'server.host';
  static const _serverPort = 'server.port';
  static const _syncPrefix = 'sync.last_updated.';
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
    );
  }

  Future<void> writeDeviceConfig(DeviceConfig c) async {
    await _prefs.setString(_deviceId, c.deviceId);
    await _prefs.setString(_deviceName, c.deviceName);
    await _prefs.setString(_location, c.location);
    await _prefs.setBool(_paired, c.paired);
    await _setOrRemoveInt(_pairingTime, c.pairingTime);
    await _setOrRemoveInt(_lastSync, c.lastSync);
  }

  ServerSettings readServerSettings() => ServerSettings(
    host: _prefs.getString(_serverHost) ?? '',
    port: _prefs.getString(_serverPort) ?? '',
    placeId: _prefs.getString(_location) ?? '',
  );

  Future<void> writeServerSettings(ServerSettings s) async {
    await _prefs.setString(_serverHost, s.host.trim());
    await _prefs.setString(_serverPort, s.port.trim());
    await _prefs.setString(_location, s.placeId.trim());
  }

  /// 硬體設定 (相機 / 秤 / 參考照),以 JSON 保存。
  HardwareConfig readHardwareConfig() {
    final raw = _prefs.getString(_hardware);
    if (raw == null) return const HardwareConfig();
    try {
      return HardwareConfig.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      return const HardwareConfig();
    }
  }

  Future<void> writeHardwareConfig(HardwareConfig c) =>
      _prefs.setString(_hardware, jsonEncode(c.toJson()));

  /// 各資料集最後同步時間 (rooms / beds / meals),用於增量同步與快取有效期。
  int? lastUpdated(String dataset) => _prefs.getInt('$_syncPrefix$dataset');

  Future<void> setLastUpdated(String dataset, int? ts) =>
      _setOrRemoveInt('$_syncPrefix$dataset', ts);

  Future<void> clearSyncTimestamps() async {
    for (final k in _prefs.getKeys().where((k) => k.startsWith(_syncPrefix))) {
      await _prefs.remove(k);
    }
  }

  Future<void> _setOrRemoveInt(String key, int? value) =>
      value == null ? _prefs.remove(key) : _prefs.setInt(key, value);
}

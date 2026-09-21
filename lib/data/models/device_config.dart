/// 設備配置 (規格 3.1.1),保存於 SharedPreferences。
class DeviceConfig {
  const DeviceConfig({
    required this.deviceId,
    this.deviceName = '',
    this.location = '',
    this.paired = false,
    this.pairingTime,
    this.lastSync,
  });

  final String deviceId;
  final String deviceName;

  /// 設定畫面中的「場域」,同時作為 API 的 place_id。
  final String location;
  final bool paired;
  final int? pairingTime;
  final int? lastSync;

  DeviceConfig copyWith({
    String? deviceName,
    String? location,
    bool? paired,
    int? pairingTime,
    int? lastSync,
  }) {
    return DeviceConfig(
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      location: location ?? this.location,
      paired: paired ?? this.paired,
      pairingTime: pairingTime ?? this.pairingTime,
      lastSync: lastSync ?? this.lastSync,
    );
  }
}

/// 設定畫面的伺服器連線資訊。
class ServerSettings {
  const ServerSettings({
    this.host = '',
    this.port = '',
    this.placeId = '',
  });

  final String host;
  final String port;
  final String placeId;

  bool get isComplete =>
      host.trim().isNotEmpty &&
      port.trim().isNotEmpty &&
      placeId.trim().isNotEmpty;

  /// 由位址與埠組成 BASE_URL,未指定協定時預設 http (院內區網)。
  String? get baseUrl {
    if (host.trim().isEmpty) return null;
    var h = host.trim();
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

  @override
  bool operator ==(Object other) =>
      other is ServerSettings &&
      other.host == host &&
      other.port == port &&
      other.placeId == placeId;

  @override
  int get hashCode => Object.hash(host, port, placeId);
}

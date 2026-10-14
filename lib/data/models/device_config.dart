import '../../core/utils/server_address.dart';

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
///
/// [host] 可以是完整網址 (`https://foodintakesystem.com`) 或主機名稱 / IP;
/// [port] 可省略 (依協定預設 443 / 80)。解析規則見 [ServerAddress]。
class ServerSettings {
  const ServerSettings({
    this.host = '',
    this.port = '',
    this.placeId = '',
  });

  final String host;
  final String port;
  final String placeId;

  /// 依新規則解析 (設定畫面用;公開網域的 http 會有 [ServerAddress.error])。
  ServerAddress get address => ServerAddress.resolve(host, port: port);

  bool get isComplete => baseUrl != null && placeId.trim().isNotEmpty;

  /// 實際連線用的 BASE_URL (結尾有 `/`)。已存的舊設定即使是公開網域的 http
  /// 也照常連線 (設定畫面會提示改用 https)。
  String? get baseUrl =>
      ServerAddress.resolve(host, port: port, allowInsecurePublic: true)
          .baseUrl;

  @override
  bool operator ==(Object other) =>
      other is ServerSettings &&
      other.host == host &&
      other.port == port &&
      other.placeId == placeId;

  @override
  int get hashCode => Object.hash(host, port, placeId);
}

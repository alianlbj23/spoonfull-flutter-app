import '../../config/app_constants.dart';

/// 相機來源 (ARCHITECTURE.md §5.1:Linux 不能用 image_picker 開相機,改用 GStreamer / V4L2)。
enum CameraSource {
  /// 依平台與裝置自動判斷:Linux 有 /dev/video* → v4l2;Jetson 無 USB 相機 → nvargus;
  /// Raspberry Pi 無 USB 相機 → libcamera;其他平台 → picker。
  auto('自動'),

  /// USB / UVC 相機,GStreamer `v4l2src`。
  v4l2('USB 相機 (V4L2)'),

  /// Jetson CSI 相機,GStreamer `nvarguscamerasrc`。
  nvargus('Jetson CSI 相機'),

  /// Raspberry Pi CSI 相機,`rpicam-still` / `libcamera-still`。
  libcamera('Pi CSI 相機 (libcamera)'),

  /// image_picker (Android / iOS 相機;桌面為選擇檔案),開發用。
  picker('系統相機 / 選檔'),

  /// 依序取用資料夾裡的照片 (測試用:`device` 欄位填資料夾路徑,預設 `test_images`)。
  folder('測試圖片資料夾'),

  /// 產生合成測試圖,沒有相機時用。
  mock('模擬相機');

  const CameraSource(this.label);
  final String label;

  static CameraSource parse(String? v) => CameraSource.values.firstWhere(
    (s) => s.name == v,
    orElse: () => CameraSource.auto,
  );
}

class CameraSettings {
  const CameraSettings({
    this.source = CameraSource.auto,
    this.device = '/dev/video0',
    this.width = AppConstants.captureWidth,
    this.height = AppConstants.captureHeight,
    this.warmupFrames = AppConstants.captureWarmupFrames,
    this.mjpeg = false,
  });

  final CameraSource source;

  /// V4L2 裝置路徑;nvargus 為 sensor-id (數字字串);libcamera 為 camera index。
  final String device;
  final int width;
  final int height;

  /// 擷取前丟掉的暖機張數 (自動曝光需要時間)。
  final int warmupFrames;

  /// V4L2 要求相機直接輸出 MJPEG (高解析度 USB 相機較快)。
  final bool mjpeg;

  CameraSettings copyWith({
    CameraSource? source,
    String? device,
    int? width,
    int? height,
    int? warmupFrames,
    bool? mjpeg,
  }) => CameraSettings(
    source: source ?? this.source,
    device: device ?? this.device,
    width: width ?? this.width,
    height: height ?? this.height,
    warmupFrames: warmupFrames ?? this.warmupFrames,
    mjpeg: mjpeg ?? this.mjpeg,
  );

  Map<String, Object?> toJson() => {
    'source': source.name,
    'device': device,
    'width': width,
    'height': height,
    'warmup_frames': warmupFrames,
    'mjpeg': mjpeg,
  };

  factory CameraSettings.fromJson(Map<String, Object?> json) => CameraSettings(
    source: CameraSource.parse(json['source'] as String?),
    device: json['device'] as String? ?? '/dev/video0',
    width: (json['width'] as num?)?.toInt() ?? AppConstants.captureWidth,
    height: (json['height'] as num?)?.toInt() ?? AppConstants.captureHeight,
    warmupFrames:
        (json['warmup_frames'] as num?)?.toInt() ??
        AppConstants.captureWarmupFrames,
    mjpeg: json['mjpeg'] as bool? ?? false,
  );
}

/// 秤的連接方式。
enum ScaleKind {
  /// 沒有秤:不送 weight_g,server 以菜單標準份量估算。
  none('不使用秤'),

  /// USB HID 秤 (USB HID POS Scale 協定,如 Dymo / Stamps.com),讀 /dev/hidrawN。
  hid('USB HID 秤'),

  /// 序列埠秤或 HX711 + 微控制器,每行一個數值 (如 "ST,GS,  123.4 g")。
  serial('序列埠 / HX711 (USB)'),

  /// 本機 TCP 文字串流 (HX711 直接接 GPIO 時由 deploy/hx711_bridge.py 提供)。
  tcp('HX711 (GPIO bridge)'),

  /// 模擬秤,開發與測試用。
  mock('模擬秤');

  const ScaleKind(this.label);
  final String label;

  static ScaleKind parse(String? v) => ScaleKind.values.firstWhere(
    (s) => s.name == v,
    orElse: () => ScaleKind.none,
  );
}

class ScaleSettings {
  const ScaleSettings({
    this.kind = ScaleKind.none,
    this.device = '/dev/hidraw0',
    this.baudRate = 9600,
    this.host = '127.0.0.1',
    this.port = 9100,
    this.mockWeightG = 420,
  });

  final ScaleKind kind;

  /// hid: /dev/hidrawN;serial: /dev/ttyUSB0 或 /dev/ttyACM0。
  final String device;
  final int baudRate;
  final String host;
  final int port;

  /// 模擬秤回傳的重量。
  final double mockWeightG;

  bool get enabled => kind != ScaleKind.none;

  ScaleSettings copyWith({
    ScaleKind? kind,
    String? device,
    int? baudRate,
    String? host,
    int? port,
    double? mockWeightG,
  }) => ScaleSettings(
    kind: kind ?? this.kind,
    device: device ?? this.device,
    baudRate: baudRate ?? this.baudRate,
    host: host ?? this.host,
    port: port ?? this.port,
    mockWeightG: mockWeightG ?? this.mockWeightG,
  );

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'device': device,
    'baud_rate': baudRate,
    'host': host,
    'port': port,
    'mock_weight_g': mockWeightG,
  };

  factory ScaleSettings.fromJson(Map<String, Object?> json) => ScaleSettings(
    kind: ScaleKind.parse(json['kind'] as String?),
    device: json['device'] as String? ?? '/dev/hidraw0',
    baudRate: (json['baud_rate'] as num?)?.toInt() ?? 9600,
    host: json['host'] as String? ?? '127.0.0.1',
    port: (json['port'] as num?)?.toInt() ?? 9100,
    mockWeightG: (json['mock_weight_g'] as num?)?.toDouble() ?? 420,
  );
}

/// 機台硬體設定 (相機、秤、空秤參考照),保存於 SharedPreferences。
class HardwareConfig {
  const HardwareConfig({
    this.camera = const CameraSettings(),
    this.scale = const ScaleSettings(),
    this.referenceImagePath,
    this.qualityCheckEnabled = true,
  });

  final CameraSettings camera;
  final ScaleSettings scale;

  /// 「空秤參考照」路徑:餐盒不在畫面的判斷基準,在硬體設定頁拍攝。
  final String? referenceImagePath;

  /// 關閉後仍會計算品質指標,但不會提示重拍。
  final bool qualityCheckEnabled;

  HardwareConfig copyWith({
    CameraSettings? camera,
    ScaleSettings? scale,
    String? referenceImagePath,
    bool clearReference = false,
    bool? qualityCheckEnabled,
  }) => HardwareConfig(
    camera: camera ?? this.camera,
    scale: scale ?? this.scale,
    referenceImagePath: clearReference
        ? null
        : (referenceImagePath ?? this.referenceImagePath),
    qualityCheckEnabled: qualityCheckEnabled ?? this.qualityCheckEnabled,
  );

  Map<String, Object?> toJson() => {
    'camera': camera.toJson(),
    'scale': scale.toJson(),
    'reference_image_path': referenceImagePath,
    'quality_check_enabled': qualityCheckEnabled,
  };

  factory HardwareConfig.fromJson(Map<String, Object?> json) {
    final cam = json['camera'];
    final sc = json['scale'];
    return HardwareConfig(
      camera: cam is Map
          ? CameraSettings.fromJson(cam.cast<String, Object?>())
          : const CameraSettings(),
      scale: sc is Map
          ? ScaleSettings.fromJson(sc.cast<String, Object?>())
          : const ScaleSettings(),
      referenceImagePath: json['reference_image_path'] as String?,
      qualityCheckEnabled: json['quality_check_enabled'] as bool? ?? true,
    );
  }
}

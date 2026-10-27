import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../../config/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/logger.dart';
import '../../data/models/hardware_config.dart';
import 'depth_image.dart';

typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// 執行外部擷取程式。超過 [AppConstants.captureTimeout] 就砍掉子行程再丟
/// [TimeoutException]:只放棄等待的話,卡住的程式會一直佔著相機,之後每次拍照都失敗。
Future<ProcessResult> _defaultRunner(String exe, List<String> args) async {
  final process = await Process.start(exe, args);
  final out = process.stdout.transform(systemEncoding.decoder).join();
  final err = process.stderr.transform(systemEncoding.decoder).join();
  final int code;
  try {
    code = await process.exitCode.timeout(AppConstants.captureTimeout);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    // 等它真的結束,相機裝置才會釋放。
    await process.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () => -1,
    );
    out.ignore();
    err.ignore();
    rethrow;
  }
  return ProcessResult(process.pid, code, await out, await err);
}

/// 注入的 runner 沒有自己的逾時時的保險 (預設 runner 會先逾時並砍掉子行程)。
const _runnerGrace = Duration(seconds: 5);

/// 給現場人員看的訊息固定為幾種;技術細節 ([detail]) 只寫進 log。
AppException _cameraError(String code, Object? detail) {
  Log.e('camera $code', detail);
  return AppException(AppErrorType.localValidation, switch (code) {
    'CAMERA_UNAVAILABLE' => '這台機器的相機還沒設定好,請聯絡管理員',
    'CAMERA_NOT_FOUND' => '找不到 RealSense 相機,請確認相機的 USB 線有接好,再試一次',
    'CAMERA_TIMEOUT' => '相機沒有回應,請確認相機的線有接好,再試一次',
    _ => '相機沒有拍到畫面,請確認相機的線有接好,再試一次',
  }, code: code);
}

/// 相機擷取到的原始檔案:RGB 一定有;RealSense 另外有深度圖與其 meta。
class RawCapture {
  const RawCapture({
    required this.imagePath,
    this.depthPath,
    this.depthMetaPath,
  });

  final String imagePath;

  /// 16-bit 灰階 PNG,單位 mm,已對齊到 RGB、同解析度;0 = 沒有資料。
  final String? depthPath;

  /// 內參、序號、depth_unit_m 等 (deploy/realsense_bridge.py 的 META)。
  final String? depthMetaPath;

  bool get hasDepth => depthPath != null;
}

/// 相機擷取:拍一張原始照片 (RealSense 連同深度圖) 寫到指定路徑。
/// 壓縮與品質檢查由 [ImagePipeline] 負責。
abstract class CameraService {
  const CameraService();

  /// 擷取到 [outputPath] (副檔名由實作決定,回傳實際路徑);使用者取消時回 null。
  Future<RawCapture?> capture(String outputPath);

  /// 顯示在硬體設定頁的說明。
  String get description;

  Future<void> dispose() async {}

  /// 依設定建立相機。
  static CameraService create(
    CameraSettings settings, {
    ProcessRunner? runner,
    ImagePicker? picker,
  }) => switch (settings.source) {
    CameraSource.realsense => RealSenseCameraService(settings, runner: runner),
    CameraSource.picker => ImagePickerCameraService(picker: picker),
  };
}

/// `--probe` 的結果:接上的 RealSense 相機資訊。
class RealSenseInfo {
  const RealSenseInfo({
    required this.serial,
    required this.name,
    this.firmware,
    this.usbType,
    this.mock = false,
    this.librealsense,
  });

  final String serial;
  final String name;
  final String? firmware;

  /// `3.2` = USB 3;`2.1` 代表接在 USB 2 (解析度 / fps 受限)。
  final String? usbType;
  final bool mock;
  final String? librealsense;

  bool get onUsb2 => usbType != null && usbType!.startsWith('2');

  factory RealSenseInfo.fromJson(Map<String, Object?> json) => RealSenseInfo(
    serial: json['serial']?.toString() ?? '',
    name: json['name']?.toString() ?? 'Intel RealSense',
    firmware: json['firmware']?.toString(),
    usbType: json['usb_type']?.toString(),
    mock: json['mock'] == true,
    librealsense: json['librealsense']?.toString(),
  );

  /// 給設定頁顯示的一行摘要。
  String get summary {
    final parts = [
      name,
      if (serial.isNotEmpty) '序號 $serial',
      if (firmware != null) '韌體 $firmware',
      if (usbType != null) 'USB $usbType${onUsb2 ? ' (請改接 USB 3 埠)' : ''}',
      if (mock) '(模擬)',
    ];
    return parts.join(' · ');
  }
}

/// Intel RealSense D435f:呼叫 `deploy/realsense_bridge.py` 拍一張 RGB-D。
///
/// bridge 寫出三個檔案:RGB JPEG、深度 16-bit PNG (mm,對齊到 RGB、同解析度)、
/// meta JSON。App 不直接連結 librealsense,所以 Flutter 這邊只有「跑外部程序 +
/// 逾時 + 檢查輸出檔」。
///
/// 環境變數:`SPOONFULL_REALSENSE_BRIDGE` 指定 bridge 路徑、`SPOONFULL_PYTHON`
/// 指定 python 執行檔、`SPOONFULL_REALSENSE_MOCK=1` 沒有相機時用合成影像。
class RealSenseCameraService extends CameraService {
  RealSenseCameraService(
    this.settings, {
    ProcessRunner? runner,
    String? bridgePath,
    String? python,
    bool? mock,
    Map<String, String>? environment,
  }) : _run = runner ?? _defaultRunner,
       _env = environment ?? Platform.environment,
       _bridgeOverride = bridgePath,
       _pythonOverride = python,
       _mockOverride = mock;

  final CameraSettings settings;
  final ProcessRunner _run;
  final Map<String, String> _env;
  final String? _bridgeOverride;
  final String? _pythonOverride;
  final bool? _mockOverride;

  /// bridge 的檔名;隨 App 一起發佈 (pubspec assets),也可裝在 /opt/spoonfull。
  static const bridgeFileName = 'realsense_bridge.py';

  /// 機台安裝路徑 (deploy/install-device.sh)。
  static const installedBridgePath = '/opt/spoonfull/$bridgeFileName';

  String get python => _pythonOverride ?? _env['SPOONFULL_PYTHON'] ?? 'python3';

  bool get mock => _mockOverride ?? _env['SPOONFULL_REALSENSE_MOCK'] == '1';

  /// 依序找 bridge:環境變數 → App bundle 內的 assets → 執行目錄的 deploy/
  /// (開發時 `flutter run`) → /opt/spoonfull。都沒有回 null。
  String? get bridgePath {
    final override = _bridgeOverride ?? _env['SPOONFULL_REALSENSE_BRIDGE'];
    if (override != null && override.isNotEmpty) {
      if (File(override).existsSync()) return override;
      Log.e('realsense bridge not found', override);
      return null;
    }
    for (final c in bridgeCandidates()) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  static List<String> bridgeCandidates() {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    return [
      p.join(exeDir, 'data', 'flutter_assets', 'deploy', bridgeFileName),
      p.join(Directory.current.path, 'deploy', bridgeFileName),
      installedBridgePath,
    ];
  }

  @override
  String get description {
    final serial = settings.device.isEmpty ? '' : ' 序號 ${settings.device}';
    return 'RealSense D435f RGB-D$serial${mock ? ' (模擬)' : ''}';
  }

  List<String> _commonArgs() => [
    if (mock) '--mock',
    if (settings.device.isNotEmpty) ...['--serial', settings.device],
  ];

  /// `--once` 的參數 (公開以便測試)。
  List<String> captureArgs(String rgb, String depth, String meta) => [
    bridgePath ?? bridgeFileName,
    '--once',
    rgb,
    depth,
    meta,
    '--width',
    '${settings.width}',
    '--height',
    '${settings.height}',
    '--warmup',
    '${math.max(0, settings.warmupFrames)}',
    '--timeout',
    '${math.max(1, AppConstants.captureTimeout.inSeconds - 5)}',
    ..._commonArgs(),
  ];

  List<String> probeArgs() => [
    bridgePath ?? bridgeFileName,
    '--probe',
    ..._commonArgs(),
  ];

  /// 偵測相機 (硬體設定頁的「偵測相機」)。找不到 / bridge 沒裝都丟 [AppException]。
  Future<RealSenseInfo> probe() async {
    if (bridgePath == null) {
      throw _cameraError(
        'CAMERA_UNAVAILABLE',
        'realsense_bridge.py not found in ${bridgeCandidates()}',
      );
    }
    final ProcessResult result;
    try {
      result = await _run(
        python,
        probeArgs(),
      ).timeout(AppConstants.cameraProbeTimeout + _runnerGrace);
    } on ProcessException catch (e) {
      throw _cameraError('CAMERA_UNAVAILABLE', '$python: ${e.message}');
    } on TimeoutException catch (e) {
      throw _cameraError('CAMERA_TIMEOUT', e);
    }
    final stderr = (result.stderr ?? '').toString().trim();
    if (result.exitCode == 2) {
      throw _cameraError('CAMERA_NOT_FOUND', stderr);
    }
    if (result.exitCode != 0) {
      throw _cameraError(
        'CAMERA_UNAVAILABLE',
        'probe exit ${result.exitCode}: $stderr',
      );
    }
    final json = _parseJsonLine(result.stdout.toString());
    if (json == null || json['found'] != true) {
      throw _cameraError('CAMERA_NOT_FOUND', result.stdout);
    }
    final info = RealSenseInfo.fromJson(json);
    Log.i('realsense probe: ${info.summary}');
    return info;
  }

  @override
  Future<RawCapture?> capture(String outputPath) async {
    final rgb = p.setExtension(outputPath, '.jpg');
    final depth = depthPathFor(rgb);
    final meta = depthMetaPathFor(rgb);
    final bridge = bridgePath;
    if (bridge == null) {
      throw _cameraError(
        'CAMERA_UNAVAILABLE',
        'realsense_bridge.py not found in ${bridgeCandidates()}',
      );
    }
    await File(rgb).parent.create(recursive: true);
    void discard() {
      for (final f in [rgb, depth, meta]) {
        try {
          File(f).deleteSync();
        } catch (_) {}
      }
    }

    final ProcessResult result;
    try {
      result = await _run(
        python,
        captureArgs(rgb, depth, meta),
      ).timeout(AppConstants.captureTimeout + _runnerGrace);
    } on ProcessException catch (e) {
      throw _cameraError('CAMERA_UNAVAILABLE', '$python: ${e.message}');
    } on TimeoutException catch (e) {
      discard();
      throw _cameraError('CAMERA_TIMEOUT', e);
    } on Object catch (e) {
      discard();
      throw _cameraError('CAMERA_FAILED', e);
    }

    final stderr = (result.stderr ?? '').toString().trim();
    if (result.exitCode != 0) {
      discard();
      throw _cameraError(switch (result.exitCode) {
        2 => 'CAMERA_NOT_FOUND',
        1 => 'CAMERA_UNAVAILABLE',
        _ => 'CAMERA_FAILED',
      }, 'bridge exit ${result.exitCode}: $stderr');
    }
    final rgbFile = File(rgb);
    final depthFile = File(depth);
    final metaFile = File(meta);
    if (!rgbFile.existsSync() || rgbFile.lengthSync() == 0) {
      discard();
      throw _cameraError('CAMERA_FAILED', 'bridge wrote no RGB file: $stderr');
    }
    if (!depthFile.existsSync() || !metaFile.existsSync()) {
      discard();
      throw _cameraError(
        'CAMERA_FAILED',
        'bridge wrote no depth / meta file: $stderr',
      );
    }
    // 深度圖必須是 16-bit 灰階 PNG,尺寸要和 meta 一致 (bridge 已對齊到 RGB)。
    final Map<String, Object?> metaJson;
    try {
      metaJson = (jsonDecode(await metaFile.readAsString()) as Map)
          .cast<String, Object?>();
    } on Object catch (e) {
      discard();
      throw _cameraError('CAMERA_FAILED', 'bad depth meta: $e');
    }
    final head = pngHeader(await _readHead(depthFile));
    final mw = (metaJson['width'] as num?)?.toInt();
    final mh = (metaJson['height'] as num?)?.toInt();
    if (head == null || head.bitDepth != 16 || head.colorType != 0) {
      discard();
      throw _cameraError('CAMERA_FAILED', 'depth is not a 16-bit gray PNG');
    }
    if (head.width != mw || head.height != mh) {
      discard();
      throw _cameraError(
        'CAMERA_FAILED',
        'depth ${head.width}x${head.height} != meta ${mw}x$mh',
      );
    }
    Log.i('realsense capture: ${result.stdout.toString().trim()}');
    return RawCapture(imagePath: rgb, depthPath: depth, depthMetaPath: meta);
  }

  static Future<List<int>> _readHead(File f) async {
    final raf = await f.open();
    try {
      return await raf.read(64);
    } finally {
      await raf.close();
    }
  }

  static Map<String, Object?>? _parseJsonLine(String stdout) {
    for (final line in stdout.split('\n').reversed) {
      final t = line.trim();
      if (!t.startsWith('{')) continue;
      try {
        return (jsonDecode(t) as Map).cast<String, Object?>();
      } catch (_) {}
    }
    return null;
  }

  /// 深度圖與 meta 的檔名慣例:`<照片去掉副檔名>_depth.png` / `_depth.json`。
  static String depthPathFor(String imagePath) =>
      '${p.withoutExtension(imagePath)}_depth.png';
  static String depthMetaPathFor(String imagePath) =>
      '${p.withoutExtension(imagePath)}_depth.json';
}

/// image_picker:Android / iOS 開相機,桌面平台為選擇檔案 (開發用)。
///
/// [filesOnly] 為 true 時一律選擇檔案 (行動裝置開相簿),給「選擇檔案」按鈕用。
class ImagePickerCameraService extends CameraService {
  ImagePickerCameraService({ImagePicker? picker, this.filesOnly = false})
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;
  final bool filesOnly;

  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// 這個 picker 實際會開相機 (而不是選檔)。
  bool get opensCamera =>
      !filesOnly && _picker.supportsImageSource(ImageSource.camera);

  @override
  String get description => opensCamera ? '系統相機' : '選擇圖片檔案 (無深度)';

  @override
  Future<RawCapture?> capture(String outputPath) async {
    if (opensCamera && _isMobile) {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        throw const AppException(AppErrorType.localValidation, '需要相機權限才能拍攝照片');
      }
    }
    final picked = await _picker.pickImage(
      source: opensCamera ? ImageSource.camera : ImageSource.gallery,
    );
    if (picked == null) return null;
    var ext = p.extension(picked.path).toLowerCase();
    if (ext != '.png') ext = '.jpg';
    final out = p.setExtension(outputPath, ext);
    await File(out).parent.create(recursive: true);
    await picked.saveTo(out);
    return RawCapture(imagePath: out);
  }
}

/// 模擬相機 (測試用):畫一個放在秤面上的餐盒 (四格、有紋理),品質檢查會通過。
/// [withDepth] 為 true 時連深度圖一起產生 (與 realsense_bridge.py --mock 相同格式)。
class MockCameraService extends CameraService {
  const MockCameraService({
    this.width = AppConstants.captureWidth,
    this.height = AppConstants.captureHeight,
    this.withTray = true,
    this.withDepth = false,
    this.seed = 42,
  });

  final int width;
  final int height;

  /// false 時只畫空秤面 (用來產生參考照或測試「餐盒不在畫面」)。
  final bool withTray;
  final bool withDepth;
  final int seed;

  @override
  String get description =>
      '模擬相機 (${width}x$height${withDepth ? ', RGB-D' : ''})';

  @override
  Future<RawCapture?> capture(String outputPath) async {
    final out = p.setExtension(outputPath, '.jpg');
    await File(out).parent.create(recursive: true);
    await File(out).writeAsBytes(
      img.encodeJpg(
        render(width, height, withTray: withTray, seed: seed),
        quality: 92,
      ),
      flush: true,
    );
    if (!withDepth) return RawCapture(imagePath: out);
    final depth = RealSenseCameraService.depthPathFor(out);
    final meta = RealSenseCameraService.depthMetaPathFor(out);
    await File(depth).writeAsBytes(
      img.encodePng(renderDepth(width, height, withTray: withTray)),
      flush: true,
    );
    await File(meta).writeAsString(
      jsonEncode({
        'format': 'spoonfull-rgbd/1',
        'mock': true,
        'serial': 'MOCK000000',
        'name': 'Intel RealSense D435f (mock)',
        'width': width,
        'height': height,
        'depth_unit_m': 0.001,
        'depth_aligned_to': 'color',
        'intrinsics': {
          'fx': width * 0.72,
          'fy': width * 0.72,
          'ppx': width / 2,
          'ppy': height / 2,
        },
      }),
      flush: true,
    );
    return RawCapture(imagePath: out, depthPath: depth, depthMetaPath: meta);
  }

  /// 對應 [render] 構圖的深度:秤面 600 mm,餐盒邊緣高 40 mm,格子裡的食物再凸起。
  static img.Image renderDepth(int width, int height, {bool withTray = true}) {
    final depth = img.Image(
      width: width,
      height: height,
      format: img.Format.uint16,
      numChannels: 1,
    );
    final x0 = (width * 0.22).round(), y0 = (height * 0.18).round();
    final x1 = (width * 0.78).round(), y1 = (height * 0.82).round();
    for (final px in depth) {
      var mm = 600.0;
      if (withTray && px.x >= x0 && px.x < x1 && px.y >= y0 && px.y < y1) {
        final inset = math.min(
          math.min(px.x - x0, x1 - 1 - px.x),
          math.min(px.y - y0, y1 - 1 - px.y),
        );
        mm = inset < 2 ? 0 : (inset < 6 ? 560 : 575);
      }
      px.r = mm.round();
    }
    return depth;
  }

  static img.Image render(
    int width,
    int height, {
    bool withTray = true,
    int seed = 42,
  }) {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(196, 198, 204));
    if (withTray) {
      final x0 = (width * 0.22).round(), y0 = (height * 0.18).round();
      final x1 = (width * 0.78).round(), y1 = (height * 0.82).round();
      img.fillRect(
        image,
        x1: x0,
        y1: y0,
        x2: x1,
        y2: y1,
        color: img.ColorRgb8(245, 245, 240),
      );
      final mx = (x0 + x1) ~/ 2, my = (y0 + y1) ~/ 2;
      final pad = (width * 0.015).round();
      final colors = [
        img.ColorRgb8(230, 226, 210), // 飯
        img.ColorRgb8(96, 150, 70), // 葉菜
        img.ColorRgb8(180, 110, 70), // 肉
        img.ColorRgb8(220, 170, 60), // 蛋
      ];
      final cells = [
        (x0 + pad, y0 + pad, mx - pad, my - pad),
        (mx + pad, y0 + pad, x1 - pad, my - pad),
        (x0 + pad, my + pad, mx - pad, y1 - pad),
        (mx + pad, my + pad, x1 - pad, y1 - pad),
      ];
      // 餐盒邊框與分隔線 (深色),模擬真實餐盒的強邊緣
      final rim = img.ColorRgb8(70, 70, 75);
      img.drawRect(
        image,
        x1: x0,
        y1: y0,
        x2: x1,
        y2: y1,
        color: rim,
        thickness: 3,
      );
      img.drawLine(
        image,
        x1: mx,
        y1: y0,
        x2: mx,
        y2: y1,
        color: rim,
        thickness: 3,
      );
      img.drawLine(
        image,
        x1: x0,
        y1: my,
        x2: x1,
        y2: my,
        color: rim,
        thickness: 3,
      );
      final cellCount = (width * height / 2500).round();
      for (var i = 0; i < cells.length; i++) {
        final (cx0, cy0, cx1, cy1) = cells[i];
        img.fillRect(
          image,
          x1: cx0,
          y1: cy0,
          x2: cx1,
          y2: cy1,
          color: colors[i],
        );
        final rnd = math.Random(seed + i);
        // 食物紋理:大量明暗不一的小圓 (飯粒、菜葉、肉塊)
        for (var k = 0; k < cellCount; k++) {
          final shade = rnd.nextInt(160) - 80;
          img.fillCircle(
            image,
            x: cx0 + rnd.nextInt(math.max(1, cx1 - cx0)),
            y: cy0 + rnd.nextInt(math.max(1, cy1 - cy0)),
            radius: 2 + rnd.nextInt(math.max(2, width ~/ 160)),
            color: img.ColorRgb8(
              (colors[i].r + shade).clamp(0, 255).toInt(),
              (colors[i].g + shade).clamp(0, 255).toInt(),
              (colors[i].b + shade).clamp(0, 255).toInt(),
            ),
          );
        }
      }
    }
    img.noise(image, 6, random: math.Random(seed));
    return image;
  }
}

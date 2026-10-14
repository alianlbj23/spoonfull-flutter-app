import 'dart:async';
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

/// 給現場人員看的訊息固定為三種;技術細節 ([detail]) 只寫進 log。
AppException _cameraError(String code, Object? detail) {
  Log.e('camera $code', detail);
  return AppException(AppErrorType.localValidation, switch (code) {
    'CAMERA_UNAVAILABLE' => '這台機器的相機還沒設定好,請聯絡管理員',
    'CAMERA_TIMEOUT' => '相機沒有回應,請確認相機的線有接好,再試一次',
    _ => '相機沒有拍到畫面,請確認相機的線有接好,再試一次',
  }, code: code);
}

/// 相機擷取:拍一張原始照片寫到指定路徑。壓縮與品質檢查由 [ImagePipeline] 負責。
abstract class CameraService {
  const CameraService();

  /// 擷取到 [outputPath] (副檔名由實作決定,回傳實際路徑);使用者取消時回 null。
  Future<String?> capture(String outputPath);

  /// 顯示在硬體設定頁的說明。
  String get description;

  Future<void> dispose() async {}

  /// 依設定建立相機。[CameraSource.auto] 依平台與 /dev 裝置自動判斷。
  static CameraService create(
    CameraSettings settings, {
    ProcessRunner? runner,
    ImagePicker? picker,
  }) {
    final source = settings.source == CameraSource.auto
        ? detectSource(settings)
        : settings.source;
    switch (source) {
      case CameraSource.v4l2:
      case CameraSource.nvargus:
        return GStreamerCameraService(
          settings.copyWith(source: source),
          runner: runner,
        );
      case CameraSource.libcamera:
        return LibcameraCameraService(settings, runner: runner);
      case CameraSource.picker:
        return ImagePickerCameraService(picker: picker);
      case CameraSource.folder:
        return FolderCameraService(settings.device);
      case CameraSource.mock:
        return MockCameraService(
          width: settings.width,
          height: settings.height,
        );
      case CameraSource.auto:
        return MockCameraService();
    }
  }

  /// 自動偵測 (只在 Linux 機台上有意義):
  /// 1. 設定的 V4L2 裝置存在 → v4l2;
  /// 2. Jetson (`/etc/nv_tegra_release`) → nvargus;
  /// 3. Raspberry Pi (`/proc/device-tree/model`) → libcamera;
  /// 4. 其他平台 → picker (Android/iOS 相機、桌面選檔)。
  static CameraSource detectSource(CameraSettings settings) {
    if (kIsWeb) return CameraSource.picker;
    if (!Platform.isLinux) return CameraSource.picker;
    try {
      if (File(settings.device).existsSync() ||
          File('/dev/video0').existsSync()) {
        return CameraSource.v4l2;
      }
      if (File('/etc/nv_tegra_release').existsSync()) {
        return CameraSource.nvargus;
      }
      final model = File('/proc/device-tree/model');
      if (model.existsSync() &&
          model.readAsStringSync().contains('Raspberry Pi')) {
        return CameraSource.libcamera;
      }
    } catch (e) {
      Log.i('camera auto-detect failed: $e');
    }
    return CameraSource.picker;
  }
}

/// GStreamer (`gst-launch-1.0`):USB 相機用 `v4l2src`,Jetson CSI 用 `nvarguscamerasrc`。
///
/// 連拍 [CameraSettings.warmupFrames]+1 張讓自動曝光穩定,只保留最後一張。
class GStreamerCameraService extends CameraService {
  GStreamerCameraService(this.settings, {ProcessRunner? runner})
    : _run = runner ?? _defaultRunner;

  final CameraSettings settings;
  final ProcessRunner _run;

  @override
  String get description => settings.source == CameraSource.nvargus
      ? 'GStreamer nvarguscamerasrc sensor-id=${settings.device}'
      : 'GStreamer v4l2src device=${settings.device}';

  /// 組出 pipeline 參數 (公開以便測試)。
  List<String> pipelineArgs(String pattern) {
    final frames = math.max(1, settings.warmupFrames + 1);
    final w = settings.width, h = settings.height;
    if (settings.source == CameraSource.nvargus) {
      final sensor = int.tryParse(settings.device) ?? 0;
      return [
        '-q',
        'nvarguscamerasrc',
        'sensor-id=$sensor',
        'num-buffers=$frames',
        '!',
        'video/x-raw(memory:NVMM),width=$w,height=$h,framerate=30/1',
        '!',
        'nvvidconv',
        '!',
        'video/x-raw,format=I420',
        '!',
        'jpegenc',
        'quality=92',
        '!',
        'multifilesink',
        'location=$pattern',
      ];
    }
    final caps = settings.mjpeg
        ? 'image/jpeg,width=$w,height=$h'
        : 'video/x-raw,width=$w,height=$h';
    return [
      '-q',
      'v4l2src',
      'device=${settings.device}',
      'num-buffers=$frames',
      '!',
      caps,
      '!',
      if (settings.mjpeg) ...[
        'jpegparse',
        '!',
      ] else ...[
        'videoconvert',
        '!',
        'jpegenc',
        'quality=92',
        '!',
      ],
      'multifilesink',
      'location=$pattern',
    ];
  }

  @override
  Future<String?> capture(String outputPath) async {
    final out = p.setExtension(outputPath, '.jpg');
    final dir = await Directory(
      p.join(Directory.systemTemp.path, 'spoonfull_cap'),
    ).create(recursive: true);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final pattern = p.join(dir.path, 'cap_${stamp}_%03d.jpg');

    List<File> frames() =>
        dir
            .listSync()
            .whereType<File>()
            .where((f) => p.basename(f.path).startsWith('cap_${stamp}_'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    void discard() {
      for (final f in frames()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }

    final ProcessResult result;
    try {
      result = await _run(
        'gst-launch-1.0',
        pipelineArgs(pattern),
      ).timeout(AppConstants.captureTimeout + _runnerGrace);
    } on ProcessException catch (e) {
      throw _cameraError('CAMERA_UNAVAILABLE', 'gst-launch-1.0: ${e.message}');
    } on TimeoutException catch (e) {
      discard();
      throw _cameraError('CAMERA_TIMEOUT', e);
    } on Object catch (e) {
      discard();
      throw _cameraError('CAMERA_FAILED', e);
    }

    final captured = frames();
    // 相機中途斷線時 gst-launch 會以錯誤結束,只留下前幾張暖機幀 (曝光還沒穩定),
    // 不能拿來當成品。
    final expected = math.max(1, settings.warmupFrames + 1);
    if (captured.isEmpty ||
        (result.exitCode != 0 && captured.length < expected)) {
      discard();
      throw _cameraError(
        'CAMERA_FAILED',
        'gst-launch-1.0 exit ${result.exitCode}, ${captured.length}/$expected '
            'frames: ${(result.stderr ?? '').toString().trim()}',
      );
    }
    final last = captured.removeLast();
    for (final f in captured) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
    await File(out).parent.create(recursive: true);
    try {
      await last.rename(out);
    } on FileSystemException {
      // 跨檔案系統時 rename 會失敗,改用複製。
      await last.copy(out);
      await last.delete();
    }
    return out;
  }
}

/// Raspberry Pi CSI 相機:`rpicam-still` (Bookworm) 或 `libcamera-still` (Bullseye)。
class LibcameraCameraService extends CameraService {
  LibcameraCameraService(this.settings, {ProcessRunner? runner})
    : _run = runner ?? _defaultRunner;

  final CameraSettings settings;
  final ProcessRunner _run;

  @override
  String get description => 'rpicam-still / libcamera-still';

  List<String> args(String out) => [
    '-n',
    '-t',
    '1500',
    '--width',
    '${settings.width}',
    '--height',
    '${settings.height}',
    '-q',
    '92',
    if (int.tryParse(settings.device) case final idx?) ...['--camera', '$idx'],
    '-o',
    out,
  ];

  @override
  Future<String?> capture(String outputPath) async {
    final out = p.setExtension(outputPath, '.jpg');
    await File(out).parent.create(recursive: true);
    Object? lastError;
    var found = false;
    for (final exe in ['rpicam-still', 'libcamera-still']) {
      try {
        final r = await _run(
          exe,
          args(out),
        ).timeout(AppConstants.captureTimeout + _runnerGrace);
        found = true;
        if (r.exitCode == 0 && File(out).existsSync()) return out;
        lastError =
            '$exe exit ${r.exitCode}: '
            '${(r.stderr ?? r.stdout ?? '').toString().trim()}';
      } on ProcessException catch (e) {
        // 這個指令沒裝,試下一個。
        lastError = '$exe: ${e.message}';
      } on TimeoutException catch (e) {
        // 相機卡住:換一個指令也一樣,不要讓使用者再等一輪。
        throw _cameraError('CAMERA_TIMEOUT', '$exe: $e');
      } on Object catch (e) {
        found = true;
        lastError = e;
      }
    }
    throw _cameraError(
      found ? 'CAMERA_FAILED' : 'CAMERA_UNAVAILABLE',
      lastError,
    );
  }
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
  String get description => opensCamera ? '系統相機' : '選擇圖片檔案';

  @override
  Future<String?> capture(String outputPath) async {
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
    return out;
  }
}

/// 測試圖片資料夾:每次拍照依檔名順序取下一張 (循環),複製到輸出路徑。
///
/// 用來在沒有相機時以真實照片走完整個上傳流程 (例如 RealSense 接上前,
/// 先用 `test_images/` 裡的照片測 server)。路徑可為相對路徑 (相對於執行目錄)。
class FolderCameraService extends CameraService {
  FolderCameraService(String path)
    : directory = Directory(
        path.trim().isEmpty || path.startsWith('/dev/')
            ? defaultFolder
            : path.trim(),
      );

  static const String defaultFolder = 'test_images';
  static const _extensions = {'.jpg', '.jpeg', '.png'};

  final Directory directory;
  int _next = 0;

  @override
  String get description => '測試圖片 ${directory.absolute.path}';

  List<File> listImages() {
    if (!directory.existsSync()) return const [];
    return directory
        .listSync()
        .whereType<File>()
        .where((f) => _extensions.contains(p.extension(f.path).toLowerCase()))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  @override
  Future<String?> capture(String outputPath) async {
    final files = listImages();
    if (files.isEmpty) {
      throw AppException(
        AppErrorType.localValidation,
        '測試圖片資料夾沒有 JPG / PNG:${directory.absolute.path}',
        code: 'CAMERA_UNAVAILABLE',
      );
    }
    final file = files[_next % files.length];
    _next = (_next + 1) % files.length;
    var ext = p.extension(file.path).toLowerCase();
    if (ext != '.png') ext = '.jpg';
    final out = p.setExtension(outputPath, ext);
    await File(out).parent.create(recursive: true);
    await file.copy(out);
    Log.i('folder camera: ${file.path}');
    return out;
  }
}

/// 模擬相機:畫一個放在秤面上的餐盒 (四格、有紋理),品質檢查會通過。
class MockCameraService extends CameraService {
  const MockCameraService({
    this.width = AppConstants.captureWidth,
    this.height = AppConstants.captureHeight,
    this.withTray = true,
    this.seed = 42,
  });

  final int width;
  final int height;

  /// false 時只畫空秤面 (用來產生參考照或測試「餐盒不在畫面」)。
  final bool withTray;
  final int seed;

  @override
  String get description => '模擬相機 (${width}x$height)';

  @override
  Future<String?> capture(String outputPath) async {
    final out = p.setExtension(outputPath, '.jpg');
    await File(out).parent.create(recursive: true);
    await File(out).writeAsBytes(
      img.encodeJpg(
        render(width, height, withTray: withTray, seed: seed),
        quality: 92,
      ),
      flush: true,
    );
    return out;
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

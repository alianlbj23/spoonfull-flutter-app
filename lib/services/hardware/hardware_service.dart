import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../config/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/logger.dart';
import '../../data/models/hardware_config.dart';
import '../../data/models/image_quality.dart';
import '../../data/models/weight_reading.dart';
import '../local_storage_service.dart';
import 'camera_service.dart';
import 'depth_image.dart';
import 'image_pipeline.dart';
import 'scale_service.dart';

typedef DirectoryProvider = Future<Directory> Function();

Future<Directory> _defaultDocumentsDir() => getApplicationDocumentsDirectory();

/// 照片來源:用設定好的相機拍,或由使用者選擇圖片檔案。
enum CaptureMethod { camera, file }

/// 一次「拍照 + 秤重」的結果。
class CaptureResult {
  const CaptureResult({
    required this.imagePath,
    required this.width,
    required this.height,
    required this.quality,
    this.depthPath,
    this.depthMetaPath,
    this.depth,
    this.weight,
    this.weightError,
    this.capturedAt,
  });

  final String imagePath;
  final int width;
  final int height;
  final ImageQualityReport quality;

  /// RealSense 的深度圖 (16-bit PNG, mm, 與 [imagePath] 逐像素對齊) 與 meta;
  /// 選擇圖片時為 null。
  final String? depthPath;
  final String? depthMetaPath;

  /// 深度圖統計 (有深度圖時)。
  final DepthStats? depth;

  bool get hasDepth => depthPath != null;

  /// 秤的穩定讀數;沒有秤或逾時沒讀到時為 null。
  final WeightReading? weight;

  /// 秤讀取失敗的原因 (裝置不存在等),顯示給操作者。
  final String? weightError;

  /// 快門時間 (相機拍到 / 使用者選好檔案的那一刻),上傳時當 capture_time。
  final DateTime? capturedAt;

  /// 秤上幾乎沒有重量 → 多半是餐盒沒放上去。
  bool get scaleLooksEmpty =>
      weight != null && weight!.grams < AppConstants.scaleEmptyThresholdG;
}

/// 機台硬體的統一入口:相機、秤、影像處理與空秤參考照。
///
/// 設定變更 ([apply]) 會重建相機與秤;測試可注入固定的 [camera] / [scale]。
class HardwareService {
  HardwareService({
    required this._storage,
    CameraService? camera,
    this._filePicker,
    ScaleService? scale,
    ImagePipeline? pipeline,
    DirectoryProvider? documentsDir,
  }) : _fixedCamera = camera,
       _fixedScale = scale,
       _pipeline = pipeline ?? const ImagePipeline(),
       _documentsDir = documentsDir ?? _defaultDocumentsDir {
    _camera = camera;
    _scale = scale;
  }

  final LocalStorageService _storage;
  final CameraService? _fixedCamera;
  CameraService? _filePicker;
  final ScaleService? _fixedScale;
  final ImagePipeline _pipeline;
  final DirectoryProvider _documentsDir;

  CameraService? _camera;
  ScaleService? _scale;

  HardwareConfig get config => _storage.hardwareConfig;

  CameraService get camera => _camera ??= CameraService.create(config.camera);

  /// 「選擇檔案」用的來源,與相機設定無關。
  CameraService get filePicker =>
      _filePicker ??= ImagePickerCameraService(filesOnly: true);

  /// 設定的相機能真的拍照;桌面平台的 picker 只能選檔,這時不必提供兩種選擇。
  bool get cameraAvailable {
    final cam = camera;
    return cam is! ImagePickerCameraService || cam.opensCamera;
  }

  /// 偵測 RealSense 相機 (硬體設定頁)。相機來源不是 RealSense 時回 null。
  Future<RealSenseInfo?> probeCamera() async {
    final cam = camera;
    if (cam is! RealSenseCameraService) return null;
    return cam.probe();
  }

  ScaleService get scale => _scale ??= ScaleService(
    ScaleReader.create(config.scale),
    settings: config.scale,
  );

  /// 儲存設定並重建相機與秤。
  Future<void> apply(HardwareConfig next) async {
    await _storage.saveHardwareConfig(next);
    if (_fixedCamera == null) {
      await _camera?.dispose();
      _camera = null;
    }
    if (_fixedScale == null) _scale = null;
  }

  /// 餐點照片的資料夾 (不存在時建立)。
  Future<Directory> imagesDirectory() async {
    final dir = Directory(p.join((await _documentsDir()).path, 'meal_images'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<String> _newImagePath() async =>
      p.join((await imagesDirectory()).path, '${const Uuid().v4()}.jpg');

  /// 拍照 (擷取 → 縮放壓縮 → 品質檢查) 並同時讀秤。
  /// [method] 為 [CaptureMethod.file] 時改由使用者選擇圖片檔案,後續處理相同。
  /// 使用者取消拍照時回 null。
  Future<CaptureResult?> capture({
    bool readWeight = true,
    CaptureMethod method = CaptureMethod.camera,
  }) async {
    final weightFuture = readWeight && scale.enabled
        ? _readWeightSafely()
        : Future.value(const _WeightOutcome(null, null));

    final target = await _newImagePath();
    final source = method == CaptureMethod.file ? filePicker : camera;
    final RawCapture? raw;
    try {
      raw = await source.capture('$target.raw');
    } on Object {
      // 仍等秤結束,避免裝置握把未釋放。
      await weightFuture;
      rethrow;
    }
    if (raw == null) {
      // 使用者取消:仍等秤結束,避免裝置握把未釋放。
      await weightFuture;
      return null;
    }
    // 快門時間:擷取完成的那一刻,不是之後壓縮、品質檢查或使用者按上傳的時間。
    final capturedAt = DateTime.now();
    final ProcessedCapture processed;
    try {
      processed = await _pipeline.process(
        sourcePath: raw.imagePath,
        outputPath: target,
        referencePath: config.referenceImagePath,
      );
    } on Object {
      await _discardDepth(raw);
      await weightFuture;
      rethrow;
    }
    final depth = await _keepDepth(raw, processed);
    final weight = await weightFuture;
    Log.i(
      'captured ${processed.path} ${processed.width}x${processed.height} '
      '${processed.quality} depth=${depth?.stats} weight=${weight.reading}',
    );
    return CaptureResult(
      imagePath: processed.path,
      width: processed.width,
      height: processed.height,
      quality: processed.quality,
      depthPath: depth?.path,
      depthMetaPath: depth?.metaPath,
      depth: depth?.stats,
      weight: weight.reading,
      weightError: weight.error,
      capturedAt: capturedAt,
    );
  }

  /// 深度圖搬到正式照片旁邊 (`<uuid>_depth.png` / `_depth.json`),並把統計寫進 meta。
  /// RGB 經 pipeline 縮放過 (尺寸與深度圖不同) 時深度就對不上,丟掉並記 log。
  Future<_KeptDepth?> _keepDepth(RawCapture raw, ProcessedCapture rgb) async {
    final rawDepth = raw.depthPath, rawMeta = raw.depthMetaPath;
    if (rawDepth == null || rawMeta == null) return null;
    final depthPath = RealSenseCameraService.depthPathFor(rgb.path);
    final metaPath = RealSenseCameraService.depthMetaPathFor(rgb.path);
    try {
      await _move(File(rawDepth), depthPath);
      await _move(File(rawMeta), metaPath);
      final stats = await _pipeline.analyzeDepth(depthPath);
      if (stats == null ||
          stats.width != rgb.width ||
          stats.height != rgb.height) {
        Log.e(
          'depth dropped',
          'depth ${stats?.width}x${stats?.height} != photo '
              '${rgb.width}x${rgb.height} (capture resolution too large?)',
        );
        await discardDepthFor(rgb.path);
        return null;
      }
      // meta 加上統計,上傳時整個檔案當 depth_meta 送出。
      final metaFile = File(metaPath);
      final meta = (jsonDecode(await metaFile.readAsString()) as Map)
          .cast<String, Object?>();
      meta['stats'] = stats.toJson();
      await metaFile.writeAsString(jsonEncode(meta), flush: true);
      return _KeptDepth(depthPath, metaPath, stats);
    } on Object catch (e) {
      Log.e('depth dropped', e);
      await _discardDepth(raw);
      await discardDepthFor(rgb.path);
      return null;
    }
  }

  static Future<void> _move(File from, String to) async {
    await File(to).parent.create(recursive: true);
    try {
      await from.rename(to);
    } on FileSystemException {
      // 跨檔案系統時 rename 會失敗,改用複製。
      await from.copy(to);
      await from.delete();
    }
  }

  Future<void> _discardDepth(RawCapture raw) async {
    for (final path in [raw.depthPath, raw.depthMetaPath]) {
      if (path == null) continue;
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  /// 刪掉照片對應的深度圖與 meta (照片本身由呼叫端處理)。
  static Future<void> discardDepthFor(String imagePath) async {
    for (final path in [
      RealSenseCameraService.depthPathFor(imagePath),
      RealSenseCameraService.depthMetaPathFor(imagePath),
    ]) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  Future<_WeightOutcome> _readWeightSafely() async {
    try {
      return _WeightOutcome(await scale.readStable(), null);
    } on Object catch (e) {
      final msg = e is AppException ? e.message : '秤讀取失敗: $e';
      Log.i('scale read failed: $e');
      return _WeightOutcome(null, msg);
    }
  }

  /// 單獨重新秤重 (確認畫面的「重新秤重」)。
  Future<WeightReading?> readWeight() {
    if (!scale.enabled) {
      throw const AppException(
        AppErrorType.localValidation,
        '尚未設定秤,請到硬體設定選擇秤的類型',
        code: 'SCALE_UNAVAILABLE',
      );
    }
    return scale.readStable();
  }

  /// 即時讀數 (硬體設定頁)。
  Stream<WeightReading> liveWeight() => scale.readings;

  /// 拍攝「空秤參考照」:秤上不放任何東西,之後用來判斷餐盒是否在畫面。
  Future<String> captureReference() async {
    final dir = Directory(p.join((await _documentsDir()).path, 'reference'));
    await dir.create(recursive: true);
    final target = p.join(dir.path, 'empty_scale.jpg');
    final raw = await camera.capture('$target.raw');
    if (raw == null) {
      throw const AppException(AppErrorType.localValidation, '已取消拍攝');
    }
    // 參考照只比對 RGB,深度不需要。
    await _discardDepth(raw);
    final processed = await _pipeline.process(
      sourcePath: raw.imagePath,
      outputPath: target,
    );
    await apply(config.copyWith(referenceImagePath: processed.path));
    return processed.path;
  }

  Future<void> clearReference() async {
    final path = config.referenceImagePath;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    await apply(config.copyWith(clearReference: true));
  }

  /// 測試拍照 (硬體設定頁):不讀秤,回傳處理後的照片與品質報告。
  Future<CaptureResult?> testCapture() => capture(readWeight: false);

  Future<void> dispose() async {
    await _camera?.dispose();
  }
}

class _KeptDepth {
  const _KeptDepth(this.path, this.metaPath, this.stats);
  final String path;
  final String metaPath;
  final DepthStats stats;
}

class _WeightOutcome {
  const _WeightOutcome(this.reading, this.error);
  final WeightReading? reading;
  final String? error;
}

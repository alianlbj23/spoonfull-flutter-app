import 'dart:async';
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
    this.weight,
    this.weightError,
  });

  final String imagePath;
  final int width;
  final int height;
  final ImageQualityReport quality;

  /// 秤的穩定讀數;沒有秤或逾時沒讀到時為 null。
  final WeightReading? weight;

  /// 秤讀取失敗的原因 (裝置不存在等),顯示給操作者。
  final String? weightError;

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

  Future<Directory> _imagesDir() async {
    final dir = Directory(p.join((await _documentsDir()).path, 'meal_images'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<String> _newImagePath() async =>
      p.join((await _imagesDir()).path, '${const Uuid().v4()}.jpg');

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
    final rawPath = await source.capture('$target.raw');
    if (rawPath == null) {
      // 使用者取消:仍等秤結束,避免裝置握把未釋放。
      await weightFuture;
      return null;
    }
    final processed = await _pipeline.process(
      sourcePath: rawPath,
      outputPath: target,
      referencePath: config.referenceImagePath,
    );
    final weight = await weightFuture;
    Log.i(
      'captured ${processed.path} ${processed.width}x${processed.height} '
      '${processed.quality} weight=${weight.reading}',
    );
    return CaptureResult(
      imagePath: processed.path,
      width: processed.width,
      height: processed.height,
      quality: processed.quality,
      weight: weight.reading,
      weightError: weight.error,
    );
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
    final dir = Directory(
      p.join((await _documentsDir()).path, 'reference'),
    );
    await dir.create(recursive: true);
    final target = p.join(dir.path, 'empty_scale.jpg');
    final rawPath = await camera.capture('$target.raw');
    if (rawPath == null) {
      throw const AppException(AppErrorType.localValidation, '已取消拍攝');
    }
    final processed = await _pipeline.process(
      sourcePath: rawPath,
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

class _WeightOutcome {
  const _WeightOutcome(this.reading, this.error);
  final WeightReading? reading;
  final String? error;
}

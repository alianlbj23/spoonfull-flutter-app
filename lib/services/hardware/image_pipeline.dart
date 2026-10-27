import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../config/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/image_quality_analyzer.dart';
import '../../core/utils/logger.dart';
import '../../data/models/image_quality.dart';
import 'depth_image.dart';

/// 處理後的照片:已縮放、重新編碼為 JPEG,並附品質檢查結果。
class ProcessedCapture {
  const ProcessedCapture({
    required this.path,
    required this.width,
    required this.height,
    required this.quality,
  });

  final String path;
  final int width;
  final int height;
  final ImageQualityReport quality;
}

/// 純 Dart 的影像結果 (不碰檔案,方便測試)。
class ProcessedBytes {
  const ProcessedBytes({
    required this.jpeg,
    required this.width,
    required this.height,
    required this.quality,
  });

  final Uint8List jpeg;
  final int width;
  final int height;
  final ImageQualityReport quality;
}

/// 拍照後的處理:解碼 → 套用 EXIF 方向 → 長邊縮到 1280 → JPEG 品質 80 → 品質檢查。
///
/// 解碼與編碼都是純 Dart,預設在背景 isolate 執行以免卡住觸控畫面。
class ImagePipeline {
  const ImagePipeline({this.useIsolate = true});

  final bool useIsolate;

  /// 讀取 [sourcePath],輸出到 [outputPath] (JPEG)。
  /// [referencePath] 為空秤參考照;[deleteSource] 為 true 時處理完刪除原檔。
  Future<ProcessedCapture> process({
    required String sourcePath,
    required String outputPath,
    String? referencePath,
    bool deleteSource = true,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const AppException(AppErrorType.localValidation, '找不到照片檔案');
    }
    final bytes = await source.readAsBytes();
    Uint8List? reference;
    if (referencePath != null) {
      final ref = File(referencePath);
      if (await ref.exists()) reference = await ref.readAsBytes();
    }

    final ProcessedBytes result;
    try {
      result = useIsolate
          ? await Isolate.run(() => processBytes(bytes, reference: reference))
          : processBytes(bytes, reference: reference);
      final out = File(outputPath);
      await out.parent.create(recursive: true);
      await out.writeAsBytes(result.jpeg, flush: true);
    } finally {
      // 解碼失敗也要刪掉原始檔,否則每次失敗都留下一個檔案。
      if (deleteSource && sourcePath != outputPath) {
        try {
          await source.delete();
        } catch (_) {}
      }
    }
    return ProcessedCapture(
      path: outputPath,
      width: result.width,
      height: result.height,
      quality: result.quality,
    );
  }

  /// 深度圖統計 (有效像素比例、中央距離);讀不到或不是 PNG 時回 null。
  Future<DepthStats?> analyzeDepth(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    try {
      return useIsolate
          ? await Isolate.run(() => DepthStats.analyze(bytes))
          : DepthStats.analyze(bytes);
    } on Object catch (e) {
      Log.i('depth analyze failed: $e');
      return null;
    }
  }

  /// 純函式:縮放、編碼並分析。可在任何 isolate 執行。
  static ProcessedBytes processBytes(
    Uint8List bytes, {
    Uint8List? reference,
    int maxLongSide = AppConstants.uploadMaxLongSide,
    int jpegQuality = AppConstants.uploadJpegQuality,
  }) {
    var image = img.decodeImage(bytes);
    if (image == null) {
      throw const AppException(
        AppErrorType.localValidation,
        '無法解碼照片,請重新拍攝',
        code: 'INVALID_IMAGE_FORMAT',
      );
    }
    image = img.bakeOrientation(image);
    image = resizeToLongSide(image, maxLongSide);

    GrayImage? refGray;
    if (reference != null) {
      final ref = img.decodeImage(reference);
      if (ref != null) {
        refGray = GrayImage.from(img.bakeOrientation(ref));
      }
    }
    final gray = GrayImage.from(image);
    // 參考照解析度不同時縮到相同尺寸再比對。
    if (refGray != null &&
        (refGray.width != gray.width || refGray.height != gray.height)) {
      refGray = null;
    }
    final quality = ImageQualityAnalyzer.analyze(gray, reference: refGray);

    final jpeg = img.encodeJpg(image, quality: jpegQuality);
    return ProcessedBytes(
      jpeg: jpeg,
      width: image.width,
      height: image.height,
      quality: quality,
    );
  }

  static img.Image resizeToLongSide(img.Image image, int maxLongSide) {
    final long = math.max(image.width, image.height);
    if (long <= maxLongSide) return image;
    final scale = maxLongSide / long;
    return img.copyResize(
      image,
      width: math.max(1, (image.width * scale).round()),
      height: math.max(1, (image.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
  }
}

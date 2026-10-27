import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../config/app_constants.dart';

/// 深度圖 (16-bit 灰階 PNG,單位 mm,0 = 沒有資料) 的基本統計,
/// 給硬體設定頁的測試拍照顯示,並隨 depth_meta 一起上傳。
class DepthStats {
  const DepthStats({
    required this.width,
    required this.height,
    required this.validRatio,
    required this.centerMedianMm,
  });

  final int width;
  final int height;

  /// 有深度資料 (非 0) 的像素比例,0–1。
  final double validRatio;

  /// 畫面中央 ROI (餐盒位置) 的有效深度中位數 (mm);沒有有效像素時為 null。
  final int? centerMedianMm;

  Map<String, Object?> toJson() => {
    'width': width,
    'height': height,
    'valid_ratio': double.parse(validRatio.toStringAsFixed(4)),
    'center_median_mm': centerMedianMm,
  };

  factory DepthStats.fromJson(Map<String, Object?> json) => DepthStats(
    width: (json['width'] as num?)?.toInt() ?? 0,
    height: (json['height'] as num?)?.toInt() ?? 0,
    validRatio: (json['valid_ratio'] as num?)?.toDouble() ?? 0,
    centerMedianMm: (json['center_median_mm'] as num?)?.toInt(),
  );

  @override
  String toString() =>
      'DepthStats(${width}x$height valid=${(validRatio * 100).toStringAsFixed(1)}% '
      'center=${centerMedianMm}mm)';

  /// 解碼 PNG 並統計。純函式,可在背景 isolate 執行;不是深度圖時回 null。
  static DepthStats? analyze(
    Uint8List pngBytes, {
    double roiFraction = AppConstants.qualityTrayRoiFraction,
  }) {
    final image = img.decodePng(pngBytes);
    if (image == null || image.width == 0 || image.height == 0) return null;
    final w = image.width, h = image.height;
    var valid = 0;
    final rx0 = (w * (1 - roiFraction) / 2).floor();
    final ry0 = (h * (1 - roiFraction) / 2).floor();
    final rx1 = w - rx0, ry1 = h - ry0;
    // 直方圖求中位數,避免排序整張 ROI。
    final hist = Uint32List(65536);
    var roiValid = 0;
    for (final px in image) {
      final v = px.r.toInt();
      if (v == 0) continue;
      valid++;
      if (px.x >= rx0 && px.x < rx1 && px.y >= ry0 && px.y < ry1) {
        hist[v.clamp(0, 65535)]++;
        roiValid++;
      }
    }
    int? median;
    if (roiValid > 0) {
      final target = (roiValid + 1) ~/ 2;
      var acc = 0;
      for (var v = 1; v < hist.length; v++) {
        acc += hist[v];
        if (acc >= target) {
          median = v;
          break;
        }
      }
    }
    return DepthStats(
      width: w,
      height: h,
      validRatio: valid / (w * h),
      centerMedianMm: median,
    );
  }
}

/// 只讀 PNG 表頭 (IHDR) 取得尺寸與位元深度,不解碼整張圖。不是 PNG 時回 null。
({int width, int height, int bitDepth, int colorType})? pngHeader(
  List<int> bytes,
) {
  if (bytes.length < 29) return null;
  const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < sig.length; i++) {
    if (bytes[i] != sig[i]) return null;
  }
  // bytes 12..16 = 'IHDR'
  if (bytes[12] != 0x49 ||
      bytes[13] != 0x48 ||
      bytes[14] != 0x44 ||
      bytes[15] != 0x52) {
    return null;
  }
  int be32(int o) =>
      (bytes[o] << 24) |
      (bytes[o + 1] << 16) |
      (bytes[o + 2] << 8) |
      bytes[o + 3];
  return (
    width: be32(16),
    height: be32(20),
    bitDepth: bytes[24],
    colorType: bytes[25],
  );
}

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../config/app_constants.dart';
import '../../data/models/image_quality.dart';

/// 8-bit 灰階影像 (分析用縮圖)。
class GrayImage {
  const GrayImage(this.width, this.height, this.data);

  final int width;
  final int height;

  /// row-major,長度 width*height。
  final Uint8List data;

  int at(int x, int y) => data[y * width + x];

  /// 由彩色影像縮放成寬 [targetWidth] 的灰階圖。
  factory GrayImage.from(img.Image source, {int? targetWidth}) {
    var image = source;
    final tw = targetWidth ?? AppConstants.qualityAnalysisWidth;
    if (image.width > tw) {
      final th = math.max(1, (image.height * tw / image.width).round());
      image = img.copyResize(
        image,
        width: tw,
        height: th,
        interpolation: img.Interpolation.average,
      );
    }
    if (image.format != img.Format.uint8 || image.numChannels < 3) {
      image = image.convert(format: img.Format.uint8, numChannels: 3);
    }
    final data = Uint8List(image.width * image.height);
    var i = 0;
    for (final p in image) {
      data[i++] = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b)
          .round()
          .clamp(0, 255);
    }
    return GrayImage(image.width, image.height, data);
  }

  /// 3x3 平均濾波:抑制感光元件雜訊,讓邊緣與清晰度指標不被雜訊灌水。
  GrayImage boxBlur3() {
    if (width < 3 || height < 3) return this;
    final out = Uint8List(width * height);
    for (var y = 0; y < height; y++) {
      final y0 = math.max(0, y - 1), y1 = math.min(height - 1, y + 1);
      for (var x = 0; x < width; x++) {
        final x0 = math.max(0, x - 1), x1 = math.min(width - 1, x + 1);
        var sum = 0, n = 0;
        for (var yy = y0; yy <= y1; yy++) {
          final row = yy * width;
          for (var xx = x0; xx <= x1; xx++) {
            sum += data[row + xx];
            n++;
          }
        }
        out[y * width + x] = (sum / n).round();
      }
    }
    return GrayImage(width, height, out);
  }
}

/// 畫面中央的矩形區域 (餐盒固定放在秤面上,也就是畫面中央)。
class _Roi {
  _Roi(GrayImage g, double fraction)
    : x0 = ((1 - fraction) / 2 * g.width).floor(),
      y0 = ((1 - fraction) / 2 * g.height).floor(),
      x1 = ((1 + fraction) / 2 * g.width).ceil().clamp(0, g.width),
      y1 = ((1 + fraction) / 2 * g.height).ceil().clamp(0, g.height);

  final int x0, y0, x1, y1;
  bool contains(int x, int y) => x >= x0 && x < x1 && y >= y0 && y < y1;
}

/// 純 CPU 的拍照品質檢查 (ARCHITECTURE.md §5.1)。
///
/// 所有數值皆以縮到 [AppConstants.qualityAnalysisWidth] 的灰階圖計算,
/// 門檻在 [AppConstants] 中集中管理,方便依現場相機調整。
class ImageQualityAnalyzer {
  ImageQualityAnalyzer._();

  /// [reference] 為空秤參考照 (同一相機、同一角度、秤上沒有東西) 的灰階圖;
  /// 有參考照時以差異判斷餐盒是否在畫面,沒有時退回用 ROI 邊緣密度。
  static ImageQualityReport analyze(GrayImage g, {GrayImage? reference}) {
    final n = g.data.length;
    if (n == 0 || g.width < 3 || g.height < 3) {
      return const ImageQualityReport(
        meanLuma: 0,
        darkRatio: 1,
        brightRatio: 0,
        blurScore: 0,
        trayScore: 0,
        trayScoreMethod: 'edges',
        roiContrast: 0,
        issues: [QualityIssue.tooDark, QualityIssue.trayMissing],
      );
    }

    // --- 亮度 (用原始灰階) ---
    var sum = 0;
    var dark = 0;
    var bright = 0;
    for (final v in g.data) {
      sum += v;
      if (v < 40) dark++;
      if (v > 235) bright++;
    }
    final mean = sum / n;
    final darkRatio = dark / n;
    final brightRatio = bright / n;

    // --- 清晰度:平滑後的 Laplacian 變異數;同時累積 ROI 內的邊緣密度 ---
    final s = g.boxBlur3();
    final roi = _Roi(g, AppConstants.qualityTrayRoiFraction);
    var lapSum = 0.0;
    var lapSq = 0.0;
    var lapCount = 0;
    var roiEdges = 0;
    var roiCount = 0;
    var roiSum = 0.0;
    var roiSq = 0.0;
    for (var y = 1; y < s.height - 1; y++) {
      final row = y * s.width;
      for (var x = 1; x < s.width - 1; x++) {
        final i = row + x;
        final v = s.data[i];
        final lap =
            4 * v -
            s.data[i - 1] -
            s.data[i + 1] -
            s.data[i - s.width] -
            s.data[i + s.width];
        lapSum += lap;
        lapSq += lap * lap;
        lapCount++;
        if (roi.contains(x, y)) {
          roiCount++;
          roiSum += v;
          roiSq += v * v;
          if (lap.abs() > AppConstants.qualityEdgeLaplacianMin) roiEdges++;
        }
      }
    }
    final lapMean = lapSum / lapCount;
    final blurScore = lapSq / lapCount - lapMean * lapMean;
    // ROI 亮度標準差:餐盒 (多格不同顏色) 即使拍糊了對比仍高,空秤面則接近 0。
    final roiMean = roiCount == 0 ? 0.0 : roiSum / roiCount;
    final roiVar = roiCount == 0 ? 0.0 : roiSq / roiCount - roiMean * roiMean;
    final roiContrast = math.sqrt(math.max(0, roiVar));

    // --- 餐盒是否在畫面 ---
    double trayScore;
    String method;
    bool trayPresent;
    if (reference != null &&
        reference.width == g.width &&
        reference.height == g.height) {
      final r = reference.boxBlur3();
      var diff = 0;
      var count = 0;
      for (var y = roi.y0; y < roi.y1; y++) {
        for (var x = roi.x0; x < roi.x1; x++) {
          diff += (s.at(x, y) - r.at(x, y)).abs();
          count++;
        }
      }
      trayScore = count == 0 ? 0 : diff / count;
      method = 'reference';
      trayPresent = trayScore >= AppConstants.qualityTrayRefDiffMin;
    } else {
      trayScore = roiCount == 0 ? 0 : roiEdges / roiCount;
      method = 'edges';
      // 邊緣夠多 (清晰的餐盒) 或對比夠高 (拍糊的餐盒) 都算有餐盒。
      trayPresent =
          trayScore >= AppConstants.qualityTrayEdgeDensityMin ||
          roiContrast >= AppConstants.qualityTrayContrastMin;
    }

    final issues = <QualityIssue>[];
    final tooDark =
        mean < AppConstants.qualityDarkMeanLuma ||
        darkRatio > AppConstants.qualityDarkPixelRatio;
    final tooBright =
        mean > AppConstants.qualityBrightMeanLuma ||
        brightRatio > AppConstants.qualityBrightPixelRatio;
    if (tooDark) issues.add(QualityIssue.tooDark);
    if (tooBright) issues.add(QualityIssue.tooBright);
    // 過暗 / 過亮時影像本身就缺乏細節,模糊與餐盒判斷不可靠,不重複提示。
    // 沒有餐盒時畫面本來就沒有細節,只提示「餐盒不在畫面」,不再說模糊。
    if (!tooDark && !tooBright) {
      if (!trayPresent) {
        issues.add(QualityIssue.trayMissing);
      } else if (blurScore < AppConstants.qualityBlurVarianceMin) {
        issues.add(QualityIssue.blurry);
      }
    }

    return ImageQualityReport(
      meanLuma: mean,
      darkRatio: darkRatio,
      brightRatio: brightRatio,
      blurScore: blurScore,
      trayScore: trayScore,
      trayScoreMethod: method,
      roiContrast: roiContrast,
      issues: issues,
    );
  }
}

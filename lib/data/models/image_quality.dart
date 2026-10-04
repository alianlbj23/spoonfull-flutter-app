/// 拍照品質問題 (ARCHITECTURE.md §5.1:過暗、過亮、模糊、餐盒不在畫面)。
enum QualityIssue {
  tooDark('照片過暗,請開補光燈後重拍'),
  tooBright('照片過亮,請調整補光或角度後重拍'),
  blurry('照片模糊,請穩定相機後重拍'),
  trayMissing('畫面中沒有餐盒,請把餐盒放到秤上後重拍');

  const QualityIssue(this.message);
  final String message;

  static QualityIssue? tryParse(String? v) {
    for (final i in QualityIssue.values) {
      if (i.name == v) return i;
    }
    return null;
  }
}

/// 品質檢查結果。數值一律以縮圖 (寬 320) 計算,門檻見 AppConstants。
class ImageQualityReport {
  const ImageQualityReport({
    required this.meanLuma,
    required this.darkRatio,
    required this.brightRatio,
    required this.blurScore,
    required this.trayScore,
    required this.trayScoreMethod,
    this.roiContrast = 0,
    required this.issues,
  });

  /// 平均亮度 0-255。
  final double meanLuma;

  /// 亮度 < 40 的像素比例。
  final double darkRatio;

  /// 亮度 > 235 的像素比例。
  final double brightRatio;

  /// Laplacian 變異數,越大越清晰。
  final double blurScore;

  /// 餐盒存在分數:`reference` 時為與空秤參考照的平均絕對差;`edges` 時為 ROI 邊緣密度。
  final double trayScore;
  final String trayScoreMethod;

  /// ROI 亮度標準差 (餐盒對比),`edges` 方法的輔助判斷。
  final double roiContrast;
  final List<QualityIssue> issues;

  bool get passed => issues.isEmpty;
  bool get trayDetected => !issues.contains(QualityIssue.trayMissing);

  Map<String, Object?> toJson() => {
    'mean_luma': _round(meanLuma),
    'dark_ratio': _round(darkRatio),
    'bright_ratio': _round(brightRatio),
    'blur_score': _round(blurScore),
    'tray_score': _round(trayScore),
    'tray_score_method': trayScoreMethod,
    'roi_contrast': _round(roiContrast),
    'tray_detected': trayDetected,
    'issues': [for (final i in issues) i.name],
  };

  factory ImageQualityReport.fromJson(Map<String, Object?> json) =>
      ImageQualityReport(
        meanLuma: (json['mean_luma'] as num?)?.toDouble() ?? 0,
        darkRatio: (json['dark_ratio'] as num?)?.toDouble() ?? 0,
        brightRatio: (json['bright_ratio'] as num?)?.toDouble() ?? 0,
        blurScore: (json['blur_score'] as num?)?.toDouble() ?? 0,
        trayScore: (json['tray_score'] as num?)?.toDouble() ?? 0,
        trayScoreMethod: json['tray_score_method'] as String? ?? 'edges',
        roiContrast: (json['roi_contrast'] as num?)?.toDouble() ?? 0,
        issues: [
          for (final v in (json['issues'] as List? ?? const []))
            ?QualityIssue.tryParse(v?.toString()),
        ],
      );

  static double _round(double v) => (v * 1000).roundToDouble() / 1000;

  @override
  String toString() =>
      'Quality(luma ${meanLuma.toStringAsFixed(0)}, '
      'blur ${blurScore.toStringAsFixed(1)}, '
      'tray ${trayScore.toStringAsFixed(2)}/$trayScoreMethod, issues $issues)';
}

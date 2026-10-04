/// 重量來源 (隨紀錄上傳給 server 參考)。
enum WeightSource {
  /// 由秤自動讀取。
  scale,

  /// 操作者手動輸入。
  manual,

  /// 沒有重量,server 以菜單標準份量估算。
  none;

  static WeightSource parse(String? v) =>
      WeightSource.values.firstWhere((s) => s.name == v, orElse: () => none);
}

/// 一筆秤的讀數 (已換算為公克)。
class WeightReading {
  const WeightReading({
    required this.grams,
    required this.stable,
    this.at,
    this.raw,
  });

  final double grams;

  /// 由秤回報或由連續讀數判定為穩定。
  final bool stable;
  final DateTime? at;

  /// 原始資料 (除錯用)。
  final String? raw;

  WeightReading copyWith({double? grams, bool? stable, DateTime? at}) =>
      WeightReading(
        grams: grams ?? this.grams,
        stable: stable ?? this.stable,
        at: at ?? this.at,
        raw: raw,
      );

  @override
  String toString() =>
      'WeightReading(${grams.toStringAsFixed(1)} g, stable: $stable)';
}

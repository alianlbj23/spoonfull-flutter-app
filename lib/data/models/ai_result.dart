import '../../core/utils/time_utils.dart';

/// AI 辨識結構化結果 (規格 4.3 ai_result)。
class AiResult {
  const AiResult({
    this.hasFood,
    this.hasPerson,
    this.leftoverPercentage,
    this.confidence,
    this.note,
  });

  final bool? hasFood;
  final bool? hasPerson;

  /// 0-100
  final double? leftoverPercentage;

  /// 0-1
  final double? confidence;
  final String? note;

  factory AiResult.fromJson(Map<String, Object?> json) => AiResult(
    hasFood: json['has_food'] as bool?,
    hasPerson: json['has_person'] as bool?,
    leftoverPercentage: asDouble(json['leftover_percentage']),
    confidence: asDouble(json['confidence']),
    note: asString(json['note']),
  );

  Map<String, Object?> toJson() => {
    'has_food': hasFood,
    'has_person': hasPerson,
    'leftover_percentage': leftoverPercentage,
    'confidence': confidence,
    'note': note,
  };
}

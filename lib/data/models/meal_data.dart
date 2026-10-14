import 'dart:convert';

import '../../core/utils/time_utils.dart';

enum MealType {
  breakfast('早餐'),
  lunch('午餐'),
  dinner('晚餐'),
  snack('點心');

  const MealType(this.label);
  final String label;

  /// 票券直式標題用的單字:早/午/晚/點。
  String get shortLabel => label.substring(0, 1);

  static MealType parse(String? value) => MealType.values.firstWhere(
    (t) => t.name == value,
    orElse: () => MealType.snack,
  );
}

/// 膳食 (規格 3.1.4)。
class MealData {
  const MealData({
    required this.placeId,
    required this.mealId,
    required this.mealName,
    required this.mealType,
    this.mealTimeSlot,
    this.assignedPatientIds = const [],
    required this.lastUpdated,
  });

  final String placeId;
  final String mealId;
  final String mealName;
  final MealType mealType;

  /// 這份膳食屬於哪個時段 (`time_slot_id`,如 `lunch`);舊版 server 沒給時為 null。
  final String? mealTimeSlot;

  /// server 指派這份膳食的住民 (patient_id);用來預選該住民的餐。
  final List<String> assignedPatientIds;
  final int lastUpdated;

  bool isAssignedTo(String? patientId) =>
      patientId != null && assignedPatientIds.contains(patientId);

  static List<String> _ids(Object? value) =>
      value is List ? [for (final v in value) '$v'] : const [];

  factory MealData.fromApi(Map<String, Object?> json) => MealData(
    placeId: asString(json['place_id']) ?? '',
    mealId: asString(json['meal_id']) ?? '',
    mealName: asString(json['meal_name']) ?? '',
    mealType: MealType.parse(asString(json['meal_type'])),
    mealTimeSlot: asString(json['meal_time_slot']),
    assignedPatientIds: _ids(json['assigned_patient_ids']),
    lastUpdated: asInt(json['updated_at']) ?? nowUnix(),
  );

  factory MealData.fromDb(Map<String, Object?> row) => MealData(
    placeId: row['place_id'] as String,
    mealId: row['meal_id'] as String,
    mealName: row['meal_name'] as String,
    mealType: MealType.parse(row['meal_type'] as String?),
    mealTimeSlot: row['meal_time_slot'] as String?,
    assignedPatientIds: _decodeIds(row['assigned_patient_ids'] as String?),
    lastUpdated: row['last_updated'] as int,
  );

  static List<String> _decodeIds(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      return _ids(jsonDecode(raw));
    } on FormatException {
      return const [];
    }
  }

  Map<String, Object?> toDb() => {
    'place_id': placeId,
    'meal_id': mealId,
    'meal_name': mealName,
    'meal_type': mealType.name,
    'meal_time_slot': mealTimeSlot,
    'assigned_patient_ids': jsonEncode(assignedPatientIds),
    'last_updated': lastUpdated,
  };
}

/// 用餐時段 (規格 4.2 meal_data.time_slots)。
class TimeSlot {
  const TimeSlot({
    required this.timeSlotId,
    required this.timeSlotName,
    required this.startTime,
    required this.endTime,
    this.sortOrder = 0,
  });

  final String timeSlotId;
  final String timeSlotName;

  /// HH:MM
  final String startTime;
  final String endTime;
  final int sortOrder;

  int get startMinutes => _minutes(startTime);
  int get endMinutes => _minutes(endTime);

  bool contains(DateTime time) {
    final m = time.hour * 60 + time.minute;
    return m >= startMinutes && m <= endMinutes;
  }

  /// API 的時段沒有標示餐別,依開始時間推估 (早 <10:30、午 <15:00、晚 <21:00)。
  MealType get inferredMealType {
    final m = startMinutes;
    if (m < 10 * 60 + 30) return MealType.breakfast;
    if (m < 15 * 60) return MealType.lunch;
    if (m < 21 * 60) return MealType.dinner;
    return MealType.snack;
  }

  static int _minutes(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length < 2) return 0;
    return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
  }

  factory TimeSlot.fromApi(Map<String, Object?> json, int order) => TimeSlot(
    timeSlotId: asString(json['time_slot_id']) ?? '',
    timeSlotName: asString(json['time_slot_name']) ?? '',
    startTime: asString(json['start_time']) ?? '00:00',
    endTime: asString(json['end_time']) ?? '23:59',
    sortOrder: order,
  );

  factory TimeSlot.fromDb(Map<String, Object?> row) => TimeSlot(
    timeSlotId: row['time_slot_id'] as String,
    timeSlotName: row['time_slot_name'] as String,
    startTime: row['start_time'] as String,
    endTime: row['end_time'] as String,
    sortOrder: row['sort_order'] as int,
  );

  Map<String, Object?> toDb(String placeId) => {
    'place_id': placeId,
    'time_slot_id': timeSlotId,
    'time_slot_name': timeSlotName,
    'start_time': startTime,
    'end_time': endTime,
    'sort_order': sortOrder,
  };
}

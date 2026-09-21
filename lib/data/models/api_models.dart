import '../../core/utils/time_utils.dart';
import 'ai_result.dart';
import 'bed_data.dart';
import 'meal_data.dart';
import 'room_data.dart';

/// device_pair.php 成功回應。
class PairingResult {
  const PairingResult({
    required this.deviceId,
    required this.deviceToken,
    this.tokenType = 'Bearer',
    this.expiresIn,
    this.message,
  });

  final String deviceId;
  final String deviceToken;
  final String tokenType;
  final int? expiresIn;
  final String? message;

  factory PairingResult.fromJson(Map<String, Object?> json) => PairingResult(
    deviceId: asString(json['device_id']) ?? '',
    deviceToken: asString(json['device_token']) ?? '',
    tokenType: asString(json['token_type']) ?? 'Bearer',
    expiresIn: asInt(json['expires_in']),
    message: asString(json['message']),
  );
}

class RoomsResponse {
  const RoomsResponse(this.rooms, this.timestamp);
  final List<RoomData> rooms;
  final int timestamp;
}

class BedsResponse {
  const BedsResponse(this.beds, this.timestamp);
  final List<BedData> beds;
  final int timestamp;
}

class MealsResponse {
  const MealsResponse(this.meals, this.timeSlots, this.timestamp);
  final List<MealData> meals;
  final List<TimeSlot> timeSlots;
  final int timestamp;
}

/// meal_record.php 上傳參數。
class MealRecordUpload {
  const MealRecordUpload({
    required this.imagePath,
    required this.bedId,
    required this.patientId,
    required this.mealId,
    required this.mealTimeSlot,
    required this.beforeAfter,
    required this.captureTime,
    required this.deviceId,
  });

  final String imagePath;
  final String bedId;
  final String patientId;
  final String mealId;
  final String mealTimeSlot;
  final String beforeAfter;
  final int captureTime;
  final String deviceId;

  Map<String, String> get fields => {
    'bed_id': bedId,
    'patient_id': patientId,
    'meal_id': mealId,
    'meal_time_slot': mealTimeSlot,
    'before_after': beforeAfter,
    'capture_time': '$captureTime',
    'device_id': deviceId,
  };

  Map<String, Object?> toJson() => {...fields, 'image_path': imagePath};

  factory MealRecordUpload.fromJson(Map<String, Object?> json) =>
      MealRecordUpload(
        imagePath: json['image_path'] as String,
        bedId: json['bed_id'] as String,
        patientId: json['patient_id'] as String,
        mealId: json['meal_id'] as String,
        mealTimeSlot: json['meal_time_slot'] as String,
        beforeAfter: json['before_after'] as String,
        captureTime: asInt(json['capture_time']) ?? 0,
        deviceId: json['device_id'] as String,
      );
}

/// meal_record.php 成功回應。
class MealRecordResult {
  const MealRecordResult({
    required this.recordId,
    this.imagePath,
    this.captureTime,
    required this.aiStatus,
    this.aiResult,
    this.createdAt,
  });

  final String recordId;
  final String? imagePath;
  final int? captureTime;
  final String aiStatus;
  final AiResult? aiResult;
  final int? createdAt;

  factory MealRecordResult.fromJson(Map<String, Object?> json) {
    final ai = json['ai_result'];
    return MealRecordResult(
      recordId: asString(json['record_id']) ?? '',
      imagePath: asString(json['image_path']),
      captureTime: asInt(json['capture_time']),
      aiStatus: asString(json['ai_status']) ?? 'pending',
      aiResult: ai is Map
          ? AiResult.fromJson(ai.cast<String, Object?>())
          : null,
      createdAt: asInt(json['created_at']),
    );
  }
}

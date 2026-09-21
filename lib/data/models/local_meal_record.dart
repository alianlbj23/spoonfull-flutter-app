import 'dart:convert';

import 'ai_result.dart';

enum MealPhase {
  before('餐前'),
  after('餐後');

  const MealPhase(this.label);
  final String label;

  static MealPhase parse(String? v) =>
      v == 'after' ? MealPhase.after : MealPhase.before;
}

enum AiStatus {
  pending,
  processing,
  completed,
  failed;

  static AiStatus parse(String? v) =>
      AiStatus.values.firstWhere((s) => s.name == v, orElse: () => pending);
}

enum SyncStatus {
  pending,
  synced,
  failed;

  static SyncStatus parse(String? v) =>
      SyncStatus.values.firstWhere((s) => s.name == v, orElse: () => pending);
}

/// 本機食物紀錄 (規格 3.1.5)。
class LocalMealRecord {
  const LocalMealRecord({
    required this.localId,
    this.recordId,
    required this.bedId,
    required this.patientId,
    required this.mealId,
    required this.mealTimeSlot,
    required this.beforeAfter,
    required this.imagePath,
    required this.captureTime,
    this.aiStatus = AiStatus.pending,
    this.aiResult,
    this.syncStatus = SyncStatus.pending,
    this.syncAttempts = 0,
    required this.createdAt,
    required this.updatedAt,
    this.errorMessage,
  });

  final String localId;

  /// 伺服器端 ID,尚未同步時為 null。
  final String? recordId;
  final String bedId;
  final String patientId;
  final String mealId;
  final String mealTimeSlot;
  final MealPhase beforeAfter;
  final String imagePath;
  final int captureTime;
  final AiStatus aiStatus;
  final AiResult? aiResult;
  final SyncStatus syncStatus;
  final int syncAttempts;
  final int createdAt;
  final int updatedAt;

  /// 最近一次上傳失敗原因 (僅本機顯示用)。
  final String? errorMessage;

  LocalMealRecord copyWith({
    String? recordId,
    AiStatus? aiStatus,
    AiResult? aiResult,
    SyncStatus? syncStatus,
    int? syncAttempts,
    int? updatedAt,
    String? errorMessage,
    bool clearError = false,
  }) {
    return LocalMealRecord(
      localId: localId,
      recordId: recordId ?? this.recordId,
      bedId: bedId,
      patientId: patientId,
      mealId: mealId,
      mealTimeSlot: mealTimeSlot,
      beforeAfter: beforeAfter,
      imagePath: imagePath,
      captureTime: captureTime,
      aiStatus: aiStatus ?? this.aiStatus,
      aiResult: aiResult ?? this.aiResult,
      syncStatus: syncStatus ?? this.syncStatus,
      syncAttempts: syncAttempts ?? this.syncAttempts,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  factory LocalMealRecord.fromDb(Map<String, Object?> row) {
    final ai = row['ai_result'] as String?;
    return LocalMealRecord(
      localId: row['local_id'] as String,
      recordId: row['record_id'] as String?,
      bedId: row['bed_id'] as String,
      patientId: row['patient_id'] as String,
      mealId: row['meal_id'] as String,
      mealTimeSlot: row['meal_time_slot'] as String,
      beforeAfter: MealPhase.parse(row['before_after'] as String?),
      imagePath: row['image_path'] as String,
      captureTime: row['capture_time'] as int,
      aiStatus: AiStatus.parse(row['ai_status'] as String?),
      aiResult: ai == null
          ? null
          : AiResult.fromJson(jsonDecode(ai) as Map<String, Object?>),
      syncStatus: SyncStatus.parse(row['sync_status'] as String?),
      syncAttempts: row['sync_attempts'] as int,
      createdAt: row['created_at'] as int,
      updatedAt: row['updated_at'] as int,
      errorMessage: row['error_message'] as String?,
    );
  }

  Map<String, Object?> toDb() => {
    'local_id': localId,
    'record_id': recordId,
    'bed_id': bedId,
    'patient_id': patientId,
    'meal_id': mealId,
    'meal_time_slot': mealTimeSlot,
    'before_after': beforeAfter.name,
    'image_path': imagePath,
    'capture_time': captureTime,
    'ai_status': aiStatus.name,
    'ai_result': aiResult == null ? null : jsonEncode(aiResult!.toJson()),
    'sync_status': syncStatus.name,
    'sync_attempts': syncAttempts,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'error_message': errorMessage,
  };
}

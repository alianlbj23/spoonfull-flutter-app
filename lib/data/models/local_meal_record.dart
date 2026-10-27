import 'dart:convert';

import 'ai_result.dart';
import 'image_quality.dart';
import 'weight_reading.dart';

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

/// 本機食物紀錄 (規格 3.1.5)。`localId` 同時是上傳的 `client_record_id`。
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
    this.depthPath,
    this.depthMetaPath,
    required this.captureTime,
    this.weightG,
    this.weightSource = WeightSource.none,
    this.quality,
    this.aiStatus = AiStatus.pending,
    this.aiResult,
    this.syncStatus = SyncStatus.pending,
    this.syncAttempts = 0,
    required this.createdAt,
    required this.updatedAt,
    this.errorMessage,
    this.serverFlags = const [],
  });

  /// server 回應的 `bed_mismatch`。
  static const flagBedMismatch = 'bed_mismatch';

  /// server 回應的 `assignment_mismatch`。
  static const flagAssignmentMismatch = 'assignment_mismatch';

  final String localId;

  /// 伺服器端 ID,尚未同步時為 null。
  final String? recordId;
  final String bedId;
  final String patientId;
  final String mealId;
  final String mealTimeSlot;
  final MealPhase beforeAfter;
  final String imagePath;

  /// RealSense 深度圖 (16-bit PNG, mm) 與 meta JSON;選擇圖片的紀錄為 null。
  final String? depthPath;
  final String? depthMetaPath;
  final int captureTime;

  /// 整盤重量 (公克),餐前餐後各一次;沒有秤時為 null。
  final double? weightG;
  final WeightSource weightSource;

  /// 拍照品質檢查結果,隨上傳放在 `edge_result`。
  final ImageQualityReport? quality;
  final AiStatus aiStatus;
  final AiResult? aiResult;
  final SyncStatus syncStatus;
  final int syncAttempts;
  final int createdAt;
  final int updatedAt;

  /// 最近一次上傳失敗原因 (僅本機顯示用)。
  final String? errorMessage;

  /// 上傳成功後 server 標記的問題 ([flagBedMismatch] / [flagAssignmentMismatch])。
  final List<String> serverFlags;

  bool get bedMismatch => serverFlags.contains(flagBedMismatch);
  bool get assignmentMismatch => serverFlags.contains(flagAssignmentMismatch);

  LocalMealRecord copyWith({
    String? recordId,
    double? weightG,
    WeightSource? weightSource,
    bool clearWeight = false,
    AiStatus? aiStatus,
    AiResult? aiResult,
    SyncStatus? syncStatus,
    int? syncAttempts,
    int? updatedAt,
    String? errorMessage,
    bool clearError = false,
    List<String>? serverFlags,
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
      depthPath: depthPath,
      depthMetaPath: depthMetaPath,
      captureTime: captureTime,
      weightG: clearWeight ? null : (weightG ?? this.weightG),
      weightSource: clearWeight
          ? WeightSource.none
          : (weightSource ?? this.weightSource),
      quality: quality,
      aiStatus: aiStatus ?? this.aiStatus,
      aiResult: aiResult ?? this.aiResult,
      syncStatus: syncStatus ?? this.syncStatus,
      syncAttempts: syncAttempts ?? this.syncAttempts,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      serverFlags: serverFlags ?? this.serverFlags,
    );
  }

  factory LocalMealRecord.fromDb(Map<String, Object?> row) {
    final ai = row['ai_result'] as String?;
    final edge = row['edge_result'] as String?;
    final flags = row['server_flags'] as String?;
    return LocalMealRecord(
      localId: row['local_id'] as String,
      recordId: row['record_id'] as String?,
      bedId: row['bed_id'] as String,
      patientId: row['patient_id'] as String,
      mealId: row['meal_id'] as String,
      mealTimeSlot: row['meal_time_slot'] as String,
      beforeAfter: MealPhase.parse(row['before_after'] as String?),
      imagePath: row['image_path'] as String,
      depthPath: row['depth_path'] as String?,
      depthMetaPath: row['depth_meta_path'] as String?,
      captureTime: row['capture_time'] as int,
      weightG: (row['weight_g'] as num?)?.toDouble(),
      weightSource: WeightSource.parse(row['weight_source'] as String?),
      quality: edge == null
          ? null
          : ImageQualityReport.fromJson(
              jsonDecode(edge) as Map<String, Object?>,
            ),
      aiStatus: AiStatus.parse(row['ai_status'] as String?),
      aiResult: ai == null
          ? null
          : AiResult.fromJson(jsonDecode(ai) as Map<String, Object?>),
      syncStatus: SyncStatus.parse(row['sync_status'] as String?),
      syncAttempts: row['sync_attempts'] as int,
      createdAt: row['created_at'] as int,
      updatedAt: row['updated_at'] as int,
      errorMessage: row['error_message'] as String?,
      serverFlags: flags == null || flags.isEmpty
          ? const []
          : flags.split(',').where((f) => f.isNotEmpty).toList(),
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
    'depth_path': depthPath,
    'depth_meta_path': depthMetaPath,
    'capture_time': captureTime,
    'weight_g': weightG,
    'weight_source': weightSource.name,
    'edge_result': quality == null ? null : jsonEncode(quality!.toJson()),
    'ai_status': aiStatus.name,
    'ai_result': aiResult == null ? null : jsonEncode(aiResult!.toJson()),
    'sync_status': syncStatus.name,
    'sync_attempts': syncAttempts,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'error_message': errorMessage,
    'server_flags': serverFlags.isEmpty ? null : serverFlags.join(','),
  };
}

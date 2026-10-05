import 'dart:io';

import 'package:uuid/uuid.dart';

import '../core/errors/app_exception.dart';
import '../core/utils/logger.dart';
import '../core/utils/time_utils.dart';
import '../core/utils/validators.dart';
import '../data/api/api_repository.dart';
import '../data/models/api_models.dart';
import '../data/models/bed_data.dart';
import '../data/models/image_quality.dart';
import '../data/models/local_meal_record.dart';
import '../data/models/meal_data.dart';
import '../data/models/weight_reading.dart';
import 'connectivity_service.dart';
import 'error_handling_service.dart';
import 'hardware/hardware_service.dart';
import 'local_storage_service.dart';
import 'offline_queue_service.dart';

enum UploadOutcomeStatus { synced, queued, failed }

class UploadOutcome {
  const UploadOutcome(this.record, this.status, this.message);
  final LocalMealRecord record;
  final UploadOutcomeStatus status;
  final String message;
}

/// 膳食紀錄:拍照 + 秤重、驗證、本機保存、上傳 (規格 4.3、5.2、9.3;ARCHITECTURE.md §5.1、§6.4)。
class RecordService {
  RecordService({
    required this._api,
    required this._storage,
    required this._queue,
    required this._connectivity,
    required this._errors,
    required this._hardware,
  });

  final ApiRepository _api;
  final LocalStorageService _storage;
  final OfflineQueueService _queue;
  final ConnectivityService _connectivity;
  final ErrorHandlingService _errors;
  final HardwareService _hardware;

  HardwareService get hardware => _hardware;

  /// 拍照 (擷取 → 壓縮 → 品質檢查) 並同時讀秤。使用者取消時回傳 null。
  Future<CaptureResult?> capture({
    CaptureMethod method = CaptureMethod.camera,
  }) => _hardware.capture(method: method);

  /// 重新秤重 (不重拍)。
  Future<WeightReading?> readWeight() => _hardware.readWeight();

  Future<void> discardImage(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  /// 建立紀錄並嘗試上傳。在線 → 立即上傳;離線或暫時性錯誤 → 加入離線佇列。
  Future<UploadOutcome> createAndUpload({
    required BedData bed,
    required List<BedData> roomBeds,
    required MealData meal,
    required List<MealData> meals,
    required TimeSlot timeSlot,
    required MealPhase phase,
    required String imagePath,
    required String deviceId,
    DateTime? captureTime,
    double? weightG,
    WeightSource weightSource = WeightSource.none,
    ImageQualityReport? quality,
  }) async {
    // 1. 本機驗證 — 失敗直接丟出,不加入佇列
    await Validators.image(imagePath);
    Validators.bedAndPatient(bed: bed, roomBeds: roomBeds);
    Validators.meal(meal.mealId, meals);
    Validators.weight(weightG);

    // 2. 記錄到本機 (sync_status = pending);localId 同時是 server 的去重鍵
    final now = nowUnix();
    var record = LocalMealRecord(
      localId: const Uuid().v4(),
      bedId: bed.bedId,
      patientId: bed.patientId!,
      mealId: meal.mealId,
      mealTimeSlot: timeSlot.timeSlotId,
      beforeAfter: phase,
      imagePath: imagePath,
      captureTime: captureTime == null ? now : toUnix(captureTime),
      weightG: weightG,
      weightSource: weightG == null ? WeightSource.none : weightSource,
      quality: quality,
      createdAt: now,
      updatedAt: now,
    );
    await _storage.saveRecord(record);
    final upload = uploadFor(record, deviceId);

    // 3. 離線 → 加入佇列
    if (!await _connectivity.isOnline()) {
      await _queue.enqueueMealRecord(
        localId: record.localId,
        upload: upload,
        immediate: true,
      );
      return UploadOutcome(
        record,
        UploadOutcomeStatus.queued,
        '離線狀態,資料將在連線恢復時同步',
      );
    }

    // 4. 在線 → 立即上傳
    try {
      final result = await _api.uploadMealRecord(upload);
      record = await applyResult(record, result);
      return UploadOutcome(record, UploadOutcomeStatus.synced, '上傳成功');
    } on Object catch (error) {
      final e = _errors.normalize(error);
      if (e.isRetryable || e.type == AppErrorType.unauthorized) {
        await _queue.enqueueMealRecord(
          localId: record.localId,
          upload: upload,
        );
        record = record.copyWith(
          syncAttempts: 1,
          updatedAt: nowUnix(),
          errorMessage: e.message,
        );
        await _storage.saveRecord(record);
        return UploadOutcome(
          record,
          UploadOutcomeStatus.queued,
          '上傳失敗,將在連線恢復時上傳',
        );
      }
      record = await markFailed(record, e);
      return UploadOutcome(
        record,
        UploadOutcomeStatus.failed,
        _errors.userMessage(e),
      );
    }
  }

  MealRecordUpload uploadFor(LocalMealRecord r, String deviceId) =>
      MealRecordUpload(
        imagePath: r.imagePath,
        bedId: r.bedId,
        patientId: r.patientId,
        mealId: r.mealId,
        mealTimeSlot: r.mealTimeSlot,
        beforeAfter: r.beforeAfter.name,
        captureTime: r.captureTime,
        deviceId: deviceId,
        clientRecordId: r.localId,
        weightG: r.weightG,
        edgeResult: r.quality == null
            ? null
            : {
                'quality_check': r.quality!.toJson(),
                'weight_source': r.weightSource.name,
              },
      );

  /// 上傳成功:保存 server 回傳的 record_id 與 AI 結果。
  Future<LocalMealRecord> applyResult(
    LocalMealRecord record,
    MealRecordResult result,
  ) async {
    final updated = record.copyWith(
      recordId: result.recordId,
      aiStatus: AiStatus.parse(result.aiStatus),
      aiResult: result.aiResult,
      syncStatus: SyncStatus.synced,
      updatedAt: nowUnix(),
      clearError: true,
    );
    await _storage.saveRecord(updated);
    Log.i('record ${record.localId} synced as ${result.recordId}');
    return updated;
  }

  Future<LocalMealRecord> markFailed(
    LocalMealRecord record,
    AppException error,
  ) async {
    final updated = record.copyWith(
      syncStatus: SyncStatus.failed,
      syncAttempts: record.syncAttempts + 1,
      updatedAt: nowUnix(),
      errorMessage: _errors.userMessage(error),
    );
    await _storage.saveRecord(updated);
    return updated;
  }

  /// 取得某床位某日的紀錄。
  Future<List<LocalMealRecord>> recordsForBed(String bedId, DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return _storage.getRecordsForBed(
      bedId,
      from: toUnix(start),
      to: toUnix(end),
    );
  }

  /// 使用者手動重試失敗紀錄:重新放回佇列 (必要時重建佇列項目)。
  Future<void> retry(LocalMealRecord record, String deviceId) async {
    final reset = await _queue.retry(record.localId);
    if (reset == null) {
      await _queue.enqueueMealRecord(
        localId: record.localId,
        upload: uploadFor(record, deviceId),
        immediate: true,
      );
    }
    await _storage.saveRecord(
      record.copyWith(
        syncStatus: SyncStatus.pending,
        updatedAt: nowUnix(),
        clearError: true,
      ),
    );
  }
}

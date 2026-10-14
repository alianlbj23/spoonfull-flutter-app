import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../config/app_constants.dart';
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
import '../data/models/offline_queue_item.dart';
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
    final upload = uploadFor(record, deviceId);

    // 3. 離線 → 加入佇列 (紀錄與佇列項目同一個 transaction)
    if (!await _connectivity.isOnline()) {
      await _queue.enqueueMealRecord(
        localId: record.localId,
        upload: upload,
        immediate: true,
        record: record,
      );
      return UploadOutcome(
        record,
        UploadOutcomeStatus.queued,
        '離線狀態,資料將在連線恢復時同步',
      );
    }

    // 4. 在線 → 立即上傳。佇列項目先以 processing 寫入:上傳到一半斷電或當機,
    //    下次啟動會把它放回佇列補傳 (server 以 client_record_id 去重)。
    final item = await _queue.enqueueMealRecord(
      localId: record.localId,
      upload: upload,
      record: record,
      status: QueueStatus.processing,
    );
    final MealRecordResult result;
    try {
      result = await _api.uploadMealRecord(upload);
    } on Object catch (error) {
      final e = _errors.normalize(error);
      final queued = await _queue.markFailed(item, e);
      if (queued.status == QueueStatus.pending) {
        record = record.copyWith(
          syncAttempts: 1,
          updatedAt: nowUnix(),
          errorMessage: _errors.userMessage(e),
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
    // server 已收下。之後的本機寫入若失敗,佇列項目仍在,下次啟動會補做。
    record = await applyResult(record, result);
    await _queue.markCompleted(item);
    return UploadOutcome(record, UploadOutcomeStatus.synced, '上傳成功');
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

  /// 啟動時的對帳:pending 的紀錄一定要有佇列項目,否則永遠不會上傳
  /// (舊版在線直傳到一半被關掉會留下這種紀錄)。[revived] 是佇列裡被放回
  /// pending 的項目,對應的紀錄也改回 pending。
  Future<void> reconcileQueue(
    String deviceId, {
    List<String> revived = const [],
  }) async {
    for (final localId in revived) {
      final record = await _storage.getRecord(localId);
      if (record == null || record.syncStatus != SyncStatus.failed) continue;
      await _storage.saveRecord(
        record.copyWith(syncStatus: SyncStatus.pending, updatedAt: nowUnix()),
      );
    }
    for (final record in await _storage.getRecordsByStatus(
      SyncStatus.pending,
    )) {
      if (await _storage.findQueueItemForRecord(record.localId) != null) {
        continue;
      }
      Log.i('record ${record.localId} had no queue item, re-queued');
      await _queue.enqueueMealRecord(
        localId: record.localId,
        upload: uploadFor(record, deviceId),
        immediate: true,
      );
    }
  }

  /// 清掉過期的本機資料,避免照片把機台的儲存空間寫滿:
  /// 已上傳超過 [AppConstants.syncedImageRetention] 的照片檔、
  /// 已上傳超過 [AppConstants.syncedRecordRetention] 的紀錄,
  /// 以及照片資料夾裡沒有紀錄指向的舊檔。還沒上傳的紀錄與照片不會動。
  /// 回傳刪除的檔案數。
  Future<int> purgeExpired({DateTime? now}) async {
    final t = toUnix(now ?? DateTime.now());
    var deleted = 0;
    Future<void> remove(File f) async {
      try {
        if (await f.exists()) {
          await f.delete();
          deleted++;
        }
      } on FileSystemException catch (e) {
        Log.i('purge: cannot delete ${f.path}: $e');
      }
    }

    final imageCutoff = t - AppConstants.syncedImageRetention.inSeconds;
    final recordCutoff = t - AppConstants.syncedRecordRetention.inSeconds;
    final expired = await _storage.getRecordsByStatus(
      SyncStatus.synced,
      updatedBefore: imageCutoff,
    );
    for (final r in expired) {
      await remove(File(r.imagePath));
      if (r.updatedAt < recordCutoff) await _storage.deleteRecord(r.localId);
    }

    final dir = await _hardware.imagesDirectory();
    final referenced = {
      for (final path in await _storage.recordImagePaths()) p.normalize(path),
    };
    final orphanCutoff = (now ?? DateTime.now()).subtract(
      AppConstants.orphanImageRetention,
    );
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (referenced.contains(p.normalize(entity.path))) continue;
      if ((await entity.lastModified()).isAfter(orphanCutoff)) continue;
      await remove(entity);
    }
    if (deleted > 0) Log.i('purge: removed $deleted old image file(s)');
    return deleted;
  }
}

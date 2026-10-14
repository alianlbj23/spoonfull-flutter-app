import 'package:uuid/uuid.dart';

import '../config/app_constants.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/time_utils.dart';
import '../data/models/api_models.dart';
import '../data/models/local_meal_record.dart';
import '../data/models/offline_queue_item.dart';
import 'local_storage_service.dart';

/// 離線佇列與指數退避 (規格 6.2、7.2)。
class OfflineQueueService {
  OfflineQueueService(this._storage);

  final LocalStorageService _storage;

  /// 加入上傳佇列。[immediate] 為 true 表示離線時建立,連線恢復即可上傳;
  /// 否則代表剛上傳失敗,依退避表延遲第一次重試。
  ///
  /// 給 [record] 時紀錄與佇列項目在同一個 transaction 寫入。[status] 設成
  /// [QueueStatus.processing] 代表呼叫端正在自己上傳這一筆,背景佇列先不要碰;
  /// 中途異常結束會由 [recoverStuckItems] 放回佇列。
  Future<OfflineQueueItem> enqueueMealRecord({
    required String localId,
    required MealRecordUpload upload,
    bool immediate = false,
    LocalMealRecord? record,
    QueueStatus status = QueueStatus.pending,
  }) async {
    final now = nowUnix();
    final item = OfflineQueueItem(
      queueId: const Uuid().v4(),
      operationType: QueueOperation.uploadMealRecord,
      endpoint: AppConstants.mealRecordPath,
      requestData: {...upload.toJson(), 'local_id': localId},
      filePath: upload.imagePath,
      status: status,
      createdAt: now,
      updatedAt: now,
      nextAttemptAt: immediate
          ? now
          : now + AppConstants.retryDelays.first.inSeconds,
    );
    if (record == null) {
      await _storage.saveQueueItem(item);
    } else {
      await _storage.saveRecordWithQueueItem(record, item);
    }
    return item;
  }

  /// 目前可執行的項目,依建立時間 FIFO。
  Future<List<OfflineQueueItem>> dueItems({int? now}) async {
    final t = now ?? nowUnix();
    final items = await _storage.getQueueItems(status: QueueStatus.pending);
    return items.where((i) => i.nextAttemptAt <= t).toList();
  }

  Future<List<OfflineQueueItem>> pendingItems() =>
      _storage.getQueueItems(status: QueueStatus.pending);

  /// 最近一個待重試項目的時間,用於排程計時器。
  Future<int?> nextDueAt() async {
    final items = await pendingItems();
    if (items.isEmpty) return null;
    return items.map((i) => i.nextAttemptAt).reduce((a, b) => a < b ? a : b);
  }

  Future<OfflineQueueItem> markProcessing(OfflineQueueItem item) async {
    final updated = item.copyWith(
      status: QueueStatus.processing,
      updatedAt: nowUnix(),
    );
    await _storage.saveQueueItem(updated);
    return updated;
  }

  Future<void> markCompleted(OfflineQueueItem item) =>
      _storage.deleteQueueItem(item.queueId);

  /// 失敗:暫時性錯誤 (網路 / 逾時 / 5xx) 與 401 依退避表一直重試,退避到表尾後
  /// 固定用最後一格;只有不可重試的錯誤 (4xx / 422 等) 才標記 failed。
  /// server 停機再久,恢復後都會自動補傳,不需要人工逐筆重送。
  Future<OfflineQueueItem> markFailed(
    OfflineQueueItem item,
    AppException error,
  ) async {
    final attempts = item.attempts + 1;
    final now = nowUnix();
    final delays = AppConstants.retryDelays;
    final giveUp =
        !error.isRetryable && error.type != AppErrorType.unauthorized;
    final updated = item.copyWith(
      status: giveUp ? QueueStatus.failed : QueueStatus.pending,
      attempts: attempts,
      updatedAt: now,
      errorMessage: error.message,
      nextAttemptAt: giveUp
          ? item.nextAttemptAt
          : now + delays[attempts.clamp(0, delays.length - 1)].inSeconds,
    );
    await _storage.saveQueueItem(updated);
    return updated;
  }

  /// 使用者手動重試失敗項目 (規格 6.3)。
  Future<OfflineQueueItem?> retry(String localId) async {
    final item = await _storage.findQueueItemForRecord(localId);
    if (item == null) return null;
    final updated = item.copyWith(
      status: QueueStatus.pending,
      attempts: 0,
      updatedAt: nowUnix(),
      nextAttemptAt: nowUnix(),
    );
    await _storage.saveQueueItem(updated);
    return updated;
  }

  /// App 異常結束時可能留下 processing 狀態,啟動時還原為 pending。
  ///
  /// 舊版把重試滿 [AppConstants.legacyMaxRetryAttempts] 次的暫時性錯誤標成 failed;
  /// 這些項目一併放回佇列 (不可重試的錯誤第一次就 failed,次數不會到上限)。
  /// 回傳被放回佇列的紀錄 local_id,讓呼叫端把紀錄改回 pending。
  Future<List<String>> recoverStuckItems() async {
    final items = await _storage.getQueueItems(status: QueueStatus.processing);
    for (final i in items) {
      await _storage.saveQueueItem(i.copyWith(status: QueueStatus.pending));
    }
    final revived = <String>[];
    for (final i in await _storage.getQueueItems(status: QueueStatus.failed)) {
      if (i.attempts < AppConstants.legacyMaxRetryAttempts) continue;
      await _storage.saveQueueItem(
        i.copyWith(status: QueueStatus.pending, nextAttemptAt: nowUnix()),
      );
      final localId = i.requestData['local_id'];
      if (localId is String) revived.add(localId);
    }
    return revived;
  }
}

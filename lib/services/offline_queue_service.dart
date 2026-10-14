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
    int? nextAttemptAt,
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
      nextAttemptAt:
          nextAttemptAt ??
          (immediate ? now : now + AppConstants.retryDelays.first.inSeconds),
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

  /// 失敗:暫時性錯誤 (網路 / 逾時 / 5xx / 代理回的 HTML) 與 401 依退避表一直重試,
  /// 退避到表尾後固定用最後一格;只有不可重試的錯誤 (server 自己回的 4xx 錯誤信封,
  /// 或 server 明講 `retryable: false`) 才標記 failed。server 停機再久,恢復後都會
  /// 自動補傳,不需要人工逐筆重送。有 `Retry-After` 時下次至少等那麼久。
  Future<OfflineQueueItem> markFailed(
    OfflineQueueItem item,
    AppException error,
  ) async {
    final attempts = item.attempts + 1;
    final now = nowUnix();
    final delays = AppConstants.retryDelays;
    final giveUp =
        !error.isRetryable && error.type != AppErrorType.unauthorized;
    var delay = delays[attempts.clamp(0, delays.length - 1)].inSeconds;
    final retryAfter = error.retryAfter?.inSeconds;
    if (retryAfter != null && retryAfter > delay) delay = retryAfter;
    final updated = item.copyWith(
      status: giveUp ? QueueStatus.failed : QueueStatus.pending,
      attempts: attempts,
      updatedAt: now,
      errorMessage: error.message,
      nextAttemptAt: giveUp ? item.nextAttemptAt : now + delay,
    );
    await _storage.saveQueueItem(updated);
    return updated;
  }

  /// 延後一筆項目而不算失敗 (例如餐後照要等餐前照先上傳)。
  Future<OfflineQueueItem> defer(
    OfflineQueueItem item,
    int nextAttemptAt,
  ) async {
    final updated = item.copyWith(
      status: QueueStatus.pending,
      updatedAt: nowUnix(),
      nextAttemptAt: nextAttemptAt,
    );
    await _storage.saveQueueItem(updated);
    return updated;
  }

  /// 所有待上傳項目改成立即可上傳 (重新配對成功後,不必等退避)。回傳筆數。
  Future<int> rescheduleAllNow({int? now}) async {
    final t = now ?? nowUnix();
    final items = await pendingItems();
    for (final i in items) {
      if (i.nextAttemptAt <= t) continue;
      await _storage.saveQueueItem(i.copyWith(nextAttemptAt: t, updatedAt: t));
    }
    return items.length;
  }

  /// [requestData] 若是餐後紀錄,找出同一住民、同一時段、同一天 (機台當地日期)
  /// 還在佇列 (pending / processing) 的餐前紀錄;沒有則回 null。
  Future<OfflineQueueItem?> pendingBeforeFor(
    Map<String, Object?> requestData, {
    String? excludeQueueId,
  }) async {
    if (requestData['before_after'] != 'after') return null;
    final patient = requestData['patient_id'];
    final slot = requestData['meal_time_slot'];
    final day = _localDay(requestData['capture_time']);
    final localId = requestData['local_id'];
    for (final i in await _storage.getQueueItems()) {
      if (i.status != QueueStatus.pending &&
          i.status != QueueStatus.processing) {
        continue;
      }
      if (i.queueId == excludeQueueId) continue;
      final d = i.requestData;
      if (d['before_after'] != 'before') continue;
      if (localId != null && d['local_id'] == localId) continue;
      if (d['patient_id'] != patient || d['meal_time_slot'] != slot) continue;
      if (_localDay(d['capture_time']) != day) continue;
      return i;
    }
    return null;
  }

  static int? _localDay(Object? captureTime) {
    final t = captureTime is int ? captureTime : int.tryParse('$captureTime');
    if (t == null) return null;
    final d = DateTime.fromMillisecondsSinceEpoch(t * 1000);
    return d.year * 10000 + d.month * 100 + d.day;
  }

  /// 餐後項目被 [blocker] (餐前) 擋住時的下次嘗試時間:稍等一下,
  /// 若餐前還在退避就排在它之後。
  static int deferredAttemptAt(OfflineQueueItem? blocker, {int? now}) {
    final soon =
        (now ?? nowUnix()) + AppConstants.afterRecordDeferral.inSeconds;
    final after = (blocker?.nextAttemptAt ?? 0) + 1;
    return after > soon ? after : soon;
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

import 'dart:async';

import '../config/app_constants.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/logger.dart';
import '../core/utils/time_utils.dart';
import '../data/api/api_repository.dart';
import '../data/models/api_models.dart';
import '../data/models/local_meal_record.dart';
import '../data/models/offline_queue_item.dart';
import 'connectivity_service.dart';
import 'error_handling_service.dart';
import 'local_storage_service.dart';
import 'offline_queue_service.dart';
import 'realtime_service.dart';
import 'record_service.dart';

class SyncSnapshot {
  const SyncSnapshot({
    required this.isOnline,
    required this.isSyncing,
    required this.pendingCount,
    required this.failedCount,
    this.lastSync,
    this.lastError,
    this.realtimeConnected = false,
  });

  final bool isOnline;
  final bool isSyncing;
  final int pendingCount;
  final int failedCount;
  final int? lastSync;
  final String? lastError;

  /// server 推播通道是否連著 (ARCHITECTURE.md §6.6)。
  final bool realtimeConnected;
}

/// 背景同步 (規格 7.2、7.3):網路恢復、定時、手動觸發時處理離線佇列與更新快取;
/// 另外接 server 推播 (ARCHITECTURE.md §6.6),資料一變動就立刻重抓。
class SyncService {
  SyncService({
    required this._api,
    required this._storage,
    required this._queue,
    required this._records,
    required this._connectivity,
    required this._errors,
    required this._isPaired,
    this._realtime,
  }) {
    _realtime?.onUnauthorized = _errors.notifyUnauthorized;
  }

  final ApiRepository _api;
  final LocalStorageService _storage;
  final OfflineQueueService _queue;
  final RecordService _records;
  final ConnectivityService _connectivity;
  final ErrorHandlingService _errors;
  final Future<bool> Function() _isPaired;
  final RealtimeService? _realtime;

  final _snapshots = StreamController<SyncSnapshot>.broadcast();
  Stream<SyncSnapshot> get snapshots => _snapshots.stream;

  StreamSubscription<bool>? _connSub;
  StreamSubscription<DataChangedEvent>? _eventSub;
  StreamSubscription<bool>? _realtimeConnSub;
  Timer? _periodic;
  Timer? _retryTimer;
  Timer? _debounce;
  final Set<String> _pendingDatasets = {};
  bool _online = true;
  bool _syncing = false;
  bool _queueRunning = false;
  String? _lastError;

  bool get isOnline => _online;
  bool get realtimeConnected => _realtime?.isConnected ?? false;

  Future<void> start() async {
    final revived = await _queue.recoverStuckItems();
    await _records.reconcileQueue(
      _storage.deviceConfig.deviceId,
      revived: revived,
    );
    unawaited(_purge());
    _online = await _connectivity.isOnline();
    _connSub = _connectivity.onStatusChange.listen(_onConnectivity);
    _periodic = Timer.periodic(AppConstants.periodicSyncInterval, (_) {
      unawaited(syncAll(forceCache: true));
      unawaited(_purge());
    });
    final realtime = _realtime;
    if (realtime != null) {
      _eventSub = realtime.events.listen(_onDataChanged);
      _realtimeConnSub = realtime.connectionChanges.listen(
        _onRealtimeConnection,
      );
      if (await _isPaired()) realtime.start();
    }
    await _emit();
  }

  Future<void> _purge() async {
    try {
      await _records.purgeExpired();
    } on Object catch (e) {
      Log.e('purge failed', e);
    }
  }

  /// 配對狀態改變:已配對就維持推播連線,解除配對就關掉。
  Future<void> setPaired(bool paired) async {
    final realtime = _realtime;
    if (realtime == null) return;
    if (paired) {
      realtime.start();
    } else {
      _debounce?.cancel();
      _debounce = null;
      _pendingDatasets.clear();
      await realtime.stop();
    }
  }

  Future<void> _onConnectivity(bool online) async {
    final restored = online && !_online;
    _online = online;
    await _emit();
    if (restored) {
      Log.i('network restored, syncing');
      _realtime?.retryNow();
      await syncAll();
    }
  }

  /// server 推播:合併 [AppConstants.realtimeDebounce] 內的事件後只重抓列出的資料。
  void _onDataChanged(DataChangedEvent event) {
    _pendingDatasets.addAll(event.datasets);
    _debounce?.cancel();
    _debounce = Timer(AppConstants.realtimeDebounce, () {
      _debounce = null;
      final datasets = Set<String>.of(_pendingDatasets);
      _pendingDatasets.clear();
      Log.i('realtime: ${datasets.join(', ')} changed, refreshing');
      unawaited(refreshCache(force: true, datasets: datasets));
    });
  }

  /// 推播連上時一律全量重抓,補上斷線 (或啟動到連上之間) 錯過的變動。
  Future<void> _onRealtimeConnection(bool connected) async {
    await _emit();
    if (connected) await refreshCache(force: true);
  }

  /// 配對成功:佇列裡等待退避的項目 (例如 401 時留下的) 改成立刻上傳,再完整同步。
  Future<void> afterPaired() async {
    final n = await _queue.rescheduleAllNow();
    if (n > 0) Log.i('paired: $n queued record(s) rescheduled');
    await syncAll(forceCache: true);
  }

  /// 完整同步:更新快取 + 處理佇列。
  Future<void> syncAll({bool forceCache = false}) async {
    if (!await _isPaired()) return;
    await refreshCache(force: forceCache);
    await processQueue();
  }

  /// 依快取有效期更新病房/床位/膳食資料。
  ///
  /// [datasets] 限定只更新 [LocalStorageService.datasetRooms] /
  /// [LocalStorageService.datasetBeds] / [LocalStorageService.datasetMeals]
  /// 之中列出的;null 代表全部。
  Future<void> refreshCache({bool force = false, Set<String>? datasets}) async {
    if (!_online || !await _isPaired()) return;
    bool wants(String dataset) =>
        datasets == null || datasets.contains(dataset);
    final placeId = _storage.serverSettings.placeId;
    final now = nowUnix();
    _syncing = true;
    await _emit();
    try {
      final roomsTs = _storage.lastUpdated(LocalStorageService.datasetRooms);
      if (wants(LocalStorageService.datasetRooms) &&
          (force || _stale(roomsTs, AppConstants.roomBedCacheTtl, now))) {
        final res = await _api.fetchRooms(
          placeId: placeId,
          lastUpdated: force ? null : roomsTs,
        );
        await _storage.saveRooms(
          placeId,
          res.rooms,
          replace: force || roomsTs == null,
        );
        await _storage.setLastUpdated(
          LocalStorageService.datasetRooms,
          res.timestamp,
        );
      }
      final bedsTs = _storage.lastUpdated(LocalStorageService.datasetBeds);
      if (wants(LocalStorageService.datasetBeds) &&
          (force || _stale(bedsTs, AppConstants.roomBedCacheTtl, now))) {
        final res = await _api.fetchBeds(
          placeId: placeId,
          lastUpdated: force ? null : bedsTs,
        );
        await _storage.saveBeds(
          placeId,
          res.beds,
          replace: force || bedsTs == null,
        );
        await _storage.setLastUpdated(
          LocalStorageService.datasetBeds,
          res.timestamp,
        );
      }
      final mealsTs = _storage.lastUpdated(LocalStorageService.datasetMeals);
      if (wants(LocalStorageService.datasetMeals) &&
          (force || _stale(mealsTs, AppConstants.mealCacheTtl, now))) {
        final res = await _api.fetchMeals(placeId: placeId);
        await _storage.saveMeals(
          placeId,
          res.meals,
          res.timeSlots,
          currentSlot: res.currentSlot,
          currentSlotAt: nowUnix(),
        );
        await _storage.setLastUpdated(
          LocalStorageService.datasetMeals,
          res.timestamp,
        );
      }
      final config = _storage.deviceConfig;
      await _storage.saveDeviceConfig(config.copyWith(lastSync: nowUnix()));
      _lastError = null;
    } on Object catch (error) {
      final e = _errors.normalize(error);
      _lastError = _errors.userMessage(e);
      if (e.type == AppErrorType.unauthorized) _errors.notifyUnauthorized();
      Log.i('cache refresh failed: $e');
    } finally {
      _syncing = false;
      await _emit();
    }
  }

  static bool _stale(int? ts, Duration ttl, int now) =>
      ts == null || now - ts >= ttl.inSeconds;

  /// 依 FIFO 上傳佇列中到期的項目。
  Future<void> processQueue() async {
    if (_queueRunning || !_online || !await _isPaired()) return;
    _queueRunning = true;
    _syncing = true;
    await _emit();
    try {
      final deviceId = _storage.deviceConfig.deviceId;
      for (final item in await _queue.dueItems()) {
        final stop = await _processItem(item, deviceId);
        if (stop) break;
      }
    } finally {
      _queueRunning = false;
      _syncing = false;
      await _emit();
      await _scheduleNextRetry();
    }
  }

  /// 回傳 true 表示應停止處理 (401 或網路中斷)。
  Future<bool> _processItem(OfflineQueueItem item, String deviceId) async {
    final localId = item.requestData['local_id'] as String?;
    final record = localId == null ? null : await _storage.getRecord(localId);
    if (record == null) {
      await _queue.markCompleted(item);
      return false;
    }
    // 餐前照要先到 server:同一住民、同一餐、同一天的餐前還在佇列就先延後。
    final blocker = await _queue.pendingBeforeFor(
      item.requestData,
      excludeQueueId: item.queueId,
    );
    if (blocker != null) {
      Log.i(
        'record $localId (after) waits for before-record '
        '${blocker.requestData['local_id']}',
      );
      await _queue.defer(item, OfflineQueueService.deferredAttemptAt(blocker));
      return false;
    }
    final processing = await _queue.markProcessing(item);
    try {
      final upload = MealRecordUpload.fromJson(item.requestData);
      final result = await _api.uploadMealRecord(upload);
      await _records.applyResult(record, result);
      await _queue.markCompleted(processing);
      return false;
    } on Object catch (error) {
      final e = _errors.normalize(error);
      final updated = await _queue.markFailed(processing, e);
      if (updated.status == QueueStatus.failed) {
        await _records.markFailed(record, e);
      } else {
        await _storage.saveRecord(
          record.copyWith(
            syncAttempts: record.syncAttempts + 1,
            syncStatus: SyncStatus.pending,
            updatedAt: nowUnix(),
            errorMessage: _errors.userMessage(e),
          ),
        );
      }
      _lastError = _errors.userMessage(e);
      if (e.type == AppErrorType.unauthorized) {
        _errors.notifyUnauthorized();
        return true;
      }
      return e.type == AppErrorType.network;
    }
  }

  Future<void> _scheduleNextRetry() async {
    _retryTimer?.cancel();
    final next = await _queue.nextDueAt();
    if (next == null) return;
    final delay = Duration(seconds: (next - nowUnix()).clamp(1, 1 << 20));
    _retryTimer = Timer(delay, () => unawaited(processQueue()));
  }

  Future<void> _emit() async {
    if (_snapshots.isClosed) return;
    final pending = await _storage.countRecords(SyncStatus.pending);
    final failed = await _storage.countRecords(SyncStatus.failed);
    _snapshots.add(
      SyncSnapshot(
        isOnline: _online,
        isSyncing: _syncing,
        pendingCount: pending,
        failedCount: failed,
        lastSync: _storage.deviceConfig.lastSync,
        lastError: _lastError,
        realtimeConnected: realtimeConnected,
      ),
    );
  }

  Future<void> refreshStatus() => _emit();

  Future<void> dispose() async {
    await _connSub?.cancel();
    await _eventSub?.cancel();
    await _realtimeConnSub?.cancel();
    _periodic?.cancel();
    _retryTimer?.cancel();
    _debounce?.cancel();
    await _realtime?.dispose();
    await _snapshots.close();
  }
}

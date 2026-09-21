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
import 'record_service.dart';

class SyncSnapshot {
  const SyncSnapshot({
    required this.isOnline,
    required this.isSyncing,
    required this.pendingCount,
    required this.failedCount,
    this.lastSync,
    this.lastError,
  });

  final bool isOnline;
  final bool isSyncing;
  final int pendingCount;
  final int failedCount;
  final int? lastSync;
  final String? lastError;
}

/// 背景同步 (規格 7.2、7.3):網路恢復、定時、手動觸發時處理離線佇列與更新快取。
class SyncService {
  SyncService({
    required this._api,
    required this._storage,
    required this._queue,
    required this._records,
    required this._connectivity,
    required this._errors,
    required this._isPaired,
  });

  final ApiRepository _api;
  final LocalStorageService _storage;
  final OfflineQueueService _queue;
  final RecordService _records;
  final ConnectivityService _connectivity;
  final ErrorHandlingService _errors;
  final Future<bool> Function() _isPaired;

  final _snapshots = StreamController<SyncSnapshot>.broadcast();
  Stream<SyncSnapshot> get snapshots => _snapshots.stream;

  StreamSubscription<bool>? _connSub;
  Timer? _periodic;
  Timer? _retryTimer;
  bool _online = true;
  bool _syncing = false;
  bool _queueRunning = false;
  String? _lastError;

  bool get isOnline => _online;

  Future<void> start() async {
    await _queue.recoverStuckItems();
    _online = await _connectivity.isOnline();
    _connSub = _connectivity.onStatusChange.listen(_onConnectivity);
    _periodic = Timer.periodic(
      AppConstants.periodicSyncInterval,
      (_) => syncAll(forceCache: true),
    );
    await _emit();
  }

  Future<void> _onConnectivity(bool online) async {
    final restored = online && !_online;
    _online = online;
    await _emit();
    if (restored) {
      Log.i('network restored, syncing');
      await syncAll();
    }
  }

  /// 完整同步:更新快取 + 處理佇列。
  Future<void> syncAll({bool forceCache = false}) async {
    if (!await _isPaired()) return;
    await refreshCache(force: forceCache);
    await processQueue();
  }

  /// 依快取有效期更新病房/床位/膳食資料。
  Future<void> refreshCache({bool force = false}) async {
    if (!_online || !await _isPaired()) return;
    final placeId = _storage.serverSettings.placeId;
    final now = nowUnix();
    _syncing = true;
    await _emit();
    try {
      final roomsTs = _storage.lastUpdated(LocalStorageService.datasetRooms);
      if (force || _stale(roomsTs, AppConstants.roomBedCacheTtl, now)) {
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
      if (force || _stale(bedsTs, AppConstants.roomBedCacheTtl, now)) {
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
      if (force || _stale(mealsTs, AppConstants.mealCacheTtl, now)) {
        final res = await _api.fetchMeals(placeId: placeId);
        await _storage.saveMeals(placeId, res.meals, res.timeSlots);
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
            errorMessage: e.message,
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
    _retryTimer = Timer(delay, processQueue);
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
      ),
    );
  }

  Future<void> refreshStatus() => _emit();

  Future<void> dispose() async {
    await _connSub?.cancel();
    _periodic?.cancel();
    _retryTimer?.cancel();
    await _snapshots.close();
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/app_services.dart';
import '../services/sync_service.dart';

class SyncState extends ChangeNotifier {
  SyncState(this._services) {
    _sub = _services.sync.snapshots.listen((s) {
      _snapshot = s;
      notifyListeners();
    });
  }

  final AppServices _services;
  StreamSubscription<SyncSnapshot>? _sub;
  SyncSnapshot _snapshot = const SyncSnapshot(
    isOnline: true,
    isSyncing: false,
    pendingCount: 0,
    failedCount: 0,
  );

  bool get isOnline => _snapshot.isOnline;
  bool get isSyncing => _snapshot.isSyncing;
  int get pendingCount => _snapshot.pendingCount;
  int get failedCount => _snapshot.failedCount;
  int? get lastSync => _snapshot.lastSync;
  String? get lastError => _snapshot.lastError;

  /// 使用者手動重新整理 (強制更新快取並上傳佇列)。
  Future<void> refreshNow() => _services.sync.syncAll(forceCache: true);

  Future<void> processQueue() => _services.sync.processQueue();

  Future<void> clearCache() async {
    await _services.storage.clearCache();
    await _services.sync.refreshStatus();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models/bed_data.dart';
import '../data/models/local_meal_record.dart';
import '../data/models/meal_data.dart';
import '../data/models/room_data.dart';
import '../services/app_services.dart';
import '../services/record_service.dart';

/// 病房/床位/膳食資料與紀錄上傳狀態。
class RecordState extends ChangeNotifier {
  RecordState(this._services) {
    _sub = _services.sync.snapshots.listen((s) {
      // 同步結束後重新讀取快取,讓畫面顯示最新資料。
      if (_wasSyncing && !s.isSyncing) loadAll();
      _wasSyncing = s.isSyncing;
    });
  }

  final AppServices _services;
  StreamSubscription<Object?>? _sub;
  bool _wasSyncing = false;

  List<RoomData> rooms = const [];
  final Map<String, List<BedData>> _beds = {};
  List<MealData> meals = const [];
  List<TimeSlot> timeSlots = const [];
  bool loading = false;
  bool uploading = false;

  String get _placeId => _services.storage.serverSettings.placeId;

  List<BedData> bedsFor(String roomId) => _beds[roomId] ?? const [];

  Future<void> loadAll() async {
    loading = true;
    notifyListeners();
    try {
      final place = _placeId;
      rooms = await _services.storage.getRooms(place);
      final beds = await _services.storage.getBeds(place);
      _beds
        ..clear()
        ..addAll(_groupBy(beds));
      meals = await _services.storage.getMeals(place);
      timeSlots = await _services.storage.getTimeSlots(place);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  static Map<String, List<BedData>> _groupBy(List<BedData> beds) {
    final map = <String, List<BedData>>{};
    for (final b in beds) {
      (map[b.roomId] ??= []).add(b);
    }
    return map;
  }

  /// 依目前時間推估時段,找不到則取第一個。
  TimeSlot? currentTimeSlot([DateTime? now]) {
    if (timeSlots.isEmpty) return null;
    final t = now ?? DateTime.now();
    for (final s in timeSlots) {
      if (s.contains(t)) return s;
    }
    final m = t.hour * 60 + t.minute;
    TimeSlot best = timeSlots.first;
    for (final s in timeSlots) {
      if (s.startMinutes <= m) best = s;
    }
    return best;
  }

  /// 預設膳食:與時段餐別相同的第一筆。
  MealData? defaultMealFor(TimeSlot? slot) {
    if (meals.isEmpty) return null;
    if (slot == null) return meals.first;
    return meals.firstWhere(
      (m) => m.mealType == slot.inferredMealType,
      orElse: () => meals.first,
    );
  }

  Future<String?> captureImage() => _services.records.captureImage();

  Future<void> discardImage(String path) =>
      _services.records.discardImage(path);

  Future<UploadOutcome> upload({
    required BedData bed,
    required MealData meal,
    required TimeSlot slot,
    required MealPhase phase,
    required String imagePath,
  }) async {
    uploading = true;
    notifyListeners();
    try {
      final outcome = await _services.records.createAndUpload(
        bed: bed,
        roomBeds: bedsFor(bed.roomId),
        meal: meal,
        meals: meals,
        timeSlot: slot,
        phase: phase,
        imagePath: imagePath,
        deviceId: _services.storage.deviceConfig.deviceId,
      );
      if (outcome.status == UploadOutcomeStatus.queued) {
        await _services.sync.processQueue();
      } else {
        await _services.sync.refreshStatus();
      }
      return outcome;
    } finally {
      uploading = false;
      notifyListeners();
    }
  }

  Future<List<LocalMealRecord>> recordsFor(String bedId, DateTime day) =>
      _services.records.recordsForBed(bedId, day);

  Future<void> retry(LocalMealRecord record) async {
    await _services.records.retry(
      record,
      _services.storage.deviceConfig.deviceId,
    );
    await _services.sync.processQueue();
  }

  String errorMessage(Object e) => _services.errors.userMessage(e);

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

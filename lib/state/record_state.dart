import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models/bed_data.dart';
import '../data/models/image_quality.dart';
import '../data/models/local_meal_record.dart';
import '../data/models/meal_data.dart';
import '../data/models/room_data.dart';
import '../data/models/weight_reading.dart';
import '../services/app_services.dart';
import '../core/utils/logger.dart';
import '../services/hardware/hardware_service.dart';
import '../services/local_storage_service.dart';
import '../services/record_service.dart';

/// 病房/床位/膳食資料與紀錄上傳狀態。
class RecordState extends ChangeNotifier {
  RecordState(this._services) {
    _sub = _services.storage.changes.listen(_onStorageChanged);
  }

  final AppServices _services;
  StreamSubscription<String>? _sub;
  bool _reloadScheduled = false;
  bool _disposed = false;

  /// 紀錄 (meal_records) 每變動一次加一;顯示紀錄的畫面 watch 這個值來重新讀取。
  int recordsVersion = 0;

  /// 照片確認畫面開著 (照片已拍、還沒上傳)。這時不安裝更新,否則照片會丟掉。
  bool confirmingCapture = false;

  /// 本機資料一變動 (同步完成、清除快取、紀錄上傳成功) 就更新畫面。
  /// 一次同步會連續寫入病房 / 床位 / 膳食,合併成一次重新讀取。
  void _onStorageChanged(String dataset) {
    if (dataset == LocalStorageService.datasetRecords) {
      recordsVersion++;
      notifyListeners();
      return;
    }
    if (_reloadScheduled) return;
    _reloadScheduled = true;
    scheduleMicrotask(() {
      _reloadScheduled = false;
      if (_disposed) return;
      unawaited(
        loadAll().catchError((Object e) => Log.e('cache reload failed', e)),
      );
    });
  }

  List<RoomData> rooms = const [];
  final Map<String, List<BedData>> _beds = {};
  List<MealData> meals = const [];
  List<TimeSlot> timeSlots = const [];
  bool loading = false;
  bool uploading = false;
  bool capturing = false;

  String get _placeId => _services.storage.serverSettings.placeId;

  /// 是否有設定秤 (確認畫面決定要不要顯示重量面板)。
  bool get scaleEnabled => _services.hardware.scale.enabled;

  /// 設定的相機能拍照 (否則只提供「選擇檔案」)。
  bool get cameraAvailable => _services.hardware.cameraAvailable;

  /// 品質檢查是否會提示重拍。
  bool get qualityCheckEnabled => _services.hardware.config.qualityCheckEnabled;

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

  /// 拍照 + 秤重 (ARCHITECTURE.md §5.1)。使用者取消時回傳 null。
  Future<CaptureResult?> capture({
    CaptureMethod method = CaptureMethod.camera,
  }) async {
    capturing = true;
    notifyListeners();
    try {
      return await _services.records.capture(method: method);
    } finally {
      capturing = false;
      notifyListeners();
    }
  }

  Future<WeightReading?> readWeight() => _services.records.readWeight();

  Future<void> discardImage(String path) =>
      _services.records.discardImage(path);

  Future<UploadOutcome> upload({
    required BedData bed,
    required MealData meal,
    required TimeSlot slot,
    required MealPhase phase,
    required String imagePath,
    double? weightG,
    WeightSource weightSource = WeightSource.none,
    ImageQualityReport? quality,
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
        weightG: weightG,
        weightSource: weightSource,
        quality: quality,
      );
      // 佇列在背景處理:裡面若有其他待傳項目,不該讓使用者等它們全部傳完。
      if (outcome.status == UploadOutcomeStatus.queued) {
        unawaited(_services.sync.processQueue());
      }
      await _services.sync.refreshStatus();
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
    await _services.sync.refreshStatus();
    unawaited(_services.sync.processQueue());
  }

  String errorMessage(Object e) => _services.errors.userMessage(e);

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}

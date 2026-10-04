import 'package:sqflite/sqflite.dart';

import '../data/local/app_database.dart';
import '../data/local/preferences_storage.dart';
import '../data/local/secure_token_storage.dart';
import '../data/models/auth_token.dart';
import '../data/models/bed_data.dart';
import '../data/models/device_config.dart';
import '../data/models/hardware_config.dart';
import '../data/models/local_meal_record.dart';
import '../data/models/meal_data.dart';
import '../data/models/offline_queue_item.dart';
import '../data/models/room_data.dart';

/// 本機儲存的統一入口:SharedPreferences (配置)、加密儲存 (Token)、SQLite (快取)。
class LocalStorageService {
  LocalStorageService({
    required this._prefs,
    required this._tokens,
    required AppDatabase database,
  }) : _db = database.db;

  final PreferencesStorage _prefs;
  final TokenStorage _tokens;
  final Database _db;

  static const datasetRooms = 'rooms';
  static const datasetBeds = 'beds';
  static const datasetMeals = 'meals';

  // ---------------- 設備配置 ----------------
  DeviceConfig get deviceConfig => _prefs.readDeviceConfig();
  Future<void> saveDeviceConfig(DeviceConfig c) => _prefs.writeDeviceConfig(c);

  ServerSettings get serverSettings => _prefs.readServerSettings();
  Future<void> saveServerSettings(ServerSettings s) =>
      _prefs.writeServerSettings(s);

  HardwareConfig get hardwareConfig => _prefs.readHardwareConfig();
  Future<void> saveHardwareConfig(HardwareConfig c) =>
      _prefs.writeHardwareConfig(c);

  int? lastUpdated(String dataset) => _prefs.lastUpdated(dataset);
  Future<void> setLastUpdated(String dataset, int ts) =>
      _prefs.setLastUpdated(dataset, ts);

  // ---------------- Token ----------------
  Future<AuthToken?> readToken() => _tokens.read();
  Future<void> saveToken(AuthToken t) => _tokens.write(t);
  Future<void> clearToken() => _tokens.clear();

  // ---------------- 病房 / 床位 ----------------
  Future<void> saveRooms(
    String placeId,
    List<RoomData> rooms, {
    bool replace = false,
  }) async {
    await _db.transaction((txn) async {
      if (replace) {
        await txn.delete('rooms', where: 'place_id = ?', whereArgs: [placeId]);
      }
      final batch = txn.batch();
      for (final r in rooms) {
        batch.insert(
          'rooms',
          r.toDb(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<RoomData>> getRooms(String placeId) async {
    final rows = await _db.query(
      'rooms',
      where: 'place_id = ?',
      whereArgs: [placeId],
    );
    return rows.map(RoomData.fromDb).toList()..sort(_compareRooms);
  }

  /// 數字房號依大小排序,其他 (如「門診」) 排在最後。
  static int _compareRooms(RoomData a, RoomData b) {
    final na = int.tryParse(a.roomName);
    final nb = int.tryParse(b.roomName);
    if (na != null && nb != null) return na.compareTo(nb);
    if (na != null) return -1;
    if (nb != null) return 1;
    return a.roomName.compareTo(b.roomName);
  }

  Future<void> saveBeds(
    String placeId,
    List<BedData> beds, {
    bool replace = false,
  }) async {
    await _db.transaction((txn) async {
      if (replace) {
        await txn.delete('beds', where: 'place_id = ?', whereArgs: [placeId]);
      }
      final batch = txn.batch();
      for (final b in beds) {
        batch.insert(
          'beds',
          b.toDb(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<BedData>> getBeds(String placeId, {String? roomId}) async {
    final rows = await _db.query(
      'beds',
      where: roomId == null ? 'place_id = ?' : 'place_id = ? AND room_id = ?',
      whereArgs: roomId == null ? [placeId] : [placeId, roomId],
      orderBy: 'bed_name',
    );
    return rows.map(BedData.fromDb).toList();
  }

  Future<BedData?> getBed(String placeId, String bedId) async {
    final rows = await _db.query(
      'beds',
      where: 'place_id = ? AND bed_id = ?',
      whereArgs: [placeId, bedId],
      limit: 1,
    );
    return rows.isEmpty ? null : BedData.fromDb(rows.first);
  }

  // ---------------- 膳食 / 時段 ----------------
  Future<void> saveMeals(
    String placeId,
    List<MealData> meals,
    List<TimeSlot> slots,
  ) async {
    await _db.transaction((txn) async {
      await txn.delete('meals', where: 'place_id = ?', whereArgs: [placeId]);
      await txn.delete(
        'time_slots',
        where: 'place_id = ?',
        whereArgs: [placeId],
      );
      final batch = txn.batch();
      for (final m in meals) {
        batch.insert('meals', m.toDb());
      }
      for (final s in slots) {
        batch.insert('time_slots', s.toDb(placeId));
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<MealData>> getMeals(String placeId) async {
    final rows = await _db.query(
      'meals',
      where: 'place_id = ?',
      whereArgs: [placeId],
      orderBy: 'meal_name',
    );
    return rows.map(MealData.fromDb).toList();
  }

  Future<List<TimeSlot>> getTimeSlots(String placeId) async {
    final rows = await _db.query(
      'time_slots',
      where: 'place_id = ?',
      whereArgs: [placeId],
      orderBy: 'sort_order, start_time',
    );
    return rows.map(TimeSlot.fromDb).toList();
  }

  // ---------------- 食物紀錄 ----------------
  Future<void> saveRecord(LocalMealRecord r) => _db.insert(
    'meal_records',
    r.toDb(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<LocalMealRecord?> getRecord(String localId) async {
    final rows = await _db.query(
      'meal_records',
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    return rows.isEmpty ? null : LocalMealRecord.fromDb(rows.first);
  }

  Future<List<LocalMealRecord>> getRecordsForBed(
    String bedId, {
    required int from,
    required int to,
  }) async {
    final rows = await _db.query(
      'meal_records',
      where: 'bed_id = ? AND capture_time >= ? AND capture_time < ?',
      whereArgs: [bedId, from, to],
      orderBy: 'capture_time DESC',
    );
    return rows.map(LocalMealRecord.fromDb).toList();
  }

  Future<int> countRecords(SyncStatus status) async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM meal_records WHERE sync_status = ?',
      [status.name],
    );
    return (r.first['c'] as int?) ?? 0;
  }

  // ---------------- 離線佇列 ----------------
  Future<void> saveQueueItem(OfflineQueueItem item) => _db.insert(
    'offline_queue',
    item.toDb(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<void> deleteQueueItem(String queueId) =>
      _db.delete('offline_queue', where: 'queue_id = ?', whereArgs: [queueId]);

  Future<List<OfflineQueueItem>> getQueueItems({QueueStatus? status}) async {
    final rows = await _db.query(
      'offline_queue',
      where: status == null ? null : 'status = ?',
      whereArgs: status == null ? null : [status.name],
      orderBy: 'created_at ASC',
    );
    return rows.map(OfflineQueueItem.fromDb).toList();
  }

  Future<OfflineQueueItem?> findQueueItemForRecord(String localId) async {
    final items = await getQueueItems();
    for (final i in items) {
      if (i.requestData['local_id'] == localId) return i;
    }
    return null;
  }

  /// 清除病房/床位/膳食快取 (不影響未同步的紀錄與佇列)。
  Future<void> clearCache() async {
    await _db.transaction((txn) async {
      for (final t in ['rooms', 'beds', 'meals', 'time_slots']) {
        await txn.delete(t);
      }
    });
    await _prefs.clearSyncTimestamps();
  }
}

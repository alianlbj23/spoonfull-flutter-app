import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// SQLite 快取與離線佇列 (規格 3.1.3 ~ 3.1.6)。
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  /// v2:meal_records 新增 weight_g / weight_source / edge_result (ARCHITECTURE.md §6.4)。
  /// v3:meals 新增 assigned_patient_ids;meal_records 新增 server_flags
  /// (server 回的 bed_mismatch / assignment_mismatch)。
  static const int _version = 3;

  /// Jetson / Raspberry Pi (Linux) 與其他桌面平台透過 FFI 使用 SQLite。
  static bool _factoryReady = false;

  static void initFactory() {
    if (_factoryReady) return;
    _factoryReady = true;
    if (!kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  static Future<AppDatabase> open({String? path}) async {
    initFactory();
    final dbPath =
        path ?? p.join(await getDatabasesPath(), 'spoonfull.db');
    final db = await openDatabase(
      dbPath,
      version: _version,
      onCreate: (db, _) => _create(db),
      onUpgrade: _upgrade,
    );
    return AppDatabase._(db);
  }

  /// 測試可傳入 `databaseFactoryFfiNoIsolate`,讓查詢在同一 isolate 同步完成。
  static Future<AppDatabase> openInMemory({DatabaseFactory? factory}) async {
    initFactory();
    final db = await (factory ?? databaseFactory).openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: _version,
        onCreate: (db, _) => _create(db),
        onUpgrade: _upgrade,
      ),
    );
    return AppDatabase._(db);
  }

  static Future<void> _upgrade(Database db, int from, int to) async {
    if (from < 2) {
      await db.execute('ALTER TABLE meal_records ADD COLUMN weight_g REAL');
      await db.execute(
        "ALTER TABLE meal_records ADD COLUMN weight_source TEXT NOT NULL DEFAULT 'none'",
      );
      await db.execute('ALTER TABLE meal_records ADD COLUMN edge_result TEXT');
    }
    if (from < 3) {
      await db.execute('ALTER TABLE meals ADD COLUMN assigned_patient_ids TEXT');
      await db.execute('ALTER TABLE meal_records ADD COLUMN server_flags TEXT');
    }
  }

  static Future<void> _create(Database db) async {
    final batch = db.batch()
      ..execute('''
        CREATE TABLE rooms (
          place_id TEXT NOT NULL,
          room_id TEXT NOT NULL,
          room_name TEXT NOT NULL,
          beds_count INTEGER NOT NULL,
          last_updated INTEGER NOT NULL,
          PRIMARY KEY (place_id, room_id)
        )''')
      ..execute('''
        CREATE TABLE beds (
          place_id TEXT NOT NULL,
          room_id TEXT NOT NULL,
          bed_id TEXT NOT NULL,
          bed_name TEXT NOT NULL,
          patient_id TEXT,
          patient_name TEXT,
          patient_age INTEGER,
          last_updated INTEGER NOT NULL,
          PRIMARY KEY (place_id, bed_id)
        )''')
      ..execute('CREATE INDEX idx_beds_room ON beds (place_id, room_id)')
      ..execute('''
        CREATE TABLE meals (
          place_id TEXT NOT NULL,
          meal_id TEXT NOT NULL,
          meal_name TEXT NOT NULL,
          meal_type TEXT NOT NULL,
          meal_time_slot TEXT,
          assigned_patient_ids TEXT,
          last_updated INTEGER NOT NULL,
          PRIMARY KEY (place_id, meal_id)
        )''')
      ..execute('''
        CREATE TABLE time_slots (
          place_id TEXT NOT NULL,
          time_slot_id TEXT NOT NULL,
          time_slot_name TEXT NOT NULL,
          start_time TEXT NOT NULL,
          end_time TEXT NOT NULL,
          sort_order INTEGER NOT NULL,
          PRIMARY KEY (place_id, time_slot_id)
        )''')
      ..execute('''
        CREATE TABLE meal_records (
          local_id TEXT PRIMARY KEY,
          record_id TEXT,
          bed_id TEXT NOT NULL,
          patient_id TEXT NOT NULL,
          meal_id TEXT NOT NULL,
          meal_time_slot TEXT NOT NULL,
          before_after TEXT NOT NULL,
          image_path TEXT NOT NULL,
          capture_time INTEGER NOT NULL,
          weight_g REAL,
          weight_source TEXT NOT NULL DEFAULT 'none',
          edge_result TEXT,
          server_flags TEXT,
          ai_status TEXT NOT NULL,
          ai_result TEXT,
          sync_status TEXT NOT NULL,
          sync_attempts INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          error_message TEXT
        )''')
      ..execute(
        'CREATE INDEX idx_records_bed ON meal_records (bed_id, capture_time)',
      )
      ..execute('''
        CREATE TABLE offline_queue (
          queue_id TEXT PRIMARY KEY,
          operation_type TEXT NOT NULL,
          endpoint TEXT NOT NULL,
          request_data TEXT NOT NULL,
          file_path TEXT,
          status TEXT NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          error_message TEXT,
          next_attempt_at INTEGER NOT NULL DEFAULT 0
        )''');
    await batch.commit(noResult: true);
  }

  Future<void> close() => db.close();
}

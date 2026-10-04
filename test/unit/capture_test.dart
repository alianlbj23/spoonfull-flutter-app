import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spoonfull_flutter_app/config/app_constants.dart';
import 'package:spoonfull_flutter_app/core/errors/app_exception.dart';
import 'package:spoonfull_flutter_app/data/api/mock_api_repository.dart';
import 'package:spoonfull_flutter_app/data/local/app_database.dart';
import 'package:spoonfull_flutter_app/data/models/api_models.dart';
import 'package:spoonfull_flutter_app/data/models/hardware_config.dart';
import 'package:spoonfull_flutter_app/data/models/image_quality.dart';
import 'package:spoonfull_flutter_app/data/models/local_meal_record.dart';
import 'package:spoonfull_flutter_app/data/models/weight_reading.dart';
import 'package:spoonfull_flutter_app/services/hardware/camera_service.dart';
import 'package:spoonfull_flutter_app/services/record_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/test_services.dart';

/// 記下每次上傳的欄位。
class _RecordingApi extends MockApiRepository {
  _RecordingApi() : super(latency: Duration.zero);
  final List<MealRecordUpload> uploads = [];

  @override
  Future<MealRecordResult> uploadMealRecord(MealRecordUpload upload) {
    uploads.add(upload);
    return super.uploadMealRecord(upload);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestEnv env;
  late _RecordingApi api;

  setUp(() async {
    api = _RecordingApi();
    env = await createTestEnv(api: api, prefs: configuredPrefs);
    await env.services.pairing.pair(MockApiRepository.validPairingCode);
    await env.services.sync.start();
    await env.services.sync.refreshCache(force: true);
  });

  tearDown(() => env.dispose());

  Future<UploadOutcome> upload({
    required String imagePath,
    double? weightG,
    WeightSource source = WeightSource.none,
    ImageQualityReport? quality,
  }) async {
    final storage = env.services.storage;
    final beds = await storage.getBeds('demo', roomId: 'R101');
    final bed = beds.firstWhere((b) => b.hasPatient);
    final meals = await storage.getMeals('demo');
    final slots = await storage.getTimeSlots('demo');
    return env.services.records.createAndUpload(
      bed: bed,
      roomBeds: beds,
      meal: meals.first,
      meals: meals,
      timeSlot: slots.first,
      phase: MealPhase.before,
      imagePath: imagePath,
      deviceId: storage.deviceConfig.deviceId,
      weightG: weightG,
      weightSource: source,
      quality: quality,
    );
  }

  test('capture produces compressed JPEG, quality report and weight', () async {
    final result = await env.services.records.capture();
    expect(result, isNotNull);
    final file = File(result!.imagePath);
    expect(await file.exists(), isTrue);
    expect(result.imagePath, endsWith('.jpg'));
    expect(result.width <= AppConstants.uploadMaxLongSide, isTrue);
    expect(result.quality.passed, isTrue, reason: '${result.quality}');
    expect(result.weight, isNotNull);
    expect(result.weight!.grams, closeTo(testScaleWeightG, 0.01));
    expect(result.weight!.stable, isTrue);
    // 原始擷取檔已刪除
    expect(await File('${result.imagePath}.raw.jpg').exists(), isFalse);
  });

  test('upload sends client_record_id, weight_g and edge_result', () async {
    final capture = (await env.services.records.capture())!;
    final outcome = await upload(
      imagePath: capture.imagePath,
      weightG: capture.weight!.grams,
      source: WeightSource.scale,
      quality: capture.quality,
    );
    expect(outcome.status, UploadOutcomeStatus.synced);

    final sent = api.uploads.single;
    expect(sent.clientRecordId, outcome.record.localId);
    expect(sent.fields['client_record_id'], outcome.record.localId);
    expect(sent.fields['weight_g'], '420.0');
    expect(sent.fields['edge_result'], contains('"tray_detected":true'));
    expect(sent.fields['edge_result'], contains('"weight_source":"scale"'));

    final saved = await env.services.storage.getRecord(outcome.record.localId);
    expect(saved!.weightG, 420);
    expect(saved.weightSource, WeightSource.scale);
    expect(saved.quality!.passed, isTrue);
  });

  test('upload without scale omits weight_g', () async {
    final capture = (await env.services.records.capture())!;
    await upload(imagePath: capture.imagePath);
    final sent = api.uploads.single;
    expect(sent.fields.containsKey('weight_g'), isFalse);
    expect(sent.fields.containsKey('client_record_id'), isTrue);
  });

  test('unreasonable weight is rejected locally', () async {
    final capture = (await env.services.records.capture())!;
    await expectLater(
      upload(imagePath: capture.imagePath, weightG: 50000),
      throwsA(
        isA<AppException>().having((e) => e.code, 'code', 'INVALID_WEIGHT'),
      ),
    );
    expect(api.uploads, isEmpty);
  });

  test('re-sending the same client_record_id returns the same record_id', () async {
    final capture = (await env.services.records.capture())!;
    final outcome = await upload(imagePath: capture.imagePath);
    final first = api.uploads.single;
    final again = await api.uploadMealRecord(first);
    expect(again.recordId, outcome.record.recordId);
  });

  test('queued upload keeps weight and client_record_id through restart', () async {
    env.connectivity.online = false;
    await pumpEventQueue();
    final capture = (await env.services.records.capture())!;
    await upload(
      imagePath: capture.imagePath,
      weightG: 388.4,
      source: WeightSource.manual,
    );
    final item = (await env.services.queue.pendingItems()).single;
    final restored = MealRecordUpload.fromJson(item.requestData);
    expect(restored.weightG, 388.4);
    expect(restored.clientRecordId, item.requestData['local_id']);
  });

  test('mock camera without tray fails the quality check', () async {
    await env.dispose();
    env = await createTestEnv(
      api: api,
      prefs: configuredPrefs,
      camera: const MockCameraService(width: 640, height: 480, withTray: false),
    );
    final result = (await env.services.records.capture())!;
    expect(result.quality.issues, contains(QualityIssue.trayMissing));
  });

  test('empty-scale reference improves tray detection', () async {
    final hw = env.services.hardware;
    // 用「沒有餐盒」的模擬相機拍參考照
    await env.dispose();
    env = await createTestEnv(
      api: api,
      prefs: configuredPrefs,
      camera: const MockCameraService(width: 640, height: 480, withTray: false),
    );
    final ref = await env.services.hardware.captureReference();
    expect(await File(ref).exists(), isTrue);
    expect(env.services.hardware.config.referenceImagePath, ref);
    expect(hw, isNot(same(env.services.hardware)));
  });

  test('hardware config persists and apply() rebuilds the scale', () async {
    final hw = env.services.hardware;
    expect(hw.scale.enabled, isTrue);
    await hw.apply(
      hw.config.copyWith(scale: const ScaleSettings(kind: ScaleKind.none)),
    );
    // 測試注入的秤是固定的,設定仍要保存
    expect(env.services.storage.hardwareConfig.scale.kind, ScaleKind.none);
    expect(env.services.storage.hardwareConfig.camera.source, CameraSource.auto);
  });

  test('database upgrades v1 schema with the new record columns', () async {
    sqfliteFfiInit();
    final factory = databaseFactoryFfiNoIsolate;
    final path = '${env.tempDir.path}${Platform.pathSeparator}v1.db';
    final v1 = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE meal_records (
              local_id TEXT PRIMARY KEY, record_id TEXT, bed_id TEXT NOT NULL,
              patient_id TEXT NOT NULL, meal_id TEXT NOT NULL,
              meal_time_slot TEXT NOT NULL, before_after TEXT NOT NULL,
              image_path TEXT NOT NULL, capture_time INTEGER NOT NULL,
              ai_status TEXT NOT NULL, ai_result TEXT, sync_status TEXT NOT NULL,
              sync_attempts INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
              error_message TEXT)''');
          await db.insert('meal_records', {
            'local_id': 'old', 'bed_id': 'b', 'patient_id': 'p', 'meal_id': 'm',
            'meal_time_slot': 't', 'before_after': 'before', 'image_path': '/x',
            'capture_time': 1, 'ai_status': 'pending', 'sync_status': 'synced',
            'created_at': 1, 'updated_at': 1,
          });
        },
      ),
    );
    await v1.close();

    AppDatabase.initFactory();
    databaseFactory = factory;
    final upgraded = await AppDatabase.open(path: path);
    final rows = await upgraded.db.query('meal_records');
    final record = LocalMealRecord.fromDb(rows.single);
    expect(record.weightG, isNull);
    expect(record.weightSource, WeightSource.none);
    expect(record.quality, isNull);
    await upgraded.close();
  });
}

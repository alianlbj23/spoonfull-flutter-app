import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:spoonfull_flutter_app/config/app_constants.dart';
import 'package:spoonfull_flutter_app/core/errors/app_exception.dart';
import 'package:spoonfull_flutter_app/core/utils/time_utils.dart';
import 'package:spoonfull_flutter_app/data/api/mock_api_repository.dart';
import 'package:spoonfull_flutter_app/data/local/app_database.dart';
import 'package:spoonfull_flutter_app/data/models/api_models.dart';
import 'package:spoonfull_flutter_app/data/models/hardware_config.dart';
import 'package:spoonfull_flutter_app/data/models/image_quality.dart';
import 'package:spoonfull_flutter_app/data/models/local_meal_record.dart';
import 'package:spoonfull_flutter_app/data/models/meal_data.dart';
import 'package:spoonfull_flutter_app/data/models/weight_reading.dart';
import 'package:spoonfull_flutter_app/services/hardware/camera_service.dart';
import 'package:spoonfull_flutter_app/services/hardware/hardware_service.dart';
import 'package:spoonfull_flutter_app/services/record_service.dart';
import 'package:spoonfull_flutter_app/state/record_state.dart';
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

/// 記下被呼叫幾次的模擬相機;[cancel] 時模擬使用者取消。
class _CountingCamera extends CameraService {
  _CountingCamera({this.cancel = false});
  final bool cancel;
  int calls = 0;

  @override
  String get description => 'counting';

  @override
  Future<RawCapture?> capture(String outputPath) async {
    calls++;
    if (cancel) return null;
    return const MockCameraService(width: 640, height: 480).capture(outputPath);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestEnv env;
  late _RecordingApi api;

  setUp(() async {
    api = _RecordingApi();
    env = await createTestEnv(api: api, prefs: configuredPrefs);
    await pairWithMock(env);
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

  group('RGB-D', () {
    late TestEnv rgbd;

    setUp(() async {
      rgbd = await createTestEnv(
        api: api,
        prefs: configuredPrefs,
        camera: const MockCameraService(
          width: 640,
          height: 480,
          withDepth: true,
        ),
      );
      await pairWithMock(rgbd);
      await rgbd.services.sync.start();
      await rgbd.services.sync.refreshCache(force: true);
    });

    test('capture through the preview stream keeps the depth', () async {
      final records = rgbd.services.records;
      expect(records.previewSupported, isTrue);
      final preview = records.openPreview() as MockCameraPreview;
      await preview.ready;
      final frame = await preview.frames.first;
      expect(frame.sublist(0, 2), [0xff, 0xd8], reason: '預覽影格是 JPEG');

      final result = (await records.capture(via: preview))!;
      expect(result.hasDepth, isTrue);
      expect(File(result.depthPath!).existsSync(), isTrue);
      expect(result.weight, isNotNull);

      await preview.close();
      expect(preview.closed, isTrue);
      await expectLater(preview.capture('x'), throwsA(isA<AppException>()));
    });

    tearDown(() => rgbd.dispose());

    Future<UploadOutcome> uploadRgbd(CaptureResult c) async {
      final storage = rgbd.services.storage;
      final beds = await storage.getBeds('demo', roomId: 'R101');
      final meals = await storage.getMeals('demo');
      final slots = await storage.getTimeSlots('demo');
      return rgbd.services.records.createAndUpload(
        bed: beds.firstWhere((b) => b.hasPatient),
        roomBeds: beds,
        meal: meals.first,
        meals: meals,
        timeSlot: slots.first,
        phase: MealPhase.before,
        imagePath: c.imagePath,
        depthPath: c.depthPath,
        depthMetaPath: c.depthMetaPath,
        deviceId: storage.deviceConfig.deviceId,
        quality: c.quality,
      );
    }

    test('capture keeps the depth map beside the photo', () async {
      final result = (await rgbd.services.records.capture())!;
      expect(result.hasDepth, isTrue);
      expect(
        result.depthPath,
        '${p.withoutExtension(result.imagePath)}_depth.png',
      );
      expect(result.depthMetaPath, endsWith('_depth.json'));
      expect(File(result.depthPath!).existsSync(), isTrue);
      expect(result.depth!.width, result.width);
      expect(result.depth!.height, result.height);
      expect(result.depth!.validRatio, greaterThan(0.9));
      expect(result.depth!.centerMedianMm, 575);
      // meta 內已補上統計
      final meta = jsonDecode(File(result.depthMetaPath!).readAsStringSync());
      expect(meta['stats']['center_median_mm'], 575);
      expect(meta['depth_unit_m'], 0.001);
      // 原始擷取檔都已清掉
      final leftovers = (await rgbd.services.hardware.imagesDirectory())
          .listSync()
          .map((f) => p.basename(f.path))
          .where((n) => n.contains('.raw'));
      expect(leftovers, isEmpty);
    });

    test('upload carries depth paths and flags depth_attached', () async {
      final c = (await rgbd.services.records.capture())!;
      final outcome = await uploadRgbd(c);
      expect(outcome.status, UploadOutcomeStatus.synced);
      final sent = api.uploads.single;
      expect(sent.depthPath, c.depthPath);
      expect(sent.depthMetaPath, c.depthMetaPath);
      expect(sent.fields['edge_result'], contains('"depth_attached":true'));
      final saved = await rgbd.services.storage.getRecord(
        outcome.record.localId,
      );
      expect(saved!.depthPath, c.depthPath);
      expect(saved.depthMetaPath, c.depthMetaPath);
    });

    test('queued upload restores depth paths after restart', () async {
      rgbd.connectivity.online = false;
      await pumpEventQueue();
      final c = (await rgbd.services.records.capture())!;
      await uploadRgbd(c);
      final item = (await rgbd.services.queue.pendingItems()).single;
      final restored = MealRecordUpload.fromJson(item.requestData);
      expect(restored.depthPath, c.depthPath);
      expect(restored.depthMetaPath, c.depthMetaPath);
    });

    test('discarding a photo removes its depth files', () async {
      final c = (await rgbd.services.records.capture())!;
      await rgbd.services.records.discardImage(c.imagePath);
      expect(File(c.imagePath).existsSync(), isFalse);
      expect(File(c.depthPath!).existsSync(), isFalse);
      expect(File(c.depthMetaPath!).existsSync(), isFalse);
    });

    test('missing depth file uploads RGB only', () async {
      final c = (await rgbd.services.records.capture())!;
      File(c.depthPath!).deleteSync();
      final outcome = await uploadRgbd(c);
      expect(outcome.status, UploadOutcomeStatus.synced);
      expect(api.uploads.single.depthPath, isNull);
      expect(outcome.record.depthPath, isNull);
    });

    test('purge removes expired depth files with the photo', () async {
      final c = (await rgbd.services.records.capture())!;
      final outcome = await uploadRgbd(c);
      final old = DateTime.now().add(
        AppConstants.syncedImageRetention + const Duration(days: 1),
      );
      final deleted = await rgbd.services.records.purgeExpired(now: old);
      expect(deleted, 3);
      expect(File(c.imagePath).existsSync(), isFalse);
      expect(File(c.depthPath!).existsSync(), isFalse);
      expect(File(c.depthMetaPath!).existsSync(), isFalse);
      expect(
        await rgbd.services.storage.getRecord(outcome.record.localId),
        isNotNull,
        reason: '紀錄保留 90 天',
      );
    });

    test(
      'orphan cleanup leaves depth files of pending records alone',
      () async {
        rgbd.connectivity.online = false;
        await pumpEventQueue();
        final c = (await rgbd.services.records.capture())!;
        await uploadRgbd(c);
        final later = DateTime.now().add(const Duration(days: 2));
        await rgbd.services.records.purgeExpired(now: later);
        expect(File(c.depthPath!).existsSync(), isTrue);
        expect(File(c.depthMetaPath!).existsSync(), isTrue);
      },
    );

    test('reference capture does not keep depth files', () async {
      final ref = await rgbd.services.hardware.captureReference();
      expect(File(ref).existsSync(), isTrue);
      final dir = File(ref).parent.listSync().map((f) => p.basename(f.path));
      expect(dir.where((n) => n.contains('depth')), isEmpty);
    });
  });

  test('file capture uses the file picker instead of the camera', () async {
    final camera = _CountingCamera();
    final picker = _CountingCamera();
    final fileEnv = await createTestEnv(camera: camera, filePicker: picker);
    addTearDown(fileEnv.dispose);

    final result = await fileEnv.services.records.capture(
      method: CaptureMethod.file,
    );
    expect(result, isNotNull);
    expect(result!.quality.passed, isTrue, reason: '${result.quality}');
    expect(result.weight?.grams, testScaleWeightG);
    expect(picker.calls, 1);
    expect(camera.calls, 0);

    await fileEnv.services.records.capture();
    expect(camera.calls, 1);
    expect(picker.calls, 1);
  });

  test('cancelling the file picker returns null', () async {
    final fileEnv = await createTestEnv(
      filePicker: _CountingCamera(cancel: true),
    );
    addTearDown(fileEnv.dispose);
    expect(
      await fileEnv.services.records.capture(method: CaptureMethod.file),
      isNull,
    );
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

  test(
    're-sending the same client_record_id returns the same record_id',
    () async {
      final capture = (await env.services.records.capture())!;
      final outcome = await upload(imagePath: capture.imagePath);
      final first = api.uploads.single;
      final again = await api.uploadMealRecord(first);
      expect(again.recordId, outcome.record.recordId);
    },
  );

  test(
    'queued upload keeps weight and client_record_id through restart',
    () async {
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
    },
  );

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
    expect(
      env.services.storage.hardwareConfig.camera.source,
      CameraSource.platformDefault,
    );
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
          await db.execute('''
            CREATE TABLE meals (
              place_id TEXT NOT NULL, meal_id TEXT NOT NULL,
              meal_name TEXT NOT NULL, meal_type TEXT NOT NULL,
              meal_time_slot TEXT, last_updated INTEGER NOT NULL,
              PRIMARY KEY (place_id, meal_id))''');
          await db.insert('meals', {
            'place_id': 'A',
            'meal_id': 'm',
            'meal_name': '午餐',
            'meal_type': 'lunch',
            'last_updated': 1,
          });
          await db.insert('meal_records', {
            'local_id': 'old',
            'bed_id': 'b',
            'patient_id': 'p',
            'meal_id': 'm',
            'meal_time_slot': 't',
            'before_after': 'before',
            'image_path': '/x',
            'capture_time': 1,
            'ai_status': 'pending',
            'sync_status': 'synced',
            'created_at': 1,
            'updated_at': 1,
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
    expect(record.serverFlags, isEmpty, reason: 'v3 server_flags 欄位');
    expect(record.depthPath, isNull, reason: 'v4 depth_path 欄位');
    expect(record.depthMetaPath, isNull);
    final meal = MealData.fromDb((await upgraded.db.query('meals')).single);
    expect(meal.assignedPatientIds, isEmpty, reason: 'v3 新欄位預設空');
    await upgraded.close();
  });

  test('capture records the shutter time', () async {
    final before = DateTime.now();
    final result = await env.services.records.capture();
    final after = DateTime.now();
    expect(result!.capturedAt, isNotNull);
    expect(result.capturedAt!.isBefore(before), isFalse);
    expect(result.capturedAt!.isAfter(after), isFalse);
  });

  test('RecordState passes the shutter time as capture_time', () async {
    final state = RecordState(env.services);
    addTearDown(state.dispose);
    await state.loadAll();
    final result = await env.services.records.capture();
    final shutter = DateTime(2026, 10, 14, 11, 58, 7);
    final bed = state.bedsFor('R101').firstWhere((b) => b.hasPatient);
    final outcome = await state.upload(
      bed: bed,
      meal: state.meals.first,
      slot: state.timeSlots.first,
      phase: MealPhase.before,
      imagePath: result!.imagePath,
      captureTime: shutter,
    );
    expect(outcome.status, UploadOutcomeStatus.synced);
    expect(api.uploads.last.captureTime, toUnix(shutter));
    expect(outcome.record.captureTime, toUnix(shutter));
  });

  test('server flags from the record response are stored', () async {
    final now = nowUnix();
    final record = LocalMealRecord(
      localId: 'flags',
      bedId: 'R101-B1',
      patientId: 'P1',
      mealId: 'M1',
      mealTimeSlot: 'T1',
      beforeAfter: MealPhase.after,
      imagePath: '/x.jpg',
      captureTime: now,
      createdAt: now,
      updatedAt: now,
    );
    final saved = await env.services.records.applyResult(
      record,
      MealRecordResult.fromJson({
        'record_id': '42',
        'ai_status': 'pending',
        'duplicate': false,
        'assignment_mismatch': true,
        'bed_mismatch': true,
      }),
    );
    expect(saved.bedMismatch, isTrue);
    expect(saved.assignmentMismatch, isTrue);
    final reloaded = await env.services.storage.getRecord('flags');
    expect(reloaded!.bedMismatch, isTrue);
    expect(reloaded.assignmentMismatch, isTrue);
    expect(reloaded.syncStatus, SyncStatus.synced);
  });
}

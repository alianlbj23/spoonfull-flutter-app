import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spoonfull_flutter_app/config/app_constants.dart';
import 'package:spoonfull_flutter_app/core/errors/app_exception.dart';
import 'package:spoonfull_flutter_app/core/utils/time_utils.dart';
import 'package:spoonfull_flutter_app/data/api/mock_api_repository.dart';
import 'package:spoonfull_flutter_app/data/models/api_models.dart';
import 'package:spoonfull_flutter_app/data/models/local_meal_record.dart';
import 'package:spoonfull_flutter_app/data/models/offline_queue_item.dart';
import 'package:spoonfull_flutter_app/services/record_service.dart';

import '../helpers/test_services.dart';

/// 可指定上傳錯誤的假 API。
class FlakyApi extends MockApiRepository {
  FlakyApi() : super(latency: Duration.zero);

  final List<AppException> uploadErrors = [];
  int uploads = 0;

  @override
  Future<MealRecordResult> uploadMealRecord(MealRecordUpload upload) async {
    uploads++;
    if (uploadErrors.isNotEmpty) throw uploadErrors.removeAt(0);
    return super.uploadMealRecord(upload);
  }
}

const _network = AppException(AppErrorType.network, 'down');

Future<String> _writePng(Directory dir, int w, int h) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF88AAFF),
  );
  final image = await recorder.endRecording().toImage(w, h);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('${dir.path}/meal_${w}x$h.png');
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  return file.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestEnv env;
  late FlakyApi api;
  late Directory tmp;

  setUp(() async {
    api = FlakyApi();
    env = await createTestEnv(api: api, prefs: configuredPrefs);
    await env.services.pairing.pair(MockApiRepository.validPairingCode);
    await env.services.sync.start();
    await env.services.sync.refreshCache(force: true);
    tmp = await Directory.systemTemp.createTemp('spoonfull_test');
  });

  tearDown(() async {
    await env.dispose();
    await tmp.delete(recursive: true);
  });

  Future<UploadOutcome> createRecord(String imagePath) async {
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
      phase: MealPhase.after,
      imagePath: imagePath,
      deviceId: storage.deviceConfig.deviceId,
    );
  }

  test('pairing stores token and marks device paired', () async {
    expect(await env.services.pairing.hasValidToken(), isTrue);
    expect(env.services.storage.deviceConfig.paired, isTrue);
    expect((await env.tokens.read())!.deviceToken, startsWith('mock-token-'));
  });

  test('refreshCache stores rooms, beds, meals and time slots', () async {
    final storage = env.services.storage;
    final rooms = await storage.getRooms('demo');
    expect(rooms.map((r) => r.roomName).first, '101');
    expect(rooms.last.roomName, '門診', reason: '非數字房號排在最後');
    expect(await storage.getBeds('demo', roomId: 'R101'), hasLength(3));
    expect(await storage.getTimeSlots('demo'), hasLength(3));
  });

  test('online upload syncs immediately and stores AI result', () async {
    final path = await _writePng(tmp, 640, 480);
    final outcome = await createRecord(path);

    expect(outcome.status, UploadOutcomeStatus.synced);
    final saved = await env.services.storage.getRecord(outcome.record.localId);
    expect(saved!.syncStatus, SyncStatus.synced);
    expect(saved.recordId, startsWith('SRV-'));
    expect(saved.aiStatus, AiStatus.completed);
    expect(saved.aiResult!.leftoverPercentage, isNotNull);
  });

  test('offline upload is queued then synced when network returns', () async {
    env.connectivity.online = false;
    await pumpEventQueue();
    final path = await _writePng(tmp, 640, 480);

    final outcome = await createRecord(path);
    expect(outcome.status, UploadOutcomeStatus.queued);
    expect(api.uploads, 0);
    expect(await env.services.queue.pendingItems(), hasLength(1));

    env.connectivity.online = true;
    await pumpEventQueue(times: 50);

    final saved = await env.services.storage.getRecord(outcome.record.localId);
    expect(saved!.syncStatus, SyncStatus.synced);
    expect(await env.services.queue.pendingItems(), isEmpty);
  });

  test('image that is too small is rejected locally and not queued', () async {
    final path = await _writePng(tmp, 300, 200);
    await expectLater(
      createRecord(path),
      throwsA(
        isA<AppException>().having(
          (e) => e.type,
          'type',
          AppErrorType.localValidation,
        ),
      ),
    );
    expect(await env.services.queue.pendingItems(), isEmpty);
  });

  test('retryable failure uses backoff, gives up after max attempts', () async {
    final queue = env.services.queue;
    final storage = env.services.storage;
    final now = nowUnix();
    final record = LocalMealRecord(
      localId: 'L1',
      bedId: 'R101-B1',
      patientId: 'P1',
      mealId: 'M1',
      mealTimeSlot: 'T1',
      beforeAfter: MealPhase.before,
      imagePath: '/nonexistent.png',
      captureTime: now,
      createdAt: now,
      updatedAt: now,
    );
    await storage.saveRecord(record);
    var item = await queue.enqueueMealRecord(
      localId: 'L1',
      upload: env.services.records.uploadFor(record, 'dev'),
    );
    expect(item.nextAttemptAt - now, AppConstants.retryDelays[0].inSeconds);

    for (var i = 1; i <= AppConstants.maxRetryAttempts; i++) {
      item = await queue.markFailed(item, _network);
      expect(item.attempts, i);
      if (i < AppConstants.maxRetryAttempts) {
        expect(item.status, QueueStatus.pending);
        expect(
          item.nextAttemptAt - nowUnix(),
          closeTo(AppConstants.retryDelays[i].inSeconds, 1),
        );
      }
    }
    expect(item.status, QueueStatus.failed);

    // 使用者手動重試 → 重新排入
    final retried = await queue.retry('L1');
    expect(retried!.status, QueueStatus.pending);
    expect(retried.attempts, 0);
  });

  test('non-retryable error fails immediately', () async {
    final queue = env.services.queue;
    final now = nowUnix();
    final item = OfflineQueueItem(
      queueId: 'q',
      operationType: QueueOperation.uploadMealRecord,
      endpoint: AppConstants.mealRecordPath,
      requestData: const {'local_id': 'x'},
      createdAt: now,
      updatedAt: now,
    );
    final failed = await queue.markFailed(
      item,
      const AppException(AppErrorType.validation, 'bad'),
    );
    expect(failed.status, QueueStatus.failed);
  });

  test('401 during sync clears pairing via DeviceState hook', () async {
    var unauthorized = false;
    final sub = env.services.errors.onUnauthorized.listen(
      (_) => unauthorized = true,
    );
    api.uploadErrors.add(
      const AppException(AppErrorType.unauthorized, 'expired', statusCode: 401),
    );
    final path = await _writePng(tmp, 640, 480);
    final outcome = await createRecord(path);
    expect(outcome.status, UploadOutcomeStatus.queued,
        reason: '401 時保留紀錄於佇列,重新配對後可上傳');

    // 等待退避時間到期後由佇列處理
    final items = await env.services.queue.pendingItems();
    await env.services.storage.saveQueueItem(
      items.single.copyWith(nextAttemptAt: 0),
    );
    api.uploadErrors.add(
      const AppException(AppErrorType.unauthorized, 'expired', statusCode: 401),
    );
    await env.services.sync.processQueue();
    await pumpEventQueue();
    expect(unauthorized, isTrue);
    await sub.cancel();
  });
}

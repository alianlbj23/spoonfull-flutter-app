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

  /// 每次上傳的 before_after,依呼叫順序。
  final List<String> phases = [];

  @override
  Future<MealRecordResult> uploadMealRecord(MealRecordUpload upload) async {
    uploads++;
    phases.add(upload.beforeAfter);
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
    await pairWithMock(env);
    await env.services.sync.start();
    await env.services.sync.refreshCache(force: true);
    tmp = await Directory.systemTemp.createTemp('spoonfull_test');
  });

  tearDown(() async {
    await env.dispose();
    await tmp.delete(recursive: true);
  });

  Future<UploadOutcome> createRecord(
    String imagePath, {
    MealPhase phase = MealPhase.after,
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
      phase: phase,
      imagePath: imagePath,
      deviceId: storage.deviceConfig.deviceId,
    );
  }

  /// 讓佇列裡所有項目立即到期。
  Future<void> makeAllDue() async {
    for (final i in await env.services.queue.pendingItems()) {
      await env.services.storage.saveQueueItem(i.copyWith(nextAttemptAt: 0));
    }
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

  test('retryable failure backs off and never gives up', () async {
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

    // server 停機再久都留在佇列;退避到表尾後固定用最後一格 (30 分鐘)。
    final delays = AppConstants.retryDelays;
    for (var i = 1; i <= delays.length + 3; i++) {
      item = await queue.markFailed(item, _network);
      expect(item.attempts, i);
      expect(item.status, QueueStatus.pending);
      expect(
        item.nextAttemptAt - nowUnix(),
        closeTo(delays[i.clamp(0, delays.length - 1)].inSeconds, 1),
      );
    }

    // 使用者手動重試 → 立即重新排入
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
    expect(
      outcome.status,
      UploadOutcomeStatus.queued,
      reason: '401 時保留紀錄於佇列,重新配對後可上傳',
    );

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

  test('online upload leaves no queue item behind', () async {
    final path = await _writePng(tmp, 640, 480);
    final outcome = await createRecord(path);
    expect(outcome.status, UploadOutcomeStatus.synced);
    expect(await env.services.storage.getQueueItems(), isEmpty);
  });

  test('upload interrupted by a crash is re-sent on the next start', () async {
    // 模擬舊版留下的狀態:紀錄是 pending,但沒有佇列項目。
    final storage = env.services.storage;
    final now = nowUnix();
    final path = await _writePng(tmp, 640, 480);
    await storage.saveRecord(
      LocalMealRecord(
        localId: 'orphan',
        bedId: 'R101-B1',
        patientId: 'P001',
        mealId: 'M1',
        mealTimeSlot: 'T1',
        beforeAfter: MealPhase.before,
        imagePath: path,
        captureTime: now,
        createdAt: now,
        updatedAt: now,
      ),
    );
    expect(await storage.findQueueItemForRecord('orphan'), isNull);

    await env.services.records.reconcileQueue('dev');
    final item = await storage.findQueueItemForRecord('orphan');
    expect(item, isNotNull);
    expect(item!.status, QueueStatus.pending);
  });

  test(
    'items given up by the old 5-attempt limit go back to the queue',
    () async {
      final storage = env.services.storage;
      final now = nowUnix();
      final record = LocalMealRecord(
        localId: 'old-failed',
        bedId: 'R101-B1',
        patientId: 'P1',
        mealId: 'M1',
        mealTimeSlot: 'T1',
        beforeAfter: MealPhase.before,
        imagePath: '/nonexistent.png',
        captureTime: now,
        syncStatus: SyncStatus.failed,
        createdAt: now,
        updatedAt: now,
      );
      await storage.saveRecord(record);
      final item = await env.services.queue.enqueueMealRecord(
        localId: 'old-failed',
        upload: env.services.records.uploadFor(record, 'dev'),
      );
      await storage.saveQueueItem(
        item.copyWith(
          status: QueueStatus.failed,
          attempts: AppConstants.legacyMaxRetryAttempts,
        ),
      );

      final revived = await env.services.queue.recoverStuckItems();
      expect(revived, ['old-failed']);
      await env.services.records.reconcileQueue('dev', revived: revived);
      expect(
        (await storage.getRecord('old-failed'))!.syncStatus,
        SyncStatus.pending,
      );
      expect(
        (await storage.findQueueItemForRecord('old-failed'))!.status,
        QueueStatus.pending,
      );
    },
  );

  test('unexpected errors show a generic message, not the raw exception', () {
    final errors = env.services.errors;
    final e = errors.normalize(const FileSystemException('boom', '/x'));
    expect(e.type, AppErrorType.unknown);
    // 非預期的 I/O 錯誤可能只是暫時的,紀錄留在佇列重試,不標成永久失敗。
    expect(e.isRetryable, isTrue);
    expect(errors.userMessage(e), isNot(contains('FileSystemException')));
  });

  test('purge removes old synced images and orphan files only', () async {
    final storage = env.services.storage;
    final dir = await env.services.hardware.imagesDirectory();
    final now = DateTime.now();
    final old = toUnix(now.subtract(const Duration(days: 30)));
    final ancient = toUnix(now.subtract(const Duration(days: 120)));

    Future<String> file(String name) async {
      final f = File('${dir.path}/$name');
      await f.writeAsString('x');
      return f.path;
    }

    LocalMealRecord rec(String id, String path, SyncStatus s, int t) =>
        LocalMealRecord(
          localId: id,
          bedId: 'R101-B1',
          patientId: 'P1',
          mealId: 'M1',
          mealTimeSlot: 'T1',
          beforeAfter: MealPhase.before,
          imagePath: path,
          captureTime: t,
          syncStatus: s,
          createdAt: t,
          updatedAt: t,
        );

    final syncedOld = await file('synced_old.jpg');
    final syncedAncient = await file('synced_ancient.jpg');
    final pendingOld = await file('pending_old.jpg');
    final fresh = await file('fresh.jpg');
    final orphan = await file('orphan.jpg.raw');
    await storage.saveRecord(rec('a', syncedOld, SyncStatus.synced, old));
    await storage.saveRecord(
      rec('b', syncedAncient, SyncStatus.synced, ancient),
    );
    await storage.saveRecord(rec('c', pendingOld, SyncStatus.pending, old));
    await storage.saveRecord(rec('d', fresh, SyncStatus.synced, toUnix(now)));

    // 「現在」設在兩天後,孤兒檔就超過保留期了。
    await env.services.records.purgeExpired(
      now: now.add(const Duration(days: 2)),
    );

    expect(File(syncedOld).existsSync(), isFalse);
    expect(await storage.getRecord('a'), isNotNull, reason: '紀錄保留 90 天');
    expect(File(syncedAncient).existsSync(), isFalse);
    expect(await storage.getRecord('b'), isNull);
    expect(File(pendingOld).existsSync(), isTrue, reason: '未上傳的不能刪');
    expect(File(fresh).existsSync(), isTrue);
    expect(File(orphan).existsSync(), isFalse);
  });

  test('Retry-After is the minimum next delay', () async {
    final queue = env.services.queue;
    final now = nowUnix();
    final item = OfflineQueueItem(
      queueId: 'ra',
      operationType: QueueOperation.uploadMealRecord,
      endpoint: AppConstants.mealRecordPath,
      requestData: const {'local_id': 'x'},
      createdAt: now,
      updatedAt: now,
    );
    final updated = await queue.markFailed(
      item,
      const AppException(
        AppErrorType.client,
        'slow down',
        statusCode: 429,
        retryAfter: Duration(minutes: 10),
      ),
    );
    expect(updated.status, QueueStatus.pending, reason: '429 可重試');
    expect(updated.nextAttemptAt - nowUnix(), closeTo(600, 1));
  });

  test('a proxy HTML response never marks the record failed', () async {
    // 例如 Cloudflare WAF 的 403 HTML:ApiClient 轉成可重試的 parse 錯誤。
    api.uploadErrors.add(
      const AppException(
        AppErrorType.parse,
        '伺服器回應異常 (HTTP 403)',
        statusCode: 403,
        retryable: true,
      ),
    );
    final path = await _writePng(tmp, 640, 480);
    final outcome = await createRecord(path);
    expect(outcome.status, UploadOutcomeStatus.queued);
    api.uploadErrors.add(
      const AppException(
        AppErrorType.server,
        '伺服器故障',
        statusCode: 530,
        retryable: true,
      ),
    );
    await makeAllDue();
    await env.services.sync.processQueue();
    final saved = await env.services.storage.getRecord(outcome.record.localId);
    expect(saved!.syncStatus, SyncStatus.pending);
    expect(
      (await env.services.queue.pendingItems()).single.status,
      QueueStatus.pending,
    );

    await makeAllDue();
    await env.services.sync.processQueue();
    final synced = await env.services.storage.getRecord(outcome.record.localId);
    expect(synced!.syncStatus, SyncStatus.synced);
  });

  test('server retryable:false fails the record for good', () async {
    api.uploadErrors.add(
      const AppException(
        AppErrorType.server,
        'bad image',
        code: 'INVALID_IMAGE',
        statusCode: 500,
        retryable: false,
      ),
    );
    final path = await _writePng(tmp, 640, 480);
    final outcome = await createRecord(path);
    expect(outcome.status, UploadOutcomeStatus.failed);
  });

  test(
    'after-photo waits until the before-photo of the same meal is up',
    () async {
      // 餐前上傳失敗 (留在佇列退避),接著拍餐後:餐後不能搶先送出。
      api.uploadErrors.add(_network);
      final before = await createRecord(
        await _writePng(tmp, 640, 480),
        phase: MealPhase.before,
      );
      expect(before.status, UploadOutcomeStatus.queued);
      final after = await createRecord(await _writePng(tmp, 640, 480));
      expect(after.status, UploadOutcomeStatus.queued, reason: '餐前還沒上傳');
      expect(after.message, contains('餐前'));
      expect(api.phases, ['before'], reason: '餐後沒有直接上傳');

      // 兩筆都到期:FIFO 先送餐前,餐後隨後。
      await makeAllDue();
      await env.services.sync.processQueue();
      expect(api.phases, ['before', 'before', 'after']);
      expect(
        (await env.services.storage.getRecord(after.record.localId))!
            .syncStatus,
        SyncStatus.synced,
      );
    },
  );

  test(
    'after-photo is deferred while its before-photo is still pending',
    () async {
      final storage = env.services.storage;
      final queue = env.services.queue;
      final now = nowUnix();
      LocalMealRecord rec(String id, MealPhase phase, String path) =>
          LocalMealRecord(
            localId: id,
            bedId: 'R101-B1',
            patientId: 'P1',
            mealId: 'M1',
            mealTimeSlot: 'T1',
            beforeAfter: phase,
            imagePath: path,
            captureTime: now,
            createdAt: now,
            updatedAt: now,
          );
      final b = rec('b', MealPhase.before, await _writePng(tmp, 640, 480));
      final a = rec('a', MealPhase.after, await _writePng(tmp, 640, 480));
      // 餐後先建立 (FIFO 排在前面),餐前還在退避中 (尚未到期)。
      await queue.enqueueMealRecord(
        localId: 'a',
        upload: env.services.records.uploadFor(a, 'dev'),
        record: a,
        immediate: true,
      );
      await queue.enqueueMealRecord(
        localId: 'b',
        upload: env.services.records.uploadFor(b, 'dev'),
        record: b,
        nextAttemptAt: now + 100,
      );

      await env.services.sync.processQueue();
      expect(api.uploads, 0, reason: '餐後要等餐前');
      final deferred = (await queue.pendingItems()).firstWhere(
        (i) => i.requestData['local_id'] == 'a',
      );
      expect(deferred.attempts, 0, reason: '延後不算失敗');
      expect(deferred.nextAttemptAt, greaterThan(now + 100));
      expect((await storage.getRecord('a'))!.syncStatus, SyncStatus.pending);

      // 不同住民或不同天的餐前不會擋。
      final other = await queue.pendingBeforeFor({
        ...env.services.records.uploadFor(a, 'dev').toJson(),
        'patient_id': 'P2',
      });
      expect(other, isNull);
      final nextDay = await queue.pendingBeforeFor({
        ...env.services.records.uploadFor(a, 'dev').toJson(),
        'capture_time': now + 2 * 86400,
      });
      expect(nextDay, isNull);
    },
  );

  test('re-pairing makes every waiting item due and syncs', () async {
    api.uploadErrors.add(
      const AppException(AppErrorType.unauthorized, 'expired', statusCode: 401),
    );
    final outcome = await createRecord(await _writePng(tmp, 640, 480));
    expect(outcome.status, UploadOutcomeStatus.queued);
    final waiting = (await env.services.queue.pendingItems()).single;
    await env.services.storage.saveQueueItem(
      waiting.copyWith(nextAttemptAt: nowUnix() + 1800),
    );

    await pairWithMock(env);
    await env.services.sync.afterPaired();

    expect(await env.services.queue.pendingItems(), isEmpty);
    expect(
      (await env.services.storage.getRecord(outcome.record.localId))!
          .syncStatus,
      SyncStatus.synced,
    );
  });
}

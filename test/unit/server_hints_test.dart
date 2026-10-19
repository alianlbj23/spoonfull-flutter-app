import 'package:flutter_test/flutter_test.dart';
import 'package:spoonfull_flutter_app/config/app_constants.dart';
import 'package:spoonfull_flutter_app/core/errors/app_exception.dart';
import 'package:spoonfull_flutter_app/core/utils/time_utils.dart';
import 'package:spoonfull_flutter_app/data/api/mock_api_repository.dart';
import 'package:spoonfull_flutter_app/data/models/api_models.dart';
import 'package:spoonfull_flutter_app/data/models/device_config.dart';
import 'package:spoonfull_flutter_app/data/models/meal_data.dart';
import 'package:spoonfull_flutter_app/state/device_state.dart';
import 'package:spoonfull_flutter_app/state/record_state.dart';

import '../helpers/test_services.dart';

/// 模擬新版 server:meals 帶時段與指派提示,health 可設定時間差,
/// 配對的 start / poll 可排入錯誤與 pending 次數。
class HintApi extends MockApiRepository {
  HintApi() : super(latency: Duration.zero, pendingPolls: 0);

  String? currentSlot = 'T3';
  final List<AppException> startErrors = [];
  final List<AppException> pollErrors = [];
  int startCalls = 0;
  int pollCalls = 0;

  /// 前幾次輪詢回 pending。
  int pendingFirst = 0;
  Duration clockOffset = Duration.zero;

  @override
  Future<PairingStart> startPairing({
    required String hardwareId,
    required String appVersion,
  }) {
    startCalls++;
    if (startErrors.isNotEmpty) throw startErrors.removeAt(0);
    return super.startPairing(hardwareId: hardwareId, appVersion: appVersion);
  }

  @override
  Future<PairingPoll> pollPairing(String deviceCode) async {
    pollCalls++;
    if (pollErrors.isNotEmpty) throw pollErrors.removeAt(0);
    if (pollCalls <= pendingFirst) return const PairingPoll.pending();
    return super.pollPairing(deviceCode);
  }

  @override
  Future<MealsResponse> fetchMeals({String? placeId}) async {
    final base = await super.fetchMeals(placeId: placeId);
    MealData meal(String id, MealType type, String slot, List<String> who) =>
        MealData(
          placeId: 'demo',
          mealId: id,
          mealName: id,
          mealType: type,
          mealTimeSlot: slot,
          assignedPatientIds: who,
          lastUpdated: 1,
        );
    return MealsResponse(
      [
        meal('L-general', MealType.lunch, 'T2', const []),
        meal('L-lowsalt', MealType.lunch, 'T2', const ['P2']),
        meal('D-soft', MealType.dinner, 'T3', const ['P2']),
      ],
      base.timeSlots,
      base.timestamp,
      currentSlot: currentSlot,
    );
  }

  @override
  Future<ServerHealth> checkHealth() async => ServerHealth(
    reachable: true,
    status: 'ok',
    serverTime: toUnix(DateTime.now().subtract(clockOffset)),
    apiVersion: 1,
    checkedAt: DateTime.now(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestEnv env;
  late HintApi api;

  setUp(() async {
    api = HintApi();
    env = await createTestEnv(api: api, prefs: configuredPrefs);
  });

  tearDown(() async {
    await pumpEventQueue();
    await env.dispose();
  });

  group('meal selection from server hints', () {
    late RecordState state;

    setUp(() async {
      await pairWithMock(env);
      await env.services.sync.refreshCache(force: true);
      state = RecordState(env.services);
      await state.loadAll();
    });

    tearDown(() => state.dispose());

    TimeSlot slot(String id) =>
        state.timeSlots.firstWhere((s) => s.timeSlotId == id);

    test('meals response hints are cached', () async {
      final meals = await env.services.storage.getMeals('demo');
      final soft = meals.firstWhere((m) => m.mealId == 'D-soft');
      expect(soft.mealTimeSlot, 'T3');
      expect(soft.assignedPatientIds, ['P2']);
      expect(env.services.storage.currentSlotHint.$1, 'T3');
    });

    test('only dishes of the selected slot, assigned ones first', () {
      expect(state.mealsFor(slot('T2'), patientId: 'P2').map((m) => m.mealId), [
        'L-lowsalt',
        'L-general',
      ]);
      expect(state.mealsFor(slot('T3')).map((m) => m.mealId), ['D-soft']);
    });

    test('default prefers the patient assignment within the slot', () {
      expect(
        state.defaultMealFor(slot('T2'), patientId: 'P2')!.mealId,
        'L-lowsalt',
      );
      expect(
        state.defaultMealFor(slot('T2'), patientId: 'P1')!.mealId,
        'L-general',
      );
      expect(
        state.defaultMealFor(slot('T3'), patientId: 'P1')!.mealId,
        'D-soft',
      );
    });

    test('never defaults to a dish from another slot', () {
      expect(state.mealsFor(slot('T1')), isEmpty);
      expect(state.defaultMealFor(slot('T1'), patientId: 'P2'), isNull);
    });

    test('current_slot from the server wins while it is fresh', () async {
      final evening = DateTime(2026, 10, 14, 18);
      final meals = await env.services.storage.getMeals('demo');
      final slots = await env.services.storage.getTimeSlots('demo');
      await env.services.storage.saveMeals(
        'demo',
        meals,
        slots,
        currentSlot: 'T2',
        currentSlotAt: toUnix(evening),
      );
      await state.loadAll();
      // 機台時鐘說是 18:05 (晚餐),但 server 剛說是午餐 → 用午餐。
      expect(
        state
            .currentTimeSlot(evening.add(const Duration(minutes: 5)))!
            .timeSlotId,
        'T2',
      );
      // 提示過期 (超過一次定時同步的間隔) → 退回機台時鐘。
      final stale = evening.add(
        AppConstants.periodicSyncInterval + const Duration(minutes: 1),
      );
      expect(state.currentTimeSlot(stale)!.timeSlotId, 'T3');
    });
  });

  group('DeviceState pairing (device authorization flow)', () {
    late DeviceState device;

    setUp(() => device = DeviceState(env.services));
    tearDown(() => device.dispose());

    AppException error(
      String code,
      int status, {
      AppErrorType type = AppErrorType.client,
      bool? retryable,
      Duration? retryAfter,
      String message = '',
    }) => AppException(
      type,
      message,
      code: code,
      statusCode: status,
      retryable: retryable,
      retryAfter: retryAfter,
    );

    test('pending → approved stores the token and pairs', () async {
      final uuid = env.services.storage.deviceConfig.deviceId;
      api.pendingFirst = 1;
      await device.startPairing();
      expect(device.status, PairingStatus.pairing);
      expect(device.pairingCode, matches(RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$')));
      expect(device.pairingTimeLeft(), isNotNull);
      expect(device.pairingRetryIn()!.inSeconds, inInclusiveRange(3, 5));
      expect(api.startCalls, 1);

      await device.pollPairingNow();
      expect(device.status, PairingStatus.pairing, reason: 'pending → 繼續等');
      expect(await env.tokens.read(), isNull);

      await device.pollPairingNow();
      expect(device.status, PairingStatus.paired);
      expect(device.pairingCode, isNull, reason: '配對完成後丟掉配對碼');
      expect(device.pairingRetryIn(), isNull);
      expect((await env.tokens.read())!.deviceToken, 'mock-token-$uuid');
      final config = env.services.storage.deviceConfig;
      expect(config.paired, isTrue);
      expect(config.deviceName, MockApiRepository.mockDeviceName);
      expect(config.serverDeviceId, MockApiRepository.mockServerDeviceId);
      expect(config.deviceId, uuid, reason: 'server 的 device_id 不覆蓋 UUID');
      expect(await env.services.pairing.hasValidToken(), isTrue);
    });

    test('EXPIRED fetches a new code without user action', () async {
      await device.startPairing();
      api.pollErrors.add(error('EXPIRED', 400, retryable: false));
      await device.pollPairingNow();
      await pumpEventQueue();
      expect(api.startCalls, 2);
      expect(device.status, PairingStatus.pairing);
      expect(device.pairingCode, isNotNull);
      expect(device.pairingDenied, isFalse);
      expect(device.pairingRetryIn(), isNotNull, reason: '新碼繼續輪詢');
    });

    test('DENIED shows the message and stops polling', () async {
      await device.startPairing();
      api.pollErrors.add(
        error('DENIED', 403, type: AppErrorType.forbidden, retryable: false),
      );
      await device.pollPairingNow();
      await pumpEventQueue();
      expect(device.pairingDenied, isTrue);
      expect(device.pairingError, '管理員拒絕了這次配對');
      expect(device.status, PairingStatus.notPaired);
      expect(device.pairingCode, isNull);
      expect(device.pairingRetryIn(), isNull, reason: '不自動重試');
      expect(api.startCalls, 1);
      expect(api.pollCalls, 1);

      // 使用者按「重新取得配對碼」才再開始。
      await device.startPairing();
      expect(api.startCalls, 2);
      expect(device.pairingDenied, isFalse);
      expect(device.status, PairingStatus.pairing);
    });

    test('SLOW_DOWN lengthens the polling interval', () async {
      await device.startPairing();
      expect(device.pollInterval, const Duration(seconds: 5));
      api.pollErrors.add(error('SLOW_DOWN', 429, retryable: true));
      await device.pollPairingNow();
      expect(device.pollInterval, const Duration(seconds: 10));
      expect(device.pairingRetryIn()!.inSeconds, inInclusiveRange(8, 10));
      expect(device.status, PairingStatus.pairing);
      expect(device.pairingCode, isNotNull, reason: '不換碼');
    });

    test('THROTTLED on start waits Retry-After before trying again', () async {
      api.startErrors.add(
        error(
          'THROTTLED',
          429,
          retryable: true,
          retryAfter: const Duration(seconds: 30),
          message: '嘗試太多次,請稍後再試',
        ),
      );
      await device.startPairing();
      expect(api.startCalls, 1);
      expect(device.status, PairingStatus.pairing);
      expect(device.pairingCode, isNull);
      expect(device.pairingError, '嘗試太多次,請稍後再試');
      expect(device.pairingRetryIn()!.inSeconds, inInclusiveRange(28, 30));
      expect(
        device.pairingRetryIn(DateTime.now().add(const Duration(seconds: 31))),
        isNull,
      );
    });

    test('THROTTLED without Retry-After waits one poll interval', () async {
      api.startErrors.add(error('THROTTLED', 429, retryable: true));
      await device.startPairing();
      expect(device.pairingRetryIn()!.inSeconds, inInclusiveRange(3, 5));
    });

    test('network errors keep the code and retry with backoff', () async {
      await device.startPairing();
      final code = device.pairingCode;
      api.pollErrors.add(const AppException(AppErrorType.network, '無法連線到伺服器'));
      await device.pollPairingNow();
      expect(device.status, PairingStatus.pairing);
      expect(device.pairingCode, code);
      expect(api.startCalls, 1);
      expect(
        device.pairingRetryIn()!.inMilliseconds,
        inInclusiveRange(1, AppConstants.retryDelays.first.inMilliseconds),
      );
    });

    test('unrecoverable errors stop with the server message', () async {
      api.startErrors.add(
        error(
          'INVALID_HARDWARE_ID',
          400,
          retryable: false,
          message: 'hardware_id 格式錯誤',
        ),
      );
      await device.startPairing();
      expect(device.status, PairingStatus.notPaired);
      expect(device.pairingError, 'hardware_id 格式錯誤');
      expect(device.pairingRetryIn(), isNull);
    });

    test('stopPairing drops the code; resumePairing restarts', () async {
      await device.startPairing();
      device.stopPairing();
      expect(device.status, PairingStatus.notPaired);
      expect(device.pairingCode, isNull);
      expect(device.pairingRetryIn(), isNull);
      await device.resumePairing();
      expect(api.startCalls, 2, reason: '碼已丟掉,重新取');
      expect(device.status, PairingStatus.pairing);
    });

    test('401 clears the token and returns to not paired', () async {
      await device.startPairing();
      await device.pollPairingNow();
      expect(device.status, PairingStatus.paired);

      env.services.errors.notifyUnauthorized();
      await pumpEventQueue();
      expect(device.status, PairingStatus.notPaired);
      expect(await env.tokens.read(), isNull);
      expect(device.forcedLogoutMessage, isNotNull);
      expect(env.services.storage.deviceConfig.paired, isFalse);
      expect(
        env.services.storage.deviceConfig.serverDeviceId,
        MockApiRepository.mockServerDeviceId,
        reason: '解除配對不清掉 server 編號',
      );
    });

    test('startPairing without server settings fails locally', () async {
      await env.services.storage.saveServerSettings(
        const ServerSettings(host: '', placeId: ''),
      );
      await device.startPairing();
      expect(device.status, PairingStatus.notPaired);
      expect(device.pairingError, '請先完成伺服器設定');
      expect(api.startCalls, 0);
    });
  });

  group('DeviceState health check', () {
    late DeviceState device;

    setUp(() => device = DeviceState(env.services));
    tearDown(() => device.dispose());

    test('warns when the device clock is off by more than 2 minutes', () async {
      api.clockOffset = const Duration(minutes: 5);
      await device.checkServer();
      expect(device.serverReachable, isTrue);
      expect(device.clockSkewWarning, isNotNull);
      expect(device.clockSkewWarning, contains('機台時間'));
    });

    test('no warning when clocks agree', () async {
      api.clockOffset = const Duration(seconds: 30);
      await device.checkServer();
      expect(device.serverReachable, isTrue);
      expect(device.clockSkewWarning, isNull);
    });
  });
}

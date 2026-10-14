import 'package:flutter_test/flutter_test.dart';
import 'package:spoonfull_flutter_app/config/app_constants.dart';
import 'package:spoonfull_flutter_app/core/errors/app_exception.dart';
import 'package:spoonfull_flutter_app/core/utils/time_utils.dart';
import 'package:spoonfull_flutter_app/data/api/mock_api_repository.dart';
import 'package:spoonfull_flutter_app/data/models/api_models.dart';
import 'package:spoonfull_flutter_app/data/models/meal_data.dart';
import 'package:spoonfull_flutter_app/state/device_state.dart';
import 'package:spoonfull_flutter_app/state/record_state.dart';

import '../helpers/test_services.dart';

/// 模擬新版 server:meals 帶時段與指派提示,health 可設定時間差,配對可設定錯誤。
class HintApi extends MockApiRepository {
  HintApi() : super(latency: Duration.zero);

  String? currentSlot = 'T3';
  final List<AppException> pairErrors = [];
  int pairCalls = 0;
  Duration clockOffset = Duration.zero;

  @override
  Future<PairingResult> pairDevice({
    required String deviceId,
    required String deviceName,
    required String location,
    required String pairingCode,
  }) {
    pairCalls++;
    if (pairErrors.isNotEmpty) throw pairErrors.removeAt(0);
    return super.pairDevice(
      deviceId: deviceId,
      deviceName: deviceName,
      location: location,
      pairingCode: pairingCode,
    );
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
      await env.services.pairing.pair(MockApiRepository.validPairingCode);
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

  group('DeviceState pairing errors', () {
    late DeviceState device;

    setUp(() => device = DeviceState(env.services));
    tearDown(() => device.dispose());

    test('server message is shown as-is', () async {
      api.pairErrors.add(
        const AppException(
          AppErrorType.validation,
          '此機台已被管理員停用,請聯絡管理員',
          code: 'DEVICE_DISABLED',
          statusCode: 422,
          retryable: false,
        ),
      );
      expect(await device.pair('123456'), isFalse);
      expect(device.pairingError, '此機台已被管理員停用,請聯絡管理員');

      // Mock 的錯誤配對碼 (400 INVALID_PAIRING_CODE)。
      expect(await device.pair('000000'), isFalse);
      expect(device.pairingError, '配對碼無效或已過期');
      expect(device.pairingError, isNot(contains('請求參數錯誤')));
    });

    test('THROTTLED blocks pairing for Retry-After seconds', () async {
      api.pairErrors.add(
        const AppException(
          AppErrorType.client,
          '嘗試太多次,請稍後再試',
          code: 'THROTTLED',
          statusCode: 429,
          retryable: true,
          retryAfter: Duration(seconds: 30),
        ),
      );
      expect(await device.pair('123456'), isFalse);
      expect(device.pairingError, '嘗試太多次,請稍後再試');
      final left = device.pairingCooldown()!;
      expect(left.inSeconds, inInclusiveRange(28, 30));

      // 倒數中按配對不會打到 server。
      expect(await device.pair('123456'), isFalse);
      expect(api.pairCalls, 1);

      // 倒數結束後可以再配對。
      expect(
        device.pairingCooldown(DateTime.now().add(const Duration(seconds: 31))),
        isNull,
      );
      device.pairingBlockedUntil = null;
      expect(await device.pair('123456'), isTrue);
    });

    test('THROTTLED without Retry-After waits the default', () async {
      api.pairErrors.add(
        const AppException(
          AppErrorType.client,
          'slow',
          code: 'THROTTLED',
          statusCode: 429,
        ),
      );
      await device.pair('123456');
      expect(
        device.pairingCooldown()!.inSeconds,
        closeTo(AppConstants.pairingThrottleDefault.inSeconds, 2),
      );
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

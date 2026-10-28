import 'dart:math';

import '../../core/errors/app_exception.dart';
import '../../core/utils/time_utils.dart';
import '../models/ai_result.dart';
import '../models/api_models.dart';
import '../models/bed_data.dart';
import '../models/meal_data.dart';
import '../models/room_data.dart';
import 'api_repository.dart';

/// 無後端時的示範資料 (`--dart-define=USE_MOCK_API=true`)。
///
/// 配對不需要管理員:輪詢 [pendingPolls] 次後自動核准。
class MockApiRepository implements ApiRepository {
  MockApiRepository({
    this.latency = const Duration(milliseconds: 400),
    this.pendingPolls = 1,
  });

  static const String mockDeviceName = '示範機台';
  static const int mockServerDeviceId = 12;

  final Duration latency;

  /// 核准前回幾次 `pending`。
  final int pendingPolls;

  final _random = Random();

  /// 目前有效的 device_code → 已輪詢次數;換新碼時舊碼失效。
  final Map<String, int> _polls = {};
  String? _hardwareId;

  static const _roomNames = [
    '101',
    '102',
    '103',
    '104',
    '105',
    '106',
    '107',
    '108',
    '109',
    '110',
    '111',
    '門診',
  ];
  static const _patients = ['王小明', '陳美玲', '林志強', '張淑芬', '李大同', '黃怡君'];

  Future<void> _delay() => Future<void>.delayed(latency);

  @override
  Future<PairingStart> startPairing({
    required String hardwareId,
    required String appVersion,
  }) async {
    await _delay();
    _hardwareId = hardwareId;
    _polls.clear();
    final deviceCode = List.generate(
      64,
      (_) => '0123456789abcdef'[_random.nextInt(16)],
    ).join();
    _polls[deviceCode] = 0;
    final pairingCode = List.generate(
      8,
      (_) => 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'[_random.nextInt(31)],
    ).join();
    return PairingStart(
      deviceCode: deviceCode,
      pairingCode: pairingCode,
      expiresIn: 600,
      interval: 5,
    );
  }

  @override
  Future<PairingPoll> pollPairing(String deviceCode) async {
    await _delay();
    final n = _polls[deviceCode];
    if (n == null) {
      throw const AppException(
        AppErrorType.client,
        '配對碼已過期,請重新取得',
        code: 'EXPIRED',
        statusCode: 400,
        retryable: false,
      );
    }
    _polls[deviceCode] = n + 1;
    if (n < pendingPolls) return const PairingPoll.pending();
    _polls.remove(deviceCode);
    return PairingPoll.approved(
      deviceToken: 'mock-token-$_hardwareId',
      serverDeviceId: mockServerDeviceId,
      deviceName: mockDeviceName,
    );
  }

  @override
  Future<DeviceIdentity> fetchMe() async {
    await _delay();
    return const DeviceIdentity(
      serverDeviceId: mockServerDeviceId,
      deviceName: mockDeviceName,
      location: 'demo',
    );
  }

  @override
  Future<RoomsResponse> fetchRooms({String? placeId, int? lastUpdated}) async {
    await _delay();
    final now = nowUnix();
    return RoomsResponse([
      for (final name in _roomNames)
        RoomData(
          placeId: placeId ?? 'demo',
          roomId: 'R$name',
          roomName: name,
          bedsCount: 3,
          lastUpdated: now,
        ),
    ], now);
  }

  @override
  Future<BedsResponse> fetchBeds({
    String? placeId,
    String? roomId,
    int? lastUpdated,
  }) async {
    await _delay();
    final now = nowUnix();
    final beds = <BedData>[];
    for (var r = 0; r < _roomNames.length; r++) {
      final rid = 'R${_roomNames[r]}';
      if (roomId != null && roomId != rid) continue;
      for (var b = 1; b <= 3; b++) {
        final occupied = (r + b) % 4 != 0;
        beds.add(
          BedData(
            placeId: placeId ?? 'demo',
            roomId: rid,
            bedId: '$rid-B$b',
            bedName: '床號$b',
            patientId: occupied ? 'P${r * 10 + b}' : null,
            patientName: occupied
                ? _patients[(r * 3 + b) % _patients.length]
                : null,
            patientAge: occupied ? 50 + (r * 7 + b * 3) % 40 : null,
            lastUpdated: now,
          ),
        );
      }
    }
    return BedsResponse(beds, now);
  }

  @override
  Future<MealsResponse> fetchMeals({String? placeId}) async {
    await _delay();
    final now = nowUnix();
    final place = placeId ?? 'demo';
    return MealsResponse(
      [
        MealData(
          placeId: place,
          mealId: 'M1',
          mealName: '一般早餐',
          mealType: MealType.breakfast,
          lastUpdated: now,
        ),
        MealData(
          placeId: place,
          mealId: 'M2',
          mealName: '一般午餐',
          mealType: MealType.lunch,
          lastUpdated: now,
        ),
        MealData(
          placeId: place,
          mealId: 'M3',
          mealName: '一般晚餐',
          mealType: MealType.dinner,
          lastUpdated: now,
        ),
        MealData(
          placeId: place,
          mealId: 'M4',
          mealName: '低鈉餐',
          mealType: MealType.lunch,
          lastUpdated: now,
        ),
      ],
      const [
        TimeSlot(
          timeSlotId: 'T1',
          timeSlotName: '07:00 - 08:30',
          startTime: '07:00',
          endTime: '08:30',
          sortOrder: 0,
        ),
        TimeSlot(
          timeSlotId: 'T2',
          timeSlotName: '11:30 - 13:00',
          startTime: '11:30',
          endTime: '13:00',
          sortOrder: 1,
        ),
        TimeSlot(
          timeSlotId: 'T3',
          timeSlotName: '17:00 - 18:30',
          startTime: '17:00',
          endTime: '18:30',
          sortOrder: 2,
        ),
      ],
      now,
    );
  }

  /// 以 client_record_id 去重 (ARCHITECTURE.md §6.4):重送同一筆回原本的 record_id。
  final Map<String, String> _recordIds = {};

  @override
  Future<MealRecordResult> uploadMealRecord(MealRecordUpload upload) async {
    await _delay();
    final after = upload.beforeAfter == 'after';
    final leftover = after ? _random.nextInt(60).toDouble() : 100.0;
    final recordId = _recordIds.putIfAbsent(
      upload.clientRecordId,
      () => 'SRV-${DateTime.now().microsecondsSinceEpoch}',
    );
    return MealRecordResult(
      recordId: recordId,
      captureTime: upload.captureTime,
      aiStatus: 'completed',
      aiResult: AiResult(
        hasFood: leftover > 0,
        hasPerson: false,
        leftoverPercentage: leftover,
        confidence: 0.8 + _random.nextDouble() * 0.19,
        note: after ? '剩餘約 ${leftover.round()}%' : '餐點完整',
      ),
      createdAt: nowUnix(),
    );
  }

  @override
  Future<bool> ping() async => true;

  @override
  Future<ServerHealth> checkHealth() async => ServerHealth(
    reachable: true,
    status: 'ok',
    serverTime: nowUnix(),
    apiVersion: 1,
    checkedAt: DateTime.now(),
  );
}

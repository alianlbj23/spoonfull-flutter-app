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
/// 配對碼固定為 `123456`。
class MockApiRepository implements ApiRepository {
  MockApiRepository({this.latency = const Duration(milliseconds: 400)});

  static const String validPairingCode = '123456';

  final Duration latency;
  final _random = Random();

  static const _roomNames = [
    '101', '102', '103', '104', '105', '106',
    '107', '108', '109', '110', '111', '門診',
  ];
  static const _patients = ['王小明', '陳美玲', '林志強', '張淑芬', '李大同', '黃怡君'];

  Future<void> _delay() => Future<void>.delayed(latency);

  @override
  Future<PairingResult> pairDevice({
    required String deviceId,
    required String deviceName,
    required String location,
    required String pairingCode,
  }) async {
    await _delay();
    if (pairingCode != validPairingCode) {
      throw const AppException(
        AppErrorType.client,
        '配對碼無效或已過期',
        code: 'INVALID_PAIRING_CODE',
        statusCode: 400,
      );
    }
    return PairingResult(
      deviceId: deviceId,
      deviceToken: 'mock-token-$deviceId',
      expiresIn: 86400,
      message: 'Device paired successfully',
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
        MealData(placeId: place, mealId: 'M1', mealName: '一般早餐', mealType: MealType.breakfast, lastUpdated: now),
        MealData(placeId: place, mealId: 'M2', mealName: '一般午餐', mealType: MealType.lunch, lastUpdated: now),
        MealData(placeId: place, mealId: 'M3', mealName: '一般晚餐', mealType: MealType.dinner, lastUpdated: now),
        MealData(placeId: place, mealId: 'M4', mealName: '低鈉餐', mealType: MealType.lunch, lastUpdated: now),
      ],
      const [
        TimeSlot(timeSlotId: 'T1', timeSlotName: '07:00 - 08:30', startTime: '07:00', endTime: '08:30', sortOrder: 0),
        TimeSlot(timeSlotId: 'T2', timeSlotName: '11:30 - 13:00', startTime: '11:30', endTime: '13:00', sortOrder: 1),
        TimeSlot(timeSlotId: 'T3', timeSlotName: '17:00 - 18:30', startTime: '17:00', endTime: '18:30', sortOrder: 2),
      ],
      now,
    );
  }

  @override
  Future<MealRecordResult> uploadMealRecord(MealRecordUpload upload) async {
    await _delay();
    final after = upload.beforeAfter == 'after';
    final leftover = after ? _random.nextInt(60).toDouble() : 100.0;
    return MealRecordResult(
      recordId: 'SRV-${DateTime.now().microsecondsSinceEpoch}',
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
}

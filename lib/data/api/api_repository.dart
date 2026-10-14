import 'dart:io';

import 'package:path/path.dart' as p;

import '../../config/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/logger.dart';
import '../../core/utils/time_utils.dart';
import '../models/api_models.dart';
import '../models/bed_data.dart';
import '../models/meal_data.dart';
import '../models/room_data.dart';
import 'api_client.dart';

/// 後端 API 介面 (規格 4)。
abstract class ApiRepository {
  Future<PairingResult> pairDevice({
    required String deviceId,
    required String deviceName,
    required String location,
    required String pairingCode,
  });

  Future<RoomsResponse> fetchRooms({String? placeId, int? lastUpdated});

  Future<BedsResponse> fetchBeds({
    String? placeId,
    String? roomId,
    int? lastUpdated,
  });

  Future<MealsResponse> fetchMeals({String? placeId});

  Future<MealRecordResult> uploadMealRecord(MealRecordUpload upload);

  /// 伺服器是否可連線 (`api/machine/health/`,舊版 server 退回舊做法)。
  Future<bool> ping();

  /// 健康檢查,另外帶回 server 時間供時鐘誤差檢查。
  Future<ServerHealth> checkHealth();
}

class HttpApiRepository implements ApiRepository {
  HttpApiRepository(this._client);

  final ApiClient _client;

  @override
  Future<PairingResult> pairDevice({
    required String deviceId,
    required String deviceName,
    required String location,
    required String pairingCode,
  }) async {
    final data = await _client.postJson(
      AppConstants.devicePairPath,
      {
        'device_id': deviceId,
        'device_name': deviceName,
        'location': location,
        'pairing_code': pairingCode,
      },
      authenticated: false,
    );
    return PairingResult.fromJson(data);
  }

  @override
  Future<RoomsResponse> fetchRooms({String? placeId, int? lastUpdated}) async {
    final data = await _client.get(
      AppConstants.roomDataPath,
      query: {
        'place_id': ?placeId,
        if (lastUpdated != null) 'last_updated': '$lastUpdated',
      },
    );
    final rooms = _list(data['rooms']).map(RoomData.fromApi).toList();
    return RoomsResponse(rooms, asInt(data['timestamp']) ?? nowUnix());
  }

  @override
  Future<BedsResponse> fetchBeds({
    String? placeId,
    String? roomId,
    int? lastUpdated,
  }) async {
    final data = await _client.get(
      AppConstants.bedDataPath,
      query: {
        'place_id': ?placeId,
        'room_id': ?roomId,
        if (lastUpdated != null) 'last_updated': '$lastUpdated',
      },
    );
    final beds = _list(data['beds']).map(BedData.fromApi).toList();
    return BedsResponse(beds, asInt(data['timestamp']) ?? nowUnix());
  }

  @override
  Future<MealsResponse> fetchMeals({String? placeId}) async {
    final data = await _client.get(
      AppConstants.mealDataPath,
      query: {'place_id': ?placeId},
    );
    final meals = _list(data['meals']).map(MealData.fromApi).toList();
    final slots = _list(data['time_slots']);
    final current = asString(data['current_slot']);
    return MealsResponse(
      meals,
      [for (var i = 0; i < slots.length; i++) TimeSlot.fromApi(slots[i], i)],
      asInt(data['timestamp']) ?? nowUnix(),
      currentSlot: (current == null || current.isEmpty) ? null : current,
    );
  }

  @override
  Future<MealRecordResult> uploadMealRecord(MealRecordUpload upload) async {
    final file = File(upload.imagePath);
    // 照片不見了重試也沒用;其他 I/O 錯誤 (暫時讀不到) 會照常重試。
    if (!await file.exists()) {
      throw const AppException(
        AppErrorType.localValidation,
        '照片檔案不存在,無法上傳',
        code: 'IMAGE_MISSING',
      );
    }
    final bytes = await file.readAsBytes();
    final ext = p.extension(upload.imagePath).toLowerCase();
    final data = await _client.postMultipart(
      AppConstants.mealRecordPath,
      fields: upload.fields,
      fileField: 'image',
      fileBytes: bytes,
      fileName: p.basename(upload.imagePath),
      mimeType: ext == '.png' ? 'image/png' : 'image/jpeg',
    );
    final result = MealRecordResult.fromJson(data);
    if (result.duplicate ||
        result.assignmentMismatch ||
        result.bedMismatch) {
      Log.i(
        'record ${upload.clientRecordId} → ${result.recordId}: '
        'duplicate=${result.duplicate} '
        'assignment_mismatch=${result.assignmentMismatch} '
        'bed_mismatch=${result.bedMismatch}',
      );
    }
    return result;
  }

  @override
  Future<bool> ping() => _client.ping();

  @override
  Future<ServerHealth> checkHealth() => _client.checkHealth();

  static List<Map<String, Object?>> _list(Object? value) => value is List
      ? value.whereType<Map>().map((m) => m.cast<String, Object?>()).toList()
      : const [];
}

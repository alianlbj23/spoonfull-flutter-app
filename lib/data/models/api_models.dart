import 'dart:convert';

import '../../config/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/time_utils.dart';
import 'ai_result.dart';
import 'bed_data.dart';
import 'meal_data.dart';
import 'room_data.dart';

/// `pair/start/` 成功回應:機台顯示 [pairingCode] 給管理員,之後拿 [deviceCode] 輪詢。
///
/// [deviceCode] 等同一次性的密碼:只放在記憶體,不寫 log、不顯示在畫面。
class PairingStart {
  const PairingStart({
    required this.deviceCode,
    required this.pairingCode,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String pairingCode;

  /// 配對碼有效秒數。
  final int expiresIn;

  /// 輪詢間隔 (秒)。
  final int interval;

  factory PairingStart.fromJson(Map<String, Object?> json) {
    final deviceCode = asString(json['device_code']) ?? '';
    final pairingCode = asString(json['pairing_code']) ?? '';
    if (deviceCode.isEmpty || pairingCode.isEmpty) {
      throw const AppException(AppErrorType.parse, '伺服器未回傳配對碼');
    }
    final expiresIn = asInt(json['expires_in']);
    final interval = asInt(json['interval']);
    return PairingStart(
      deviceCode: deviceCode,
      pairingCode: pairingCode,
      expiresIn: expiresIn == null || expiresIn <= 0
          ? AppConstants.pairingDefaultExpiry.inSeconds
          : expiresIn,
      interval: interval == null || interval <= 0
          ? AppConstants.pairingDefaultInterval.inSeconds
          : interval,
    );
  }
}

/// `pair/poll/` 回應:管理員還沒核准 ([approved] 為 false),或已核准並附上 token。
///
/// token 只會回這一次;存進安全儲存前不要丟掉這個物件。
class PairingPoll {
  const PairingPoll.pending()
    : approved = false,
      deviceToken = '',
      serverDeviceId = null,
      deviceName = '';

  const PairingPoll.approved({
    required this.deviceToken,
    required this.serverDeviceId,
    required this.deviceName,
  }) : approved = true;

  final bool approved;
  final String deviceToken;

  /// server 端的整數 id;與 App 自己的 UUID (`DeviceConfig.deviceId`) 不同。
  final int? serverDeviceId;

  /// 管理員在網頁設定的機台名稱。
  final String deviceName;

  factory PairingPoll.fromJson(Map<String, Object?> json) {
    final status = asString(json['status']) ?? '';
    if (status == 'pending') return const PairingPoll.pending();
    if (status != 'approved') {
      throw AppException(AppErrorType.parse, '伺服器回傳未知的配對狀態 ($status)');
    }
    final token = asString(json['device_token']) ?? '';
    if (token.isEmpty) {
      throw const AppException(AppErrorType.parse, '伺服器未回傳 token');
    }
    return PairingPoll.approved(
      deviceToken: token,
      serverDeviceId: asInt(json['device_id']),
      deviceName: asString(json['device_name']) ?? '',
    );
  }
}

/// `GET api/machine/me/`:已配對機台在 server 上的身分。
class DeviceIdentity {
  const DeviceIdentity({
    required this.serverDeviceId,
    required this.deviceName,
    required this.location,
  });

  final int? serverDeviceId;
  final String deviceName;
  final String location;

  factory DeviceIdentity.fromJson(Map<String, Object?> json) => DeviceIdentity(
    serverDeviceId: asInt(json['device_id']),
    deviceName: asString(json['device_name']) ?? '',
    location: asString(json['location']) ?? '',
  );
}

class RoomsResponse {
  const RoomsResponse(this.rooms, this.timestamp);
  final List<RoomData> rooms;
  final int timestamp;
}

class BedsResponse {
  const BedsResponse(this.beds, this.timestamp);
  final List<BedData> beds;
  final int timestamp;
}

class MealsResponse {
  const MealsResponse(
    this.meals,
    this.timeSlots,
    this.timestamp, {
    this.currentSlot,
  });
  final List<MealData> meals;
  final List<TimeSlot> timeSlots;
  final int timestamp;

  /// server 依它的時鐘判斷的目前時段 (`time_slot_id`);不在任何時段內或舊版
  /// server 時為 null。
  final String? currentSlot;
}

/// `GET api/machine/health/` 的結果 (或舊版 server 的退回結果)。
class ServerHealth {
  const ServerHealth({
    required this.reachable,
    this.legacy = false,
    this.status,
    this.serverTime,
    this.apiVersion,
    this.checkedAt,
    this.error,
  });

  /// 舊版 server (沒有 health API):只知道能不能連。
  const ServerHealth.legacy({required bool reachable})
    : this(reachable: reachable, legacy: true);

  const ServerHealth.unreachable([String? error])
    : this(reachable: false, error: error);

  factory ServerHealth.fromJson(
    Map<String, Object?> json, {
    required DateTime checkedAt,
  }) {
    final status = asString(json['status']);
    return ServerHealth(
      reachable: status == null || status == 'ok',
      status: status,
      serverTime: asInt(json['server_time']),
      apiVersion: asInt(json['api_version']),
      checkedAt: checkedAt,
    );
  }

  final bool reachable;

  /// true = 舊版 server,沒有 health API。
  final bool legacy;
  final String? status;

  /// server 的 unix 秒數。
  final int? serverTime;
  final int? apiVersion;

  /// 收到回應時的機台時間。
  final DateTime? checkedAt;
  final String? error;

  /// 機台時間 − server 時間;正值代表機台比較快。無法判斷時為 null。
  Duration? get clockSkew {
    if (serverTime == null || checkedAt == null) return null;
    return Duration(seconds: toUnix(checkedAt!) - serverTime!);
  }

  bool get hasClockSkew {
    final skew = clockSkew;
    return skew != null && skew.abs() > AppConstants.clockSkewTolerance;
  }

  /// 給設定 / 狀態畫面的警告文字;時間正常時為 null。
  String? get clockSkewWarning {
    if (!hasClockSkew) return null;
    final s = clockSkew!.inSeconds;
    final minutes = (s.abs() / 60).toStringAsFixed(s.abs() < 600 ? 1 : 0);
    return '機台時間比伺服器${s > 0 ? '快' : '慢'}約 $minutes 分鐘,'
        '拍攝時間可能不正確,請校正系統時間';
  }
}

/// api/machine/records/ 上傳參數 (ARCHITECTURE.md §6.4)。
class MealRecordUpload {
  const MealRecordUpload({
    required this.imagePath,
    required this.bedId,
    required this.patientId,
    required this.mealId,
    required this.mealTimeSlot,
    required this.beforeAfter,
    required this.captureTime,
    required this.deviceId,
    required this.clientRecordId,
    this.weightG,
    this.edgeResult,
    this.depthPath,
    this.depthMetaPath,
  });

  final String imagePath;

  /// RealSense 深度圖 (multipart 欄位 `depth`, image/png) 與 meta (`depth_meta`, JSON 字串);
  /// 沒有深度時不送這兩個欄位。
  final String? depthPath;
  final String? depthMetaPath;
  final String bedId;
  final String patientId;
  final String mealId;
  final String mealTimeSlot;
  final String beforeAfter;
  final int captureTime;
  final String deviceId;

  /// App 的 localId (UUID),server 的去重鍵:重送同一筆會回原本的 record_id。
  final String clientRecordId;

  /// 秤的讀數 (公克);沒有秤時為 null,server 以菜單標準份量估算。
  final double? weightG;

  /// 機台端即時檢查結果 (§6.5 預留欄位),目前放拍照品質檢查的指標。
  final Map<String, Object?>? edgeResult;

  Map<String, String> get fields => {
    'bed_id': bedId,
    'patient_id': patientId,
    'meal_id': mealId,
    'meal_time_slot': mealTimeSlot,
    'before_after': beforeAfter,
    'capture_time': '$captureTime',
    'device_id': deviceId,
    'client_record_id': clientRecordId,
    if (weightG != null) 'weight_g': weightG!.toStringAsFixed(1),
    if (edgeResult != null) 'edge_result': jsonEncode(edgeResult),
  };

  Map<String, Object?> toJson() => {
    'bed_id': bedId,
    'patient_id': patientId,
    'meal_id': mealId,
    'meal_time_slot': mealTimeSlot,
    'before_after': beforeAfter,
    'capture_time': captureTime,
    'device_id': deviceId,
    'client_record_id': clientRecordId,
    'weight_g': weightG,
    'edge_result': edgeResult,
    'image_path': imagePath,
    'depth_path': depthPath,
    'depth_meta_path': depthMetaPath,
  };

  factory MealRecordUpload.fromJson(Map<String, Object?> json) {
    final edge = json['edge_result'];
    return MealRecordUpload(
      imagePath: json['image_path'] as String,
      bedId: json['bed_id'] as String,
      patientId: json['patient_id'] as String,
      mealId: json['meal_id'] as String,
      mealTimeSlot: json['meal_time_slot'] as String,
      beforeAfter: json['before_after'] as String,
      captureTime: asInt(json['capture_time']) ?? 0,
      deviceId: json['device_id'] as String,
      // 舊版佇列項目沒有 client_record_id,退回用 local_id。
      clientRecordId:
          asString(json['client_record_id']) ??
          asString(json['local_id']) ??
          '',
      weightG: asDouble(json['weight_g']),
      edgeResult: edge is Map ? edge.cast<String, Object?>() : null,
      depthPath: asString(json['depth_path']),
      depthMetaPath: asString(json['depth_meta_path']),
    );
  }
}

/// api/machine/records/ 成功回應。機台不等 AI 結果,`ai_status` 通常為 pending。
class MealRecordResult {
  const MealRecordResult({
    required this.recordId,
    this.imagePath,
    this.captureTime,
    required this.aiStatus,
    this.aiResult,
    this.createdAt,
    this.duplicate = false,
    this.assignmentMismatch = false,
    this.bedMismatch = false,
  });

  final String recordId;
  final String? imagePath;
  final int? captureTime;
  final String aiStatus;
  final AiResult? aiResult;
  final int? createdAt;

  /// server 已經收過同一個 client_record_id (重送),回的是原本那筆。
  final bool duplicate;

  /// 這份膳食不是指派給這位住民的。
  final bool assignmentMismatch;

  /// 床位與住民不一致 (例如住民剛換床);server 以 patient_id 為準收下。
  final bool bedMismatch;

  factory MealRecordResult.fromJson(Map<String, Object?> json) {
    final ai = json['ai_result'];
    return MealRecordResult(
      recordId: asString(json['record_id']) ?? '',
      imagePath: asString(json['image_path']),
      captureTime: asInt(json['capture_time']),
      aiStatus: asString(json['ai_status']) ?? 'pending',
      aiResult: ai is Map
          ? AiResult.fromJson(ai.cast<String, Object?>())
          : null,
      createdAt: asInt(json['created_at']),
      duplicate: json['duplicate'] == true,
      assignmentMismatch: json['assignment_mismatch'] == true,
      bedMismatch: json['bed_mismatch'] == true,
    );
  }
}

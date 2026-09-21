import '../../core/utils/time_utils.dart';

/// 床位與病患資訊 (規格 3.1.3)。
class BedData {
  const BedData({
    required this.placeId,
    required this.roomId,
    required this.bedId,
    required this.bedName,
    this.patientId,
    this.patientName,
    this.patientAge,
    required this.lastUpdated,
  });

  final String placeId;
  final String roomId;
  final String bedId;
  final String bedName;
  final String? patientId;
  final String? patientName;
  final int? patientAge;
  final int lastUpdated;

  bool get hasPatient => patientId != null && patientId!.isNotEmpty;

  factory BedData.fromApi(Map<String, Object?> json) => BedData(
    placeId: asString(json['place_id']) ?? '',
    roomId: asString(json['room_id']) ?? '',
    bedId: asString(json['bed_id']) ?? '',
    bedName: asString(json['bed_name']) ?? '',
    patientId: asString(json['patient_id']),
    patientName: asString(json['patient_name']),
    patientAge: asInt(json['patient_age']),
    lastUpdated: asInt(json['updated_at']) ?? nowUnix(),
  );

  factory BedData.fromDb(Map<String, Object?> row) => BedData(
    placeId: row['place_id'] as String,
    roomId: row['room_id'] as String,
    bedId: row['bed_id'] as String,
    bedName: row['bed_name'] as String,
    patientId: row['patient_id'] as String?,
    patientName: row['patient_name'] as String?,
    patientAge: row['patient_age'] as int?,
    lastUpdated: row['last_updated'] as int,
  );

  Map<String, Object?> toDb() => {
    'place_id': placeId,
    'room_id': roomId,
    'bed_id': bedId,
    'bed_name': bedName,
    'patient_id': patientId,
    'patient_name': patientName,
    'patient_age': patientAge,
    'last_updated': lastUpdated,
  };
}

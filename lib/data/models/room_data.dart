import '../../core/utils/time_utils.dart';

/// 病房 (規格 3.1.3)。
class RoomData {
  const RoomData({
    required this.placeId,
    required this.roomId,
    required this.roomName,
    required this.bedsCount,
    required this.lastUpdated,
  });

  final String placeId;
  final String roomId;
  final String roomName;
  final int bedsCount;
  final int lastUpdated;

  factory RoomData.fromApi(Map<String, Object?> json) => RoomData(
    placeId: asString(json['place_id']) ?? '',
    roomId: asString(json['room_id']) ?? '',
    roomName: asString(json['room_name']) ?? '',
    bedsCount: asInt(json['beds_count']) ?? 0,
    lastUpdated: asInt(json['updated_at']) ?? nowUnix(),
  );

  factory RoomData.fromDb(Map<String, Object?> row) => RoomData(
    placeId: row['place_id'] as String,
    roomId: row['room_id'] as String,
    roomName: row['room_name'] as String,
    bedsCount: row['beds_count'] as int,
    lastUpdated: row['last_updated'] as int,
  );

  Map<String, Object?> toDb() => {
    'place_id': placeId,
    'room_id': roomId,
    'room_name': roomName,
    'beds_count': bedsCount,
    'last_updated': lastUpdated,
  };
}

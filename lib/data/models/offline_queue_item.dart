import 'dart:convert';

enum QueueOperation {
  uploadMealRecord('upload_meal_record'),
  uploadImage('upload_image');

  const QueueOperation(this.wireName);
  final String wireName;

  static QueueOperation parse(String? v) => QueueOperation.values.firstWhere(
    (o) => o.wireName == v,
    orElse: () => QueueOperation.uploadMealRecord,
  );
}

enum QueueStatus {
  pending,
  processing,
  completed,
  failed;

  static QueueStatus parse(String? v) =>
      QueueStatus.values.firstWhere((s) => s.name == v, orElse: () => pending);
}

/// 離線佇列項目 (規格 3.1.6)。
///
/// 另外記錄 `next_attempt_at` 以實作指數退避。
class OfflineQueueItem {
  const OfflineQueueItem({
    required this.queueId,
    required this.operationType,
    required this.endpoint,
    required this.requestData,
    this.filePath,
    this.status = QueueStatus.pending,
    this.attempts = 0,
    required this.createdAt,
    required this.updatedAt,
    this.errorMessage,
    this.nextAttemptAt = 0,
  });

  final String queueId;
  final QueueOperation operationType;
  final String endpoint;
  final Map<String, Object?> requestData;
  final String? filePath;
  final QueueStatus status;
  final int attempts;
  final int createdAt;
  final int updatedAt;
  final String? errorMessage;
  final int nextAttemptAt;

  OfflineQueueItem copyWith({
    QueueStatus? status,
    int? attempts,
    int? updatedAt,
    String? errorMessage,
    int? nextAttemptAt,
  }) {
    return OfflineQueueItem(
      queueId: queueId,
      operationType: operationType,
      endpoint: endpoint,
      requestData: requestData,
      filePath: filePath,
      status: status ?? this.status,
      attempts: attempts ?? this.attempts,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      errorMessage: errorMessage ?? this.errorMessage,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
    );
  }

  factory OfflineQueueItem.fromDb(Map<String, Object?> row) => OfflineQueueItem(
    queueId: row['queue_id'] as String,
    operationType: QueueOperation.parse(row['operation_type'] as String?),
    endpoint: row['endpoint'] as String,
    requestData:
        jsonDecode(row['request_data'] as String) as Map<String, Object?>,
    filePath: row['file_path'] as String?,
    status: QueueStatus.parse(row['status'] as String?),
    attempts: row['attempts'] as int,
    createdAt: row['created_at'] as int,
    updatedAt: row['updated_at'] as int,
    errorMessage: row['error_message'] as String?,
    nextAttemptAt: row['next_attempt_at'] as int? ?? 0,
  );

  Map<String, Object?> toDb() => {
    'queue_id': queueId,
    'operation_type': operationType.wireName,
    'endpoint': endpoint,
    'request_data': jsonEncode(requestData),
    'file_path': filePath,
    'status': status.name,
    'attempts': attempts,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'error_message': errorMessage,
    'next_attempt_at': nextAttemptAt,
  };
}

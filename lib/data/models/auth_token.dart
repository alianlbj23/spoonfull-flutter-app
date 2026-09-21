import '../../core/utils/time_utils.dart';

/// 認證資訊 (規格 3.1.2),保存於加密儲存。
class AuthToken {
  const AuthToken({
    required this.deviceToken,
    required this.tokenAcquiredAt,
    this.tokenExpiresAt,
  });

  final String deviceToken;
  final int tokenAcquiredAt;
  final int? tokenExpiresAt;

  bool get isExpired =>
      tokenExpiresAt != null && nowUnix() >= tokenExpiresAt!;

  Map<String, Object?> toJson() => {
    'device_token': deviceToken,
    'token_acquired_at': tokenAcquiredAt,
    'token_expires_at': tokenExpiresAt,
  };

  factory AuthToken.fromJson(Map<String, Object?> json) => AuthToken(
    deviceToken: json['device_token'] as String,
    tokenAcquiredAt: asInt(json['token_acquired_at']) ?? 0,
    tokenExpiresAt: asInt(json['token_expires_at']),
  );
}

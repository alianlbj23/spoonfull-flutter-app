/// 錯誤分類 (規格 6.1)。
enum AppErrorType {
  /// 連線失敗 → 加入離線佇列重試
  network,

  /// 逾時 → 加入離線佇列重試
  timeout,

  /// 4xx 用戶端錯誤 → 顯示錯誤,不重試
  client,

  /// 401 / TOKEN_EXPIRED → 清除 token,返回配對畫面
  unauthorized,

  /// 403 → 顯示錯誤,不重試
  forbidden,

  /// 5xx → 加入離線佇列重試
  server,

  /// 422 → 顯示錯誤,不重試
  validation,

  /// 本機驗證失敗 → 立即顯示,不加入佇列
  localValidation,

  /// 回應格式無法解析
  parse,

  /// 非預期的例外 (程式或本機 I/O 錯誤) → 顯示通用訊息,細節只寫 log
  unknown,
}

class AppException implements Exception {
  const AppException(this.type, this.message, {this.code, this.statusCode});

  final AppErrorType type;
  final String message;

  /// 後端回傳的錯誤碼,例如 `INVALID_PAIRING_CODE`。
  final String? code;
  final int? statusCode;

  /// 網路/逾時/伺服器錯誤屬於暫時性錯誤,可進離線佇列重試。
  bool get isRetryable =>
      type == AppErrorType.network ||
      type == AppErrorType.timeout ||
      type == AppErrorType.server;

  @override
  String toString() =>
      'AppException($type, code: $code, status: $statusCode, $message)';
}

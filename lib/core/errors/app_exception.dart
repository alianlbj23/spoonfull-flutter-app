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

  /// 回應格式無法解析 (常見於代理 / Cloudflare 回 HTML) → 重試
  parse,

  /// 非預期的例外 (程式或本機 I/O 錯誤) → 顯示通用訊息,細節只寫 log;會重試
  unknown,
}

class AppException implements Exception {
  const AppException(
    this.type,
    this.message, {
    this.code,
    this.statusCode,
    this.retryable,
    this.retryAfter,
  });

  final AppErrorType type;
  final String message;

  /// 後端回傳的錯誤碼,例如 `DENIED`、`TOKEN_EXPIRED`。
  final String? code;
  final int? statusCode;

  /// 後端在錯誤信封裡明講的 `retryable`;舊版 server 沒有這個欄位時為 null,
  /// 改由 [isRetryable] 依錯誤類型判斷。
  final bool? retryable;

  /// `Retry-After` header:下次重試至少要等這麼久 (429 / 503)。
  final Duration? retryAfter;

  /// 是否值得稍後重試 (離線佇列不會把它標成永久失敗)。
  ///
  /// server 有給 `retryable` 就照做;否則只有「app server 自己回的」用戶端錯誤
  /// (403 / 422 / 其他 4xx,408 與 429 除外) 與本機驗證失敗不重試。代理或防火牆
  /// 擋下的 HTML、無法解析的回應 ([AppErrorType.parse]) 與非預期的 I/O 錯誤都重試,
  /// 紀錄不會因為 Cloudflare 的錯誤頁而被放棄。
  bool get isRetryable {
    if (retryable != null) return retryable!;
    return switch (type) {
      AppErrorType.network ||
      AppErrorType.timeout ||
      AppErrorType.server ||
      AppErrorType.parse ||
      AppErrorType.unknown => true,
      AppErrorType.client => statusCode == 408 || statusCode == 429,
      AppErrorType.unauthorized ||
      AppErrorType.forbidden ||
      AppErrorType.validation ||
      AppErrorType.localValidation => false,
    };
  }

  @override
  String toString() =>
      'AppException($type, code: $code, status: $statusCode, $message)';
}

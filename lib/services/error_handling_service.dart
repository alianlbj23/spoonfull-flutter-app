import 'dart:async';

import '../core/errors/app_exception.dart';
import '../core/utils/logger.dart';

/// 統一錯誤處理 (規格 6):將錯誤轉成使用者提示,並廣播 401 事件。
class ErrorHandlingService {
  final _unauthorized = StreamController<void>.broadcast();

  /// 收到 401 時觸發;DeviceState 監聽後清除 token 並返回配對畫面。
  Stream<void> get onUnauthorized => _unauthorized.stream;

  void notifyUnauthorized() => _unauthorized.add(null);

  AppException normalize(Object error) {
    if (error is AppException) return error;
    Log.e('Unexpected error', error);
    return AppException(AppErrorType.parse, error.toString());
  }

  /// 規格 6.1 的使用者提示。
  String userMessage(Object error) {
    final e = normalize(error);
    return switch (e.type) {
      AppErrorType.network => '離線狀態,資料將在連線恢復時同步',
      AppErrorType.timeout => '連線逾時,請檢查網路',
      AppErrorType.client => '請求參數錯誤:${e.message}',
      AppErrorType.unauthorized => '認證失敗,需要重新配對',
      AppErrorType.forbidden => '無權限操作此資源',
      AppErrorType.server => '伺服器故障,請稍後重試',
      AppErrorType.validation => '資料驗證失敗:${e.message}',
      AppErrorType.localValidation => e.message,
      AppErrorType.parse => e.message,
    };
  }

  void dispose() => _unauthorized.close();
}

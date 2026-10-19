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
    return AppException(AppErrorType.unknown, error.toString());
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
      // 例外原文是給工程師看的,只進 log;畫面顯示固定訊息。
      AppErrorType.unknown => '發生未預期的錯誤,請再試一次;持續發生請聯絡管理員',
    };
  }

  /// 配對 (pair/start、pair/poll) 失敗的提示。
  ///
  /// `DENIED` 固定顯示「管理員拒絕了這次配對」;其他配對錯誤碼 (EXPIRED、SLOW_DOWN、
  /// THROTTLED、INVALID_HARDWARE_ID) 與 server 自己回的錯誤信封原樣顯示
  /// `error.message`,不加「請求參數錯誤:」之類的前綴;沒有訊息才用這裡的預設。
  String pairingMessage(Object error) {
    final e = normalize(error);
    final fallback = switch (e.code) {
      'DENIED' => '管理員拒絕了這次配對',
      'EXPIRED' => '配對碼已過期,正在重新取得',
      'SLOW_DOWN' => '查詢太頻繁,已放慢輪詢速度',
      'THROTTLED' => '嘗試太多次,請稍後再試',
      'INVALID_HARDWARE_ID' => '機台識別碼格式錯誤,請聯絡管理員',
      _ => null,
    };
    if (e.code == 'DENIED') return fallback!;
    final fromServer =
        e.code != null &&
        e.message.isNotEmpty &&
        (e.type == AppErrorType.client ||
            e.type == AppErrorType.validation ||
            e.type == AppErrorType.forbidden ||
            e.type == AppErrorType.unauthorized);
    if (fromServer) return e.message;
    if (fallback != null) return fallback;
    if (e.type == AppErrorType.client && e.statusCode == 429) {
      return '嘗試太多次,請稍後再試';
    }
    return userMessage(e);
  }

  void dispose() => _unauthorized.close();
}

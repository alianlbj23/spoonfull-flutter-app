import 'package:flutter/foundation.dart';

import '../../config/app_config.dart';

/// 依 LOG_LEVEL 過濾的簡易 logger。
class Log {
  Log._();

  static void d(String message) => _log(LogLevel.debug, message);
  static void i(String message) => _log(LogLevel.info, message);
  static void e(String message, [Object? error, StackTrace? stack]) {
    _log(LogLevel.error, error == null ? message : '$message: $error');
    if (stack != null && AppConfig.logLevel == LogLevel.debug) {
      debugPrintStack(stackTrace: stack);
    }
  }

  static void _log(LogLevel level, String message) {
    if (level.index < AppConfig.logLevel.index) return;
    debugPrint('[${level.name.toUpperCase()}] $message');
  }
}

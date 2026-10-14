import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../config/app_config.dart';

/// 依 LOG_LEVEL 過濾的簡易 logger。
///
/// [attachFile] 之後 info 以上的訊息也會寫進檔案,機台出問題時才有紀錄可查
/// (kiosk 沒有終端機,debugPrint 的輸出只在 journald 裡)。
class Log {
  Log._();

  static IOSink? _sink;

  static void d(String message) => _log(LogLevel.debug, message);
  static void i(String message) => _log(LogLevel.info, message);
  static void e(String message, [Object? error, StackTrace? stack]) {
    _log(LogLevel.error, error == null ? message : '$message: $error');
    if (stack == null) return;
    _sink?.writeln(stack);
    if (AppConfig.logLevel == LogLevel.debug) {
      debugPrintStack(stackTrace: stack);
    }
  }

  /// 開始寫入 [file];超過 [maxBytes] 時把舊檔改名為 `<檔名>.1` (只留一份)。
  static Future<void> attachFile(File file, {int maxBytes = 1 << 20}) async {
    try {
      await file.parent.create(recursive: true);
      if (await file.exists() && await file.length() > maxBytes) {
        await file.rename('${file.path}.1');
      }
      // 整個 App 執行期間都開著,程序結束時由系統關閉。
      // ignore: close_sinks
      final sink = file.openWrite(mode: FileMode.append);
      // 磁碟滿等寫入錯誤不能讓 App 當掉,停止寫檔即可。
      sink.done.catchError((Object e) {
        _sink = null;
        debugPrint('[ERROR] log file closed: $e');
      }).ignore();
      _sink = sink;
    } on Object catch (e) {
      debugPrint('[ERROR] cannot open log file ${file.path}: $e');
    }
  }

  /// 把還沒寫入的內容寫到磁碟 (結束程序前呼叫)。
  static Future<void> flush() async {
    try {
      await _sink?.flush();
    } on Object catch (_) {}
  }

  static void _log(LogLevel level, String message) {
    if (level.index < AppConfig.logLevel.index) return;
    final line = '[${level.name.toUpperCase()}] $message';
    debugPrint(line);
    if (level != LogLevel.debug) {
      _sink?.writeln('${DateTime.now().toIso8601String()} $line');
    }
  }
}

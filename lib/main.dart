import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/utils/logger.dart';
import 'services/app_services.dart';
import 'services/connectivity_service.dart';
import 'services/update_service.dart';
import 'ui/screens/startup_failed_screen.dart';

void main() {
  // 沒有人接的例外都記下來:機台無人看管,出事後只能靠 log 回查。
  runZonedGuarded(
    _bootstrap,
    (error, stack) => Log.e('uncaught error', error, stack),
  );
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    Log.e('flutter error', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    Log.e('platform error', error, stack);
    return true;
  };
  await _attachLogFile();
  try {
    // 機台為橫向觸控螢幕
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  } on Object catch (e) {
    Log.i('cannot lock orientation: $e');
  }

  // 自動更新要比其他服務早啟動:新版若在開資料庫等初始化階段就失敗,
  // 更新器仍在跑,之後推出的修正版才裝得上 (services/update_service.dart)。
  final connectivity = PlusConnectivityService();
  final updates = UpdateService(connectivity: connectivity)..start();
  await _startApp(updates, connectivity);
}

Future<void> _attachLogFile() async {
  try {
    final dir = await getApplicationSupportDirectory();
    await Log.attachFile(File(p.join(dir.path, 'logs', 'spoonfull.log')));
  } on Object catch (e) {
    Log.i('log file unavailable: $e');
  }
}

Future<void> _startApp(
  UpdateService updates,
  ConnectivityService connectivity,
) async {
  final AppServices services;
  try {
    services = await AppServices.create(
      connectivity: connectivity,
      updates: updates,
    );
  } on Object catch (e, stack) {
    Log.e('startup failed', e, stack);
    runApp(
      StartupFailedApp(
        updateStatus: updates.status,
        onRetry: () => _startApp(updates, connectivity),
      ),
    );
    // 剛更新完就起不來:結束程序讓 kiosk 服務重啟,spoonfull-recover.sh
    // 數到上限會退回上一版。沒有那支腳本時留在這個畫面等修正版。
    if (updates.rollbackSupervised) {
      await Future<void>.delayed(const Duration(seconds: 10));
      await Log.flush();
      exit(1);
    }
    return;
  }
  updates
    ..onBeforeRestart = services.dispose
    ..confirmHealthy();
  runApp(SpoonfullApp(services: services));
}

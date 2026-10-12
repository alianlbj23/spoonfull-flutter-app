import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'services/app_services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 機台為橫向觸控螢幕
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  final services = await AppServices.create();
  // 自動更新:有新版時在閒置狀態下替換檔案並重新啟動 (services/update_service.dart)
  services.updates
    ..onBeforeRestart = services.dispose
    ..start();
  runApp(SpoonfullApp(services: services));
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spoonfull_flutter_app/data/api/api_repository.dart';
import 'package:spoonfull_flutter_app/data/api/mock_api_repository.dart';
import 'package:spoonfull_flutter_app/data/local/app_database.dart';
import 'package:spoonfull_flutter_app/data/local/preferences_storage.dart';
import 'package:spoonfull_flutter_app/data/local/secure_token_storage.dart';
import 'package:spoonfull_flutter_app/services/app_services.dart';
import 'package:spoonfull_flutter_app/services/connectivity_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TestEnv {
  TestEnv(this.services, this.connectivity, this.tokens);
  final AppServices services;
  final FakeConnectivityService connectivity;
  final InMemoryTokenStorage tokens;
}

/// 以記憶體 SQLite、假網路與 Mock API 建立整套服務。
Future<TestEnv> createTestEnv({
  ApiRepository? api,
  Map<String, Object> prefs = const {},
  bool online = true,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  sqfliteFfiInit();
  final db = await AppDatabase.openInMemory(
    factory: databaseFactoryFfiNoIsolate,
  );
  final connectivity = FakeConnectivityService(online: online);
  final tokens = InMemoryTokenStorage();
  final services = await AppServices.create(
    database: db,
    prefs: await PreferencesStorage.create(),
    tokens: tokens,
    api: api ?? MockApiRepository(latency: Duration.zero),
    connectivity: connectivity,
  );
  return TestEnv(services, connectivity, tokens);
}

/// 已完成伺服器設定的偏好值。
const configuredPrefs = <String, Object>{
  'server.host': '192.168.0.10',
  'server.port': '8080',
  'device_config.location': 'demo',
};

void useDesignViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1024, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spoonfull_flutter_app/data/api/api_repository.dart';
import 'package:spoonfull_flutter_app/data/api/mock_api_repository.dart';
import 'package:spoonfull_flutter_app/data/local/app_database.dart';
import 'package:spoonfull_flutter_app/data/local/preferences_storage.dart';
import 'package:spoonfull_flutter_app/data/local/secure_token_storage.dart';
import 'package:spoonfull_flutter_app/data/models/hardware_config.dart';
import 'package:spoonfull_flutter_app/services/app_services.dart';
import 'package:spoonfull_flutter_app/services/connectivity_service.dart';
import 'package:spoonfull_flutter_app/services/hardware/camera_service.dart';
import 'package:spoonfull_flutter_app/services/hardware/hardware_service.dart';
import 'package:spoonfull_flutter_app/services/hardware/image_pipeline.dart';
import 'package:spoonfull_flutter_app/services/hardware/scale_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TestEnv {
  TestEnv(this.services, this.connectivity, this.tokens, this.tempDir);
  final AppServices services;
  final FakeConnectivityService connectivity;
  final InMemoryTokenStorage tokens;

  /// 模擬 App 文件目錄 (照片輸出位置)。
  final Directory tempDir;

  Future<void> dispose() async {
    await services.dispose();
    // 同步刪除:testWidgets 在 FakeAsync 內,真正的非同步 I/O 不會完成。
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// 模擬秤的預設重量。
const testScaleWeightG = 420.0;

/// 以記憶體 SQLite、假網路、Mock API、模擬相機與模擬秤建立整套服務。
Future<TestEnv> createTestEnv({
  ApiRepository? api,
  Map<String, Object> prefs = const {},
  bool online = true,
  CameraService? camera,
  CameraService? filePicker,
  ScaleService? scale,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  sqfliteFfiInit();
  final db = await AppDatabase.openInMemory(
    factory: databaseFactoryFfiNoIsolate,
  );
  final connectivity = FakeConnectivityService(online: online);
  final tokens = InMemoryTokenStorage();
  // 同步建立:widget 測試的 FakeAsync 區域裡 await 真實檔案 I/O 會卡住。
  final tempDir = Directory.systemTemp.createTempSync('spoonfull_env');
  final services = await AppServices.create(
    database: db,
    prefs: await PreferencesStorage.create(),
    tokens: tokens,
    api: api ?? MockApiRepository(latency: Duration.zero),
    connectivity: connectivity,
    hardwareBuilder: (storage) => HardwareService(
      storage: storage,
      camera: camera ?? const MockCameraService(width: 640, height: 480),
      filePicker:
          filePicker ?? const MockCameraService(width: 640, height: 480),
      scale:
          scale ??
          ScaleService(
            const MockScaleReader(
              grams: testScaleWeightG,
              interval: Duration(milliseconds: 1),
            ),
            settings: const ScaleSettings(
              kind: ScaleKind.mock,
              mockWeightG: testScaleWeightG,
            ),
          ),
      // 測試中直接在主 isolate 處理影像
      pipeline: const ImagePipeline(useIsolate: false),
      documentsDir: () async => tempDir,
    ),
  );
  return TestEnv(services, connectivity, tokens, tempDir);
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

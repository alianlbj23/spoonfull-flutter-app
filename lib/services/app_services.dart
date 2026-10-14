import '../config/app_config.dart';
import '../data/api/api_client.dart';
import '../data/api/api_repository.dart';
import '../data/api/mock_api_repository.dart';
import '../data/local/app_database.dart';
import '../data/local/preferences_storage.dart';
import '../data/local/secure_token_storage.dart';
import 'connectivity_service.dart';
import 'device_pairing_service.dart';
import 'error_handling_service.dart';
import 'hardware/hardware_service.dart';
import 'local_storage_service.dart';
import 'offline_queue_service.dart';
import 'realtime_service.dart';
import 'record_service.dart';
import 'sync_service.dart';
import 'update_service.dart';

/// 依賴組裝 (Composition Root)。
class AppServices {
  AppServices._({
    required this.storage,
    required this.api,
    required this.errors,
    required this.connectivity,
    required this.pairing,
    required this.queue,
    required this.hardware,
    required this.records,
    required this.sync,
    required this.updates,
    required this.database,
  });

  final LocalStorageService storage;
  final ApiRepository api;
  final ErrorHandlingService errors;
  final ConnectivityService connectivity;
  final DevicePairingService pairing;
  final OfflineQueueService queue;
  final HardwareService hardware;
  final RecordService records;
  final SyncService sync;
  final UpdateService updates;
  final AppDatabase database;

  static Future<AppServices> create({
    AppDatabase? database,
    PreferencesStorage? prefs,
    TokenStorage? tokens,
    ApiRepository? api,
    ConnectivityService? connectivity,
    HardwareService Function(LocalStorageService storage)? hardwareBuilder,
    RealtimeService? realtime,
    UpdateService? updates,
  }) async {
    final db = database ?? await AppDatabase.open();
    final storage = LocalStorageService(
      prefs: prefs ?? await PreferencesStorage.create(),
      // Linux kiosk 沒有 keyring 時自動退回檔案儲存 (ARCHITECTURE.md §5.1)。
      tokens: tokens ?? FallbackTokenStorage(),
      database: db,
    );
    final errors = ErrorHandlingService();

    late final DevicePairingService pairing;
    final repo =
        api ??
        (AppConfig.useMockApi
            ? MockApiRepository()
            : HttpApiRepository(
                ApiClient(
                  baseUrlProvider: () => storage.serverSettings.baseUrl,
                  interceptors: [
                    AuthInterceptor(() => pairing.currentToken()),
                    const LoggingInterceptor(),
                    UnauthorizedInterceptor(errors.notifyUnauthorized),
                  ],
                ),
              ));
    pairing = DevicePairingService(repo, storage);
    // 推播通道只對真正的 HTTP 後端有意義;Mock API 或測試注入的 API 沒有。
    final push =
        realtime ??
        (api == null && !AppConfig.useMockApi
            ? RealtimeService(
                baseUrlProvider: () => storage.serverSettings.baseUrl,
                tokenProvider: () => pairing.currentToken(),
              )
            : null);

    final conn = connectivity ?? PlusConnectivityService();
    final queue = OfflineQueueService(storage);
    final hardware =
        hardwareBuilder?.call(storage) ?? HardwareService(storage: storage);
    final records = RecordService(
      api: repo,
      storage: storage,
      queue: queue,
      connectivity: conn,
      errors: errors,
      hardware: hardware,
    );
    final sync = SyncService(
      api: repo,
      storage: storage,
      queue: queue,
      records: records,
      connectivity: conn,
      errors: errors,
      isPaired: pairing.hasValidToken,
      realtime: push,
    );
    return AppServices._(
      storage: storage,
      api: repo,
      errors: errors,
      connectivity: conn,
      pairing: pairing,
      queue: queue,
      hardware: hardware,
      records: records,
      sync: sync,
      updates: updates ?? UpdateService(connectivity: conn),
      database: db,
    );
  }

  Future<void> dispose() async {
    await updates.dispose();
    await sync.dispose();
    await hardware.dispose();
    await storage.dispose();
    errors.dispose();
    await database.close();
  }
}

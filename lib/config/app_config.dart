/// 環境配置 (規格 12.2)。
///
/// 以 `--dart-define=APP_ENV=dev|test|prod` 切換環境,
/// `--dart-define=USE_MOCK_API=true` 可在沒有後端時以假資料運行。
enum AppEnvironment { dev, test, prod }

enum LogLevel { debug, info, error }

class AppConfig {
  AppConfig._();

  static const String _envName = String.fromEnvironment(
    'APP_ENV',
    defaultValue: 'dev',
  );

  static const bool useMockApi = bool.fromEnvironment('USE_MOCK_API');

  /// 開發 / 測試用固定配對碼 (`--dart-define=PAIRING_CODE=123456`)。
  ///
  /// 有設定時,儲存伺服器設定後與每次啟動若尚未配對,App 會自動用這組碼配對,
  /// 不用在機台上輸入;server 端需在測試環境接受同一組碼。正式部署不要設定。
  static const String autoPairingCode = String.fromEnvironment('PAIRING_CODE');

  static bool get hasAutoPairingCode => autoPairingCode.isNotEmpty;

  /// CI 編譯時帶入的遞增版本編號 (`--dart-define=APP_BUILD=<run number>`)。
  /// 本機編譯為 0,這時不會自動更新。
  static const int buildNumber = int.fromEnvironment('APP_BUILD');

  /// 自動更新的下載位置:底下要有 `version.json` 與各平台的安裝檔。
  static const String updateBaseUrl = String.fromEnvironment(
    'UPDATE_BASE_URL',
    defaultValue:
        'https://github.com/alianlbj23/spoonfull-flutter-app/releases/latest/download/',
  );

  static AppEnvironment get environment => switch (_envName) {
    'prod' => AppEnvironment.prod,
    'test' => AppEnvironment.test,
    _ => AppEnvironment.dev,
  };

  /// 預設 BASE_URL;使用者在設定畫面輸入伺服器位址後會覆蓋此值。
  static String get defaultBaseUrl => switch (environment) {
    AppEnvironment.dev => 'http://dev-server.local/',
    AppEnvironment.test => 'https://test-server.example.com/',
    AppEnvironment.prod => 'https://prod-server.example.com/',
  };

  static LogLevel get logLevel => switch (environment) {
    AppEnvironment.dev => LogLevel.debug,
    AppEnvironment.test => LogLevel.info,
    AppEnvironment.prod => LogLevel.error,
  };
}

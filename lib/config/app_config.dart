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

import '../core/utils/server_address.dart';

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

  /// CI 編譯時帶入的遞增版本編號 (`--dart-define=APP_BUILD=<run number>`)。
  /// 本機編譯為 0,這時不會自動更新。
  static const int buildNumber = int.fromEnvironment('APP_BUILD');

  /// 送給 server 的 App 版本 (`pair/start/` 的 `app_version`):CI 版與
  /// `--build-name` 相同 (`1.0.<build>`),本機編譯為 `dev`。
  static String get appVersion => buildNumber > 0 ? '1.0.$buildNumber' : 'dev';

  /// 機台還沒存過伺服器設定時,設定畫面預設帶入的伺服器位址
  /// (`--dart-define=DEFAULT_SERVER_URL=...`)。使用者可在設定畫面改成任何位址;
  /// 存過之後就以存的為準。
  static const String _defaultServerUrl = String.fromEnvironment(
    'DEFAULT_SERVER_URL',
    defaultValue: 'https://foodintakesystem.com',
  );

  /// [_defaultServerUrl] 去掉結尾的 `/`,直接當設定畫面的位址欄內容。
  /// 設成空字串或不合法的網址 (格式錯誤、公開網域用 http) 時為空字串,
  /// 等於沒有預設,使用者要自己填。
  static final String defaultServerHost = _normalizeDefault(_defaultServerUrl);

  static String _normalizeDefault(String raw) {
    var h = raw.trim();
    while (h.endsWith('/')) {
      h = h.substring(0, h.length - 1);
    }
    return ServerAddress.resolve(h).isValid ? h : '';
  }

  /// 機台還沒存過場域時,設定畫面預設帶入的場域 (`--dart-define=DEFAULT_PLACE_ID=...`)。
  /// 位址與場域都有預設值時,新機台開機就能直接「開始使用」進入配對,不必先填設定。
  /// 設成空字串等於沒有預設,使用者要自己填。
  static const String _defaultPlaceId = String.fromEnvironment(
    'DEFAULT_PLACE_ID',
    defaultValue: 'demo',
  );
  static final String defaultPlaceId = _defaultPlaceId.trim();

  /// 自動更新的下載位置:底下要有 `version.json` 與各平台的安裝檔。
  static const String updateBaseUrl = String.fromEnvironment(
    'UPDATE_BASE_URL',
    defaultValue: 'https://github.com/alianlbj23/spoonfull-flutter-app/releases/latest/download/',
  );

  static AppEnvironment get environment => switch (_envName) {
    'prod' => AppEnvironment.prod,
    'test' => AppEnvironment.test,
    _ => AppEnvironment.dev,
  };

  static LogLevel get logLevel => switch (environment) {
    AppEnvironment.dev => LogLevel.debug,
    AppEnvironment.test => LogLevel.info,
    AppEnvironment.prod => LogLevel.error,
  };
}

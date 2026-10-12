/// 全域常數:API 路徑、快取有效期、重試策略、圖片限制、機台硬體預設。
class AppConstants {
  AppConstants._();

  // --- API endpoints (ARCHITECTURE.md §6.1) ---
  // 路徑結尾一律有斜線,避免 Django APPEND_SLASH 轉址丟掉 POST body。
  static const String devicePairPath = 'api/machine/pair/';
  static const String roomDataPath = 'api/machine/rooms/';
  static const String bedDataPath = 'api/machine/beds/';
  static const String mealDataPath = 'api/machine/meals/';
  static const String mealRecordPath = 'api/machine/records/';

  /// server 推播通道 (ARCHITECTURE.md §6.6);協定由 BASE_URL 的 http/https 對應成 ws/wss。
  static const String machineEventsPath = 'ws/machine/';

  static const Duration requestTimeout = Duration(seconds: 15);
  static const Duration uploadTimeout = Duration(seconds: 60);
  static const Duration healthCheckTimeout = Duration(seconds: 5);

  // --- 快取有效期 (規格 7.3) ---
  static const Duration roomBedCacheTtl = Duration(hours: 1);
  static const Duration mealCacheTtl = Duration(hours: 24);
  static const Duration periodicSyncInterval = Duration(minutes: 30);

  // --- 推播 (ARCHITECTURE.md §6.6) ---
  /// 連續收到多個 data_changed (例如整批匯入住民) 時,合併成一次重抓。
  static const Duration realtimeDebounce = Duration(milliseconds: 1500);

  /// 推播斷線重連的退避:1s, 2s, 5s, 10s, 30s,之後每 60s。
  static const List<Duration> realtimeReconnectDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  // --- 重試策略 (規格 6.2):1s, 5s, 30s, 5min, 30min,最多 5 次 ---
  static const List<Duration> retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 5),
    Duration(seconds: 30),
    Duration(minutes: 5),
    Duration(minutes: 30),
  ];
  static int get maxRetryAttempts => retryDelays.length;

  // --- 圖片驗證 (規格 8.4) ---
  static const int maxImageBytes = 5 * 1024 * 1024;
  static const int minImageLongSide = 480;
  static const int minImageShortSide = 320;
  static const int maxImageLongSide = 4000;
  static const int maxImageShortSide = 3000;

  // --- 上傳前壓縮 (ARCHITECTURE.md §5.1):長邊 1280、JPEG 品質 80 ---
  static const int uploadMaxLongSide = 1280;
  static const int uploadJpegQuality = 80;

  // --- 相機擷取 (預設解析度與暖機張數;USB 相機前幾張常曝光不足) ---
  static const int captureWidth = 1280;
  static const int captureHeight = 720;
  static const int captureWarmupFrames = 8;
  static const Duration captureTimeout = Duration(seconds: 20);

  // --- 拍照品質檢查 (純 CPU,ARCHITECTURE.md §5.1) ---
  /// 分析前先縮到此寬度,門檻皆以此尺度校正。
  static const int qualityAnalysisWidth = 320;

  /// 平均亮度 (0-255) 低於此值 → 過暗。
  static const double qualityDarkMeanLuma = 60;

  /// 暗像素 (<40) 比例超過此值 → 過暗。
  static const double qualityDarkPixelRatio = 0.6;

  /// 平均亮度高於此值 → 過亮。
  static const double qualityBrightMeanLuma = 215;

  /// 爆白像素 (>235) 比例超過此值 → 過亮。
  static const double qualityBrightPixelRatio = 0.3;

  /// (3x3 平滑後) Laplacian 變異數低於此值 → 模糊。
  static const double qualityBlurVarianceMin = 50;

  /// |Laplacian| 超過此值的像素算邊緣 (3x3 平滑後,雜訊約 ±5)。
  static const int qualityEdgeLaplacianMin = 40;

  /// 畫面中央 ROI 佔長寬的比例 (餐盒放固定位置)。
  static const double qualityTrayRoiFraction = 0.6;

  /// 有空秤參考照時:ROI 與參考照的平均絕對差低於此值 → 餐盒不在畫面。
  static const double qualityTrayRefDiffMin = 12;

  /// 沒有參考照時:ROI 邊緣密度低於此值,且 ROI 亮度標準差也低於
  /// [qualityTrayContrastMin] → 餐盒不在畫面。
  static const double qualityTrayEdgeDensityMin = 0.02;
  static const double qualityTrayContrastMin = 12;

  // --- 秤重 ---
  static const Duration scaleStableTimeout = Duration(seconds: 6);
  static const int scaleStableWindow = 5;
  static const double scaleStableToleranceG = 2.0;

  /// 低於此重量視為秤上沒有餐盒。
  static const double scaleEmptyThresholdG = 5.0;

  // --- 自動更新 (lib/services/update_service.dart) ---
  static const Duration updateCheckInterval = Duration(minutes: 10);
  static const Duration updateDownloadTimeout = Duration(minutes: 10);

  /// 使用者這段時間沒有碰螢幕才安裝更新並重新啟動。
  static const Duration updateIdleBeforeRestart = Duration(seconds: 60);

  /// 更新已下載但 App 正在使用時,多久後再看一次是否閒置。
  static const Duration updateIdleRetry = Duration(seconds: 15);

  /// 重新啟動前顯示「正在更新」提示的時間。
  static const Duration updateInstallNotice = Duration(seconds: 3);

  static const int pairingCodeLength = 6;

  /// Figma 設計稿的畫布大小 (機台觸控螢幕 1024x600)。
  static const double designWidth = 1024;
  static const double designHeight = 600;
}

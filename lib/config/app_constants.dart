/// 全域常數:API 路徑、快取有效期、重試策略、圖片限制、機台硬體預設。
class AppConstants {
  AppConstants._();

  // --- API endpoints (ARCHITECTURE.md §6.1) ---
  // 路徑結尾一律有斜線,避免 Django APPEND_SLASH 轉址丟掉 POST body。
  /// 配對 (Device Authorization Flow,README §4.1):機台取碼 → 管理員在網頁核准 → 機台輪詢。
  static const String pairStartPath = 'api/machine/pair/start/';
  static const String pairPollPath = 'api/machine/pair/poll/';

  /// 已配對機台的身分 (device_id / device_name / location),啟動時確認 token 仍有效。
  static const String mePath = 'api/machine/me/';
  static const String roomDataPath = 'api/machine/rooms/';
  static const String bedDataPath = 'api/machine/beds/';
  static const String mealDataPath = 'api/machine/meals/';
  static const String mealRecordPath = 'api/machine/records/';

  /// 健康檢查 (不需認證):回 `status`、`server_time`、`api_version`。
  /// 舊版 server 沒有這支 (404) 時退回「有任何 HTTP 回應就算可達」。
  static const String healthPath = 'api/machine/health/';

  /// server 推播通道 (ARCHITECTURE.md §6.6);協定由 BASE_URL 的 http/https 對應成 ws/wss。
  /// 放在 `api/` 底下,經 Cloudflare 公開網址也能連 (舊的 `ws/machine/` 只剩區網能用)。
  static const String machineEventsPath = 'api/machine/ws/';

  static const Duration requestTimeout = Duration(seconds: 15);
  static const Duration uploadTimeout = Duration(seconds: 60);
  static const Duration healthCheckTimeout = Duration(seconds: 5);

  /// 機台時間與 server_time 相差超過這個值就在設定 / 狀態畫面警告
  /// (capture_time 與 token 期限都靠機台時鐘)。
  static const Duration clockSkewTolerance = Duration(seconds: 120);

  // --- 配對輪詢 (server 沒給時的預設值) ---
  /// `pair/start/` 回應沒有 `interval` 時的輪詢間隔。
  static const Duration pairingDefaultInterval = Duration(seconds: 5);

  /// 收到 429 SLOW_DOWN 時,輪詢間隔加長這麼多。
  static const Duration pairingSlowDownStep = Duration(seconds: 5);

  /// `pair/start/` 回應沒有 `expires_in` 時,配對碼的有效時間。
  static const Duration pairingDefaultExpiry = Duration(minutes: 10);

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

  /// 推播連線的心跳間隔,用來發現已經斷掉卻沒收到關閉通知的連線。
  static const Duration realtimePingInterval = Duration(seconds: 20);

  // --- 重試策略 (規格 6.2):1s, 5s, 30s, 5min,之後每 30min,直到成功 ---
  static const List<Duration> retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 5),
    Duration(seconds: 30),
    Duration(minutes: 5),
    Duration(minutes: 30),
  ];

  /// 同一住民、同一餐、同一天的餐前照還在佇列時,餐後照延後這麼久再試,
  /// 讓餐前照先送到 server。
  static const Duration afterRecordDeferral = Duration(seconds: 5);

  /// 舊版重試滿這個次數就放棄;啟動時用來找出被舊版放棄的項目並放回佇列。
  static int get legacyMaxRetryAttempts => retryDelays.length;

  // --- 本機保留期 ---
  /// 已上傳的照片保留天數,過期後刪除檔案 (紀錄仍在)。
  static const Duration syncedImageRetention = Duration(days: 14);

  /// 已上傳的紀錄保留天數,過期後連同紀錄一起刪除。
  static const Duration syncedRecordRetention = Duration(days: 90);

  /// 照片資料夾裡沒有任何紀錄指向的檔案 (取消拍攝、測試拍照留下的) 多久後清掉。
  static const Duration orphanImageRetention = Duration(days: 1);

  // --- 圖片驗證 (規格 8.4) ---
  static const int maxImageBytes = 5 * 1024 * 1024;
  static const int minImageLongSide = 480;
  static const int minImageShortSide = 320;
  static const int maxImageLongSide = 4000;
  static const int maxImageShortSide = 3000;

  // --- 上傳前壓縮 (ARCHITECTURE.md §5.1):長邊 1280、JPEG 品質 80 ---
  static const int uploadMaxLongSide = 1280;
  static const int uploadJpegQuality = 80;

  // --- 相機擷取 (RealSense D435f,deploy/realsense_bridge.py) ---
  /// 擷取解析度。深度最高 1280x720,與 [uploadMaxLongSide] 相同,
  /// 所以 RGB 不會再縮放,深度圖與上傳的照片逐像素對齊。
  static const int captureWidth = 1280;
  static const int captureHeight = 720;

  /// 擷取前丟掉的暖機影格數 (自動曝光收斂;30 fps 下約半秒)。
  static const int captureWarmupFrames = 15;
  static const Duration captureTimeout = Duration(seconds: 20);

  /// 偵測相機 (`--probe`) 的逾時。
  static const Duration cameraProbeTimeout = Duration(seconds: 10);

  /// 拍照畫面的即時預覽:影格縮到這個寬度、每秒張數 (Raspberry Pi 也跑得動)。
  static const int previewWidth = 640;
  static const int previewFps = 10;

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

  /// 新版啟動後正常跑滿這段時間才算更新成功,之後刪掉留著當退路的舊檔。
  static const Duration updateHealthyAfter = Duration(seconds: 60);

  /// 重新啟動前顯示「正在更新」提示的時間。
  static const Duration updateInstallNotice = Duration(seconds: 3);

  /// Figma 設計稿的畫布大小 (機台觸控螢幕 1024x600)。
  static const double designWidth = 1024;
  static const double designHeight = 600;
}

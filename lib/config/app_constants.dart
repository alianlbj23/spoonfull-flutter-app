/// 全域常數:API 路徑、快取有效期、重試策略、圖片限制。
class AppConstants {
  AppConstants._();

  // --- API endpoints (規格 4) ---
  static const String devicePairPath = 'work/api/device_pair.php';
  static const String roomDataPath = 'work/api/room_data.php';
  static const String bedDataPath = 'work/api/bed_data.php';
  static const String mealDataPath = 'work/api/meal_data.php';
  static const String mealRecordPath = 'work/api/meal_record.php';

  static const Duration requestTimeout = Duration(seconds: 15);
  static const Duration uploadTimeout = Duration(seconds: 60);
  static const Duration healthCheckTimeout = Duration(seconds: 5);

  // --- 快取有效期 (規格 7.3) ---
  static const Duration roomBedCacheTtl = Duration(hours: 1);
  static const Duration mealCacheTtl = Duration(hours: 24);
  static const Duration periodicSyncInterval = Duration(minutes: 30);

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

  static const int pairingCodeLength = 6;

  /// Figma 設計稿的畫布大小 (機台觸控螢幕 1024x600)。
  static const double designWidth = 1024;
  static const double designHeight = 600;
}

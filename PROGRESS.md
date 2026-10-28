# 進度紀錄

最後更新:2026-10-27

## 已完成

### 伺服器位址允許 Tailscale / CGNAT (100.64.0.0/10)
- 問題:設定頁輸入 `http://100.110.50.9:8000` 被判成公開網址,要求 https 而無法儲存。
- 原因:`ServerAddress.isPrivateHost` 只認 10/8、172.16/12、192.168/16、loopback、link-local。
- 修法:[lib/core/utils/server_address.dart](lib/core/utils/server_address.dart) 加入 100.64/10 (RFC 6598,Tailscale 節點 IP 範圍)。
- 測試:[test/unit/validators_test.dart](test/unit/validators_test.dart) 新增正常路徑 (100.64.0.0、100.110.50.9、100.127.255.255) 與邊界外 (100.63.255.255、100.128.0.0 仍視為公開)。
- 已知與此無關的測試失敗:`test/unit/update_test.dart` 的「newer build is downloaded…」在 Windows 上失敗 (檢查檔案執行位元,Windows 沒有權限模型),改動前就如此。

## 相機改為 RealSense D435f (RGB-D) — App 端已完成 (2026-10-27),待機台驗證

### 需求 (已確認)
- 相機來源只保留兩種:**選擇圖片** (picker) 與 **RealSense D435f**。
- 要同時擷取 **RGB 與深度** (RGB-D)。
- 舊機台已存的 `auto` / `v4l2` / `nvargus` / `libcamera` / `folder` / `mock` 設定一律轉成 RealSense。

### 已做 (dev 分支,2026-10-27)
- **bridge** [deploy/realsense_bridge.py](deploy/realsense_bridge.py):`--probe` 偵測 (JSON:序號 / 韌體 / USB 版本,找不到回 2);`--once RGB DEPTH META` 拍一組 RGB-D (暖機 15 張、對齊到 color、深度轉 mm 寫 16-bit PNG、meta 含內參與 `depth_unit_m`);USB 2 時自動降 fps;`--mock` 沒相機也能跑 (已在 PC 驗證輸出格式)。寫檔優先 OpenCV,沒有就用 Pillow。
- **Dart**:
  - `CameraSource` 只剩 `realsense` / `picker`;舊值 `parse()` 轉 RealSense,`device` 改存序號 (舊的 `/dev/video0` 等自動清掉);沒存過設定時 Linux 預設 RealSense、桌面預設選擇圖片。
  - `RealSenseCameraService`:外部程序 + 逾時 + 檢查三個輸出檔 (PNG 表頭 16-bit 灰階、尺寸對 meta);結束碼 2 → `CAMERA_NOT_FOUND`、1 → `CAMERA_UNAVAILABLE`。bridge 位置:`SPOONFULL_REALSENSE_BRIDGE` → bundle 內 `data/flutter_assets/deploy/` (pubspec assets,隨自動更新) → `./deploy/` → `/opt/spoonfull/`。`SPOONFULL_REALSENSE_MOCK=1` 走 mock。
  - `HardwareService.capture`:深度圖搬到 `<uuid>_depth.png` / `_depth.json`,算 `DepthStats` (有效比例、中央中位距離) 寫進 meta `stats`;RGB 若被縮放 (尺寸不符) 就丟掉深度並記 log。
  - 上傳:multipart 多 `depth` (image/png) 與 `depth_meta` (JSON 字串),`edge_result.depth_attached`;深度檔不見只送 RGB。`ApiClient.postMultipart` 改成多檔。
  - 本機:`meal_records` v4 加 `depth_path` / `depth_meta_path`;佇列 request_data 帶兩個路徑;`discardImage` / `purgeExpired` / 孤兒清理都連深度檔一起處理。
  - 硬體設定頁:來源兩個選項、序號欄、「偵測相機」按鈕顯示摘要 (USB 2 會提示換埠);測試拍照對話框多一行深度統計。移除解析度 / MJPEG 選項。
  - 測試:`test/unit/realsense_camera_test.dart` (成功 / 找不到相機 / 沒裝 / 逾時 / 缺檔 / 尺寸不符 / probe / 舊值遷移)、`capture_test.dart` RGB-D 群組 (搬檔、上傳欄位、佇列還原、丟棄、清理、參考照)、`api_client_test.dart` multipart 含 depth。全部 185 個測試通過 (Flutter 3.47.6)。
- **拍照畫面 (2026-10-28)**:按「拍照」不再直接拍,先開 [lib/ui/screens/camera_preview_screen.dart](lib/ui/screens/camera_preview_screen.dart):bridge 以 `--preview` 一直開著 (stdout 送 640 寬 JPEG 每秒 10 張,stdin 收 `{"cmd":"capture",...}` / `{"cmd":"quit"}`,格式見 bridge 開頭),`RealSensePreview` 解析訊息 ([bridge_protocol.dart](lib/services/hardware/bridge_protocol.dart)) 餵 `Image.memory`;快門從同一條串流拍 (`HardwareService.capture(via:)`),品質不佳的重拍不用重開相機。啟動失敗 / 串流中斷顯示原因與「重試」。`MockCameraService` 也有預覽 (widget 測試用);「選擇檔案」與沒有預覽能力的相機走原本的流程。測試 200 個。 (Pi 5 原生編 librealsense v2.56.3 + pyrealsense2,裝 udev 規則,cpack 出 .deb);`install-device.sh` 改裝 numpy / OpenCV、檢查 pyrealsense2、放 bridge 到 `/opt/spoonfull`;udev 規則加 RealSense USB (8086:0bxx)。
- 文件:README §1 / §2.2 / §4.6 (`depth`、`depth_meta` 欄位與範例) / §6、deploy/README §1 / §3 / §4 / §6、ARCHITECTURE §5.1。

### 待辦 (需要機台或 server)
1. **Pi 5 實機驗證**:`build-librealsense.sh` 跑一次 (v2.56.3 若有 cmake 問題換 v2.55.1)、`rs-enumerate-devices`、`realsense_bridge.py --probe` / `--once`,再走 App 的「偵測相機」→「測試拍照」→ 上傳。注意 D435f 深度 < 30 cm 不可靠,架設 40–60 cm。
2. **Server 契約**:`POST api/machine/records/` 要收 `depth` (16-bit PNG, mm) 與 `depth_meta` (JSON);舊 server 會忽略這兩個欄位不報錯。vision-worker 的體積估算改讀 PNG + `intrinsics` / `depth_unit_m` (不再是 depth CSV)。
3. `tools/send_test_records.py` 還沒帶深度 (只送 RGB)。
4. Jetson 若之後要用:程式相同,只有 pyrealsense2 安裝方式不同 (JetPack 可用 pip wheel 或同一支 build 腳本)。

## 其他筆記
- 已加 `.gitattributes` 固定 `.cc` / `.h` / `.cmake` / `.swift` 為 LF;`flutter pub get` 重寫 generated plugin 檔案後不會再因 `core.autocrlf=true` 出現幻影修改。
- `[ERROR:flutter/shell/platform/common/accessibility_bridge.cc(114)] Failed to update ui::AXTree` 為 Flutter 桌面引擎已知的無障礙層訊息,系統有 UIA 用戶端連上視窗時會出現,無害可忽略。

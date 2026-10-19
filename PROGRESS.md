# 進度紀錄

最後更新:2026-10-19

## 已完成

### 伺服器位址允許 Tailscale / CGNAT (100.64.0.0/10)
- 問題:設定頁輸入 `http://100.110.50.9:8000` 被判成公開網址,要求 https 而無法儲存。
- 原因:`ServerAddress.isPrivateHost` 只認 10/8、172.16/12、192.168/16、loopback、link-local。
- 修法:[lib/core/utils/server_address.dart](lib/core/utils/server_address.dart) 加入 100.64/10 (RFC 6598,Tailscale 節點 IP 範圍)。
- 測試:[test/unit/validators_test.dart](test/unit/validators_test.dart) 新增正常路徑 (100.64.0.0、100.110.50.9、100.127.255.255) 與邊界外 (100.63.255.255、100.128.0.0 仍視為公開)。
- 已知與此無關的測試失敗:`test/unit/update_test.dart` 的「newer build is downloaded…」在 Windows 上失敗 (檢查檔案執行位元,Windows 沒有權限模型),改動前就如此。

## 進行中:相機改為 RealSense D435f (RGB-D)

### 需求 (已確認)
- 相機來源只保留兩種:**選擇圖片** (picker) 與 **RealSense D435f**。
- 要同時擷取 **RGB 與深度** (RGB-D)。
- 舊機台已存的 `auto` / `v4l2` / `nvargus` / `libcamera` 設定一律轉成 RealSense。
- `folder` / `mock` 來源從 UI 移除。

### 建議做法 (已提出,待實作)
- 取像走 librealsense 的 pyrealsense2,做一支 `deploy/realsense_bridge.py`,模式比照 [deploy/hx711_bridge.py](deploy/hx711_bridge.py)。
- App 端新增 `CameraSource.realsense`,沿用 `GStreamerCameraService` 的「呼叫外部程序 + timeout + 檢查輸出檔」模式,呼叫 `realsense_bridge.py --once <rgb.jpg> <depth.png> <meta.json>`。
- 輸出格式:RGB JPEG;深度 16-bit PNG (mm,對齊到 color、同解析度);meta.json 含 `fx, fy, ppx, ppy, depth_scale, serial`。
- 不走 V4L2:UVC 只給未對齊的 Z16 原始幀,沒有內參與 depth_scale。
- Bridge 提供 `--mock` 模式,沒有相機也能驗證串接。

### 測試環境分工
| 環境 | 用途 |
|---|---|
| WSL / PC | Dart 單元測試 (假 `ProcessRunner`)、bridge `--mock` |
| Ubuntu x64 | `pip install pyrealsense2` 有 wheel,可快速驗證 |
| Jetson Orin Nano | 最終驗證與部署;librealsense 需從原始碼建 (`FORCE_RSUSB_BACKEND=ON`、`BUILD_PYTHON_BINDINGS=ON`) |

決定:直接在 Jetson 上開發與測試 (VS Code Remote-SSH),用 `git clone` 搬專案,開發時先停 `spoonfull-kiosk` service。

### 待決事項 (需要確認後才動工)
1. **Server 契約**:`POST api/machine/records/` 目前只收 `image` 欄位 ([lib/data/api/api_repository.dart](lib/data/api/api_repository.dart))。建議新增 `depth` (image/png) 與 `depth_meta` (JSON);若 vision-worker 只認 depth CSV,格式要改。
2. **離線佇列**:目前只存一張圖片路徑,加深度後佇列與本機清理要一起改。
3. **新相依套件**:pyrealsense2 (只裝在機台,不進 pubspec),版本固定 2.55 系列。

### 實作順序 (確認後)
1. `CameraSource` enum 與舊值遷移
2. `realsense_bridge.py` 與 `--mock`
3. Dart `RealSenseCameraService` 與測試 (成功、timeout、輸出檔缺失、depth 尺寸不符)
4. 硬體設定頁:來源只剩兩個選項,移除解析度 / MJPEG 選項
5. 上傳新增深度欄位、離線佇列
6. README、deploy/README、`install-device.sh` 加 librealsense 建置步驟

## 其他筆記
- `[ERROR:flutter/shell/platform/common/accessibility_bridge.cc(114)] Failed to update ui::AXTree` 為 Flutter 桌面引擎已知的無障礙層訊息,系統有 UIA 用戶端連上視窗時會出現,無害可忽略。

# 機台部署:技術說明

操作步驟請看 [README.md](../README.md)。這份是背後的機制與開發用資訊,對應 [ARCHITECTURE.md](../ARCHITECTURE.md) §5 與 §11 階段 5。機台只做採集:拍照、秤重、品質檢查、上傳,不跑任何 AI。

## 1. deploy/ 資料夾裡的檔案

| 檔案 | 用途 |
|---|---|
| `spoonfull.py` | 互動選單。也是 HX711 開機服務本身 (服務以 `spoonfull.py hx711-bridge` 執行)。kiosk / HX711 systemd 服務與 udev 規則的內容都寫在這個檔案裡,安裝時寫到 `/etc/systemd/system/`、`/etc/udev/rules.d/99-spoonfull-hardware.rules` |
| `realsense_bridge.py` | App 拍照時呼叫 (即時預覽與快門)。直接執行:`--probe` 偵測、`--once a.jpg a_depth.png a.json` 拍一張、`--mock` 沒相機時產生合成影像、`--serial <序號>` 指定相機、`--width 640 --height 480` 改解析度 |
| `realsense_tool.py` | 相機校正 (選單「相機 → 相機校正」) |
| `build-librealsense.sh` | 編譯 librealsense + pyrealsense2 (選單「相機 → 編譯 / 安裝相機驅動」)。參數:`--version v2.56.3`、`--jobs 2`、`--dir ~/librealsense`。產出的 `~/librealsense/build/librealsense2-*.deb` 可給下一台機台 `sudo dpkg -i` |
| `spoonfull-recover.sh` | 自動更新的退路。kiosk 服務每次啟動 App 前執行 (`ExecStartPre`),CI 也會打包進 Release (§4) |
| `tests/` | `python3 -m unittest discover -s deploy/tests -v` (不需要硬體) |

「安裝 / 更新機台」做的事:apt 安裝 numpy / OpenCV / libsecret / GTK 等、udev 權限與 `video,dialout,plugdev` 群組、NTP、下載 Release 到 `/opt/spoonfull` (已有就略過)、複製 `spoonfull.py` 等檔案到 `/opt/spoonfull`、把 `/opt/spoonfull` 擁有者改成執行 App 的帳號、安裝 kiosk 服務 (選擇是否 enable)、(選用) HX711 服務 (`enable --now`)。下載來源可用環境變數 `SPOONFULL_RELEASE_URL` 改。

HX711:設定 (offset、scale、腳位) 存在執行服務那個帳號的 `~/.config/spoonfull/hx711.json`;TCP 輸出 `127.0.0.1:9100`,每行 `ST,GS, 123.4 g` / `US,GS, 120.1 g`。GPIO 函式庫:Pi 5 `python3-lgpio` + `rpi-lgpio`;Pi 4 `python3-rpi.gpio`;Jetson 內建 `Jetson.GPIO`。

## 2. 自己編譯 (開發用)

自己 `flutter build` 的版本 `APP_BUILD` 是 0,**不會自動更新**,只適合開發測試。Flutter Linux 需要在 **arm64 Linux** 上編譯 (Flutter 不支援從 x86 交叉編譯到 arm64):

```bash
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev \
  libsecret-1-dev libjsoncpp-dev   # flutter_secure_storage_linux 需要
flutter config --enable-linux-desktop
flutter build linux --release
sudo mkdir -p /opt/spoonfull
sudo cp -r build/linux/arm64/release/bundle/* /opt/spoonfull/
python3 deploy/spoonfull.py     # 1 安裝 / 更新機台 (App 已經在 /opt/spoonfull,不會問要不要下載)
```

不要帶 `--dart-define=USE_MOCK_API=true` 到正式機台。

## 3. 硬體與 App 設定

| 項目 | App 設定 (設定 → 硬體設定) | 備註 |
|---|---|---|
| RealSense D435f | 來源 **RealSense D435f (RGB-D)**,序號留空 (只接一台) | 拍照同時輸出 RGB + 深度圖 (1280x720,mm,對齊到彩色) |
| 沒有相機 (開發) | 來源 **選擇圖片** | 沒有深度圖 |
| USB HID 秤 (Dymo / Stamps.com 類) | 類型 **USB HID 秤**,裝置 `/dev/hidraw0` | udev 規則開放 plugdev 群組;`cat /dev/hidraw0 \| xxd` 放東西應有資料 |
| 序列埠秤或 HX711 + Arduino/ESP32 | 類型 **序列埠 / HX711 (USB)**,裝置 `/dev/ttyUSB0`、鮑率 | 微控制器每行輸出 `ST,GS,  123.4 g` 或純數字即可 |
| HX711 直接接 GPIO | 類型 **HX711 (GPIO bridge)**,`127.0.0.1:9100` | 見 §1 |
| 沒有秤 | 類型 **不使用秤** | 不送 `weight_g`,server 以菜單標準份量估算 |

**空秤參考照**:之後每次拍照會與它比對畫面中央區域,差異太小就提示「餐盒不在畫面」。沒有參考照時改用邊緣密度判斷,較不準。

**品質檢查門檻**:[lib/config/app_constants.dart](../lib/config/app_constants.dart) 的 `quality*` 常數:過暗 (平均亮度 < 60)、過亮 (> 215 或爆白 > 30%)、模糊 (Laplacian 變異數 < 50)、餐盒不在畫面。以現場相機拍幾張正常與異常照片,用硬體設定頁的「測試拍照」看數值後調整。

**相機暖機**:預設丟掉 15 張暖機影格再取 (`CameraSettings.warmupFrames`)。

**資料保存**:已上傳的照片 14 天後自動刪除,紀錄 90 天後刪除;還沒上傳的不會動 (`lib/config/app_constants.dart` 的 `synced*Retention`)。

**上傳驗證 (server 端)**:`FoodIntake` 有 `weight_g`、`client_record_id`、`captured_at`;`edge_result` 有 `quality_check` 與 `depth_attached: true`;收到 `depth` (PNG) 與 `depth_meta` 兩個欄位。離線排隊的紀錄恢復連線後只會有一筆 (去重鍵 `client_record_id`)。

## 4. 自動更新

每次 push 到 `main`,GitHub Actions 會編譯三個平台並更新同一個 Release (`latest`),同時放一份 `version.json`。已安裝的 App 會在**啟動時、網路恢復時、以及每 10 分鐘**讀一次 `version.json`,發現較新的版本就下載、驗證 SHA-256、替換安裝資料夾裡的檔案,然後重新啟動 ([lib/services/update_service.dart](../lib/services/update_service.dart))。

- **不會打斷操作**:拍照或上傳中不安裝;使用者 60 秒內碰過螢幕也先不安裝。剛啟動時視為閒置,會馬上更新。安裝前畫面會顯示「正在更新到最新版本」約 3 秒。
- **只有 GitHub 編譯的版本會自動更新**。本機 `flutter build` / `flutter run` 的版本編號是 0,不會更新自己。
- **壞版本會自動退回**:安裝時被換掉的舊檔會改名成 `*.spoonfull-old` 留著,新版順利跑滿 60 秒才刪掉。
  - 安裝到一半失敗:當場換回舊檔,App 繼續使用。
  - 安裝到一半斷電:下次開機換回舊檔。
  - 新版一啟動就當掉 (或啟動失敗):kiosk 服務每次啟動前執行 `spoonfull-recover.sh`,連續 3 次沒撐過 60 秒,第 4 次啟動就換回上一版,並把這個版本記在 `/opt/spoonfull/.update-bad-build`,之後不再安裝它。
  - 選單「8 還原上一版 App」:手動做同一件事 (也會記成壞版本)。只有更新中斷或新版還沒確認正常時才有舊版可換。
- **目前跑哪一版**:設定 → 系統狀態的「版本」(build 號碼 = GitHub Actions 的 run number)。
- **安裝資料夾要可寫入**:`auto-update off: ... is not writable` 表示權限不對,重跑「安裝 / 更新機台」。Windows / Ubuntu 桌機請解壓縮到使用者自己的資料夾 (不要放 `C:\Program Files`)。
- **網路**:機台要連得到 `github.com` 與 `objects.githubusercontent.com` (醫院防火牆需放行),否則只是不會更新,App 照常運作。**repo 必須是 public**,App 才讀得到 Release。
- 更新來源可在編譯時用 `--dart-define=UPDATE_BASE_URL=https://.../` 改成自己的伺服器 (底下要有 `version.json` 與安裝檔)。

## 5. 紀錄檔與疑難排解

- **App 紀錄檔**:info 以上的訊息與所有錯誤會寫到 `~/.local/share/com.example.spoonfull_flutter_app/logs/spoonfull.log`,超過 1 MB 改名成 `spoonfull.log.1`,只留一份舊檔。kiosk 服務的 log:選單「5 查看 App 狀態與 log」(`journalctl -u spoonfull-kiosk`)。
- **「系統啟動失敗」**:通常是本機資料庫打不開 (磁碟滿或檔案損毀)。看紀錄檔的 `startup failed`;更新器在這個畫面仍會運作,有修正版會自動裝上。
- **配對狀態**:kiosk 沒有 keyring,App 會自動改用 `~/.local/share/.../auth_token.json` (權限 600)。log 有 `using file storage` 即正常。
- **找不到相機**:`rs-enumerate-devices` 沒列出 → 線材 / USB 3 埠 / 電源;有列出但 App 找不到 → 群組或 udev 規則 (重新登入、重跑安裝)。log `realsense bridge not found` 表示 bridge 檔案不在。
- **相機沒有回應**:bridge 超過 20 秒沒回,多半是 USB 2 連線或相機被另一個程序 (`realsense-viewer`) 佔著。
- **時間**:`capture_time` 用機台時鐘;`timedatectl status` 看 NTP 是否同步。

## 6. 相機校正的技術細節

- **深度校正** (On-Chip / Focal Length / Tare) 用 pyrealsense2 的 `auto_calibrated_device` API,串流設定與 JSON 參數照 Intel 官方範例 `depth_auto_calibration_example.py`;需要 Advanced Mode 與 USB 3。health 判讀依白皮書:\|值\| < 0.25 良好、0.25～1 建議重新校正、> 1 必須重新校正。白皮書:<https://intelrealsense.com/download/9277> (網頁版 <https://dev.intelrealsense.com/docs/self-calibration-for-depth-cameras>)。
- **寫入相機前**一定先備份校正開始前的校正表到 `~/.config/spoonfull/realsense_backup/calib_<日期時間>_<序號>.json`;選「不寫入」或出錯時,相機目前生效的校正會還原。
- **RGB 內參**:SDK 對 D400 回報的 RGB 畸變係數全為 0,所以另外用 OpenCV + ChArUco (7×5 格、方格 30 mm、標記 22 mm、`DICT_5X5_100`) 校正,比較 SDK 出廠內參與 OpenCV 結果的重投影誤差 (整體 / 中央 / 邊緣),存到 `~/.config/spoonfull/rgb_intrinsics.json` (序號、解析度、日期、相機矩陣、畸變係數、兩組誤差),**不寫入相機**。刪掉這個檔案就回到 SDK 出廠內參。
- **UV map (深度對齊 RGB) 尚未實作**:官方 Python 範例、unit test、白皮書都沒有 Python 的 `run_uv_map_calibration` 用法,binding 回傳 health 的方式也疑似有問題。需要時用 `realsense-viewer`。
- **官方深度標靶的紙張** (2026-11-09 下載 PDF 實測):MediaBox 792 × 612 pt = **US Letter 橫向 (279.4 × 215.9 mm)**,不是 A4。用 A4 紙選「實際大小」:上下各裁掉約 3 mm 背景,四個圓點外緣離紙邊 ≥ 37 mm,不受影響。印表機若「縮小超出的頁面」會縮成 210 / 215.9 ≈ 97.3% (圓點間距約 170 × 97 mm)。白皮書附錄 A:Letter 版效能不打折扣,不同印表機約有 0.5% 誤差。程式在輸入實測值時,與設計值差超過 1.5% 且超過 0.5 mm 會提醒。

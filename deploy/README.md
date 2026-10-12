# 機台部署 (Jetson Orin Nano / Raspberry Pi 5)

對應 [ARCHITECTURE.md](../ARCHITECTURE.md) §5 與 §11 階段 5。機台只做採集:拍照、秤重、品質檢查、上傳,不跑任何 AI。

## 1. 在開發機交叉編譯或在機台上編譯

Flutter Linux 需要在 **arm64 Linux** 上編譯 (Flutter 不支援從 x86 交叉編譯到 arm64)。兩種做法:

| 做法 | 說明 |
|---|---|
| 直接在機台上編譯 | 機台裝 Flutter SDK (arm64 Linux 版),`flutter build linux --release`。Jetson Orin Nano 8GB / Pi 5 8GB 都可以,第一次約 10–20 分鐘。 |
| 另一台 arm64 Linux 編譯機 | 例如 arm64 Ubuntu VM 或 CI 的 arm64 runner,再把 `build/linux/arm64/release/bundle/` 複製到機台。 |

編譯相依 (機台或編譯機):

```bash
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev \
  libsecret-1-dev libjsoncpp-dev   # flutter_secure_storage_linux 需要
flutter config --enable-linux-desktop
flutter build linux --release
```

> 不要帶 `--dart-define=USE_MOCK_API=true` 到正式機台。

## 2. 安裝到機台

```bash
sudo mkdir -p /opt/spoonfull
sudo cp -r build/linux/arm64/release/bundle/* /opt/spoonfull/
sudo ./deploy/install-device.sh --user <登入帳號> [--hx711]
```

`install-device.sh` 會:安裝 GStreamer / v4l-utils / libsecret、設定 udev 權限 (hidraw、ttyUSB、video)、開 NTP、安裝 `spoonfull-kiosk.service` (開機全螢幕啟動,`SPOONFULL_KIOSK=1`)。

機台要先有自動登入的桌面 session (Pi OS Desktop 預設有;Jetson 的 Ubuntu 在「設定 → 使用者」開自動登入)。服務啟動後 App 全螢幕、無標題列、隱藏游標。

## 3. 硬體

| 項目 | App 設定 (設定 → 硬體設定) | 備註 |
|---|---|---|
| USB 相機 | 來源 **USB 相機 (V4L2)**,裝置 `/dev/video0` | `v4l2-ctl --list-devices` 查裝置;高解析度 USB 相機勾 **MJPEG** 比較快 |
| Jetson CSI 相機 (IMX219 等) | 來源 **Jetson CSI 相機**,裝置填 sensor-id (`0`) | 用 JetPack 內建的 `nvarguscamerasrc` |
| Pi CSI 相機 | 來源 **Pi CSI 相機 (libcamera)** | `sudo apt install rpicam-apps` |
| USB HID 秤 (Dymo / Stamps.com 類) | 類型 **USB HID 秤**,裝置 `/dev/hidraw0` | `ls -l /dev/hidraw*`;udev 規則已開放 plugdev 群組 |
| 序列埠秤或 HX711 + Arduino/ESP32 | 類型 **序列埠 / HX711 (USB)**,裝置 `/dev/ttyUSB0`、鮑率 | 微控制器每行輸出 `ST,GS,  123.4 g` 或純數字即可 |
| HX711 直接接 GPIO | 類型 **HX711 (GPIO bridge)**,`127.0.0.1:9100` | 跑 `hx711_bridge.py`,先 `--calibrate <已知重量>` |
| 沒有秤 | 類型 **不使用秤** | 不送 `weight_g`,server 以菜單標準份量估算 |

相機固定架在餐車上、餐盒放固定位置 (秤面就是放餐盒的位置),餐前餐後角度要一致。

### 空秤參考照

硬體設定頁的「拍攝空秤參考照」:秤上不放任何東西拍一張。之後每次拍照會與它比對畫面中央區域,差異太小就提示「餐盒不在畫面」。沒有參考照時改用邊緣密度判斷,較不準。相機位置或補光改變後要重拍參考照。

### 品質檢查門檻

在 [lib/config/app_constants.dart](../lib/config/app_constants.dart) 的 `quality*` 常數:過暗 (平均亮度 < 60)、過亮 (> 215 或爆白 > 30%)、模糊 (Laplacian 變異數 < 50)、餐盒不在畫面。以現場相機拍幾張正常與異常照片,用硬體設定頁的「測試拍照」看數值後調整。

## 4. 驗證

1. 硬體設定頁:「測試拍照」→ 看到照片與品質指標;「即時讀數」→ 秤的數字會動,放上重物後穩定圖示變綠。
2. 走一次流程:選病房 → 床位 → 餐前 → 放餐盒 → 下一步。畫面顯示「拍照與秤重中」,接著確認頁左下角出現重量 (來源「秤」),右側選時段膳食 → 上傳。
3. server 端確認 `FoodIntake` 有 `weight_g`、`client_record_id`、`captured_at`,`edge_result` 有 `quality_check`。
4. 拔網路線上傳一筆 → 顯示離線排隊;插回去自動送出,server 只會有一筆 (去重鍵 `client_record_id`)。

## 5. 自動更新

每次 push 到 `main`,GitHub Actions 會編譯三個平台並更新同一個 Release (`latest`),同時放一份 `version.json`。已安裝的 App 會在**啟動時、網路恢復時、以及每 10 分鐘**讀一次 `version.json`,發現較新的版本就下載、驗證 SHA-256、替換安裝資料夾裡的檔案,然後重新啟動 ([lib/services/update_service.dart](../lib/services/update_service.dart))。

- **不會打斷操作**:拍照或上傳中不安裝;使用者 60 秒內碰過螢幕也先不安裝。剛啟動時視為閒置,會馬上更新。安裝前畫面會顯示「正在更新到最新版本」約 3 秒。
- **只有 GitHub 編譯的版本會自動更新**。本機 `flutter build` / `flutter run` 的版本編號是 0,不會更新自己。所以每台機器**第一次**要手動安裝一份從 Release 下載的版本,之後才會自己更新。
- **安裝資料夾要可寫入**:機台由 `install-device.sh` 把 `/opt/spoonfull` 的擁有者改成執行 App 的帳號。Windows / Ubuntu 桌機請解壓縮到使用者自己的資料夾 (不要放 `C:\Program Files`)。
- **機台要連得到 `github.com`**。醫院網路若有防火牆,需要放行 `github.com` 與 `objects.githubusercontent.com`,否則只是不會更新,App 照常運作。
- **repo 必須是 public**,App 才讀得到 Release。
- 看 log:`journalctl -u spoonfull-kiosk | grep -i update`。`auto-update off: ... is not writable` 表示安裝資料夾權限不對,重跑一次 `install-device.sh`。
- 更新來源可在編譯時用 `--dart-define=UPDATE_BASE_URL=https://.../` 改成自己的伺服器 (底下要有 `version.json` 與安裝檔)。

## 6. 常見問題

- **App 啟動後配對狀態每次都消失**:kiosk 沒有 keyring,App 會自動改用 `~/.local/share/.../auth_token.json` (權限 600)。看 log 有 `using file storage` 即正常。
- **相機第一張很暗**:自動曝光還沒收斂。硬體設定沒有暴露暖機張數,預設連拍 9 張取最後一張;若仍暗,補光燈常亮,或在 `CameraSettings.warmupFrames` 調大。
- **`gst-launch-1.0` 找不到**:`sudo apt install gstreamer1.0-tools gstreamer1.0-plugins-good`。
- **HID 秤讀不到**:`cat /dev/hidraw0 | xxd` 放東西上去應該會有資料;沒有資料多半是權限 (重新登入讓 plugdev 生效) 或裝置編號不是 0。
- **時間不對**:`timedatectl status` 看 NTP 是否同步;`capture_time` 用機台時鐘。

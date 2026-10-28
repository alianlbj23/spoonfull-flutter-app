# 機台部署 (Raspberry Pi 5;Jetson Orin Nano 次要)

對應 [ARCHITECTURE.md](../ARCHITECTURE.md) §5 與 §11 階段 5。機台只做採集:拍照、秤重、品質檢查、上傳,不跑任何 AI。

## 0. 這個資料夾裡每個檔案怎麼用

| 檔案 | 在哪裡跑 | 什麼時候跑 | 指令 |
|---|---|---|---|
| `build-librealsense.sh` | 機台 (Pi),一般使用者 | 新機台第一次,裝相機驅動 (librealsense + pyrealsense2)。約 30–45 分鐘 | `./deploy/build-librealsense.sh`<br>選項:`--version v2.56.3` 指定 librealsense 版本、`--jobs 2` 減少同時編譯數 (記憶體小的 Pi)、`--dir ~/librealsense` 原始碼放哪 |
| `install-device.sh` | 機台,`sudo` | 新機台第一次;之後要更新開機服務或 bridge 再跑一次 (App 不會被覆蓋) | `sudo ./deploy/install-device.sh --user <登入帳號>`<br>選項:`--hx711` 同時裝 HX711 GPIO 秤的服務、`--skip-download` 不下載 Release (用自己 `flutter build` 放進 `/opt/spoonfull` 的版本)。環境變數 `SPOONFULL_RELEASE_URL` 可改下載來源 |
| `realsense_bridge.py` | 機台或開發電腦 | 不用手動跑,App 拍照時會自己呼叫。手動只用來檢查相機 | `python3 deploy/realsense_bridge.py --probe` 偵測相機 (找不到結束碼 2)<br>`python3 deploy/realsense_bridge.py --once a.jpg a_depth.png a.json` 拍一張 RGB-D<br>加 `--mock` 沒相機也會產生合成影像;`--serial <序號>` 指定相機;`--width 640 --height 480` 改解析度 |
| `hx711_bridge.py` | 機台 | HX711 直接接 GPIO 時。先校正一次,之後由 `spoonfull-hx711.service` 開機自動跑 | 校正:`python3 /opt/spoonfull/hx711_bridge.py --calibrate 500` (放 500 g 砝碼,照提示按 Enter)<br>看讀數:`python3 /opt/spoonfull/hx711_bridge.py --print`<br>電腦上測假資料:`--fake`;腳位 `--dout 5 --sck 6` (BCM) |
| `spoonfull-recover.sh` | 機台,自動 | 不用手動跑。開機服務每次啟動 App 前會執行,新版啟動失敗時換回上一版 (§5) | 手動強制還原上一版:`sh /opt/spoonfull/spoonfull-recover.sh /opt/spoonfull` |
| `spoonfull-kiosk.service` | 機台 | 由 `install-device.sh` 安裝,不用手動複製 | 看狀態:`systemctl status spoonfull-kiosk`;重啟 App:`sudo systemctl restart spoonfull-kiosk`;看 log:`journalctl -u spoonfull-kiosk -f`;開發時先停掉:`sudo systemctl stop spoonfull-kiosk` |
| `spoonfull-hx711.service` | 機台 | 由 `install-device.sh --hx711` 安裝 | `systemctl status spoonfull-hx711`;看輸出:`nc 127.0.0.1 9100` |
| `99-spoonfull-hardware.rules` | 機台 | 由 `install-device.sh` 安裝到 `/etc/udev/rules.d/`。改過後重載:`sudo udevadm control --reload-rules && sudo udevadm trigger` | 讓一般使用者能開 RealSense (USB)、USB HID 秤 (`/dev/hidraw*`)、序列埠秤 (`/dev/ttyUSB*`) |

## 1. 安裝到機台 (Raspberry Pi 5,Pi OS Bookworm 64-bit)

需要:Pi 5 + 官方 5 A 電源、Intel RealSense D435f 接 **USB 3** 埠(藍色)、已開自動登入的桌面 session(Pi OS Desktop 預設有)。

1. 抓專案:
   ```bash
   git clone https://github.com/alianlbj23/spoonfull-flutter-app.git
   cd spoonfull-flutter-app
   ```
2. 編相機驅動(只需一次,約 30–45 分鐘;以一般使用者執行,會自己呼叫 sudo):
   ```bash
   ./deploy/build-librealsense.sh
   ```
   跑完接上相機確認:
   ```bash
   rs-enumerate-devices                                   # 列出 D435f
   python3 deploy/realsense_bridge.py --probe             # 印出序號、韌體、USB 3.x
   ```
   腳本最後會在 `~/librealsense/build/` 產出 `librealsense2-*.deb`,留著給下一台機台 `sudo dpkg -i`,就不用再編。
3. 安裝 App 與開機服務:
   ```bash
   sudo ./deploy/install-device.sh --user <登入帳號> [--hx711]
   ```
   會從 GitHub Release 下載最新版到 `/opt/spoonfull`、設定裝置權限與 NTP、裝開機全螢幕服務。**一定要用 Release 的版本**,只有它會自動更新(見 §5)。
4. 重新登入(讓群組權限生效),再開 App:
   ```bash
   sudo systemctl start spoonfull-kiosk
   ```
5. App 裡:設定 → 硬體設定 → 相機來源 **RealSense D435f (RGB-D)**(Linux 預設已選)→ **偵測相機** → **測試拍照** → 看到照片與「深度:有效 xx%,中央 yy cm」→ 選秤的類型(§3)→ **儲存**。

> 已經在跑的機台,重跑一次 `install-device.sh` 會更新開機服務與 bridge,App 本身不會被覆蓋。

### Raspberry Pi 4 也可以

同樣步驟,差別:要 64-bit Pi OS;第 2 步編譯約 1–1.5 小時,2 GB 記憶體的型號先加 swap 並用 `./deploy/build-librealsense.sh --jobs 2`(或直接拿 Pi 5 編好的 .deb);電源用官方 3 A;相機一樣接藍色 USB 3 埠。

## 2. 自己編譯(開發用)

自己 `flutter build` 的版本 `APP_BUILD` 是 0,**不會自動更新**,只適合開發測試。Flutter Linux 需要在 **arm64 Linux** 上編譯 (Flutter 不支援從 x86 交叉編譯到 arm64):

```bash
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev \
  libsecret-1-dev libjsoncpp-dev   # flutter_secure_storage_linux 需要
flutter config --enable-linux-desktop
flutter build linux --release
sudo mkdir -p /opt/spoonfull
sudo cp -r build/linux/arm64/release/bundle/* /opt/spoonfull/
sudo ./deploy/install-device.sh --user <登入帳號> --skip-download
```

> 不要帶 `--dart-define=USE_MOCK_API=true` 到正式機台。

## 3. 硬體

| 項目 | App 設定 (設定 → 硬體設定) | 備註 |
|---|---|---|
| RealSense D435f | 來源 **RealSense D435f (RGB-D)**,序號留空 (只接一台) | 接 **USB 3** 埠;「偵測相機」會顯示序號 / 韌體 / USB 版本,USB 2 會提示換埠。拍照同時輸出 RGB + 深度圖 (1280x720,mm,對齊) |
| 沒有相機 (開發) | 來源 **選擇圖片** | 沒有深度圖 |
| USB HID 秤 (Dymo / Stamps.com 類) | 類型 **USB HID 秤**,裝置 `/dev/hidraw0` | `ls -l /dev/hidraw*`;udev 規則已開放 plugdev 群組 |
| 序列埠秤或 HX711 + Arduino/ESP32 | 類型 **序列埠 / HX711 (USB)**,裝置 `/dev/ttyUSB0`、鮑率 | 微控制器每行輸出 `ST,GS,  123.4 g` 或純數字即可 |
| HX711 直接接 GPIO | 類型 **HX711 (GPIO bridge)**,`127.0.0.1:9100` | 跑 `hx711_bridge.py`,先 `--calibrate <已知重量>` |
| 沒有秤 | 類型 **不使用秤** | 不送 `weight_g`,server 以菜單標準份量估算 |

相機固定架在餐車上、餐盒放固定位置 (秤面就是放餐盒的位置),餐前餐後角度要一致。D435f 的深度在 **30 cm 以內不可靠**,相機到餐盒建議 40–60 cm;「測試拍照」會顯示深度有效比例與中央距離,拿來確認架設高度。

### 相機檢查與架設

1. 相機接 USB 3 埠,開 App → 硬體設定 → **偵測相機**。顯示「USB 3.x」正常;顯示「USB 2.x (請改接 USB 3 埠)」就換埠或換線。
2. 把空餐盒放在秤面上,按 **測試拍照**。看三個數字:
   - 畫面要清楚、不過暗(品質檢查通過);
   - **深度有效比例**要在 90% 以上,太低代表太近(< 30 cm)或對著反光面;
   - **中央距離**就是相機到餐盒的距離,建議 40–60 cm。
3. 數字正常後拍 **空秤參考照**(下一節),再 **儲存**。

不想開 App 也可以在終端機測:

```bash
python3 /opt/spoonfull/realsense_bridge.py --probe                                  # 偵測相機
python3 /opt/spoonfull/realsense_bridge.py --once /tmp/a.jpg /tmp/a_depth.png /tmp/a.json   # 拍一張,看 /tmp/a.jpg
```

### 空秤參考照

硬體設定頁的「拍攝空秤參考照」:秤上不放任何東西拍一張。之後每次拍照會與它比對畫面中央區域,差異太小就提示「餐盒不在畫面」。沒有參考照時改用邊緣密度判斷,較不準。相機位置或補光改變後要重拍參考照。

### 品質檢查門檻

在 [lib/config/app_constants.dart](../lib/config/app_constants.dart) 的 `quality*` 常數:過暗 (平均亮度 < 60)、過亮 (> 215 或爆白 > 30%)、模糊 (Laplacian 變異數 < 50)、餐盒不在畫面。以現場相機拍幾張正常與異常照片,用硬體設定頁的「測試拍照」看數值後調整。

## 4. 驗證

1. 硬體設定頁:「偵測相機」→ 顯示 D435f 序號與 USB 3;「測試拍照」→ 看到照片、品質指標與「深度:有效 xx%,中央 yy cm」;「即時讀數」→ 秤的數字會動,放上重物後穩定圖示變綠。
2. 走一次流程:選病房 → 床位 → 餐前 → 放餐盒 → 下一步。畫面顯示「拍照與秤重中」,接著確認頁左下角出現重量 (來源「秤」),右側選時段膳食 → 上傳。
3. server 端確認 `FoodIntake` 有 `weight_g`、`client_record_id`、`captured_at`,`edge_result` 有 `quality_check` 與 `depth_attached: true`,而且收到 `depth` (PNG) 與 `depth_meta` 兩個欄位。
4. 拔網路線上傳一筆 → 顯示離線排隊;插回去自動送出,server 只會有一筆 (去重鍵 `client_record_id`)。

## 5. 自動更新

每次 push 到 `main`,GitHub Actions 會編譯三個平台並更新同一個 Release (`latest`),同時放一份 `version.json`。已安裝的 App 會在**啟動時、網路恢復時、以及每 10 分鐘**讀一次 `version.json`,發現較新的版本就下載、驗證 SHA-256、替換安裝資料夾裡的檔案,然後重新啟動 ([lib/services/update_service.dart](../lib/services/update_service.dart))。

- **不會打斷操作**:拍照或上傳中不安裝;使用者 60 秒內碰過螢幕也先不安裝。剛啟動時視為閒置,會馬上更新。安裝前畫面會顯示「正在更新到最新版本」約 3 秒。
- **只有 GitHub 編譯的版本會自動更新**。本機 `flutter build` / `flutter run` 的版本編號是 0,不會更新自己。`install-device.sh` 預設就會下載 Release 版本。
- **壞版本會自動退回**:安裝時被換掉的舊檔會改名成 `*.spoonfull-old` 留著,新版順利跑滿 60 秒才刪掉。
  - 安裝到一半失敗:當場換回舊檔,App 繼續使用。
  - 安裝到一半斷電:下次開機換回舊檔。
  - 新版一啟動就當掉(或啟動失敗):kiosk 服務每次啟動前執行 `spoonfull-recover.sh`,連續 3 次沒撐過 60 秒,第 4 次啟動就換回上一版,並把這個版本記在 `/opt/spoonfull/.update-bad-build`,之後不再安裝它。修正後推出更新的版本會照常安裝。
  - 這需要 kiosk 服務裡的 `ExecStartPre=...spoonfull-recover.sh`;舊機台重跑一次 `install-device.sh` 即可。
- **目前跑哪一版**:設定 → 系統狀態的「版本」(build 號碼 = GitHub Actions 的 run number)。
- **安裝資料夾要可寫入**:機台由 `install-device.sh` 把 `/opt/spoonfull` 的擁有者改成執行 App 的帳號。Windows / Ubuntu 桌機請解壓縮到使用者自己的資料夾 (不要放 `C:\Program Files`)。
- **機台要連得到 `github.com`**。醫院網路若有防火牆,需要放行 `github.com` 與 `objects.githubusercontent.com`,否則只是不會更新,App 照常運作。
- **repo 必須是 public**,App 才讀得到 Release。
- 看 log:`journalctl -u spoonfull-kiosk | grep -i update`,或 App 自己的紀錄檔 `~/.local/share/com.example.spoonfull_flutter_app/logs/spoonfull.log` (見 §6)。`auto-update off: ... is not writable` 表示安裝資料夾權限不對,重跑一次 `install-device.sh`。
- 更新來源可在編譯時用 `--dart-define=UPDATE_BASE_URL=https://.../` 改成自己的伺服器 (底下要有 `version.json` 與安裝檔)。

## 6. 常見問題

- **App 的紀錄檔**:info 以上的訊息與所有錯誤 (含當機前的例外) 會寫到 App support 資料夾的 `logs/spoonfull.log`,Linux 通常是 `~/.local/share/com.example.spoonfull_flutter_app/logs/`。超過 1 MB 會改名成 `spoonfull.log.1`,只留一份舊檔。
- **畫面顯示「系統啟動失敗」**:通常是本機資料庫打不開 (磁碟滿或檔案損毀)。看紀錄檔的 `startup failed`;更新器在這個畫面仍會運作,有修正版會自動裝上。
- **照片佔用空間**:已上傳的照片 14 天後自動刪除,紀錄 90 天後刪除;還沒上傳的不會動。調整在 `lib/config/app_constants.dart` 的 `synced*Retention`。

- **App 啟動後配對狀態每次都消失**:kiosk 沒有 keyring,App 會自動改用 `~/.local/share/.../auth_token.json` (權限 600)。看 log 有 `using file storage` 即正常。
- **「找不到 RealSense 相機」**:`rs-enumerate-devices` 沒列出 → 換 USB 3 線 / 埠、確認電源夠 (5 A);有列出但 App 找不到 → 重新登入讓 plugdev 群組生效,或 `sudo udevadm trigger`。
- **「這台機器的相機還沒設定好」**:`python3 -c "import pyrealsense2"` 失敗 → 跑 `deploy/build-librealsense.sh`;或 bridge 檔案不在 (看 log `realsense bridge not found`)。
- **「相機沒有回應」**:bridge 超過 20 秒沒回。多半是 USB 2 連線 (「偵測相機」會顯示 USB 2.x) 或相機被另一個程序佔著 (`realsense-viewer` 還開著)。
- **深度有效比例很低 / 中央距離 0**:相機太近 (< 30 cm) 或對著反光面;拉開到 40–60 cm。
- **相機第一張很暗**:自動曝光還沒收斂。預設丟掉 15 張暖機影格再取;若仍暗,補光燈常亮,或在 `CameraSettings.warmupFrames` 調大。
- **HID 秤讀不到**:`cat /dev/hidraw0 | xxd` 放東西上去應該會有資料;沒有資料多半是權限 (重新登入讓 plugdev 生效) 或裝置編號不是 0。
- **時間不對**:`timedatectl status` 看 NTP 是否同步;`capture_time` 用機台時鐘。

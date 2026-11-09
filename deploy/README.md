# 機台部署 (Raspberry Pi 5;Jetson Orin Nano 次要)

對應 [ARCHITECTURE.md](../ARCHITECTURE.md) §5 與 §11 階段 5。機台只做採集:拍照、秤重、品質檢查、上傳,不跑任何 AI。

## 0. 只要記一個指令

```bash
python3 deploy/spoonfull.py              # 在專案資料夾 (第一次安裝用這個)
python3 /opt/spoonfull/spoonfull.py      # 安裝後在任何地方都可以
```

用**一般使用者**執行 (不要加 `sudo`),需要權限的步驟程式會自己呼叫 sudo。畫面會列出目前 App 是否執行中、開機是否自動啟動,輸入數字選項即可:

| 主選單 | 做什麼 |
|---|---|
| 1 安裝 / 更新機台 | 新機台第一次;之後要更新服務或 bridge 再跑一次 (App 不會被覆蓋)。會依序問:執行 App 的帳號、開機要不要自動啟動 App、HX711 是否直接接 GPIO、(沒有 App 時) 要不要下載最新版,確認後安裝套件、udev 權限、NTP、App、kiosk 服務 |
| 2 開啟 App / 3 關閉 App | 全螢幕 kiosk 服務 |
| 4 開機自動啟動 App | 依目前狀態問要開還是關 |
| 5 查看 App 狀態與 log | 服務狀態、最近 50 行 log,可選擇持續看 (Ctrl-C 結束) |
| 6 相機 | 偵測相機 (序號 / 韌體 / USB)、拍一張測試照 (深度有效比例與距離)、相機校正 (見 §3)、編譯相機驅動。App 開著時會先問要不要關掉讓出相機 |
| 7 HX711 秤 | 校正 (放已知重量的砝碼)、看即時讀數、設定腳位、開機服務狀態、假資料測試。開機服務在跑時會先暫停、做完再開回來。設定存在執行 App 那個帳號的 `~/.config/spoonfull/hx711.json`,所以要用**那個帳號**登入操作 (用別的帳號會被擋下並提示) |
| 8 還原上一版 App | 自動更新後新版有問題時;只有「更新中斷」或「新版還沒確認正常」時才有舊版可以換回 (§5)。換回後會把那一版記成壞版本,App 不會再自動裝它 |

這個資料夾裡的其他檔案,平常不用直接執行:

| 檔案 | 用途 |
|---|---|
| `spoonfull.py` | 上面的選單。也是 HX711 開機服務本身 (服務以 `spoonfull.py hx711-bridge` 執行,不用手動跑)。kiosk / HX711 服務與 udev 規則的內容都寫在這個檔案裡 |
| `realsense_bridge.py` | App 拍照時自己呼叫 (即時預覽與快門)。手動檢查請用選單「相機」;要直接跑:`--probe` 偵測、`--once a.jpg a_depth.png a.json` 拍一張、`--mock` 沒相機時產生合成影像 |
| `realsense_tool.py` | 相機校正,從選單「相機 → 相機校正」進入 (§3) |
| `build-librealsense.sh` | 編譯相機驅動,從選單「相機 → 編譯 / 安裝相機驅動」執行 |
| `spoonfull-recover.sh` | 自動更新的退路。kiosk 服務每次啟動 App 前自動執行,CI 也會打包進 Release (§5) |
| `tests/` | `python3 -m unittest discover -s deploy/tests -v` (不需要硬體) |

## 1. 安裝到機台 (Raspberry Pi 5,Pi OS Bookworm 64-bit)

需要:Pi 5 + 官方 5 A 電源、Intel RealSense D435f 接 **USB 3** 埠(藍色)、已開自動登入的桌面 session(Pi OS Desktop 預設有)。

1. 抓專案:
   ```bash
   git clone https://github.com/alianlbj23/spoonfull-flutter-app.git
   cd spoonfull-flutter-app
   ```
2. 開選單:
   ```bash
   python3 deploy/spoonfull.py
   ```
3. **相機 → 編譯 / 安裝相機驅動**(只需一次,約 30–45 分鐘)。最後會在 `~/librealsense/build/` 產出 `librealsense2-*.deb`,留著給下一台機台 `sudo dpkg -i`,就不用再編。
4. 回主選單 **1 安裝 / 更新機台**,照提示回答 (Enter = 括號裡的預設值):
   - 執行 App 的帳號:直接 Enter 用目前登入的帳號;
   - 開機自動啟動 App:正式上線的機台選 `y`,測試中的機台 Enter (不自動啟動);
   - HX711 直接接 GPIO:有才選 `y` (會裝開機服務,並問要不要馬上校正);
   - 沒有 App 時會問要不要從 GitHub Release 下載最新版:Enter (下載)。**一定要用 Release 的版本**,只有它會自動更新(見 §5)。
5. 重新登入(讓群組權限生效),再開選單:**相機 → 偵測相機** 應印出序號、韌體、USB 3.x;然後主選單 **2 開啟 App**。
6. App 裡:設定 → 硬體設定 → 相機來源 **RealSense D435f (RGB-D)**(Linux 預設已選)→ **偵測相機** → **測試拍照** → 看到照片與「深度:有效 xx%,中央 yy cm」→ 選秤的類型(§3)→ **儲存**。

> 已經在跑的機台,重跑一次「安裝 / 更新機台」會更新 kiosk 服務與 bridge,App 本身不會被覆蓋。開機自動啟動那題回答 Enter (否) 的話,會把開機自動啟動關掉。
>
> 從舊版 `install-device.sh` 裝的機台:重跑一次「安裝 / 更新機台」(HX711 那題照實回答),HX711 開機服務才會改用 `spoonfull.py`。`/opt/spoonfull/hx711_bridge.py` 之後用不到,可以自己刪掉。

### Raspberry Pi 4 也可以

同樣步驟,差別:要 64-bit Pi OS;編相機驅動約 1–1.5 小時,2 GB 記憶體的型號先加 swap,並在「是記憶體 2 GB 以下的 Pi 嗎?」回答 `y`(或直接拿 Pi 5 編好的 .deb);電源用官方 3 A;相機一樣接藍色 USB 3 埠。

## 2. 自己編譯(開發用)

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

> 不要帶 `--dart-define=USE_MOCK_API=true` 到正式機台。

## 3. 硬體

| 項目 | App 設定 (設定 → 硬體設定) | 備註 |
|---|---|---|
| RealSense D435f | 來源 **RealSense D435f (RGB-D)**,序號留空 (只接一台) | 接 **USB 3** 埠;「偵測相機」會顯示序號 / 韌體 / USB 版本,USB 2 會提示換埠。拍照同時輸出 RGB + 深度圖 (1280x720,mm,對齊) |
| 沒有相機 (開發) | 來源 **選擇圖片** | 沒有深度圖 |
| USB HID 秤 (Dymo / Stamps.com 類) | 類型 **USB HID 秤**,裝置 `/dev/hidraw0` | `ls -l /dev/hidraw*`;udev 規則已開放 plugdev 群組 |
| 序列埠秤或 HX711 + Arduino/ESP32 | 類型 **序列埠 / HX711 (USB)**,裝置 `/dev/ttyUSB0`、鮑率 | 微控制器每行輸出 `ST,GS,  123.4 g` 或純數字即可 |
| HX711 直接接 GPIO | 類型 **HX711 (GPIO bridge)**,`127.0.0.1:9100` | 安裝時 HX711 那題選 `y` 裝開機服務;選單 **HX711 秤 → 校正** 放已知重量的砝碼。接線預設 DT → GPIO 5、SCK → GPIO 6 (BCM),可在選單改;GPIO 函式庫見 `spoonfull.py` 開頭說明 |
| 沒有秤 | 類型 **不使用秤** | 不送 `weight_g`,server 以菜單標準份量估算 |

相機固定架在餐車上、餐盒放固定位置 (秤面就是放餐盒的位置),餐前餐後角度要一致。D435f 的深度在 **30 cm 以內不可靠**,相機到餐盒建議 40–60 cm;「測試拍照」會顯示深度有效比例與中央距離,拿來確認架設高度。

### 相機檢查與架設

1. 相機接 USB 3 埠,開 App → 硬體設定 → **偵測相機**。顯示「USB 3.x」正常;顯示「USB 2.x (請改接 USB 3 埠)」就換埠或換線。
2. 把空餐盒放在秤面上,按 **測試拍照**。看三個數字:
   - 畫面要清楚、不過暗(品質檢查通過);
   - **深度有效比例**要在 90% 以上,太低代表太近(< 30 cm)或對著反光面;
   - **中央距離**就是相機到餐盒的距離,建議 40–60 cm。
3. 數字正常後拍 **空秤參考照**(下一節),再 **儲存**。

不想開 App 也可以用選單 **相機 → 偵測相機 / 拍一張測試照**:測試照存在 `/tmp/spoonfull_test.jpg`,並印出深度有效比例與中央距離。

### 相機校正 (選單「相機 → 相機校正」)

低頻率的維護操作,透過 SSH 手動執行,App 不會呼叫。新機台第一次、相機被撞到或拆裝過、量測明顯不準時再做;平常可以只跑 health check 看要不要校正。

**要列印的圖檔**

| 用途 | 圖檔 | 取得方式 | 印好後要實測 |
|---|---|---|---|
| 深度校正 (On-Chip / Focal Length / Tare 共用) | Intel 官方標靶 `Calibration_Target_v1.pdf`:低對比紋理背景 + 四個模糊圓點 | 下載 <https://librealsense.intel.com/Releases/UCAL/Calibration_Target_v1.pdf> | 圓點中心間距 (設計值 175 mm × 100 mm) |
| RGB 內參 | ChArUco 板:7×5 格、方格 30 mm、標記 22 mm、字典 `DICT_5X5_100`,A4 橫向 | 工具選項 **8** 產生,預設存到 `~/spoonfull_charuco_7x5_30mm.pdf` | 方格邊長、標記邊長 |

列印方式 (兩張都一樣,依官方白皮書附錄 A):

- **100% 縮放 (實際大小),不可選「符合頁面」**;
- 霧面 (低反光) 紙,厚一點較好;
- 貼在平整的硬板上,不能翹曲;
- 印好後用尺量上表「印好後要實測」的尺寸,校正時要輸入。

官方白皮書「Self-Calibration for D400 Series」:<https://intelrealsense.com/download/9277> (網頁版 <https://dev.intelrealsense.com/docs/self-calibration-for-depth-cameras>)。

**執行**

`python3 /opt/spoonfull/spoonfull.py` → **6 相機 → 3 相機校正**。App 開著時會先問要不要關掉 (相機一次只能給一個程式用),校正結束會問要不要開回來。

相依:`python3-numpy`、`python3-opencv` (「安裝 / 更新機台」已裝) 與 pyrealsense2 (「編譯 / 安裝相機驅動」已裝)。

**相機校正選單**

| 選項 | 做什麼 | 需要 | 會寫入相機嗎 |
|---|---|---|---|
| 1 | 完整校正流程 (引導模式):Health check → On-Chip → Focal Length → Tare → RGB 內參 → UV map → Health check,每步可略過,最後列摘要 | 兩張標靶 | 每一步問過才寫 |
| 2 | 相機資訊:型號、序號、韌體、USB、Advanced Mode | — | 否 |
| 3 | 目前內參:深度 (左紅外線) 與 RGB 的 fx / fy / ppx / ppy、畸變,深度→RGB 外參;有 RGB 校正檔也一併顯示 | — | 否 |
| 4 | Health check:\|值\| < 0.25 良好;0.25～1 建議重新校正;> 1 必須重新校正 | 深度標靶或有紋理的平面 | 否 |
| 5 | On-Chip 自我校正 (預設內參模式,可選外參模式),改善深度雜訊 | 深度標靶或有紋理的平面,紋理占畫面 ≥ 35% | 問過才寫 |
| 6 | Focal Length 校正:輸入實測圓點中心間距 | 深度標靶,四個圓點都入鏡,距離 0.8～1 m | 問過才寫 |
| 7 | Tare 校正:輸入相機到標靶平面的真實距離 (mm),校正絕對深度 | 深度標靶,距離約 0.65～1.8 m | 問過才寫 |
| 8 | 產生 ChArUco 板 PDF | — | 否 |
| 9 | RGB 內參校正 (OpenCV + ChArUco),見下方 | ChArUco 板 | 否,存檔 |
| 10 | 深度對齊 RGB 校正 (UV map) — **尚未實作** (官方沒有 Python 用法,需要時用 `realsense-viewer`) | — | — |
| 11 | 備份目前的校正表到檔案 | — | 否 |
| 12 | 恢復出廠校正 (會再確認一次,執行前自動備份) | — | 是 |
| 13 | 顯示標靶下載連結與列印方式 | — | 否 |

**深度校正 (選項 4～7) 的流程**

1. 選項開始前會列出準備事項 (標靶、距離),標靶要平貼並正對相機,按 Enter 開始;**校正中相機與標靶都不能動**。
2. 第一次執行若相機沒開 Advanced Mode,會詢問是否開啟;開啟後相機會重新啟動,等約 10 秒再選一次。
3. 工具會先做一次 health check → 執行校正 → 暫時套用新校正再做一次 health check,然後**並排顯示校正前後的內參與 health**。
4. 詢問「是否寫入相機?(y/N)」,預設不寫入並還原為原本的校正。校正後 health 比校正前差時會提示不要寫入。
5. 選 y 才寫入;寫入前自動把原本的校正表備份到 `~/.config/spoonfull/realsense_backup/calib_<日期時間>_<序號>.json`。

建議順序 (官方):On-Chip → Focal Length → Tare,最後再跑一次 health check 確認數值變小。

**RGB 內參校正 (選項 9)**

SDK 對 D400 回報的 RGB 畸變係數全為 0,所以另外用 OpenCV 校正,結果只存檔供軟體使用,**不寫入相機**。

1. 輸入實測的方格邊長與標記邊長 (mm)。
2. 開始預覽 (RGB 1280×720)。透過 SSH 執行時會問要不要把預覽視窗顯示在機台螢幕上;開不了視窗就改用文字模式,終端機會持續顯示偵測到的角點數。
3. 手持板子,每張變換角度 (傾斜 20～40 度)、距離 (25～40 cm),讓板子輪流出現在畫面四角與邊緣;拿穩後按 **空白鍵** 拍一張,目標 20 張 (最少 10 張),**q** 提早結束。每拍一張會提示還沒拍到的區域。
4. 計算後比較同一批照片的重投影誤差 (px):A) SDK 出廠內參 (畸變 0) vs B) OpenCV 校正結果,分整體 / 畫面中央 / 邊緣列出,並給建議 (例如 B 明顯較低時建議採用)。
5. 你決定是否儲存到 `~/.config/spoonfull/rgb_intrinsics.json` (內容:相機序號、解析度、日期、相機矩陣、畸變係數、兩組重投影誤差)。已有舊檔時會先複製一份到 `realsense_backup/`。

**還原**

- 深度校正寫壞了:選項 **12** 恢復出廠校正,再重新校正。每次寫入前的原始校正表都在 `~/.config/spoonfull/realsense_backup/`。
- RGB 校正不想用了:刪掉 `~/.config/spoonfull/rgb_intrinsics.json` 即回到 SDK 出廠內參。

**測試** (不需要相機):`python3 -m unittest discover -s deploy/tests -v`

### 空秤參考照

硬體設定頁的「拍攝空秤參考照」:秤上不放任何東西拍一張。之後每次拍照會與它比對畫面中央區域,差異太小就提示「餐盒不在畫面」。沒有參考照時改用邊緣密度判斷,較不準。相機位置或補光改變後要重拍參考照。

### 品質檢查門檻

在 [lib/config/app_constants.dart](../lib/config/app_constants.dart) 的 `quality*` 常數:過暗 (平均亮度 < 60)、過亮 (> 215 或爆白 > 30%)、模糊 (Laplacian 變異數 < 50)、餐盒不在畫面。以現場相機拍幾張正常與異常照片,用硬體設定頁的「測試拍照」看數值後調整。

## 4. 驗證

1. 硬體設定頁:「偵測相機」→ 顯示 D435f 序號與 USB 3;「測試拍照」→ 看到照片、品質指標與「深度:有效 xx%,中央 yy cm」;「即時讀數」→ 秤的數字會動,放上重物後穩定圖示變綠。
2. 走一次流程:選病房 → 床位 → 餐前 → 放餐盒 → 拍照。會先出現相機的即時畫面 (1–2 秒內),按右邊的圓形快門 → 畫面顯示「拍照與秤重中」,接著確認頁左下角出現重量 (來源「秤」),右側選時段膳食 → 上傳。拔掉相機 USB 線再按拍照 → 畫面應顯示找不到相機與「重試」鈕,插回去按重試會恢復。
3. server 端確認 `FoodIntake` 有 `weight_g`、`client_record_id`、`captured_at`,`edge_result` 有 `quality_check` 與 `depth_attached: true`,而且收到 `depth` (PNG) 與 `depth_meta` 兩個欄位。
4. 拔網路線上傳一筆 → 顯示離線排隊;插回去自動送出,server 只會有一筆 (去重鍵 `client_record_id`)。

## 5. 自動更新

每次 push 到 `main`,GitHub Actions 會編譯三個平台並更新同一個 Release (`latest`),同時放一份 `version.json`。已安裝的 App 會在**啟動時、網路恢復時、以及每 10 分鐘**讀一次 `version.json`,發現較新的版本就下載、驗證 SHA-256、替換安裝資料夾裡的檔案,然後重新啟動 ([lib/services/update_service.dart](../lib/services/update_service.dart))。

- **不會打斷操作**:拍照或上傳中不安裝;使用者 60 秒內碰過螢幕也先不安裝。剛啟動時視為閒置,會馬上更新。安裝前畫面會顯示「正在更新到最新版本」約 3 秒。
- **只有 GitHub 編譯的版本會自動更新**。本機 `flutter build` / `flutter run` 的版本編號是 0,不會更新自己。「安裝 / 更新機台」預設就會下載 Release 版本。
- **壞版本會自動退回**:安裝時被換掉的舊檔會改名成 `*.spoonfull-old` 留著,新版順利跑滿 60 秒才刪掉。
  - 安裝到一半失敗:當場換回舊檔,App 繼續使用。
  - 安裝到一半斷電:下次開機換回舊檔。
  - 新版一啟動就當掉(或啟動失敗):kiosk 服務每次啟動前執行 `spoonfull-recover.sh`,連續 3 次沒撐過 60 秒,第 4 次啟動就換回上一版,並把這個版本記在 `/opt/spoonfull/.update-bad-build`,之後不再安裝它。修正後推出更新的版本會照常安裝。
  - 這需要 kiosk 服務裡的 `ExecStartPre=...spoonfull-recover.sh`;舊機台重跑一次「安裝 / 更新機台」即可。
  - 想在 App 還沒退回前手動換回:選單 **8 還原上一版 App** (只有更新中斷或新版還沒確認正常時才有舊版可換)。
- **目前跑哪一版**:設定 → 系統狀態的「版本」(build 號碼 = GitHub Actions 的 run number)。
- **安裝資料夾要可寫入**:機台由「安裝 / 更新機台」把 `/opt/spoonfull` 的擁有者改成執行 App 的帳號。Windows / Ubuntu 桌機請解壓縮到使用者自己的資料夾 (不要放 `C:\Program Files`)。
- **機台要連得到 `github.com`**。醫院網路若有防火牆,需要放行 `github.com` 與 `objects.githubusercontent.com`,否則只是不會更新,App 照常運作。
- **repo 必須是 public**,App 才讀得到 Release。
- 看 log:選單 **5 查看 App 狀態與 log**,或 App 自己的紀錄檔 `~/.local/share/com.example.spoonfull_flutter_app/logs/spoonfull.log` (見 §6)。`auto-update off: ... is not writable` 表示安裝資料夾權限不對,重跑一次「安裝 / 更新機台」。
- 更新來源可在編譯時用 `--dart-define=UPDATE_BASE_URL=https://.../` 改成自己的伺服器 (底下要有 `version.json` 與安裝檔)。

## 6. 常見問題

- **App 的紀錄檔**:info 以上的訊息與所有錯誤 (含當機前的例外) 會寫到 App support 資料夾的 `logs/spoonfull.log`,Linux 通常是 `~/.local/share/com.example.spoonfull_flutter_app/logs/`。超過 1 MB 會改名成 `spoonfull.log.1`,只留一份舊檔。
- **畫面顯示「系統啟動失敗」**:通常是本機資料庫打不開 (磁碟滿或檔案損毀)。看紀錄檔的 `startup failed`;更新器在這個畫面仍會運作,有修正版會自動裝上。
- **照片佔用空間**:已上傳的照片 14 天後自動刪除,紀錄 90 天後刪除;還沒上傳的不會動。調整在 `lib/config/app_constants.dart` 的 `synced*Retention`。

- **App 啟動後配對狀態每次都消失**:kiosk 沒有 keyring,App 會自動改用 `~/.local/share/.../auth_token.json` (權限 600)。看 log 有 `using file storage` 即正常。
- **「找不到 RealSense 相機」**:`rs-enumerate-devices` 沒列出 → 換 USB 3 線 / 埠、確認電源夠 (5 A);有列出但 App 找不到 → 重新登入讓 plugdev 群組生效,或重跑一次「安裝 / 更新機台」(會重新載入 udev 規則)。
- **「這台機器的相機還沒設定好」**:選單「相機 → 偵測相機」說找不到 pyrealsense2 → 跑「相機 → 編譯 / 安裝相機驅動」;或 bridge 檔案不在 (看 log `realsense bridge not found`) → 重跑「安裝 / 更新機台」。
- **「相機沒有回應」**:bridge 超過 20 秒沒回。多半是 USB 2 連線 (「偵測相機」會顯示 USB 2.x) 或相機被另一個程序佔著 (`realsense-viewer` 還開著)。
- **深度有效比例很低 / 中央距離 0**:相機太近 (< 30 cm) 或對著反光面;拉開到 40–60 cm。
- **相機第一張很暗**:自動曝光還沒收斂。預設丟掉 15 張暖機影格再取;若仍暗,補光燈常亮,或在 `CameraSettings.warmupFrames` 調大。
- **HID 秤讀不到**:`cat /dev/hidraw0 | xxd` 放東西上去應該會有資料;沒有資料多半是權限 (重新登入讓 plugdev 生效) 或裝置編號不是 0。
- **時間不對**:`timedatectl status` 看 NTP 是否同步;`capture_time` 用機台時鐘。

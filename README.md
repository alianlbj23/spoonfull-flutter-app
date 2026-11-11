# Spoonfull 送餐系統 — 機台端 App

這份只寫**怎麼做**:測試、部署到機台、校正相機。
API 規格與開發細節見 [docs/API.md](docs/API.md);部署的技術說明見 [docs/DEPLOY_NOTES.md](docs/DEPLOY_NOTES.md)。

## 要執行哪個 script?

| 在哪裡 | 執行這個 | 做什麼 |
|---|---|---|
| 開發電腦 | `flutter analyze`、`flutter test` | 測試 App (一、測試) |
| 開發電腦 | `python3 -m unittest discover -s deploy/tests -v` | 測試機台工具 (一、測試) |
| 開發電腦 | `python tools/send_test_records.py` | 不開 App,直接對 server 測配對與上傳 (互動選單) |
| **機台** | **`python3 deploy/spoonfull.py`** (安裝後也可以用 `python3 /opt/spoonfull/spoonfull.py`) | **機台上只要執行這一個**:安裝、開關 App、相機、秤、相機校正全部在這個選單裡 |

`deploy/` 底下其他檔案都**不用自己執行**:

| 檔案 | 誰會執行它 |
|---|---|
| `deploy/build-librealsense.sh` | 選單 **6 → 4** (安裝相機驅動) |
| `deploy/realsense_tool.py` | 選單 **6 → 3** (相機校正) |
| `deploy/realsense_bridge.py` | App 拍照時自己會用 |
| `deploy/spoonfull-recover.sh` | App 每次啟動時自動執行 (更新壞掉時換回舊版) |

機台上的選單:輸入數字選擇;問題後面括號裡的是預設值,直接按 Enter 就是選它。**不要加 sudo**,需要時程式會問密碼。

---

## 一、測試 (開發電腦)

1. 第一次先裝套件:
   ```bash
   flutter pub get
   ```
2. 跑 App 的測試 (不需要硬體或網路):
   ```bash
   flutter analyze
   flutter test
   ```
3. 跑機台工具的測試 (需要 Python 3 的 numpy、opencv-contrib-python):
   ```bash
   python3 -m unittest discover -s deploy/tests -v
   ```
4. 在電腦上把 App 跑起來看畫面 (沒有 server 也可以,用內建假資料、配對自動核准):
   ```bash
   flutter run -d windows --dart-define=USE_MOCK_API=true
   ```
   - Linux 電腦把 `windows` 換成 `linux`。
   - 沒有相機但想測拍照流程 (Linux):`SPOONFULL_REALSENSE_MOCK=1 flutter run -d linux`,拍照會產生一張合成的餐盒照片。
5. 要測真的 server (配對 → 同步 → 上傳):
   ```bash
   python tools/send_test_records.py
   ```

> 推到 `main` 之前,1～3 都要通過。CI 也會跑 `flutter analyze` 與 `flutter test`,沒過就不會發佈。

---

## 二、部署到機台

### 1. 新機台安裝 (只做一次)

準備:Raspberry Pi 5 + 官方 5 A 電源、相機接**藍色 USB 3 孔**、桌面設定成自動登入。

1. 在機台開終端機,下載專案並開啟選單:
   ```bash
   git clone https://github.com/alianlbj23/spoonfull-flutter-app.git
   cd spoonfull-flutter-app
   python3 deploy/spoonfull.py
   ```
2. 選 **6 相機** → **4 編譯 / 安裝相機驅動** → 等它跑完 (約 30–45 分鐘)。
   - 記憶體 2 GB 以下的 Pi 問到時回答 `y`。
3. 回主選單,選 **1 安裝 / 更新機台**,依序回答:
   1. 帳號 → Enter
   2. 開機自動啟動 App → 正式上線的機台 `y`;測試中的機台 Enter
   3. HX711 秤直接接在 GPIO 上 → 有才 `y`
   4. 要下載最新版 App → Enter
   5. 開始安裝 → Enter
4. **登出再登入** (讓權限生效)。
5. 再執行 `python3 /opt/spoonfull/spoonfull.py`,選 **6 相機** → **1 偵測相機**:看到序號和「USB 3.x」就對了。
6. 選 **2 開啟 App**。

### 2. 架設相機與秤 (在 App 裡)

1. 相機固定在餐車上,餐盒每次放在秤面同一個位置,相機到餐盒 40–60 cm。
2. App:**設定 → 硬體設定**。
3. 相機來源選 **RealSense D435f (RGB-D)** → 按 **偵測相機** → 按 **測試拍照**,確認畫面清楚、深度有效 90% 以上、中央距離 40–60 cm。
4. 秤上不放東西 → 按 **拍攝空秤參考照**。
5. 選秤的類型:

   | 你的秤 | 選這個 |
   |---|---|
   | USB 秤 (插上就能用的那種) | USB HID 秤,裝置 `/dev/hidraw0` |
   | 秤接 Arduino / ESP32 再接 USB | 序列埠 / HX711 (USB),裝置 `/dev/ttyUSB0` |
   | HX711 直接接 Pi 的 GPIO | HX711 (GPIO bridge),位址 `127.0.0.1:9100` (先做下面第 3 步) |
   | 沒有秤 | 不使用秤 |

6. 按 **儲存**,然後走一次:選病房 → 床位 → 餐前 → 放餐盒 → 拍照 → 按快門 → 確認頁有重量 → 上傳。

### 3. HX711 秤校正 (秤直接接 GPIO 才需要)

準備一個已知重量的砝碼 (例如 500 g)。

1. 用**執行 App 的那個帳號**登入,執行 `python3 /opt/spoonfull/spoonfull.py`。
2. 選 **7 HX711 秤** → **1 校正** → 輸入砝碼重量 → 秤上清空按 Enter → 放上砝碼按 Enter。
3. 選 **2 看即時讀數** 確認數字正確,按 Ctrl-C 結束。

### 4. 發佈新版

push 到 `main` 就會自動編譯並發佈,所有機台會在 10 分鐘內自動更新,不用到機台上操作。

### 5. 日常操作 (`python3 /opt/spoonfull/spoonfull.py`)

| 想做的事 | 選單 |
|---|---|
| 開 App / 關 App | 2 / 3 |
| 開機要不要自動開 App | 4 |
| App 有問題,看記錄 | 5 |
| App 自動更新後壞掉,換回上一版 | 8 |
| 機台設定要更新 (App 不會被覆蓋) | 1 |

---

## 三、校正相機

新機台第一次、相機被撞到或拆裝過、量測不準時才做。

### 1. 先準備材料 (一次備齊再開始)

- [ ] **深度校正標靶**:下載 <https://librealsense.intel.com/Releases/UCAL/Calibration_Target_v1.pdf>
- [ ] **ChArUco 板**:選單裡產生 (見下面第 2 步)
- [ ] 兩張都要:**列印時選「實際大小 / 100%」**,不要選「符合頁面」或「縮小超出的頁面」;霧面紙
  - 深度標靶的檔案是美規 Letter 尺寸,用 A4 紙印沒問題 (只會切掉一點邊緣背景)
- [ ] 平整硬板 2 塊 + 膠水或雙面膠:兩張標靶各貼一塊,不能翹
- [ ] 捲尺 (Tare 要量相機到標靶的距離)
- [ ] 能把深度標靶立著固定的支架或牆面 (Focal Length 不能用手拿)
- [ ] 白熾燈 / 鹵素燈或 850 nm 紅外線補光燈:Focal Length 這步會關投射器,D435f 在室內 LED 燈下太暗
- [ ] 機台電源用 **5V/5A (27W)**:3A 電源時 USB 只給 600 mA,相機開投射器會被斷電

### 2. 印標靶

1. 在機台執行 `python3 /opt/spoonfull/spoonfull.py`,選 **6 相機** → **3 相機校正** (App 開著會問要不要先關,按 Enter)。
2. 畫面先列出材料清單,輸入 `p` 產生 ChArUco 板 PDF (存在家目錄的 `spoonfull_charuco_7x5_30mm.pdf`)。
3. 把兩張 PDF 拿去列印,貼到硬板上。
4. 尺寸不用量:照 100% 列印就是設計值,程式直接用。只有懷疑印表機縮放時,量一下深度標靶左右圓點中心距離是不是 175 mm (縮小時約 170 mm,要重印)。

### 看預覽畫面

每個校正開始前都會先開預覽,讓你看相機看到什麼、擺好再開始。透過 SSH 操作時選 **1 用瀏覽器看**,
程式會印出固定的網址 (例如 `http://<機台 IP>:8765/<隨機碼>/`),存成書籤即可;按鍵仍在 SSH 視窗按
(空白鍵 = 開始,`q` = 取消)。

### 3. 校正 (照順序)

進入相機校正選單後,選 **1 完整校正流程**,它會一步一步帶你做。每一步都可以輸入 `s` 略過:

| 步驟 | 你要做的事 |
|---|---|
| 1. Health check | 深度標靶固定在相機前方,正對相機。預覽的有效深度要 > 35% (越滿越好) → 空白鍵。看結果:**小於 0.25 良好**、0.25～1 建議校正、大於 1 必須校正 |
| 2. On-Chip | 標靶不動 → 空白鍵。完成後比較校正前後的 health,問「是否寫入相機」時:數字有變小就輸入 `y` |
| 3. Focal Length | 圓點間距直接按 Enter (用設計值)。標靶**固定**在 **0.8～1 m**,IR 預覽裡 4 個圓點要在畫面正中央的白框內,等畫面顯示 **READY** 再按空白鍵 → 同上決定要不要寫入 |
| 4. Tare | 先看預覽擺好標靶 → 空白鍵 → 用捲尺量相機到標靶的距離 (從相機前玻璃量要再加 4.7 mm) → 輸入 (mm) → 同上決定要不要寫入 |
| 5. RGB 內參 | 手拿 ChArUco 板在相機前 25～40 cm,擺一個姿勢**拿穩**,畫面閃綠框就是自動拍到了,再換角度 / 位置 (畫面四個角落都要拍到),共 20 張 → 看建議決定要不要儲存 |
| 6. UV map | 尚未提供,輸入 `s` 略過 |

校正失敗時程式會說明原因與調整方式,問「要再試一次嗎?」直接按 Enter 就會重新預覽再試。

注意:**校正時相機和標靶都不能動**。第一次做深度校正時,程式可能會要求開啟相機的進階模式,回答 `y` 後等 10 秒,再選一次同一個項目。

做完後輸入 `0` 離開,問要不要把 App 開回來 → Enter。

**校正後變更糟**:每次寫入前都會自動備份。進入相機校正選單選 **14 從備份還原**,或 **12 恢復出廠校正** 後重做。

**更新相機韌體**:到 <https://dev.realsenseai.com/docs/firmware-releases-d400/> 下載最新 D400 韌體 (要同意授權條款),
把 zip 放到機台,選 **15 更新相機韌體**。更新中不可拔線或斷電。

---

## 出問題時

| 狀況 | 怎麼做 |
|---|---|
| 找不到相機 | 改插藍色 USB 3 孔、換條線、確認電源是 5 A;再不行就登出登入,或重跑選單 **1** |
| 「相機還沒設定好」 | 選單 **6 → 4** 編譯 / 安裝相機驅動 (一律裝 GitHub 上最新的 librealsense 正式版) |
| 「相機沒有回應」 | 偵測相機顯示 USB 2 就改插 USB 3 孔;關掉其他正在用相機的程式 |
| 深度有效比例很低 | 相機離太近或對著反光面,拉開到 40–60 cm |
| 相機一直斷線 (「usb device disconnected」「failed to set power state」) | USB 供電不足:換 5V/5A (27W) 電源,或相機接有獨立供電的 USB 3 hub。`od -An -tu4 --endian=big /proc/device-tree/chosen/power/max_current` 顯示 5000 才是 5A |
| 第一張照片很暗 | 補光燈保持開著 |
| USB 秤讀不到 | 登出再登入;確認裝置選 `/dev/hidraw0` |
| 時間不對 | 讓機台連上網路,會自動校時 |
| 其他問題 | 選單 **5** 看記錄,把畫面拍下來回報 |

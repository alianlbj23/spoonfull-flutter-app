# Spoonfull 送餐系統 — 機台端 App

Spoonfull 機台端 App 裝在病房送餐車的觸控螢幕上(Jetson Orin Nano 或 Raspberry Pi 5,1024×600 橫向)。護理/送餐人員依序選病房、床位、膳食與時段,在**送餐前**和**回收後**各拍一張照片並**自動秤整盤重量**。照片、重量與紀錄以 HTTP 上傳到後端(以下稱「接收器」,即 server 的 `devices` 模組),接收器立刻存檔回 200,AI 分析在 server 端非同步進行。

**機台只做採集**:拍照、秤重、拍照品質檢查、壓縮、離線佇列、上傳。不跑任何 AI(見 [ARCHITECTURE.md](ARCHITECTURE.md) §2、§5)。

這份文件主要寫給**要實作接收器的人**:機台什麼時候發什麼請求、請求長什麼樣、接收器要怎麼回應,都在下面。系統整體架構與 server 端規劃見 [ARCHITECTURE.md](ARCHITECTURE.md);機台硬體(相機、秤)與部署步驟見 [deploy/README.md](deploy/README.md)。

**文件分工**:本文件描述機台與接收器之間的 API 契約,依程式碼的實際行為撰寫,API 細節與程式碼不一致時以本文件為準。[ARCHITECTURE.md](ARCHITECTURE.md) 是整體系統(含 server)的目標設計。[flutter_architecture_spec.md](flutter_architecture_spec.md) 是最早的 PHP 時期規格,已過時,只留作參考。

---

## 1. 建置與執行

```bash
flutter pub get

# 連真的接收器
flutter run -d linux          # Jetson Orin Nano / Raspberry Pi 5 / Linux 桌面
flutter run -d windows

# 還沒有接收器時,用內建假資料跑 (配對不需要管理員,輪詢一次後自動核准)
flutter run -d windows --dart-define=USE_MOCK_API=true
```

在 Windows / macOS 開發時,相機來源預設為「系統相機 / 選檔」(選一張圖片當照片),秤預設為「不使用秤」。到 **設定 → 硬體設定** 可改成:

- **測試圖片資料夾**:把餐盒照片放進 [test_images/](test_images/),每次「下一步」依檔名順序取下一張(循環)。接 RealSense 之前,用真實照片走完整個上傳流程就用這個。
- **模擬相機** / **模擬秤**:不需要任何檔案或硬體,自動產生合成圖與假重量。

不經 App、直接用 `test_images/` 的照片加假資料打 server(配對 → 同步 → 上傳 → 去重),用 [tools/send_test_records.py](tools/send_test_records.py),全部互動選單、不用記參數:

```bash
python tools/send_test_records.py
```

配對流程與 App 相同:印出配對碼 → 請 Super Admin 到管理後台核准 → 輪詢拿 token。

**Linux 機台建置相依**:`clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libjsoncpp-dev`;執行期需要 `gstreamer1.0-tools gstreamer1.0-plugins-good v4l-utils`。開機自動全螢幕 (kiosk) 的安裝步驟見 [deploy/README.md](deploy/README.md)。

| dart-define | 值 | 說明 |
|---|---|---|
| `USE_MOCK_API` | `true` / 不設 | `true` 時使用 [mock_api_repository.dart](lib/data/api/mock_api_repository.dart),不發任何 HTTP 請求 |
| `APP_ENV` | `dev`(預設)/ `test` / `prod` | 只影響 log 等級 |
| `APP_BUILD` | 整數 / 不設 (0) | 版本編號,CI 帶入 GitHub Actions 的 run number。0 代表本機編譯,**不會自動更新**。設定頁的「系統狀態」會顯示 |
| `UPDATE_BASE_URL` | URL / 不設 | 自動更新的下載位置,底下要有 `version.json` 與各平台安裝檔。預設是本 repo 的 GitHub Release `latest` |
| `DEFAULT_SERVER_URL` | URL / 不設 | 機台**還沒存過**伺服器設定時,設定畫面預設帶入的伺服器位址。預設 `https://foodintakesystem.com`(公開站台,經 Cloudflare)。使用者仍可在設定畫面改成任何位址,存過之後就以存的為準。設成空字串或不合法的網址(例如公開網域用 `http://`)等於沒有預設 |

**支援的平台**:Linux (arm64 / x64) 與 Windows,由 CI 編譯。`macos/` 可當開發機用。`android/`、`ios/`、`web/` 是 `flutter create` 產生的範本,沒有設定相機權限、CI 也不編譯,目前不支援。

### 1.1 測試

```bash
flutter analyze
flutter test
```

CI ([.github/workflows/build.yml](.github/workflows/build.yml)) 在每個 PR 與每次 push 到 `main` 時都會先跑這兩項,沒過就不會編譯。測試不需要硬體或網路:用記憶體 SQLite、Mock API、模擬相機與模擬秤 ([test/helpers/test_services.dart](test/helpers/test_services.dart))。

### 1.2 發佈與版本

- **只有 push 到 `main` 才會發佈**:CI 編譯 Linux arm64 / x64 與 Windows,更新同一個 GitHub Release (`latest`),最後才上傳 `version.json`。PR 只跑測試。
- **版本編號**是 GitHub Actions 的 run number (`APP_BUILD`,畫面上的 build 號碼),pubspec 的版本號不用改。
- **所有機台會在 10 分鐘內自動更新**,所以 push 到 `main` 前請確定測試通過。新版若啟動就失敗,機台會自動退回上一版並不再安裝這個版本 (見 [deploy/README.md](deploy/README.md) §5);修正後再 push 一版即可。

> 伺服器位址由使用者在機台的設定畫面輸入(見第 2 節);新機台預設帶入公開站台 `https://foodintakesystem.com`(可用 `DEFAULT_SERVER_URL` 改預設),要連院內或測試伺服器時直接改掉即可。

**Windows 建置注意**:[windows/CMakeLists.txt](windows/CMakeLists.txt) 已加入 `/utf-8` 與 `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`,用來解決非 UTF-8 系統語系(例如日文 CP932)及 VS 2026 下 `connectivity_plus` / `permission_handler_windows` 的編譯錯誤。請勿移除。

每次建置 Windows 都看到 `Nuget.exe not found, trying to download or use cached version.`:這是 `permission_handler_windows` 的 CMake 在 PATH 上找不到 `nuget.exe`(它用 NuGet 安裝 C++/WinRT),找不到就印這行再用快取版本,**建置仍會成功**。要讓訊息消失,裝一次 NuGet 讓它在 PATH 上:

```powershell
winget install Microsoft.NuGet
```

裝完重開終端機即可。Linux 機台沒有這段 CMake,不受影響。

---

## 2. 啟動流程

### 2.1 App 啟動時(程式內部)

```
main()
 ├─ 鎖定橫向螢幕
 ├─ AppServices.create()                      lib/services/app_services.dart
 │   ├─ 開啟 SQLite (快取 + 本機紀錄 + 離線佇列)
 │   ├─ 讀 SharedPreferences (device_id、伺服器設定)
 │   │    └─ 第一次啟動時產生 device_id (UUID v4),之後永久沿用
 │   └─ 讀加密儲存區 (device_token)
 └─ DeviceState.initialize()                  lib/state/device_state.dart
     ├─ 檢查 token:存在且未過期 → 已配對;已過期 → 清除 → 未配對
     │    └─ 已配對 → GET api/machine/me/ 確認 token 仍有效並更新機台名稱 (401 → 解除配對)
     ├─ SyncService.start()
     │   ├─ 將上次異常中斷而卡在 processing 的佇列項目改回 pending
     │   ├─ 監聽網路狀態 (斷線 → 恢復時自動同步)
     │   ├─ 每 30 分鐘強制完整同步一次
     │   └─ 若已配對 → 連上推播 api/machine/ws/ (server 資料一變動就重抓,§4.7)
     ├─ 健康檢查 GET api/machine/health/ (歡迎畫面「伺服器」燈號;順便檢查機台時鐘,§4.0)
     └─ 若已配對 → syncAll():更新快取 + 上傳離線佇列
歡迎畫面:設定齊全但沒有 token (第一次、401 被撤銷、重新配對) → 自動開啟配對畫面
```

### 2.2 第一次使用(操作流程)

```
歡迎畫面
 └─ 點左上齒輪 → 伺服器設定畫面
      輸入:伺服器位址 (預設 https://foodintakesystem.com,可改成任何完整網址)、埠號 (選填)、場域 (place_id)
      儲存 ─┬─ 尚未配對 → 配對畫面 (Device Authorization Flow,§4.1)
            │     ├─ POST api/machine/pair/start/ → 大字顯示配對碼 (例如 K7QM-42XP) 與倒數
            │     ├─ 管理員到管理後台「機台管理」輸入配對碼核准 (機台名稱由管理員設定)
            │     └─ 每 interval 秒 POST api/machine/pair/poll/ → approved 拿到 token
            │          └─ 佇列中等待重試的紀錄改成立即上傳,並強制同步 (rooms / beds / meals)
            └─ 已配對且位址/埠/場域有變更 → 自動解除配對並清除快取 → 回歡迎畫面自動開啟配對畫面
歡迎畫面「開始使用」→ 病房列表 → 床位 → 餐前/餐後 → 放餐盒 → 拍照 + 秤重 (同時) → 品質檢查 → 確認 (時段/膳食/重量) → 上傳
```

**拍照 + 秤重**(第一次使用前先到「設定 → 硬體設定」選相機與秤,詳見 [deploy/README.md](deploy/README.md)):

1. 相機擷取一張原始照片(Linux 用 GStreamer `v4l2src` / `nvarguscamerasrc` 或 `rpicam-still`;Android/iOS 用系統相機;桌面開發用選檔),同時讀秤直到讀數穩定(連續 5 筆差距 ≤ 2 g,或秤自己回報穩定;最多等 6 秒)。
2. 照片縮到**長邊 1280、JPEG 品質 80**,並做純 CPU 品質檢查:過暗、過亮、模糊(Laplacian 變異數)、餐盒不在畫面(與「空秤參考照」比對,沒有參考照則看畫面中央邊緣密度與對比)。不通過時提示重拍,也可選「仍要使用」。
3. 確認畫面左下顯示重量與來源(秤 / 手動),可「重新秤重」或「手動輸入」;沒有秤時不送重量。

**BASE_URL 組法**([server_address.dart](lib/core/utils/server_address.dart) `ServerAddress.resolve`,設定畫面在位址欄下方即時顯示「將連線到 …」):

- 位址欄預設為公開站台 `https://foodintakesystem.com`(沒存過設定時);可直接改成任何完整網址,例如院內 `http://192.168.1.10:8000`
- **埠可省略**,依協定預設 443(https)/ 80(http);網址裡有寫埠就以網址為準,否則才用埠欄位
- 只輸入主機名稱 / IP 時:院內區網位址(私有 IP `10.*` / `172.16–31.*` / `192.168.*`、`localhost`、`*.local`、沒有點的單段主機名稱)預設 `http://`,**其他(公開網域)預設 `https://`**
- 公開網域輸入 `http://` 會被拒絕(「公開網址必須使用 https://…」),避免 token 與照片以明文經過網際網路
- 位址可帶子路徑,例如 `192.168.1.10:8080/spoonfull` → `http://192.168.1.10:8080/spoonfull/`
- 所有 API 路徑都是**相對路徑**,接在 BASE_URL 後面,例如 `https://foodintakesystem.com/api/machine/rooms/`
- 舊版存的設定(位址 + 埠,沒寫協定一律 http)升級後會自動轉成完整網址,仍連到原本的位址(包含公開網域的 http,狀態畫面會提示未加密)

### 2.3 什麼時候會發請求

| 時機 | 發出的請求 |
|---|---|
| 啟動、儲存設定、配對成功、按「重新整理資料」 | `GET api/machine/health/`(5 秒逾時;舊版 server 回 404 時退回 `GET /`,有任何 HTTP 回應就算可連線) |
| 進入配對畫面 | `POST api/machine/pair/start/`,之後每 `interval` 秒 `POST api/machine/pair/poll/` 直到核准、被拒或離開畫面 |
| 啟動時已配對 | `GET api/machine/me/`(確認 token 仍有效、更新機台名稱) |
| 配對成功後 | 佇列中所有待上傳紀錄改成立即上傳;三個查詢 API 全部重抓(不帶 `last_updated`),並建立推播連線 `api/machine/ws/` |
| 推播連線建立(含斷線重連) | 三個查詢 API 全部重抓,補上斷線期間錯過的變動 |
| 收到推播 `data_changed` | 只重抓事件列出的資料(1.5 秒內的多個事件合併成一次),見 §4.7 |
| 啟動、網路恢復時 | 查詢 API:病房/床位超過 1 小時、膳食超過 24 小時才重抓 |
| 每 30 分鐘 | 三個查詢 API 全部重抓(推播的最後保險) |
| 按下上傳 | `POST api/machine/records/`(離線則先進佇列) |
| 佇列重試到期 | `POST api/machine/records/` |

---

## 3. 傳輸協定

### 3.1 共通規則

| 項目 | 規格 |
|---|---|
| 路徑 | 全部相對於 BASE_URL,**結尾一律有斜線**(`api/machine/.../`),避免 Django `APPEND_SLASH` 把 POST 轉址而丟掉 body |
| 協定 | HTTP/1.1(院內區網通常是 `http`;經 Cloudflare 的公開網址一律 `https`) |
| 編碼 | 回應 body 一律以 **UTF-8** 解碼 |
| 時間 | 所有時間戳都是 **Unix timestamp(秒)**,不是毫秒 |
| 認證 | 除了配對的 `pair/start/`、`pair/poll/` 與健康檢查以外,所有請求都帶 `Authorization: Bearer {device_token}` |
| 逾時 | 一般請求 15 秒;上傳 60 秒;健康檢查 5 秒 |
| 查詢參數 | 值為空字串的參數會被省略,不會送出 |
| 數字欄位 | 機台可以接受字串數字(`"12"`)或 JSON 數字(`12`),兩者都能解析 |

### 3.2 回應格式(所有 API 相同)

**成功**:HTTP 2xx,而且 `success` 必須是 JSON 布林 `true`(字串 `"true"` 不算):

```json
{ "success": true, "data": { ... } }
```

`data` 必須是物件;如果不是物件,機台會把它當成空物件處理。

**失敗**:

```json
{ "success": false, "error": { "code": "DENIED", "message": "管理員拒絕了這次配對", "retryable": false } }
```

`error.message` 會**直接顯示在機台螢幕上**,請用使用者看得懂的中文(配對錯誤原樣顯示,不加前綴)。
`error.retryable`(新版 server 一律附上)告訴機台這個錯誤值不值得重試;機台**以它為準**,舊版 server 沒給時才依 §3.3 的狀態碼判斷。

### 3.3 HTTP 狀態碼與機台行為

接收器回的狀態碼會決定機台**要不要重試**,這點很重要([api_client.dart](lib/data/api/api_client.dart) `_mapError`、[app_exception.dart](lib/core/errors/app_exception.dart) `isRetryable`):

| 接收器回應 | 機台行為 |
|---|---|
| 2xx + `success:true` | 成功 |
| 錯誤信封帶 `error.retryable` | **照 server 說的做**(`true` 重試、`false` 不重試) |
| **401**(JSON 回應),或 JSON 的 `error.code = "TOKEN_EXPIRED"`(管理員撤銷或重新配對) | 清除 token、**強制解除配對**,回到配對畫面重新取碼;待上傳的資料保留,重新配對後立刻補傳 |
| 4xx 的 JSON 錯誤信封(403、422、其他 4xx,**408 / 429 除外**) | 顯示錯誤,**不重試** |
| 408、429 | **會重試**;有 `Retry-After`(秒數或 HTTP 日期)時,下次至少等那麼久 |
| **5xx** | 進入離線佇列,**會重試** |
| 連線失敗 / 逾時 / TLS 交握失敗 / 其他 I/O 錯誤 | 進入離線佇列,**會重試** |
| **不是 JSON 的回應**(HTML、空 body:Cloudflare Access 登入頁、WAF 403、502 / 530 錯誤頁)、3xx、JSON 但沒有錯誤信封 | 視為代理或網路問題,**會重試**;不會因此解除配對,紀錄**不會**因此被標成永久失敗 |
| 2xx 但 `success != true` 且有 `error.code` | 依 `retryable`,沒給則**重試** |

> **設計接收器時請注意**:只有暫時性的問題(資料庫忙碌、磁碟滿、AI 服務掛掉)才回 5xx。資料本身有錯要回 4xx 的錯誤信封(最好附 `retryable: false`),否則機台會一直重送同一筆錯誤資料。

### 3.4 上傳重試策略

上傳失敗後,依序間隔 **1 秒 → 5 秒 → 30 秒 → 5 分鐘 → 30 分鐘**重試,之後**每 30 分鐘一次,直到成功**(沒有次數上限):網路中斷、逾時、5xx、代理回的 HTML 與 401 都不會放棄,server 停機再久,恢復後都會自動補傳。server 回 `Retry-After` 時,下次重試至少等那麼久。只有不可重試的錯誤(§3.3:`retryable: false`,或舊版 server 的 4xx 錯誤信封)才標記為 failed,由使用者在紀錄畫面確認後手動重試。佇列依建立時間先進先出(FIFO),遇到網路中斷或 401 就停止這一輪;重新配對成功後,所有待上傳項目立即重試,不等退避。

**餐前先到**:餐後照片上傳前,若同一住民、同一時段、同一天(機台當地日期)的餐前照片還在佇列裡,餐後照片先留在佇列(不算失敗),約 5 秒後或排在餐前那筆的下次重試之後再試,確保 server 先收到餐前。

每筆紀錄在上傳前就連同佇列項目一起寫入本機資料庫;上傳到一半斷電或當機,下次啟動會自動補傳。所以**同一筆紀錄可能送到兩次**,接收器一定要依 `client_record_id` 去重(見 §4.6)。

---

## 4. API 規格

### 4.0 `GET api/machine/health/` — 健康檢查(不需認證)

```json
{ "success": true, "data": { "status": "ok", "server_time": 1726900123, "api_version": 1 } }
```

- 歡迎畫面燈號、設定畫面儲存 / 「重新整理資料」都用它測試連線;回 5xx 或 HTML(例如 Cloudflare 502)就算無法連線
- 舊版 server 沒有這支(回 **404**)時,退回舊做法:`GET BASE_URL`,有任何 HTTP 回應就算可連線
- `server_time` 與機台時間相差超過 **120 秒**時,設定畫面與「系統狀態」顯示「機台時間比伺服器快/慢約 N 分鐘…」警告並寫 log(`capture_time` 依賴機台時鐘)

### 4.1 機台配對 — Device Authorization Flow

機台**顯示**配對碼,管理員在網頁核准;機台上不輸入任何東西,機台名稱也由管理員在網頁設定。
三支 API 都用 `{success, data}` / `{success, error}` 信封。

**`POST api/machine/pair/start/`**(不帶 `Authorization`)

```json
{ "hardware_id": "3f1c2a9e-8b7d-4e21-9c55-0a1b2c3d4e5f", "app_version": "1.0.57" }
```

| 欄位 | 說明 |
|---|---|
| `hardware_id` | 機台第一次啟動時產生的 UUID v4(`DeviceConfig.deviceId`),重裝 App 才會改變。1–128 個 `A-Za-z0-9._:-` 字元。同一個 `hardware_id` 再配對時,server 視為同一台機台(舊 token 失效) |
| `app_version` | CI 版為 `1.0.<build>`,本機編譯為 `dev` |

```json
{ "success": true, "data": { "device_code": "<64 hex>", "pairing_code": "K7QM-42XP", "expires_in": 600, "interval": 5 } }
```

- 機台大字顯示 `pairing_code` 與倒數(`expires_in` 秒),提示「請到管理後台『機台管理』輸入:K7QM-42XP」
- `device_code` 只放在記憶體,不寫 log、不顯示;配對完成、過期、被拒或離開配對畫面就丟掉
- 錯誤碼:`INVALID_HARDWARE_ID`(400)、`THROTTLED`(429,照 `Retry-After` 等待後自動再試;沒給則等一個 `interval`)

**`POST api/machine/pair/poll/`**(不帶 `Authorization`),每 `interval` 秒一次

```json
{ "device_code": "<64 hex>" }
```

| 回應 | 機台行為 |
|---|---|
| 200 `{"status": "pending"}` | 繼續等 |
| 200 `{"status": "approved", "device_token": "spf_…", "device_id": 12, "device_name": "A棟2樓"}` | 存 token(**只會回這一次**)、把 `device_name` 寫進設備配置、進入已配對並觸發一次同步。`device_id` 是 server 的整數 id,另存為 `serverDeviceId`,**不覆蓋** App 的 UUID |
| 400 `EXPIRED` | 碼過期或失效:自動重新呼叫 `pair/start/` 換新碼,不需要使用者操作 |
| 403 `DENIED` | 顯示「管理員拒絕了這次配對」與「重新取得配對碼」按鈕,**不自動重試** |
| 429 `SLOW_DOWN` | 輪詢間隔加 5 秒後繼續 |
| 連線失敗 / 逾時 / 5xx | 照 §3.4 的重試間隔再試,**不換新碼** |

**`GET api/machine/me/`**(帶 `Authorization`):`{ "device_id": 12, "device_name": "A棟2樓", "location": "WARD7" }`。
機台啟動時呼叫,確認 token 仍有效並更新顯示名稱;回 401 就走解除配對流程。

- 任何 API 回 **401**(`TOKEN_EXPIRED`,管理員撤銷或重新配對)或 WebSocket 收到 close code **4401**:清掉 token,回到配對畫面重新取碼
- 離開配對畫面或 App 進背景時停止輪詢;回來時繼續,碼已過期就重新取
- `error.message` 是中文,機台**原樣顯示**(`DENIED` 固定顯示「管理員拒絕了這次配對」)

### 4.2 `GET api/machine/rooms/` — 病房列表

查詢參數:`place_id`(一定會帶)、`last_updated`(選填,見 4.5)

```json
{
  "success": true,
  "data": {
    "rooms": [
      { "place_id": "WARD7", "room_id": "R101", "room_name": "101", "beds_count": 3, "updated_at": 1726900000 }
    ],
    "timestamp": 1726900123
  }
}
```

### 4.3 `GET api/machine/beds/` — 床位與病患

查詢參數:`place_id`、`last_updated`、`room_id`(皆選填)。`room_id` 是 `rooms` 回的 `room_id`,帶了就只回該病房的床位;機台目前**不會**帶,而是一次抓整個場域後在本機分組。

```json
{
  "success": true,
  "data": {
    "beds": [
      {
        "place_id": "WARD7", "room_id": "R101", "bed_id": "R101-B1", "bed_name": "床號1",
        "patient_id": "P0001", "patient_name": "王小明", "patient_age": 72,
        "updated_at": 1726900000
      },
      {
        "place_id": "WARD7", "room_id": "R101", "bed_id": "R101-B2", "bed_name": "床號2",
        "patient_id": null, "patient_name": null, "patient_age": null,
        "updated_at": 1726900000
      }
    ],
    "timestamp": 1726900123
  }
}
```

- 空床的 `patient_id` 請給 `null` 或空字串;空床在機台上**無法**記錄
- `room_id` 必須對得上 `room_data` 的 `room_id`

### 4.4 `GET api/machine/meals/` — 膳食與用餐時段

查詢參數:`place_id`。**每次都是全量取代**(不支援增量)。

```json
{
  "success": true,
  "data": {
    "current_slot": "lunch",
    "meals": [
      { "place_id": "WARD7", "meal_id": "M1", "meal_name": "一般午餐", "meal_type": "lunch",
        "meal_time_slot": "lunch", "assigned_patient_ids": ["12", "15"], "updated_at": 1726900000 }
    ],
    "time_slots": [
      { "time_slot_id": "lunch", "time_slot_name": "午餐 11:00 - 13:30", "start_time": "11:00", "end_time": "13:30" }
    ],
    "timestamp": 1726900123
  }
}
```

- `meal_type` 只能是 `breakfast` / `lunch` / `dinner` / `snack`,其他值一律當成 `snack`
- `start_time` / `end_time` 格式為 `HH:MM`(24 小時制)。機台依目前時間自動選時段,並依開始時間推估餐別:早於 10:30 為早餐、早於 15:00 為午餐、早於 21:00 為晚餐,其餘為點心
- `time_slots` 的陣列順序就是畫面上的顯示順序
- `current_slot`(選填):server 依它的時鐘判斷的目前時段 `time_slot_id`,不在任何時段內時為 `null`。機台預設選這個時段(收到後 30 分鐘內有效,過期才退回機台時鐘推估),不受機台時鐘誤差影響
- `meal_time_slot`(選填):這份膳食屬於哪個時段。只要有任何膳食帶這個欄位,確認畫面就**只列出所選時段的膳食**,絕不預選別的時段的菜
- `assigned_patient_ids`(選填):指派這份膳食的住民。確認畫面優先預選、並排在最前面的是指派給該住民的膳食
- 舊版 server 沒有這些欄位時,機台依時段開始時間推估餐別來預選(舊行為)

### 4.5 增量同步(`last_updated`)

- 機台保存上一次回應裡的 `data.timestamp`,下次請求時當成 `last_updated` 帶回來
- **有帶** `last_updated` 且本機已有快取:機台以 `bed_id` / `room_id` 為 key **合併(upsert)**回傳的資料,所以接收器可以只回有變動的資料
- **沒帶** `last_updated`(第一次、配對後、每 30 分鐘):機台**整批取代**快取,所以接收器必須回全部資料
- 接收器也可以忽略 `last_updated` 一律回全量,這樣最簡單也正確。但要注意:增量模式下機台不會刪除資料,已刪除的病房/床位要等下一次全量同步才會消失(推播連上時或每 30 分鐘;收到 `data_changed` 的重抓也是全量取代)
- `timestamp` 請用**伺服器時間**,不要用資料的最大 `updated_at`,以免漏掉同一秒內的變動

### 4.6 `POST api/machine/records/` — 上傳膳食紀錄(主要輸出)

`Content-Type: multipart/form-data`,帶 `Authorization: Bearer …`

| 欄位 | 型別 | 說明 |
|---|---|---|
| `image` | 檔案 | JPEG 或 PNG;檔名為 `{uuid}.jpg` 或 `{uuid}.png`;part 的 Content-Type 為 `image/jpeg` 或 `image/png` |
| `bed_id` | 文字 | 來自 bed_data |
| `patient_id` | 文字 | 拍照當時這張床的病患 |
| `meal_id` | 文字 | 來自 meal_data |
| `meal_time_slot` | 文字 | **`time_slot_id`**(例如 `T1`),不是顯示名稱 |
| `before_after` | 文字 | `before`(送餐前)或 `after`(回收後) |
| `capture_time` | 文字(數字) | **快門時間**(相機拍到 / 選好檔案的那一刻,不是按上傳的時間),Unix 秒(機台時鐘,機台應開 NTP;時鐘與 server 差超過 2 分鐘時設定 / 狀態畫面會警告)。server 存入 `captured_at` |
| `device_id` | 文字 | 與配對時相同,可用來比對 token |
| `client_record_id` | 文字 | **一定會帶**。App 本機紀錄的 UUID,**去重鍵**:同一 `client_record_id` 再送一次 → 回原本的 `record_id`,不新增 |
| `weight_g` | 文字(數字,1 位小數) | 整盤重量(公克),餐前餐後各一次,**容器重量在餐前−餐後相減時自動抵消**。沒有秤或沒讀到時**不帶此欄位**,server 以菜單標準份量估算並標記 `weight_source=estimated` |
| `edge_result` | 文字(JSON) | 選填,機台端即時檢查結果(ARCHITECTURE.md §6.5 預留欄位)。目前內容為 `{"quality_check": {...}, "weight_source": "scale" 或 "manual"}`,server 只存不處理 |

`edge_result.quality_check` 範例:

```json
{ "mean_luma": 187.2, "dark_ratio": 0.0, "bright_ratio": 0.07, "blur_score": 170.9,
  "tray_score": 0.06, "tray_score_method": "edges", "roi_contrast": 41.3,
  "tray_detected": true, "issues": [] }
```

`issues` 可能的值:`tooDark`、`tooBright`、`blurry`、`trayMissing`(使用者選了「仍要使用」才會帶著問題上傳)。

機台送出前已檢查過的限制(接收器仍應自行檢查):

- 檔案 ≤ 5 MB,格式依檔頭判斷只接受 JPEG / PNG
- 尺寸:長邊 480–4000、短邊 320–3000;拍攝後已縮到**長邊 ≤ 1280、JPEG 品質 80**
- `bed_id` 存在於該病房,且 `patient_id` 與床位目前的病患一致(依機台快取;server 端若發現不一致但 `patient_id` 是有效住民,會以 `patient_id` 為準收下並回 `bed_mismatch: true`)
- `weight_g`(若有)為 0–20000 的有限數

**成功回應**:

```json
{
  "success": true,
  "data": {
    "record_id": "SRV-000123",
    "duplicate": false,
    "assignment_mismatch": false,
    "bed_mismatch": false,
    "image_path": "/uploads/2026/09/21/abc.jpg",
    "capture_time": 1726900200,
    "ai_status": "completed",
    "ai_result": {
      "has_food": true,
      "has_person": false,
      "leftover_percentage": 35.0,
      "confidence": 0.92,
      "note": "剩餘約 35%"
    },
    "created_at": 1726900210
  }
}
```

| 欄位 | 必填 | 說明 |
|---|---|---|
| `record_id` | 是 | 伺服器端紀錄 ID,機台保存後,這筆紀錄標記為已同步 |
| `ai_status` | 否 | `pending` / `processing` / `completed` / `failed`;不給則視為 `pending` |
| `ai_result` | 否 | 可為 `null`。`leftover_percentage` 範圍 0–100,`confidence` 範圍 0–1,`note` 會顯示給使用者 |
| `duplicate` | 否 | `true` = 這個 `client_record_id` 之前已收過,回的是原本那筆;機台只寫 log |
| `assignment_mismatch` | 否 | `true` = 這份膳食不是指派給這位住民的;機台寫 log,紀錄詳情顯示「非指派膳食」標籤 |
| `bed_mismatch` | 否 | `true` = 床位與住民不一致,server 以 `patient_id` 為準收下;機台寫 log,紀錄詳情顯示「床位與住民不符」標籤 |
| 其他 | 否 | 機台目前不使用 `image_path`、`capture_time`、`created_at` |

> **機台不會回頭查詢 AI 結果**。上傳後只顯示這次回應裡的 `ai_result`。依 ARCHITECTURE.md 的設計,server 收到照片立刻存檔回 200,分析由 `vision-worker` 排隊處理,所以正常回應就是 `ai_status: "pending"`、`ai_result: null`,機台會顯示「等待辨識」,結果在網頁上看。

建議錯誤碼(請搭配 3.3 的狀態碼語意):

| code | 建議狀態碼 |
|---|---|
| `INVALID_IMAGE_FORMAT`、`IMAGE_TOO_LARGE`、`INVALID_PATIENT_ID`、`INVALID_BED_ID` | 422(不重試) |
| 菜色沒排給這位住民 | **不要拒絕**:照收並標記 `assignment_mismatch=True`(現場照片拒了就沒了) |
| `TOKEN_EXPIRED` | 401 |
| `UPLOAD_FAILED` | 500(會重試) |

#### ⚠️ 重複上傳(請務必處理)

如果接收器已經存檔,但回應在 60 秒內沒送回機台(逾時、斷線),機台會重送同一筆資料。請以 **`client_record_id`**(每筆紀錄唯一的 UUID,`FoodIntake.client_record_id` unique)判斷是否重複;遇到重複時**回傳原本那筆的 `record_id` 與成功回應**,不要回錯誤,也不要新增一筆。

> 舊版 App(沒有 `client_record_id`)可退回用 `(device_id, bed_id, meal_id, meal_time_slot, before_after, capture_time)` 判斷。

### 4.7 `WS api/machine/ws/` — 推播:資料一變動就通知機台

病房、床位、用餐時段在機台上都是快取。為了讓 server 端改了住民房號或用膳時間後**立即**反映在機台,已配對的機台會另外保持一條 WebSocket;server 一有變動就推一則事件,機台收到後馬上重抓對應的查詢 API。沒有這條連線機台也能用(退回 30 分鐘定時同步),所以接收器可以選擇不實作。

- **位址**:`BASE_URL` 的 `http`/`https` 對應成 `ws`/`wss`,路徑 `api/machine/ws/`。例如 `https://foodintakesystem.com/` → `wss://foodintakesystem.com/api/machine/ws/`、`http://192.168.0.10:8000/` → `ws://192.168.0.10:8000/api/machine/ws/`。舊路徑 `ws/machine/` 只在區網還能用,經 Cloudflare 公開網址會被擋
- **認證**:與 REST 相同,`Authorization: Bearer <device_token>` header。token 無效或機台被停用時,server **先接受再以 close code 4401 關閉**;機台視同 REST 401:清除 token、停止重連、回到配對畫面重新取碼
- **server → 機台**(JSON 文字訊息):
  - 連上後先收 `{ "event": "connected", "device_id": "...", "machine_id": 1, "server_time": "..." }`
  - 之後每次變動收 `{ "event": "data_changed", "datasets": ["rooms", "beds"], "timestamp": 1726900123 }`,`datasets` 是 `rooms` / `beds` / `meals` 的子集:住民新增、修改、刪除 → `rooms` + `beds`;用膳時段或菜單變動 → `meals`
- **機台 → server**:可送 `{ "type": "ping" }`,server 回 `{ "event": "pong" }`(選用;目前機台不送這個訊息)。機台每 20 秒送一次 WebSocket 協定層的 ping frame,用來發現已經斷掉卻沒收到關閉通知的連線;標準的 WebSocket server (Daphne / Channels) 會自動回 pong,接收器不需要處理
- **機台行為**(`lib/services/realtime_service.dart`、`sync_service.dart`):
  - 收到 `data_changed` 後合併 1.5 秒內的所有事件,只對列出的 dataset 做一次重抓(不帶 `last_updated`,整批取代快取),畫面隨即更新
  - 連線建立時(第一次或重連)一律三個查詢 API 全部重抓,補上斷線期間錯過的變動
  - 斷線以 1、2、5、10、30 秒退避重連,之後每 60 秒;網路恢復時立即重試
  - 解除配對或 4401 時關閉連線

---

## 5. 最小接收器範例

下面以 Python + Flask 示範接收器的骨架,方便驗證協定:

```python
import time, uuid
from flask import Flask, request, jsonify

app = Flask(__name__)
TOKENS = {}   # token -> hardware_id
CODES = {}    # device_code -> {"hardware_id", "approved"}
RECORDS = {}  # dedupe key -> record_id

def ok(data): return jsonify(success=True, data=data)
def fail(status, code, msg): return jsonify(success=False, error={"code": code, "message": msg}), status

def auth():
    h = request.headers.get("Authorization", "")
    return TOKENS.get(h.removeprefix("Bearer ").strip())

@app.get("/")
def ping(): return "ok"

@app.post("/api/machine/pair/start/")
def pair_start():
    body = request.get_json()
    code = uuid.uuid4().hex + uuid.uuid4().hex
    # 示範用:沒有網頁可核准,第一次輪詢就當作管理員核准了
    CODES[code] = {"hardware_id": body["hardware_id"], "approved": True}
    return ok({"device_code": code, "pairing_code": "K7QM-42XP", "expires_in": 600, "interval": 5})

@app.post("/api/machine/pair/poll/")
def pair_poll():
    entry = CODES.pop(request.get_json().get("device_code"), None)
    if entry is None:
        return fail(400, "EXPIRED", "配對碼已過期,請重新取得")
    token = "spf_" + uuid.uuid4().hex
    TOKENS[token] = entry["hardware_id"]
    return ok({"status": "approved", "device_token": token, "device_id": 1, "device_name": "示範機台"})

@app.get("/api/machine/me/")
def me():
    hw = auth()
    if not hw: return fail(401, "TOKEN_EXPIRED", "認證失敗,需要重新配對")
    return ok({"device_id": 1, "device_name": "示範機台", "location": "demo"})

@app.get("/api/machine/rooms/")
def rooms():
    if not auth(): return fail(401, "TOKEN_EXPIRED", "認證失敗,需要重新配對")
    p = request.args["place_id"]
    return ok({"rooms": [{"place_id": p, "room_id": "R101", "room_name": "101",
                          "beds_count": 1, "updated_at": int(time.time())}],
               "timestamp": int(time.time())})

@app.get("/api/machine/beds/")
def beds():
    if not auth(): return fail(401, "TOKEN_EXPIRED", "認證失敗,需要重新配對")
    p = request.args["place_id"]
    return ok({"beds": [{"place_id": p, "room_id": "R101", "bed_id": "R101-B1", "bed_name": "床號1",
                         "patient_id": "P1", "patient_name": "王小明", "patient_age": 72,
                         "updated_at": int(time.time())}],
               "timestamp": int(time.time())})

@app.get("/api/machine/meals/")
def meals():
    if not auth(): return fail(401, "TOKEN_EXPIRED", "認證失敗,需要重新配對")
    p = request.args["place_id"]
    return ok({"meals": [{"place_id": p, "meal_id": "M1", "meal_name": "一般午餐",
                          "meal_type": "lunch", "updated_at": int(time.time())}],
               "time_slots": [{"time_slot_id": "T2", "time_slot_name": "11:30 - 13:00",
                               "start_time": "11:30", "end_time": "13:00"}],
               "timestamp": int(time.time())})

@app.post("/api/machine/records/")
def meal_record():
    device = auth()
    if not device: return fail(401, "TOKEN_EXPIRED", "認證失敗,需要重新配對")
    f, form = request.files.get("image"), request.form
    if f is None or f.mimetype not in ("image/jpeg", "image/png"):
        return fail(400, "INVALID_IMAGE_FORMAT", "僅支援 JPG / PNG 圖片")
    key = form.get("client_record_id") or (form["device_id"], form["bed_id"], form["meal_id"],
           form["meal_time_slot"], form["before_after"], form["capture_time"])
    if key not in RECORDS:                       # 重複上傳 → 回原本的 record_id
        rid = f"SRV-{uuid.uuid4().hex[:8]}"
        f.save(f"uploads/{rid}{'.png' if f.mimetype == 'image/png' else '.jpg'}")
        weight = form.get("weight_g")           # 沒有秤時不會有這個欄位
        print(rid, "weight_g=", weight, "edge_result=", form.get("edge_result"))
        RECORDS[key] = rid
    return ok({"record_id": RECORDS[key], "capture_time": int(form["capture_time"]),
               "ai_status": "pending", "ai_result": None, "created_at": int(time.time())})

if __name__ == "__main__":
    import os; os.makedirs("uploads", exist_ok=True)
    app.run(host="0.0.0.0", port=8080)
```

在機台設定畫面輸入接收器的 IP、埠號 `8080`、任意場域,儲存後進入配對畫面;這個示範接收器在第一次輪詢就核准,不需要網頁操作。

用 curl 模擬機台上傳:

```bash
curl -X POST http://localhost:8080/api/machine/records/ \
  -H "Authorization: Bearer <token>" \
  -F image=@meal.jpg -F bed_id=R101-B1 -F patient_id=P1 -F meal_id=M1 \
  -F meal_time_slot=T2 -F before_after=before -F capture_time=1726900200 \
  -F device_id=<device_id> -F client_record_id=$(uuidgen) -F weight_g=412.5
```

---

## 6. 程式碼導覽

| 想了解 | 看這裡 |
|---|---|
| API 路徑、逾時、重試間隔、圖片限制 | [lib/config/app_constants.dart](lib/config/app_constants.dart) |
| HTTP 封裝、回應解析、狀態碼 / `retryable` / `Retry-After` 對應、健康檢查 | [lib/data/api/api_client.dart](lib/data/api/api_client.dart) |
| 伺服器位址 → BASE_URL (完整網址、預設埠、http/https 規則) | [lib/core/utils/server_address.dart](lib/core/utils/server_address.dart) |
| 每個 API 送什麼、讀什麼 | [lib/data/api/api_repository.dart](lib/data/api/api_repository.dart)、[lib/data/models/](lib/data/models/) |
| 假資料(可當作回應範本) | [lib/data/api/mock_api_repository.dart](lib/data/api/mock_api_repository.dart) |
| 配對 / token | [lib/services/device_pairing_service.dart](lib/services/device_pairing_service.dart);Linux 無 keyring 時退回檔案儲存:[lib/data/local/secure_token_storage.dart](lib/data/local/secure_token_storage.dart) |
| 相機擷取 (GStreamer / rpicam / image_picker / 模擬) | [lib/services/hardware/camera_service.dart](lib/services/hardware/camera_service.dart) |
| 秤 (USB HID / 序列埠 / HX711 bridge / 模擬)、穩定判斷 | [lib/services/hardware/scale_service.dart](lib/services/hardware/scale_service.dart) |
| 壓縮 (1280 / q80) 與品質檢查 | [lib/services/hardware/image_pipeline.dart](lib/services/hardware/image_pipeline.dart)、[lib/core/utils/image_quality_analyzer.dart](lib/core/utils/image_quality_analyzer.dart) |
| 拍照 + 秤重流程、空秤參考照 | [lib/services/hardware/hardware_service.dart](lib/services/hardware/hardware_service.dart)、[lib/ui/screens/capture_flow.dart](lib/ui/screens/capture_flow.dart) |
| 硬體設定頁 | [lib/ui/screens/hardware_settings_screen.dart](lib/ui/screens/hardware_settings_screen.dart) |
| 機台安裝 (kiosk、udev、NTP、HX711 bridge) | [deploy/](deploy/) |
| 不經 App 打 server 的測試腳本 | [tools/send_test_records.py](tools/send_test_records.py) |
| App 圖示 (Windows / macOS / Linux) 產生腳本 | [tools/make_icons.py](tools/make_icons.py),原圖在 [assets/icon/app_icon.png](assets/icon/app_icon.png) |
| 上傳與離線佇列 | [lib/services/record_service.dart](lib/services/record_service.dart)、[lib/services/offline_queue_service.dart](lib/services/offline_queue_service.dart) |
| 同步時機 | [lib/services/sync_service.dart](lib/services/sync_service.dart) |
| 啟動流程 | [lib/main.dart](lib/main.dart)、[lib/state/device_state.dart](lib/state/device_state.dart) |

# Spoonfull 送餐系統 — 機台端 App

Spoonfull 機台端 App 裝在病房送餐車的觸控螢幕上(Jetson Orin Nano 或 Raspberry Pi 5,1024×600 橫向)。護理/送餐人員依序選病房、床位、膳食與時段,在**送餐前**和**回收後**各拍一張照片並**自動秤整盤重量**。照片、重量與紀錄以 HTTP 上傳到後端(以下稱「接收器」,即 server 的 `devices` 模組),接收器立刻存檔回 200,AI 分析在 server 端非同步進行。

**機台只做採集**:拍照、秤重、拍照品質檢查、壓縮、離線佇列、上傳。不跑任何 AI(見 [ARCHITECTURE.md](ARCHITECTURE.md) §2、§5)。

這份文件主要寫給**要實作接收器的人**:機台什麼時候發什麼請求、請求長什麼樣、接收器要怎麼回應,都在下面。系統整體架構與 server 端規劃見 [ARCHITECTURE.md](ARCHITECTURE.md);機台硬體(相機、秤)與部署步驟見 [deploy/README.md](deploy/README.md)。若規格與程式碼不一致,以本文件為準(本文件依程式碼實際行為撰寫)。

---

## 1. 建置與執行

```bash
flutter pub get

# 連真的接收器
flutter run -d linux          # Jetson Orin Nano / Raspberry Pi 5 / Linux 桌面
flutter run -d windows

# 還沒有接收器時,用內建假資料跑 (配對碼固定為 123456)
flutter run -d windows --dart-define=USE_MOCK_API=true
```

在 Windows / macOS 開發時,相機來源預設為「系統相機 / 選檔」(選一張圖片當照片),秤預設為「不使用秤」。到 **設定 → 硬體設定** 可改成:

- **測試圖片資料夾**:把餐盒照片放進 [test_images/](test_images/),每次「下一步」依檔名順序取下一張(循環)。接 RealSense 之前,用真實照片走完整個上傳流程就用這個。
- **模擬相機** / **模擬秤**:不需要任何檔案或硬體,自動產生合成圖與假重量。

不經 App、直接用 `test_images/` 的照片加假資料打 server(配對 → 同步 → 上傳 → 去重),用 [tools/send_test_records.py](tools/send_test_records.py):

```bash
python tools/send_test_records.py --server http://192.168.0.10:8000 --place demo --code 482913 --repeat-last
```

**Linux 機台建置相依**:`clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libjsoncpp-dev`;執行期需要 `gstreamer1.0-tools gstreamer1.0-plugins-good v4l-utils`。開機自動全螢幕 (kiosk) 的安裝步驟見 [deploy/README.md](deploy/README.md)。

| dart-define | 值 | 說明 |
|---|---|---|
| `USE_MOCK_API` | `true` / 不設 | `true` 時使用 [mock_api_repository.dart](lib/data/api/mock_api_repository.dart),不發任何 HTTP 請求 |
| `APP_ENV` | `dev`(預設)/ `test` / `prod` | 只影響 log 等級 |
| `PAIRING_CODE` | 6 位數字 / 不設 | **測試用固定配對碼**。有設時,儲存伺服器設定後、每次啟動未配對時、以及收到 401 後,App 自動用這組碼配對,不跳鍵盤;server 端需在測試環境接受同一組碼。正式部署不要設 |

> 伺服器位址**不寫死在程式裡**:由使用者在機台的設定畫面輸入(見第 2 節)。

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
     ├─ SyncService.start()
     │   ├─ 將上次異常中斷而卡在 processing 的佇列項目改回 pending
     │   ├─ 監聽網路狀態 (斷線 → 恢復時自動同步)
     │   ├─ 每 30 分鐘強制完整同步一次
     │   └─ 若已配對 → 連上推播 ws/machine/ (server 資料一變動就重抓,§4.7)
     ├─ ping 伺服器 (GET BASE_URL,歡迎畫面「伺服器」燈號)
     └─ 若已配對 → syncAll():更新快取 + 上傳離線佇列
```

### 2.2 第一次使用(操作流程)

```
歡迎畫面
 └─ 點左上齒輪 → 伺服器設定畫面
      輸入:伺服器位址、埠號、場域 (place_id)
      儲存 ─┬─ 尚未配對 → 配對碼畫面 → 輸入 6 位數配對碼
            │                 └─ POST api/machine/pair/ → 取得 token
            │                      └─ 立即強制同步 (rooms / beds / meals)
            └─ 已配對且位址/埠/場域有變更 → 自動解除配對並清除快取 → 需重新配對
歡迎畫面「開始使用」→ 病房列表 → 床位 → 餐前/餐後 → 放餐盒 → 拍照 + 秤重 (同時) → 品質檢查 → 確認 (時段/膳食/重量) → 上傳
```

**拍照 + 秤重**(第一次使用前先到「設定 → 硬體設定」選相機與秤,詳見 [deploy/README.md](deploy/README.md)):

1. 相機擷取一張原始照片(Linux 用 GStreamer `v4l2src` / `nvarguscamerasrc` 或 `rpicam-still`;Android/iOS 用系統相機;桌面開發用選檔),同時讀秤直到讀數穩定(連續 5 筆差距 ≤ 2 g,或秤自己回報穩定;最多等 6 秒)。
2. 照片縮到**長邊 1280、JPEG 品質 80**,並做純 CPU 品質檢查:過暗、過亮、模糊(Laplacian 變異數)、餐盒不在畫面(與「空秤參考照」比對,沒有參考照則看畫面中央邊緣密度與對比)。不通過時提示重拍,也可選「仍要使用」。
3. 確認畫面左下顯示重量與來源(秤 / 手動),可「重新秤重」或「手動輸入」;沒有秤時不送重量。

**BASE_URL 組法**([device_config.dart](lib/data/models/device_config.dart) `ServerSettings.baseUrl`):

- 位址沒寫協定時預設為 `http://`;要用 HTTPS 請在位址欄直接輸入 `https://…`
- 結果格式為 `http://{host}:{port}/`;位址可帶子路徑,例如 `192.168.1.10/spoonfull` → `http://192.168.1.10:8080/spoonfull/`
- 所有 API 路徑都是**相對路徑**,接在 BASE_URL 後面,例如 `http://192.168.1.10:8080/api/machine/rooms/`

### 2.3 什麼時候會發請求

| 時機 | 發出的請求 |
|---|---|
| 啟動、儲存設定、配對成功後 | `GET /`(ping,只要有任何 HTTP 回應就算可連線,5 秒逾時) |
| 配對 | `POST api/machine/pair/` |
| 配對成功後 | 三個查詢 API 全部重抓(不帶 `last_updated`),並建立推播連線 `ws/machine/` |
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
| 協定 | HTTP/1.1(院內區網通常是 `http`,也支援 `https`) |
| 編碼 | 回應 body 一律以 **UTF-8** 解碼 |
| 時間 | 所有時間戳都是 **Unix timestamp(秒)**,不是毫秒 |
| 認證 | 除了配對以外,所有請求都帶 `Authorization: Bearer {device_token}` |
| 逾時 | 一般請求 15 秒;上傳 60 秒;ping 5 秒 |
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
{ "success": false, "error": { "code": "INVALID_PAIRING_CODE", "message": "配對碼無效或已過期" } }
```

`error.message` 會**直接顯示在機台螢幕上**,請用使用者看得懂的中文。

### 3.3 HTTP 狀態碼與機台行為

接收器回的狀態碼會決定機台**要不要重試**,這點很重要:

| 接收器回應 | 機台行為 |
|---|---|
| 2xx + `success:true` | 成功 |
| **401**,或任何狀態碼且 `error.code = "TOKEN_EXPIRED"` | 清除 token、**強制解除配對**,回到歡迎畫面;待上傳的資料保留,重新配對後繼續送 |
| 403 | 顯示錯誤,**不重試** |
| 422 | 資料驗證失敗,**不重試** |
| 其他 4xx | 顯示錯誤,**不重試** |
| **5xx** | 進入離線佇列,**會重試** |
| 連線失敗 / 逾時 | 進入離線佇列,**會重試** |
| 2xx 但 `success != true` | 視為 4xx,**不重試** |
| 2xx 但 body 不是 JSON | 視為格式錯誤,**不重試** |

> **設計接收器時請注意**:只有暫時性的問題(資料庫忙碌、磁碟滿、AI 服務掛掉)才回 5xx。資料本身有錯要回 4xx,否則機台會一直重送同一筆錯誤資料。

### 3.4 上傳重試策略

上傳失敗後,依序間隔 **1 秒 → 5 秒 → 30 秒 → 5 分鐘 → 30 分鐘**重試,**最多 5 次**。超過 5 次後標記為 failed,之後只能由使用者在紀錄畫面手動重試。佇列依建立時間先進先出(FIFO),遇到網路中斷或 401 就停止這一輪。

---

## 4. API 規格

### 4.1 `POST api/machine/pair/` — 機台配對

**不帶** `Authorization`。`Content-Type: application/json`

```json
{
  "device_id": "3f1c2a9e-8b7d-4e21-9c55-0a1b2c3d4e5f",
  "device_name": "Spoonfull-WARD7-3f1c",
  "location": "WARD7",
  "pairing_code": "482913"
}
```

| 欄位 | 說明 |
|---|---|
| `device_id` | 機台第一次啟動時產生的 UUID v4,重裝 App 才會改變 |
| `device_name` | 預設為 `Spoonfull-{place_id}-{device_id 前 4 碼}` |
| `location` | 設定畫面填的**場域**,也就是之後所有查詢用的 `place_id` |
| `pairing_code` | 6 位數字(機台端已先檢查格式) |

**成功回應**:

```json
{
  "success": true,
  "data": {
    "device_id": "3f1c2a9e-8b7d-4e21-9c55-0a1b2c3d4e5f",
    "device_token": "eyJhbGciOi...",
    "token_type": "Bearer",
    "expires_in": 86400,
    "message": "Device paired successfully"
  }
}
```

- `device_token` **必填且不可為空**,否則配對失敗
- `expires_in`(秒)可以不給;不給的話機台端視 token 永不過期,只有收到 401 時才會失效
- 建議錯誤碼:`INVALID_PAIRING_CODE`、`DEVICE_ALREADY_PAIRED`、`SERVER_ERROR`
- 同一台機台(同 `device_id`)可能因為更改設定或 401 而**再次配對**,接收器應允許重新配對並發放新 token

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
    "meals": [
      { "place_id": "WARD7", "meal_id": "M1", "meal_name": "一般早餐", "meal_type": "breakfast", "updated_at": 1726900000 }
    ],
    "time_slots": [
      { "time_slot_id": "T1", "time_slot_name": "07:00 - 08:30", "start_time": "07:00", "end_time": "08:30" }
    ],
    "timestamp": 1726900123
  }
}
```

- `meal_type` 只能是 `breakfast` / `lunch` / `dinner` / `snack`,其他值一律當成 `snack`
- `start_time` / `end_time` 格式為 `HH:MM`(24 小時制)。機台依目前時間自動選時段,並依開始時間推估餐別:早於 10:30 為早餐、早於 15:00 為午餐、早於 21:00 為晚餐,其餘為點心
- `time_slots` 的陣列順序就是畫面上的顯示順序

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
| `capture_time` | 文字(數字) | 拍照時間,Unix 秒(機台時鐘,機台應開 NTP)。server 存入 `captured_at` |
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
- `bed_id` 存在於該病房,且 `patient_id` 與床位目前的病患一致
- `weight_g`(若有)為 0–20000 的有限數

**成功回應**:

```json
{
  "success": true,
  "data": {
    "record_id": "SRV-000123",
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

### 4.7 `WS ws/machine/` — 推播:資料一變動就通知機台

病房、床位、用餐時段在機台上都是快取。為了讓 server 端改了住民房號或用膳時間後**立即**反映在機台,已配對的機台會另外保持一條 WebSocket;server 一有變動就推一則事件,機台收到後馬上重抓對應的查詢 API。沒有這條連線機台也能用(退回 30 分鐘定時同步),所以接收器可以選擇不實作。

- **位址**:`BASE_URL` 的 `http`/`https` 對應成 `ws`/`wss`,路徑 `ws/machine/`。例如 `http://192.168.0.10:8000/` → `ws://192.168.0.10:8000/ws/machine/`
- **認證**:與 REST 相同,`Authorization: Bearer <device_token>` header。token 無效或機台被停用時,server **先接受再以 close code 4401 關閉**;機台視同 REST 401:清除 token、停止重連、回到配對畫面
- **server → 機台**(JSON 文字訊息):
  - 連上後先收 `{ "event": "connected", "device_id": "...", "machine_id": 1, "server_time": "..." }`
  - 之後每次變動收 `{ "event": "data_changed", "datasets": ["rooms", "beds"], "timestamp": 1726900123 }`,`datasets` 是 `rooms` / `beds` / `meals` 的子集:住民新增、修改、刪除 → `rooms` + `beds`;用膳時段或菜單變動 → `meals`
- **機台 → server**:可送 `{ "type": "ping" }`,server 回 `{ "event": "pong" }`(選用;目前機台不主動送)
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
TOKENS = {}   # token -> device_id
RECORDS = {}  # dedupe key -> record_id

def ok(data): return jsonify(success=True, data=data)
def fail(status, code, msg): return jsonify(success=False, error={"code": code, "message": msg}), status

def auth():
    h = request.headers.get("Authorization", "")
    return TOKENS.get(h.removeprefix("Bearer ").strip())

@app.get("/")
def ping(): return "ok"

@app.post("/api/machine/pair/")
def pair():
    body = request.get_json()
    if body.get("pairing_code") != "123456":
        return fail(400, "INVALID_PAIRING_CODE", "配對碼無效或已過期")
    token = uuid.uuid4().hex
    TOKENS[token] = body["device_id"]
    return ok({"device_id": body["device_id"], "device_token": token,
               "token_type": "Bearer", "expires_in": 86400})

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

在機台設定畫面輸入接收器的 IP、埠號 `8080`、任意場域,再用配對碼 `123456` 配對,就能走完整個流程。

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
| HTTP 封裝、回應解析、狀態碼對應 | [lib/data/api/api_client.dart](lib/data/api/api_client.dart) |
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
| 上傳與離線佇列 | [lib/services/record_service.dart](lib/services/record_service.dart)、[lib/services/offline_queue_service.dart](lib/services/offline_queue_service.dart) |
| 同步時機 | [lib/services/sync_service.dart](lib/services/sync_service.dart) |
| 啟動流程 | [lib/main.dart](lib/main.dart)、[lib/state/device_state.dart](lib/state/device_state.dart) |

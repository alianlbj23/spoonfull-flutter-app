# 給 server 端的修改需求:機台配對與機台 API

> 這份文件是要貼給 server(Django,`spoonfull` 主專案)那邊的工程師或 AI 助手的指令。
> 機台 App 的 API 規格以 `spoonfull-flutter-app/README.md` 第 3、4 節為準,系統分工以 `ARCHITECTURE.md` §6 為準。

---

## 背景

機台 App(Flutter,repo `spoonfull-flutter-app`)已經依 ARCHITECTURE.md §6 改好,會呼叫以下五個端點(路徑結尾一律有斜線):

| 端點 | 用途 |
|---|---|
| `POST api/machine/pair/` | 配對,取得機台 token |
| `GET api/machine/rooms/` | 病房 |
| `GET api/machine/beds/` | 床位與住民 |
| `GET api/machine/meals/` | 當天菜色與時段 |
| `POST api/machine/records/` | 上傳照片 + 重量 + 欄位 |

目前的問題:**機台拿不到配對碼,配對不會成功,後面的流程都卡住**。測試期間需要一個不用網頁產碼就能配對的方式。

## 要做的事

### 1. 測試環境的固定配對碼(最優先)

在 `devices` app 的配對 view 加入:

- 讀環境變數 `MACHINE_DEV_PAIRING_CODE`(放進 `docker-compose.yml` 的 `backend` 環境變數,`.env` 可設定)。
- 若有設定,且請求的 `pairing_code` 等於它,**直接視為配對成功**:建立或更新 `Device`(以 `device_id` 為 key,可重複配對、換新 token),回傳 token。不需要 `PairingCode` 資料列。
- 若沒設定,維持正式流程:Super Admin 在網頁產生 6 位碼、10 分鐘有效、一次性。
- 正式環境的 compose / `.env.example` 不要設這個變數,並在 README 註明這只給測試用。

機台 App 這邊會用 `flutter run --dart-define=PAIRING_CODE=123456` 啟動,自動送 `123456`。請把 `MACHINE_DEV_PAIRING_CODE=123456` 當預設測試值。

### 2. 配對請求 / 回應格式

請求(無 Authorization,`Content-Type: application/json`):

```json
{ "device_id": "<uuid v4>", "device_name": "Spoonfull-demo-3f1c", "location": "demo", "pairing_code": "123456" }
```

成功回應(HTTP 200):

```json
{ "success": true, "data": { "device_id": "<同請求>", "device_token": "<不可為空>", "token_type": "Bearer", "expires_in": 86400 } }
```

- `device_token` 必填且非空,App 會存雜湊前的原字串,server 存雜湊。
- `expires_in` 可省略(省略 = 永不過期,只靠 401 失效)。
- 失敗回 `{ "success": false, "error": { "code": "INVALID_PAIRING_CODE", "message": "配對碼無效或已過期" } }`,狀態碼 **422**(不是 400 也不是 500;`error.message` 會直接顯示在機台螢幕,請用中文)。
- `location` 就是之後查詢用的 `place_id`;如果 server 沒有 place 概念,**忽略它即可,不要因為對不到而拒絕**。

### 3. 其餘四個端點(依 README 第 4 節)

- 全部要求 `Authorization: Bearer <device_token>`;token 無效回 **401** + `error.code = "TOKEN_EXPIRED"`。
- 回應一律 `{ "success": true, "data": {...} }`,`success` 必須是 JSON 布林。
- `rooms/`、`beds/`、`meals/` 帶 `place_id` 查詢參數;`rooms/`、`beds/` 另可帶 `last_updated`(可忽略,一律回全量最簡單也正確)。`data.timestamp` 用 server 當前 Unix 秒。
- `beds/` 的 `bed_id = "{room}-{bed}"`,`patient_id = LTCPatient.id`(字串),空床 `patient_id` 給 `null`。`room_id` 要對得上 `rooms/` 的 `room_id`。
- `meals/` 回**當天**的菜色與 `time_slots`(`time_slot_id`、`start_time`/`end_time` 為 `HH:MM`),`meal_type` 只能是 `breakfast` / `lunch` / `dinner` / `snack`。
- `records/` 為 multipart,欄位:`image`、`bed_id`、`patient_id`、`meal_id`、`meal_time_slot`、`before_after`(`before`/`after`)、`capture_time`(Unix 秒 → 存 `captured_at`)、`device_id`、**`client_record_id`**(去重鍵,`FoodIntake.client_record_id` unique)、**`weight_g`**(選填,公克,存既有 `FoodIntake.weight_g`)、`edge_result`(選填 JSON 字串,只存不處理)。
  - 同一 `client_record_id` 再送一次 → 回原本的 `record_id`,HTTP 200,不新增。
  - 回應:`{ "record_id": "...", "ai_status": "pending", "ai_result": null }`。機台不等 AI。
  - 床位不存在、`patient_id` 與床位不符、圖片格式錯 → **422**,不重試。菜色沒排給這位住民 → **照收**,標 `assignment_mismatch=True`。
  - 只有暫時性問題(DB 忙、磁碟滿)才回 5xx,否則機台會無限重送。

### 4. 驗證方式

機台 repo 有一支不需要 App 的測試腳本,跑完就代表五個端點都通:

```bash
cd spoonfull-flutter-app
python tools/send_test_records.py --server http://<server>:<port> --place demo --code 123456 --repeat-last
```

預期輸出:配對成功 → 列出床位/菜/時段 → 每張照片 `record_id=...` `ai_status=pending` → 最後重送一筆回**同一個** `record_id`。

跑完請確認 `FoodIntake` 有 `client_record_id`、`weight_g`、`captured_at`、`edge_result`,`Device.last_seen_at` 有更新。

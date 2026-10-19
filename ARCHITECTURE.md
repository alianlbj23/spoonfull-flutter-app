# SpoonFull 系統架構規格

> 本文件是接下來開發的依據。機台（送餐車）與 server（本專案）的職責、容器配置、API 契約、分析流程都以此為準。
> 與既有程式碼不一致的地方，以本文件為目標，逐步把程式碼改過來。
> 機台與接收器之間 API 的實際行為（請求、回應、重試細節）以 `README.md` 為準。
> 日期：2026-10-01

---

## 1. 需求（機構提出）

1. 餐前拍照：辨識餐盒內**每道菜的份量與比例**。菜名由照護端提供（當天菜單），不靠影像辨識菜名。
2. 餐後拍照：算出**每道菜剩多少**，做餐前餐後比對。
3. 連續多天觀察每位住民：
   - 依 **DRI**（國人膳食營養素參考攝取量）判斷攝取是否足夠。
   - 是否**挑食**：某類食物持續剩很多，供機構追查是否咀嚼困難或其他問題。
   - **食量趨勢**：調整份量，減少廚餘。
4. 現場限制：機構向中央廚房訂便當再自行分菜，**碗與紙盒大小不固定**。

## 2. 設計原則

| 原則 | 意思 |
|---|---|
| **機台只做採集** | 拍照、秤重、品質檢查、上傳。不跑任何 AI。機台硬體可以是 Jetson Orin Nano 或 Raspberry Pi 5，App 與 API 相同。 |
| **收照片與分析分離** | API 收到照片立刻存檔、回 200（毫秒級）。分析由獨立 worker 排隊處理，GPU 一次只跑一張。機台永遠不會因為 AI 忙而逾時重送。 |
| **菜名來自菜單，不來自影像** | YOLO 只負責「找出哪裡有食物」，名稱對應到 `MealAssignment` 當天的菜色。 |
| **比例靠影像，克數靠秤** | 單張照片算不出克數（碗大小不固定）。餐前餐後面積比給「剩餘比例」，秤給「實際吃掉的克數」。 |
| **數字用程式算，LLM 只寫文字** | DRI 比對、挑食旗標、趨勢全部是確定性的計算。Ollama 只負責把算好的結果寫成中文摘要，不讓它做算術。 |
| **一台 server 服務多台機台** | 照片總量由住民數決定（48 人 × 2 餐 × 餐前餐後 ≈ 200 張／天），不由機台數決定。 |

## 3. 系統總覽

```
送餐車（機台）                              server（本專案，5090）
┌──────────────────────┐                   ┌─────────────────────────────────────────┐
│ Flutter App          │  照片 + 重量 + 欄位 │ backend（Django，無 GPU）               │
│  選房 → 床 → 菜 → 拍照 │ ────────────────► │  machine API、存檔、FoodIntake(pending)  │
│  秤重自動讀數         │                   └──────────────┬──────────────────────────┘
│  品質檢查、離線佇列    │                                  │
└──────────────────────┘                                  ▼
                                 ┌──────────────────┐  ┌────────────┐  ┌───────────────────┐
                                 │ vision-worker    │  │ ollama     │  │ nutrition-job     │
                                 │ YOLO + SAM2，GPU  │  │ 文字 LLM   │  │ 每晚一次           │
                                 │ 一次一張          │  │ GPU        │  │ 算數字 → LLM 寫摘要 │
                                 └──────────────────┘  └────────────┘  └───────────────────┘
                                   每道菜的遮罩、面積、        每位住民：攝取 vs DRI、挑食旗標、食量趨勢
                                   餐前餐後比例、吃掉克數                    ▼
                                                                 frontend（網頁）、報表
```

## 4. Server：Docker 容器與職責

| 容器 | 職責 | 底層映像 | 相對現況的變動 |
|---|---|---|---|
| `backend` | Django API、`devices` 模組（機台配對、機台 API）、網頁後端、備份 | `python:3.11-slim` | **移除 torch / ultralytics / catboost 的依賴**，映像從 12 GB 降到約 1 GB。YOLO 體積估算（需要 depth CSV 的舊流程）移到 `vision-worker`。 |
| `vision-worker` | 輪詢 `FoodIntake` 中 `vision_status=pending` 的紀錄，跑 YOLO → SAM2，寫回每道菜的結果。一次只處理一張。 | `pytorch/pytorch:2.7.1-cuda12.8-cudnn9-runtime`（映像 `spoonfull-vision`，`ai-services/vision/`） | 第一階段先搬現有的 YOLO 體積估算進來；`sam2-service` 容器用**同一個映像**繼續提供 SAM2 HTTP API 給剩食分析用，等 §8 的流程改寫完再併入 worker。模型檔（`best.pt`、SAM2 checkpoint）掛載進容器，不打包進映像。 |
| `ollama` | 文字 LLM（營養摘要）。VLM 只在菜名對應不到時當備援。 | 官方映像 | 不變。模型由 `scripts/deploy.py` 依每台 GPU 記憶體選（`OLLAMA_VLM_MODEL=auto`，qwen3-vl 的 -instruct 系列）或手動指定，看圖與寫建議兩步共用同一個模型；規則見 README「映像」一節。 |
| `nutrition-job` | 每晚跑一次 `manage.py run_nutrition_job`：算每位住民近 N 天的攝取、比對 DRI、產生旗標與摘要。 | 與 `backend` 同一映像 | 新增。用容器內 cron 或 compose 的獨立服務 + `sleep` 迴圈皆可。 |
| `rag_backend` + `qdrant` | DRI 表、營養指引知識庫，供 `nutrition-job` 查詢 | 現有 | 不變 |
| `frontend` | 新增「機台管理」頁、每道菜的剩餘結果、住民營養報告頁 | 現有 | |
| `db`、`mailpit`、`cloudflared` | 現有 | | 不變 |

**compose 變更**：
- `docker-compose.local-ai.yml` 併入 `docker-compose.yml`，`ollama`、`vision-worker` 永遠啟動。移除 `deploy.py` 的 `--ai` / `--no-ai` 開關與 `DEPLOY_AI`。
- 映像依 `scripts/internal/stack.py` 的指紋機制建置與共享（Docker Hub，`docker.io/alianlbj23/spoonfull-*`），規則見 README「映像」一節。

## 5. 機台（送餐車）：職責與硬體

### 5.1 軟體（Flutter App，repo：`spoonfull-flutter-app`）

| 功能 | 狀態 | 說明 |
|---|---|---|
| 選病房 → 床位 → 菜色 → 餐前／餐後 → 拍照 → 上傳 | 已有 | |
| 離線佇列、重試（1s → 5s → 30s → 5m，之後每 30m 直到成功） | 已有 | 以錯誤信封的 `retryable` 為準；舊版 server 沒給時只有 4xx 錯誤信封（408 / 429 除外）不重試，代理回的 HTML 一律重試；遵守 `Retry-After`，見 §6.3 與 README §3.3 |
| 配對、token 儲存 | 已有 | Device Authorization Flow：機台顯示配對碼，管理員在網頁核准，機台輪詢拿 token（README §4.1）。Linux kiosk 沒有 keyring 時自動改用檔案儲存（權限 600） |
| 相機擷取 | 已有 | `image_picker` 在 Linux 不支援相機，改用 GStreamer / V4L2、`rpicam-still` |
| 秤重 | 已有 | 自動讀取秤的數值（USB HID 秤、序列埠秤或 HX711 load cell），餐前餐後各一次，隨照片上傳 |
| 拍照品質檢查 | 已有 | 純 CPU：過暗、過亮、模糊（Laplacian 變異數）、餐盒不在畫面 → 提示重拍 |
| 壓縮 | 已有 | 長邊 1280、JPEG 品質 80 |
| 上傳欄位 | 已有 | `weight_g`、`client_record_id`（見 §6.4） |
| 推播 | 已有 | `api/machine/ws/` 收到 `data_changed` 立刻重抓，見 §6.6 |
| 自動更新 | 已有 | 每次 push 到 `main` 由 CI 發佈；新版啟動失敗時自動退回上一版（`deploy/README.md` §5） |

### 5.2 硬體

| 項目 | 要求 | 理由 |
|---|---|---|
| 運算板 | Jetson Orin Nano 8GB（已購）或 Raspberry Pi 5 8GB（新購） | 機台不跑 AI，兩者皆可 |
| 相機 | USB 或 CSI，**固定架在餐車上，餐盒放固定位置** | 餐前餐後角度一致，SAM2 比對才準 |
| 補光燈 | 小型環形燈 | 病房燈光差異大，餐後常偏暗 |
| **秤** | 放餐盒的位置就是秤面，整盤秤重 | 餐前重 − 餐後重 = 吃掉的克數，**容器重量自動抵消**，不需要知道碗多重 |
| 時間 | NTP 自動校時 | `capture_time` 要可信 |
| 儲存 | Pi 5 用 SSD，不用 SD 卡 | 24 小時 kiosk 的壽命 |

## 6. 機台 ↔ Server API 契約

以 `spoonfull-flutter-app/README.md` 的規格為基礎，server 端在 Django 新增 `devices` app 實作。**由 server 配合 App 的請求／回應格式與狀態碼語意。**

路徑已從原本的 `work/api/*.php` 改為專案一致的 REST 風格（App 端只動 `lib/config/app_constants.dart` 的 5 個常數，已改）。路徑**結尾一律有斜線**，避免 Django `APPEND_SLASH` 把 POST 轉址而丟掉 body。

### 6.1 端點

| 端點 | 對應 server 資料 |
|---|---|
| `POST api/machine/pair/start/` | 機台送 `hardware_id`（App 的 UUID）與 `app_version`，server 發 `device_code`（機台輪詢用）與 `pairing_code`（顯示給管理員，10 分鐘內有效、一次性）。同一 `hardware_id` 再配對視為同一台機台，舊 token 失效 |
| `POST api/machine/pair/poll/` | 機台每 `interval` 秒問一次；管理員在網頁「機台管理」輸入配對碼核准後回 `approved` + 專屬 token（存雜湊值）、整數 `device_id`、`device_name`。`EXPIRED` / `DENIED` / `SLOW_DOWN` 的機台行為見 README §4.1 |
| `GET api/machine/me/` | 已配對機台的 `device_id` / `device_name` / `location`；機台啟動時用來確認 token 仍有效 |
| `GET api/machine/rooms/` | `LTCPatient.room_number` 去重 |
| `GET api/machine/beds/` | `LTCPatient`：`bed_id = "{room}-{bed}"`，`patient_id = LTCPatient.id`。選填 `?room_id=` 只回該房 |
| `GET api/machine/meals/` | **當天**的菜色：循環模式依 `day_cycle`，開放模式依 `serve_date`。時段來自 `SystemSettings.lunch_*/dinner_*` |
| `POST api/machine/records/` | 建立 `FoodIntake`，見 §6.4 |
| `GET api/machine/health/` | 健康檢查（不需認證）：`status`、`server_time`、`api_version`；機台用來測試連線與檢查時鐘誤差（README §4.0） |
| `WS api/machine/ws/` | 推播：`LTCPatient` / `SystemSettings` / `Meal` 一變動，server 送 `data_changed`，機台立刻重抓（README §4.7；server 端 `devices/consumers.py`、`devices/events.py`） |

所有回應用 `{ "success": true, "data": {...} }` / `{ "success": false, "error": { "code", "message" } }`。`error.message` 會直接顯示在機台螢幕，用中文。

### 6.2 認證

- 除配對的 `pair/start/`、`pair/poll/` 與健康檢查外，所有請求帶 `Authorization: Bearer <device_token>`。
- 每台機台獨立 token，可在網頁上個別停用。**取代現在所有機台共用的 `DEVICE_API_KEY`**；舊 Nano 機台（`X-Device-Key`）在過渡期並行支援，新機台全部上線後移除。
- token 無效（管理員撤銷或重新配對）回 **401**，機台會清除 token 並回到配對畫面重新取碼；WebSocket 以 close code 4401 表示同一件事。

### 6.3 狀態碼規則（決定機台會不會重送）

| 情況 | 狀態碼 | 機台行為 |
|---|---|---|
| 成功 | 200 | 標記已同步 |
| 資料有錯（床位不存在、圖片格式錯） | **422** | 顯示錯誤，**不重試** |
| `bed_id` 與 `patient_id` 不一致但 `patient_id` 是有效住民 | 200 | 以 `patient_id` 為準收下，回應帶 `bed_mismatch: true` |
| token 失效 | 401 | 回到配對畫面重新取碼 |
| 限流 | 429（`Retry-After`） | 依 `Retry-After` 稍後重試 |
| 暫時性問題（資料庫忙、磁碟滿） | **5xx** | 進佇列重試 |

錯誤信封一律帶 `retryable`，機台以它為準；Cloudflare 等代理回的 HTML（登入頁、WAF 403、502/530）機台一律視為可重試，不會把紀錄標成永久失敗。**只有暫時性問題才回 5xx**，否則錯誤資料會被無限重送。

### 6.4 `api/machine/records/` 欄位

| 欄位 | 來源 | server 處理 |
|---|---|---|
| `image` | 相機 | JPEG/PNG，≤ 5 MB |
| `bed_id`、`patient_id` | 同步的床位表 | 兩者對不上但 `patient_id` 是有效住民 → 照收，回 `bed_mismatch: true`；住民不存在 → 422 |
| `meal_id`、`meal_time_slot` | 同步的今日菜單 | 菜色沒排給這位住民 → **照收，標記 `assignment_mismatch=True`**，不拒絕（現場照片拒了就沒了） |
| `before_after` | 操作者選 | `before` → `meal_phase='前'`，`after` → `'後'` |
| `capture_time` | 快門時間（機台時鐘），Unix 秒 | 存入新欄位 `captured_at`；`recorded_at` 仍是 server 收到的時間 |
| `device_id` | 配對時產生 | 對應 `Device` |
| **`weight_g`** | 秤 | 存入既有的 `FoodIntake.weight_g` |
| **`client_record_id`** | App 的 `localId`（UUID） | **去重鍵**：同一 `client_record_id` 再送一次 → 回原本的 `record_id`，不新增 |

回應：`record_id`、`duplicate`、`assignment_mismatch`、`bed_mismatch`、`ai_status: "pending"`、`ai_result: null`。機台不等 AI 結果，結果在網頁看；兩個 mismatch 旗標會寫 log 並在紀錄詳情顯示標籤。同一住民同一餐同一天的餐後照會等餐前照上傳後才送。

### 6.5 預留欄位

`edge_result`（JSON，選填）：日後若機台跑即時檢查，結果放這裡。server 現在只存不處理。

### 6.6 推播 `api/machine/ws/`（舊路徑 `ws/machine/` 只剩區網可用）

已配對的機台保持一條 WebSocket（`BASE_URL` 的 `http`/`https` 對應 `ws`/`wss`，Bearer token 認證）。server 的住民、用膳時段或菜單一變動就送 `{ "event": "data_changed", "datasets": [...] }`，機台合併 1.5 秒內的事件後只重抓列出的資料；連線建立時三份資料全部重抓。token 無效以 close code 4401 關閉，機台視同 401。沒有這條連線時機台退回 30 分鐘定時同步，所以 server 可以晚點再做。訊息格式見 `README.md` §4.7。

## 7. 資料模型變更

| 表 | 變更 |
|---|---|
| `Device`（新） | 整數 id（回給機台當 `device_id`）、`hardware_id`(App 的 UUID, unique)、`name`（管理員設定）、`location`、`token_hash`、`paired_at`、`last_seen_at`、`is_active` |
| `DeviceAuthorization`（新） | `device_code`(64 hex)、`pairing_code`、`hardware_id`、`app_version`、`status`(pending / approved / denied / expired)、`expires_at`、`approved_by` |
| `FoodIntake` | 新增 `captured_at`、`client_record_id`(unique, nullable)、`device`(FK Device, nullable)、`assignment_mismatch`、`vision_status`(pending/running/done/failed)、`edge_result`(JSON)。`weight_g` 既有。 |
| `DishIntake`（新） | 每筆 `FoodIntake` 每道菜一列：`food_intake`、`dish_name`（來自菜單）、`compartment_index`、`mask`(RLE 或 polygon)、`area_px`、`matched_by`(yolo_class / vlm / manual)。餐後紀錄另有 `before_area_px`、`remaining_ratio`、`eaten_g` |
| `LeftoverAnalysis` | 保留為餐後的總結（總剩餘比例、重量比對、狀態）。`vlm_*` 欄位改為選填。 |
| `DailyNutritionReport`（新） | `ltc_patient`、`date`、`window_days`、`intake`(JSON：各營養素攝取量)、`dri`(JSON)、`flags`(JSON)、`summary`(LLM 中文摘要)、`model` |
| `RecommendedIntake` | 既有，當 DRI 目標值來源（`daily_caloric_needs`、`protein`、…）。缺的住民由 `nutrition-job` 依年齡、性別、身高體重、活動量計算補齊。 |

舊的 `EstimationResult` / `FoodSegmentation`（depth CSV 體積估算）保留給舊 Nano 機台，不再擴充。

## 8. 分析流程（`vision-worker`）

### 8.1 餐前照片

1. YOLO 找出所有食物區域（框 + 類別 + 信心值）。
2. SAM2 以框為提示精修每格遮罩，算 `area_px`。
3. **菜名對應**：取該住民當天的 `MealAssignment` 菜色清單 → 以 YOLO 類別對應；對不到的格子，呼叫 VLM 做**選擇題**（「這格是 A／B／C 哪一個？」），仍對不到則標 `unmatched`，網頁上可人工指定。
4. 寫入 `DishIntake`（每格一列），`vision_status=done`。

### 8.2 餐後照片

1. 找同住民、同餐、同日的餐前紀錄；找不到 → `vision_status=failed`，原因 `no_before`。
2. 用餐前的框跑 SAM2（同一容器、同一角度，框可直接沿用），算每格 `area_px`。
3. `remaining_ratio_i = after_area_i / before_area_i`（夾在 0–1）。
4. **克數分配**：
   ```
   eaten_total_g = before.weight_g − after.weight_g          （容器重量抵消）
   eaten_g_i     = eaten_total_g × (Δarea_i × density_i) / Σ_j (Δarea_j × density_j)
   ```
   `density_i` 為各菜類的相對密度設定表（飯 1.0、湯 1.0、葉菜 0.4…，可調）。沒有秤的紀錄用菜單標準份量 × (1 − remaining_ratio) 當備援，並標記 `weight_source=estimated`。
5. 寫入 `DishIntake`（餐後列）與 `LeftoverAnalysis`。

### 8.3 排隊規則

- 以 `vision_status` 當佇列：`pending → running → done/failed`。worker 啟動時把殘留的 `running` 改回 `pending`。
- 一次只處理一筆；餐前優先於餐後（餐後依賴餐前）。
- 失敗可在網頁上按「重新分析」。

## 9. 營養分析（`nutrition-job`）

每晚對每位住民執行：

1. 取近 `N` 天的 `DishIntake`（餐後列），`eaten_g × 每 100 g 營養成分`，加總成每日熱量、蛋白質、碳水、脂肪、纖維等。營養成分來源：`Ingredient`/`Nutrient` 擴充成含每 100 g 數值的表，或由 `rag_backend` 的食品成分資料查詢。
2. 與 `RecommendedIntake`（DRI）比對 → 各營養素達成率。
3. **旗標（確定性規則，門檻可設定）**：
   - `insufficient_intake`：連續 `K` 天某營養素達成率 < 門檻
   - `selective_eating`：某食物類別（`FoodGroup`）連續 `M` 餐 `remaining_ratio` > 門檻 → 「疑似咀嚼或吞嚥困難，建議評估」
   - `portion_adjust`：近 N 天平均剩餘 > 門檻 → 建議減量；平均剩餘 < 門檻且達成率不足 → 建議增量
4. 把 1–3 的**結果數字**餵給 Ollama（`gemma4:12b`），只要求它寫一段給照護人員看的中文摘要，**不給它原始資料重算**。
5. 寫入 `DailyNutritionReport`，網頁與通知顯示。

## 10. 待決事項

| 事項 | 選項 | 預設 |
|---|---|---|
| YOLO 策略 | (a) 維持多類別模型（新菜要重訓）／(b) 單類別「食物區域」+ 菜單給名稱 | **(b)**，不用為新菜色重訓 |
| 觀察窗口 `N` | 7 或 14 天 | 7 天，報告同時顯示 14 天趨勢 |
| 旗標門檻 | 與機構討論 | `selective_eating`：連續 5 餐剩 > 70%；`insufficient_intake`：連續 3 天熱量 < 80% |
| 各菜類相對密度表 | 初版用經驗值 | 用秤的實測資料逐步校正 |
| 舊 Nano 過渡期 | 並行支援多久 | 新機台全部上線後一個月移除 |

## 11. 實作順序

| 階段 | 內容 | 可驗證的結果 |
|---|---|---|
| **1. 機台 API** | `devices` app：Device/PairingCode 表、5 個端點、去重、`captured_at`/`weight_g`/`client_record_id`、網頁配對碼頁 | 在 Windows 跑 Flutter App 連本機 server，走完配對 → 同步 → 上傳 |
| **2. 收與分析分離** | `vision_status` 佇列、`vision-worker` 容器（先搬現有 YOLO + SAM2 程式進去）、`backend` 移除 torch | 上傳秒回；worker 一張一張處理；`backend` 映像 < 1.5 GB |
| **3. 餐前餐後比對** | §8 流程、`DishIntake`、克數分配、網頁顯示每道菜剩餘 | 一組餐前餐後照片 + 重量 → 每道菜的剩餘比例與克數 |
| **4. 營養分析** | `nutrition-job`、DRI 比對、旗標、LLM 摘要、報告頁 | 一位住民 7 天資料 → 一份報告 |
| **5. 機台實機** | Jetson/Pi 5：相機、秤、品質檢查、kiosk、NTP | 送餐車實地走一餐 |
| **6. 收尾** | AI 併入主 compose、拿掉 `--ai`、移除舊 `X-Device-Key` 路徑、README 更新 | |

階段 1–4 可在現有資料與 Windows 上的 App 完成，不需要等機台硬體。

## 12. 明確不做的事

- 機台不跑 YOLO、SAM2、VLM。理由：server 上 YOLO + SAM2 一張 1–2 秒、一餐兩分鐘內跑完；搬到機台只會讓模型更新變成每台都要燒錄。日後若需要機台即時顯示結果，`vision-worker` 容器可原樣部署到 Jetson（JetPack 支援 Docker + CUDA），用 §6.5 的 `edge_result` 回傳。
- 不用 VLM 辨識菜名。菜名來自菜單。
- 不讓 LLM 做任何計算。
- 單張照片不估算絕對克數。克數一律來自秤，沒有秤才用菜單標準份量估算並標記。

> **已過時**:這是最早對接 PHP 後端時的規格,API 路徑 (`/work/api/*.php`) 等內容已被取代。
> 目前的 API 契約見 [README.md](README.md),系統設計見 [ARCHITECTURE.md](ARCHITECTURE.md)。本文件只留作參考。

# Flutter送餐系统機台端架构设计规格书

## 1. 整体系统架构

### 1.1 系统组成
- **機台端应用** (Flutter): Jetson Nano上运行的触摸屏应用
- **后端系统** (PHP+MySQL): 现有的处方用药系统
- **通信协议**: RESTful API (HTTPS)
- **认证方式**: Bearer Token (在Authorization header中)

### 1.2 核心功能
- 病房/床位浏览
- 送餐照片纪录
- 膳食回收照片纪录
- 機台自动配對和身份验证
- 离线工作和自动同步
- AI辨识结果结构化存储

---

## 2. Flutter应用分层架构

```
┌─────────────────────────────────────────┐
│     UI Layer (Presentation)             │
│  ┌──────────────────────────────────┐   │
│  │ Screens / Widgets / Pages        │   │
│  │ - RoomListScreen                 │   │
│  │ - BedDetailScreen                │   │
│  │ - MealRecordScreen               │   │
│  │ - DevicePairingScreen            │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│  Business Logic Layer (Services)        │
│  ┌──────────────────────────────────┐   │
│  │ Service Classes                  │   │
│  │ - RecordService                  │   │
│  │ - DevicePairingService           │   │
│  │ - SyncService                    │   │
│  │ - OfflineQueueService            │   │
│  │ - LocalStorageService            │   │
│  │ - ErrorHandlingService           │   │
│  └──────────────────────────────────┘   │
│  ┌──────────────────────────────────┐   │
│  │ State Management (Provider/Bloc) │   │
│  │ - DeviceState                    │   │
│  │ - RecordState                    │   │
│  │ - SyncState                      │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│  Data Layer (Repository)                │
│  ┌──────────────────────────────────┐   │
│  │ API Client                       │   │
│  │ - ApiRepository                  │   │
│  │ - HTTP Interceptors              │   │
│  │ - Token Management               │   │
│  └──────────────────────────────────┘   │
│  ┌──────────────────────────────────┐   │
│  │ Local Storage                    │   │
│  │ - SharedPreferences (Config)     │   │
│  │ - SQLite / Hive (Cache)          │   │
│  │ - Encrypted Storage (Token)      │   │
│  └──────────────────────────────────┘   │
│  ┌──────────────────────────────────┐   │
│  │ Offline Queue                    │   │
│  │ - Pending Operations             │   │
│  │ - Sync Retry Logic               │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

---

## 3. 核心数据模型

### 3.1 本地存储数据模型

#### 3.1.1 设备配置 (SharedPreferences)
```
device_config:
  - device_id: string (uuid)
  - device_name: string
  - location: string
  - paired: boolean
  - pairing_time: int64 (unix timestamp)
  - last_sync: int64 (unix timestamp)
```

#### 3.1.2 認證信息 (Encrypted Storage)
```
auth_token:
  - device_token: string (Bearer Token)
  - token_acquired_at: int64 (unix timestamp)
  - token_expires_at: int64 (unix timestamp) [optional]
```

#### 3.1.3 病房/床位缓存 (SQLite/Hive)
```
RoomData:
  - place_id: string
  - room_id: string
  - room_name: string
  - beds_count: int
  - last_updated: int64

BedData:
  - place_id: string
  - room_id: string
  - bed_id: string
  - bed_name: string
  - patient_id: string [nullable]
  - patient_name: string [nullable]
  - patient_age: int [nullable]
  - last_updated: int64
```

#### 3.1.4 膳食数据缓存 (SQLite/Hive)
```
MealData:
  - place_id: string
  - meal_id: string
  - meal_name: string
  - meal_type: string (breakfast/lunch/dinner/snack)
  - meal_time_slot: string (time_slot_id)
  - last_updated: int64
```

#### 3.1.5 本地食物纪录缓存 (SQLite/Hive)
```
LocalMealRecord:
  - local_id: string (uuid)
  - record_id: string [nullable] (server_id, null if not synced)
  - bed_id: string
  - patient_id: string
  - meal_id: string
  - meal_time_slot: string
  - before_after: string (before/after)
  - image_path: string (local file path)
  - capture_time: int64 (unix timestamp)
  - ai_status: string (pending/processing/completed/failed)
  - ai_result: json (structured AI output)
  - sync_status: string (pending/synced/failed)
  - sync_attempts: int
  - created_at: int64
  - updated_at: int64
```

#### 3.1.6 离线队列 (SQLite/Hive)
```
OfflineQueueItem:
  - queue_id: string (uuid)
  - operation_type: string (upload_meal_record/upload_image)
  - endpoint: string
  - request_data: json
  - file_path: string [nullable]
  - status: string (pending/processing/completed/failed)
  - attempts: int
  - created_at: int64
  - updated_at: int64
  - error_message: string [nullable]
```

---

## 4. API接口完整规格

### 4.1 機台配對接口

#### POST /work/api/device_pair.php

**目的**: 新機台与后端系统配對,获取认证token

**请求数据** (JSON):
```json
{
  "device_id": "string",           // 設備的唯一識別碼 (UUID)
  "device_name": "string",         // 設備名稱 (e.g., "Floor2-Room301")
  "location": "string",            // 設備位置描述
  "pairing_code": "string"         // 6位数字配对码 (从管理端获得)
}
```

**成功响应** (200 OK):
```json
{
  "success": true,
  "data": {
    "device_id": "string",
    "device_token": "string",      // Bearer Token, 需加密本地存储
    "token_type": "Bearer",
    "expires_in": 86400,            // 秒数 (可选)
    "message": "Device paired successfully"
  }
}
```

**错误响应** (400/401/500):
```json
{
  "success": false,
  "error": {
    "code": "string",
    "message": "string"
  }
}
```

**错误码**:
- `INVALID_PAIRING_CODE`: 配对码无效或已过期
- `DEVICE_ALREADY_PAIRED`: 该设备已配对
- `SERVER_ERROR`: 服务器错误

**本地处理**:
- 获得token后,使用加密存储保存 (不能存SharedPreferences明码)
- 保存device_id和配对时间戳

---

### 4.2 数据查询接口 (需Bearer Token)

#### GET /work/api/room_data.php

**目的**: 获取所有病房列表

**请求参数** (URL):
```
place_id: string (optional, default from device config)
last_updated: int64 (optional, unix timestamp for incremental sync)
```

**请求头**:
```
Authorization: Bearer {device_token}
Content-Type: application/json
```

**成功响应** (200 OK):
```json
{
  "success": true,
  "data": {
    "rooms": [
      {
        "place_id": "string",
        "room_id": "string",
        "room_name": "string",
        "beds_count": int,
        "updated_at": int64
      }
    ],
    "timestamp": int64
  }
}
```

**错误响应**:
- `401 Unauthorized`: token无效/过期
- `403 Forbidden`: 没有权限
- `500 Internal Server Error`

**本地处理**:
- 缓存所有room数据到SQLite/Hive
- 记录last_updated时间戳用于增量同步
- 离线时使用本地缓存

---

#### GET /work/api/bed_data.php

**目的**: 获取床位列表及患者信息

**请求参数** (URL):
```
place_id: string (optional)
room_id: string (optional)
last_updated: int64 (optional)
```

**请求头**:
```
Authorization: Bearer {device_token}
Content-Type: application/json
```

**成功响应** (200 OK):
```json
{
  "success": true,
  "data": {
    "beds": [
      {
        "place_id": "string",
        "room_id": "string",
        "bed_id": "string",
        "bed_name": "string",
        "patient_id": "string",        // nullable
        "patient_name": "string",      // nullable
        "patient_age": int,            // nullable
        "updated_at": int64
      }
    ],
    "timestamp": int64
  }
}
```

**本地处理**:
- 缓存到SQLite/Hive
- 支持按room_id过滤查询
- 离线时使用本地缓存

---

#### GET /work/api/meal_data.php

**目的**: 获取膳食列表和用餐时间段

**请求参数** (URL):
```
place_id: string (optional)
```

**请求头**:
```
Authorization: Bearer {device_token}
Content-Type: application/json
```

**成功响应** (200 OK):
```json
{
  "success": true,
  "data": {
    "meals": [
      {
        "place_id": "string",
        "meal_id": "string",
        "meal_name": "string",
        "meal_type": "string",         // breakfast/lunch/dinner/snack
        "updated_at": int64
      }
    ],
    "time_slots": [
      {
        "time_slot_id": "string",
        "time_slot_name": "string",    // e.g., "07:00 - 08:30"
        "start_time": "string",        // HH:MM
        "end_time": "string"           // HH:MM
      }
    ],
    "timestamp": int64
  }
}
```

---

### 4.3 食物纪录上传接口 (需Bearer Token)

#### POST /work/api/meal_record.php

**目的**: 上传膳食/回收照片和纪录

**请求格式**: multipart/form-data

**请求参数**:
```
- image: binary (JPG/PNG, max 5MB)
- bed_id: string
- patient_id: string
- meal_id: string
- meal_time_slot: string
- before_after: string (before/after)
- capture_time: int64 (unix timestamp)
- device_id: string (redundancy check)
```

**请求头**:
```
Authorization: Bearer {device_token}
Content-Type: multipart/form-data
```

**成功响应** (200 OK):
```json
{
  "success": true,
  "data": {
    "record_id": "string",           // 服务器端生成的纪录ID
    "image_path": "string",          // 服务器存储路径
    "capture_time": int64,
    "ai_status": "string",           // pending/processing/completed/failed
    "ai_result": {
      "has_food": boolean,
      "has_person": boolean,
      "leftover_percentage": float,  // 0-100
      "confidence": float,           // 0-1
      "note": "string"
    },
    "created_at": int64
  }
}
```

**错误响应** (400/401/500):
```json
{
  "success": false,
  "error": {
    "code": "string",
    "message": "string"
  }
}
```

**错误码**:
- `INVALID_IMAGE_FORMAT`: 图片格式错误
- `IMAGE_TOO_LARGE`: 图片超过大小限制
- `INVALID_PATIENT_ID`: 患者ID无效
- `INVALID_BED_ID`: 床位ID无效
- `TOKEN_EXPIRED`: token已过期,需重新配对
- `UPLOAD_FAILED`: 文件上传失败

**本地处理**:
1. 验证图片格式和大小
2. 记录到本地SQLite (sync_status = pending)
3. 如果在线:立即上传并记录server返回的record_id
4. 如果离线:加入离线队列,稍后自动重试
5. 重试策略:指数退避 (1s, 5s, 30s, 5min, 30min)
6. 最多重试3次,失败后标记为failed并提示用户

---

## 5. 状态管理流程

### 5.1 设备配对状态流 (State Machine)

```
┌─────────┐
│  INIT   │ (应用启动)
└────┬────┘
     │ 检查本地是否存在token
     ▼
┌──────────────────┐
│ TOKEN_FOUND?     │
└──┬────────────┬──┘
   │(yes)       │(no)
   ▼            ▼
┌──────────┐  ┌─────────────────┐
│ PAIRED   │  │ NOT_PAIRED      │
└──────────┘  │ (需要配对码)    │
   │          └────┬────────────┘
   │               │ 输入配对码,调用device_pair
   │               ▼
   │          ┌──────────────┐
   │          │ PAIRING...   │
   │          └────┬─────────┘
   │               │ 成功/失败
   │               ▼
   │          ┌──────────────┐
   │     ┌────│ PAIRED       │
   │     │    └──────────────┘
   │     │
   └─────┼─────────────────┐
         │                 │
         ▼                 ▼
    ┌──────────┐      ┌──────────┐
    │ ONLINE   │◄────►│ OFFLINE  │
    │ (可同步) │      │ (缓存)   │
    └──────────┘      └──────────┘
```

---

### 5.2 记录上传状态流

```
┌──────────────────┐
│ NEW_RECORD       │ (照片拍摄后)
│ (local_id: uuid) │
└────┬─────────────┘
     │ user点击确认上传
     ▼
┌──────────────────┐
│ UPLOADING        │
│ (调用API)        │
└────┬──────┬──────┘
     │      │
   成功   失败
     │      │
     ▼      ▼
┌──────┐  ┌──────────────────┐
│SYNCED│  │ RETRY_PENDING    │
│      │  │ (离线队列)       │
└──────┘  │ attempt_count < 3│
          └────┬──────┬──────┘
               │      │
           重试成功  放弃
               │      │
               ▼      ▼
            ┌────┐  ┌──────┐
            │SYNC│  │FAILED│
            │ED  │  │      │
            └────┘  └──────┘
```

---

## 6. 错误处理机制

### 6.1 网络错误分类

| 错误类型 | HTTP状态 | 处理方式 | 用户提示 |
|---------|---------|---------|---------|
| 连接失败 | N/A | 加入离线队列,重试 | "离线状态,数据将在连接恢复时同步" |
| 超时 | N/A | 加入离线队列,重试 | "连接超时,请检查网络" |
| 4xx客户端错误 | 400-499 | 显示错误,不重试 | "请求参数错误:${error.message}" |
| Token过期 | 401 | 清除token,返回配对屏幕 | "认证失败,需要重新配对" |
| 权限拒绝 | 403 | 显示错误,不重试 | "无权限操作此资源" |
| 服务器错误 | 500-599 | 加入离线队列,重试 | "服务器故障,请稍后重试" |
| 验证失败 | 422 | 显示错误,不重试 | "数据验证失败:${error.message}" |

### 6.2 重试策略

```
重试间隔:
- 第1次: 1秒后
- 第2次: 5秒后
- 第3次: 30秒后
- 第4次: 5分钟后
- 第5次: 30分钟后

最多重试5次,之后标记为失败
```

### 6.3 本地错误处理

- 本地验证失败 → 立即显示错误,不加入队列
- 网络错误 → 加入离线队列,后台自动重试
- 服务器验证失败 → 显示具体错误信息,用户可选择重试

---

## 7. 离线工作和同步机制

### 7.1 离线能力

- ✓ 浏览本地缓存的病房/床位/膳食数据
- ✓ 拍摄和保存食物照片到本地
- ✓ 创建本地纪录(不与服务器同步)
- ✗ 不能创建新配对或获取新的token

### 7.2 自动同步流程

```
┌─────────────────────┐
│ 监测网络状态变化    │
│ (连接/断开)         │
└────┬────────────────┘
     │
     ▼ (网络恢复)
┌─────────────────────┐
│ 后台同步服务启动    │
└────┬────────────────┘
     │
     ▼
┌─────────────────────────────┐
│ 查询离线队列中的待同步项目  │
└────┬───────────────────────┘
     │ 遍历所有pending项目
     ▼
┌──────────────────────┐
│ 按创建时间排序       │
│ (FIFO)               │
└────┬─────────────────┘
     │
     ▼ 每项操作
┌─────────────────────────┐
│ 调用相应API上传数据     │
│ + 重试逻辑              │
└────┬──────┬────────────┘
     │      │
   成功   失败
     │      │
     ▼      ▼
┌─────┐  ┌──────────┐
│移除 │  │增加重试  │
│队列 │  │计数      │
└─────┘  └──────────┘
```

### 7.3 本地缓存更新

```
数据缓存有效期:
- 病房/床位数据: 1小时 (用户可手动刷新)
- 膳食数据: 24小时
- 患者信息: 1小时 (随床位数据更新)

缓存同步时机:
1. 应用启动时 (如果在线)
2. 用户主动刷新
3. 从离线状态恢复到在线时
4. 后台每30分钟自动同步一次
```

---

## 8. 安全性规格

### 8.1 Token管理

```
存储位置: 加密存储 (非SharedPreferences)
- 使用flutter_secure_storage库
- 加密算法: AES-256 (平台默认)

Token生命周期:
1. 设备配对时获得
2. 本地加密存储
3. 每次API调用时读取并放在Authorization header
4. 收到401响应时清除token,返回配对屏幕
5. 可选:支持token刷新机制
```

### 8.2 图片上传安全

```
验证步骤:
1. 本地验证: 格式(JPG/PNG) + 大小(< 5MB)
2. 网络传输: HTTPS + Bearer Token认证
3. 服务端验证: 再次验证格式和大小 + 文件类型检查
4. 存储: 服务器存储到指定目录,不在web root

安全考虑:
- 不允许上传其他类型文件
- 文件名由服务器生成 (防path traversal)
- 设置合理的文件访问权限
```

### 8.3 本地数据保护

```
加密信息:
- device_token → flutter_secure_storage

需要加密存储的其他信息:
- 患者隐私数据 (可选,根据法规要求)

不需要加密:
- 缓存的病房/床位/膳食数据 (无敏感信息)
- 本地纪录中的患者ID/床位ID (数据库中已有)
```

### 8.4 输入验证

```
所有用户输入和API响应都需要验证:

bed_id验证:
- 非空
- 格式符合服务器定义
- 在当前room的床位列表中存在

patient_id验证:
- 非空
- 与bed_id关联的患者ID一致

meal_id验证:
- 非空
- 在膳食列表中存在

image验证:
- MIME type: image/jpeg 或 image/png
- 文件大小: 不超过5MB
- 图片尺寸: 合理范围 (e.g., 480x320 - 4000x3000)
```

---

## 9. 機台端应用流程

### 9.1 启动流程

```
1. 应用启动 → 检查本地token
   ├─ token存在且有效 → 跳转到主屏幕
   ├─ token不存在 → 跳转到配对屏幕
   └─ token过期 → 清除token,跳转到配对屏幕

2. 如果在线:
   ├─ 异步加载病房/床位/膳食数据到本地缓存
   └─ 检查离线队列,自动同步失败的上传

3. 监听网络连接状态变化
```

### 9.2 主屏幕流程

```
主菜单:
├─ 浏览病房列表
│  ├─ 按病房过滤床位
│  └─ 显示每张床的患者信息
├─ 快速搜索患者/床位
├─ 膳食上传历史
└─ 设置
   ├─ 刷新本地数据缓存
   ├─ 重新配对设备
   ├─ 查看当前连接状态
   └─ 清除本地缓存 (谨慎操作)
```

### 9.3 膳食上传流程

```
1. 用户选择病房 → 床位 → 患者
2. 选择膳食类型和用餐时间段
3. 拍摄食物照片 (送餐前 或 回收后)
4. 预览照片,确认选项
5. 点击上传:
   ├─ 在线: 立即上传到服务器
   │  ├─ 上传成功: 保存record_id,显示AI识别结果
   │  └─ 上传失败: 加入离线队列,提示"将在连接恢复时上传"
   └─ 离线: 保存到本地,加入离线队列,提示"离线状态"
6. 返回主屏幕
```

---

## 10. 数据流图

### 10.1 完整数据流 (在线状态)

```
┌──────────────────┐
│ 用户拍摄食物照片 │
└────┬─────────────┘
     │
     ▼
┌──────────────────────┐
│ 本地验证图片         │
│ (格式/大小)          │
└────┬──────┬──────────┘
     │      │
   通过   失败
     │      │
     │      ▼
     │  ┌─────────────────┐
     │  │ 显示错误提示    │
     │  │ 用户重新拍摄    │
     │  └─────────────────┘
     │
     ▼
┌──────────────────────────┐
│ 用户确认选项             │
│ (床位/患者/膳食/时间)    │
└────┬─────────────────────┘
     │
     ▼
┌──────────────────────────┐
│ 构建multipart请求        │
│ POST /work/api/meal_re.. │
│ Authorization: Bearer... │
└────┬─────────────────────┘
     │
     ▼
┌──────────────────────────┐
│ 上传到服务器             │
└────┬──────┬──────────────┘
     │      │
   200OK  其他
     │      │
     ▼      ▼
┌──────────┐  ┌────────────────┐
│ 解析响应 │  │ 加入离线队列   │
│ 获得ID   │  │ 重试3-5次      │
└──────────┘  └────────────────┘
```

### 10.2 离线状态数据流

```
┌──────────────────────┐
│ 用户创建膳食纪录     │
│ (本地SQLite)         │
└────┬─────────────────┘
     │ sync_status=pending
     │ ai_status=pending
     ▼
┌───────────────────────────┐
│ 加入离线队列               │
│ OfflineQueueItem.status.. │
└────┬──────────────────────┘
     │
     ▼ (网络恢复)
┌───────────────────────────┐
│ 后台同步服务              │
│ 按队列顺序上传            │
└────┬──────┬───────────────┘
     │      │
   成功   失败
     │      │
     │      ▼
     │  ┌──────────────┐
     │  │ 增加重试计数 │
     │  │ 等待下次     │
     │  └──────────────┘
     │
     ▼
┌────────────────────┐
│ 更新本地record_id  │
│ sync_status=synced │
└────────────────────┘
```

---

## 11. 可选管理端模块

### 11.1 管理端功能 (如需实现)

```
屏幕:
├─ 登录屏幕
├─ 仪表板 (概览/统计)
├─ 设备管理
│  ├─ 设备列表
│  ├─ 生成配对码
│  └─ 设备状态监控
├─ 纪录查询
│  ├─ 按日期/患者/床位筛选
│  ├─ 查看照片和AI结果
│  └─ 导出数据
├─ 用户管理 (可选)
└─ 系统设置
```

**注**: 管理端的详细API和架构可在后续单独定义

---

## 12. 部署和配置

### 12.1 應用構建配置

```
build.gradle (Android):
- 最小API级别: 21+
- 目标API级别: 33+
- 支持ABI: arm64-v8a (Jetson Nano原生)

Podfile (iOS):
- 最小部署目标: 11.0+

pubspec.yaml (依赖):
- http: 用于API通信
- provider / bloc: 状态管理
- flutter_secure_storage: Token加密存储
- sqflite / hive: 本地数据库缓存
- connectivity_plus: 网络状态监听
- image_picker: 相机集成
- path_provider: 本地文件系统
- permission_handler: 权限管理
```

### 12.2 環境配置

```
开发环境:
- BASE_URL: http://dev-server.local/
- LOG_LEVEL: debug

测试环境:
- BASE_URL: https://test-server.example.com/
- LOG_LEVEL: info

生产环境:
- BASE_URL: https://prod-server.example.com/
- LOG_LEVEL: error
- 启用ProGuard混淆 (Android)
```

---

## 13. 总结架构要点

| 层级 | 职责 | 关键组件 |
|------|------|---------|
| **UI层** | 展示和交互 | Screens, Widgets, Navigation |
| **业务逻辑层** | 流程和状态 | Services, State Management (Provider/Bloc) |
| **数据层** | 数据获取和存储 | ApiRepository, LocalStorage, OfflineQueue |
| **安全层** | 认证和加密 | Token Manager, Secure Storage, Input Validation |
| **同步层** | 离线和同步 | OfflineQueueService, SyncService |

---

## 文档版本历史

| 版本 | 日期 | 变更说明 |
|------|------|---------|
| 1.0 | 2026-09-21 | 初版发布,包含完整架构和API规格 |

---


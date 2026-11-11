# deploy/

**只要執行 `spoonfull.py`**,其他檔案都不用自己跑:

```bash
python3 deploy/spoonfull.py              # 第一次安裝 (在專案資料夾)
python3 /opt/spoonfull/spoonfull.py      # 安裝後在任何地方都可以
```

| 檔案 | 要自己執行嗎 | 說明 |
|---|---|---|
| **`spoonfull.py`** | ✅ **只要執行這一個** | 選單。安裝、開關 App、相機、秤、相機校正全部從這裡進去 |
| `build-librealsense.sh` | ❌ 不用 | 安裝相機驅動,從選單 **6 → 4** 執行 |
| `realsense_tool.py` | ❌ 不用 | 相機校正,從選單 **6 → 3** 進入 |
| `realsense_bridge.py` | ❌ 不用 | App 拍照時自己會用 |
| `spoonfull-recover.sh` | ❌ 不用 | App 每次啟動時自動執行 (更新壞掉時換回舊版) |
| `tests/` | ❌ 不用 | 自動測試:`python3 -m unittest discover -s deploy/tests -v` |

測試、部署、校正相機的完整步驟見專案根目錄的 [README.md](../README.md)。

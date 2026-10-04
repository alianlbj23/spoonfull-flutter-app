# 測試圖片

把要測試的餐盒照片 (JPG / PNG) 放在這個資料夾。

**App 內使用**:設定 → 硬體設定 → 相機來源選「測試圖片資料夾」,路徑欄留 `test_images`
(用 `flutter run` 時相對於專案根目錄;正式機台請填絕對路徑)。每次「下一步」依檔名順序取下一張,循環使用。
秤選「模擬秤」可一起帶假的重量。

**不經 App 直接打 server**:

```bash
python tools/send_test_records.py --server http://192.168.0.10:8000 --place demo --code 123456
```

圖片檔不會進版控 (見 .gitignore),只保留這份說明。

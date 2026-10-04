#!/usr/bin/env python3
"""不經 App,直接用 test_images/ 的照片加假資料打 server 的機台 API (ARCHITECTURE.md §6)。

用途:server 端 `devices` 模組做好後,先確認配對 → 同步 → 上傳 → 去重整條路都通。
送出的欄位與 App 完全相同 (client_record_id、weight_g、edge_result、capture_time…)。

  python tools/send_test_records.py --server http://192.168.0.10:8000 --place demo --code 482913
  python tools/send_test_records.py --server http://localhost:8080 --code 123456 --images test_images --repeat-last

參數:
  --server   BASE_URL (結尾斜線可省略)
  --place    場域 place_id (預設 demo)
  --code     網頁產生的 6 位配對碼;已有 token 可改用 --token
  --images   照片資料夾 (預設 test_images)
  --bed      指定 bed_id;不給就取第一個有住民的床
  --weight   餐前重量 (g),餐後自動減掉 35% (預設 420)
  --repeat-last  最後一筆再送一次,驗證 client_record_id 去重會回同一個 record_id
只用標準函式庫,不需要 pip install。
"""
from __future__ import annotations

import argparse
import json
import mimetypes
import sys
import time
import uuid
from pathlib import Path
from urllib import error, request

PAIR, ROOMS, BEDS, MEALS, RECORDS = (
    "api/machine/pair/", "api/machine/rooms/", "api/machine/beds/",
    "api/machine/meals/", "api/machine/records/",
)


def call(base: str, path: str, *, token: str | None = None, json_body=None,
         query: dict | None = None, multipart: tuple[dict, Path] | None = None):
    url = base + path
    if query:
        url += "?" + "&".join(f"{k}={v}" for k, v in query.items() if v not in (None, ""))
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None
    if json_body is not None:
        data = json.dumps(json_body).encode()
        headers["Content-Type"] = "application/json"
    elif multipart is not None:
        fields, image = multipart
        boundary = "----spoonfull" + uuid.uuid4().hex
        parts = []
        for k, v in fields.items():
            parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
        mime = mimetypes.guess_type(image.name)[0] or "image/jpeg"
        parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{image.name}\"\r\n"
            f"Content-Type: {mime}\r\n\r\n".encode() + image.read_bytes() + b"\r\n")
        parts.append(f"--{boundary}--\r\n".encode())
        data = b"".join(parts)
        headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
    req = request.Request(url, data=data, headers=headers, method="POST" if data else "GET")
    try:
        with request.urlopen(req, timeout=60) as resp:
            status, body = resp.status, resp.read()
    except error.HTTPError as e:
        status, body = e.code, e.read()
    try:
        parsed = json.loads(body.decode("utf-8"))
    except Exception:  # noqa: BLE001
        parsed = {"raw": body[:300].decode("utf-8", "replace")}
    ok = 200 <= status < 300 and parsed.get("success") is True
    if not ok:
        print(f"  ✗ {status} {path} → {json.dumps(parsed, ensure_ascii=False)[:300]}")
    return ok, status, parsed.get("data", parsed)


def main() -> int:
    # Windows 主控台常是 cp932 / cp950,避免中文輸出炸掉
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--server", required=True)
    ap.add_argument("--place", default="demo")
    ap.add_argument("--code")
    ap.add_argument("--token")
    ap.add_argument("--images", default="test_images")
    ap.add_argument("--bed")
    ap.add_argument("--weight", type=float, default=420.0)
    ap.add_argument("--repeat-last", action="store_true")
    args = ap.parse_args()

    base = args.server.rstrip("/") + "/"
    images = sorted(p for p in Path(args.images).iterdir()
                    if p.suffix.lower() in {".jpg", ".jpeg", ".png"}) if Path(args.images).is_dir() else []
    if not images:
        print(f"{args.images} 裡沒有 JPG / PNG")
        return 1
    device_id = str(uuid.uuid4())

    token = args.token
    if not token:
        if not args.code:
            print("需要 --code (配對碼) 或 --token")
            return 1
        print(f"1. 配對 device_id={device_id}")
        ok, _, data = call(base, PAIR, json_body={
            "device_id": device_id, "device_name": f"TestSender-{device_id[:4]}",
            "location": args.place, "pairing_code": args.code})
        if not ok:
            return 1
        token = data["device_token"]
        print(f"   token={token[:12]}…")

    print("2. 同步 rooms / beds / meals")
    ok1, _, rooms = call(base, ROOMS, token=token, query={"place_id": args.place})
    ok2, _, beds = call(base, BEDS, token=token, query={"place_id": args.place})
    ok3, _, meals = call(base, MEALS, token=token, query={"place_id": args.place})
    if not (ok1 and ok2 and ok3):
        return 1
    occupied = [b for b in beds.get("beds", []) if b.get("patient_id")]
    if args.bed:
        occupied = [b for b in occupied if b["bed_id"] == args.bed]
    if not occupied or not meals.get("meals") or not meals.get("time_slots"):
        print(f"   找不到可用的床位/菜單:rooms={len(rooms.get('rooms', []))} beds={len(occupied)} "
              f"meals={len(meals.get('meals', []))} slots={len(meals.get('time_slots', []))}")
        return 1
    bed, meal, slot = occupied[0], meals["meals"][0], meals["time_slots"][0]
    print(f"   床位 {bed['bed_id']} 住民 {bed.get('patient_name')} / 菜 {meal['meal_name']} / 時段 {slot['time_slot_id']}")

    print(f"3. 上傳 {len(images)} 張 (餐前/餐後交替)")
    last_fields = None
    for i, image in enumerate(images):
        phase = "before" if i % 2 == 0 else "after"
        weight = args.weight if phase == "before" else round(args.weight * 0.65, 1)
        fields = {
            "bed_id": bed["bed_id"], "patient_id": bed["patient_id"],
            "meal_id": meal["meal_id"], "meal_time_slot": slot["time_slot_id"],
            "before_after": phase, "capture_time": str(int(time.time())),
            "device_id": device_id, "client_record_id": str(uuid.uuid4()),
            "weight_g": f"{weight:.1f}",
            "edge_result": json.dumps({"quality_check": {"issues": [], "tray_detected": True,
                                                         "source": "send_test_records.py"},
                                       "weight_source": "scale"}),
        }
        ok, status, data = call(base, RECORDS, token=token, multipart=(fields, image))
        if ok:
            print(f"   ✓ {image.name} {phase} {weight} g → record_id={data.get('record_id')} ai_status={data.get('ai_status')}")
            last_fields = fields
        time.sleep(0.2)

    if args.repeat_last and last_fields:
        print("4. 重送最後一筆 (同 client_record_id),應回同一個 record_id")
        ok, _, data = call(base, RECORDS, token=token, multipart=(last_fields, images[-1]))
        if ok:
            print(f"   ✓ record_id={data.get('record_id')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

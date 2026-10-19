#!/usr/bin/env python3
"""不經 App,直接用 test_images/ 的照片加假資料打 server 的機台 API (ARCHITECTURE.md §6)。

用途:確認 配對 (取碼 → 網頁核准 → 輪詢) → 同步 → 上傳 → 去重 整條路都通。
送出的欄位與 App 完全相同 (client_record_id、weight_g、edge_result、capture_time…)。

  python tools/send_test_records.py

全部用互動選單,不用記參數。配對流程與 App 相同 (Device Authorization Flow):
  1. POST api/machine/pair/start/  → 畫面印出配對碼
  2. 請 Super Admin 到管理後台「機台管理」輸入配對碼核准
  3. 每 interval 秒 POST api/machine/pair/poll/,直到 approved 拿到 token
device_code 與 token 不會完整印出 (最多前 8 碼)。只用標準函式庫,不需要 pip install。
"""
from __future__ import annotations

import json
import mimetypes
import sys
import time
import uuid
from pathlib import Path
from urllib import error, request

PAIR_START, PAIR_POLL, ME, ROOMS, BEDS, MEALS, RECORDS = (
    "api/machine/pair/start/", "api/machine/pair/poll/", "api/machine/me/",
    "api/machine/rooms/", "api/machine/beds/", "api/machine/meals/", "api/machine/records/",
)
DEFAULT_SERVER = "https://foodintakesystem.com"
SLOW_DOWN_STEP = 5


def short(secret: str) -> str:
    """只給前 8 碼,避免 device_code / token 進 log 或截圖。"""
    return secret[:8] + "…" if len(secret) > 8 else "…"


def call(base: str, path: str, *, token: str | None = None, json_body=None,
         query: dict | None = None, multipart: tuple[dict, Path] | None = None, quiet=False):
    """回 (ok, status, data_or_error, headers)。失敗時 data_or_error 是 error 信封 (dict)。"""
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
    resp_headers: dict = {}
    try:
        with request.urlopen(req, timeout=60) as resp:
            status, body, resp_headers = resp.status, resp.read(), dict(resp.headers)
    except error.HTTPError as e:
        status, body, resp_headers = e.code, e.read(), dict(e.headers)
    except (error.URLError, OSError) as e:
        print(f"  ✗ 連不上 {url}:{e}")
        return False, 0, {"code": "NETWORK", "message": str(e)}, {}
    try:
        parsed = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        parsed = {"raw": body[:300].decode("utf-8", "replace")}
    ok = 200 <= status < 300 and parsed.get("success") is True
    if ok:
        return True, status, parsed.get("data", {}), resp_headers
    err = parsed.get("error") if isinstance(parsed.get("error"), dict) else {"code": "?", "message": json.dumps(parsed, ensure_ascii=False)[:300]}
    if not quiet:
        print(f"  ✗ {status} {path} → {err.get('code')}:{err.get('message')}")
    return False, status, err, resp_headers


def ask(prompt: str, default: str | None = None) -> str:
    hint = f" [{default}]" if default else ""
    while True:
        value = input(f"{prompt}{hint}:").strip()
        if value:
            return value
        if default is not None:
            return default


def menu(title: str, options: list[str]) -> int:
    """印出編號選單,回傳 0-based 索引。"""
    print(f"\n{title}")
    for i, opt in enumerate(options, 1):
        print(f"  {i}. {opt}")
    while True:
        raw = input("請選擇:").strip()
        if raw.isdigit() and 1 <= int(raw) <= len(options):
            return int(raw) - 1
        print(f"  請輸入 1–{len(options)}")


def pair(base: str) -> str | None:
    """走完 Device Authorization Flow,回傳 device_token;失敗或被拒回 None。"""
    hardware_id = f"test-sender-{uuid.uuid4()}"
    print(f"\n1. 取得配對碼 (hardware_id={hardware_id})")
    while True:
        ok, status, data, headers = call(base, PAIR_START, json_body={"hardware_id": hardware_id, "app_version": "send_test_records.py"})
        if ok:
            break
        if data.get("code") == "THROTTLED":
            wait = int(headers.get("Retry-After") or 5)
            print(f"   被限流,{wait} 秒後再試")
            time.sleep(wait)
            continue
        return None
    device_code, pairing_code = data["device_code"], data["pairing_code"]
    interval, expires_in = int(data.get("interval") or 5), int(data.get("expires_in") or 600)
    print(f"   device_code={short(device_code)} 有效 {expires_in} 秒")
    print("\n" + "=" * 46)
    print(f"   請 Super Admin 到管理後台「機台管理」輸入:  {pairing_code}")
    print("=" * 46)
    print(f"\n2. 每 {interval} 秒輪詢,等管理員核准 (Ctrl+C 取消)")
    deadline = time.time() + expires_in
    while True:
        time.sleep(interval)
        ok, status, data, headers = call(base, PAIR_POLL, json_body={"device_code": device_code}, quiet=True)
        if ok:
            if data.get("status") == "approved":
                token = data["device_token"]
                print(f"   ✓ 已核准:device_id={data.get('device_id')} device_name={data.get('device_name')} token={short(token)}")
                return token
            left = max(0, int(deadline - time.time()))
            print(f"   … pending (配對碼剩 {left // 60:02d}:{left % 60:02d})")
            continue
        code = data.get("code")
        if code == "EXPIRED":
            print("   配對碼過期,重新取得")
            return pair(base)
        if code == "DENIED":
            print("   ✗ 管理員拒絕了這次配對")
            return None
        if code == "SLOW_DOWN":
            interval += SLOW_DOWN_STEP
            print(f"   server 要求放慢,改為每 {interval} 秒")
            continue
        if status == 0 or status >= 500:
            print(f"   暫時失敗 ({code}),{interval} 秒後再試")
            continue
        print(f"   ✗ {status} {code}:{data.get('message')}")
        return None


def sync_and_upload(base: str, token: str, place: str, images: list[Path], weight: float, bed_filter: str | None) -> int:
    device_id = str(uuid.uuid4())
    print("\n3. 同步 rooms / beds / meals")
    ok1, _, rooms, _ = call(base, ROOMS, token=token, query={"place_id": place})
    ok2, _, beds, _ = call(base, BEDS, token=token, query={"place_id": place})
    ok3, _, meals, _ = call(base, MEALS, token=token, query={"place_id": place})
    if not (ok1 and ok2 and ok3):
        return 1
    occupied = [b for b in beds.get("beds", []) if b.get("patient_id")]
    if bed_filter:
        occupied = [b for b in occupied if b["bed_id"] == bed_filter]
    if not occupied or not meals.get("meals") or not meals.get("time_slots"):
        print(f"   找不到可用的床位/菜單:rooms={len(rooms.get('rooms', []))} beds={len(occupied)} "
              f"meals={len(meals.get('meals', []))} slots={len(meals.get('time_slots', []))}")
        return 1
    bed, meal, slot = occupied[0], meals["meals"][0], meals["time_slots"][0]
    print(f"   床位 {bed['bed_id']} 住民 {bed.get('patient_name')} / 菜 {meal['meal_name']} / 時段 {slot['time_slot_id']}")

    print(f"\n4. 上傳 {len(images)} 張 (餐前/餐後交替)")
    last_fields = None
    for i, image in enumerate(images):
        phase = "before" if i % 2 == 0 else "after"
        w = weight if phase == "before" else round(weight * 0.65, 1)
        fields = {
            "bed_id": bed["bed_id"], "patient_id": bed["patient_id"],
            "meal_id": meal["meal_id"], "meal_time_slot": slot["time_slot_id"],
            "before_after": phase, "capture_time": str(int(time.time())),
            "device_id": device_id, "client_record_id": str(uuid.uuid4()),
            "weight_g": f"{w:.1f}",
            "edge_result": json.dumps({"quality_check": {"issues": [], "tray_detected": True,
                                                         "source": "send_test_records.py"},
                                       "weight_source": "scale"}),
        }
        ok, status, data, _ = call(base, RECORDS, token=token, multipart=(fields, image))
        if ok:
            print(f"   ✓ {image.name} {phase} {w} g → record_id={data.get('record_id')} ai_status={data.get('ai_status')}")
            last_fields = fields
        time.sleep(0.2)

    if last_fields and menu("要重送最後一筆 (同 client_record_id) 驗證去重嗎?", ["要", "不要"]) == 0:
        ok, _, data, _ = call(base, RECORDS, token=token, multipart=(last_fields, images[-1]))
        if ok:
            print(f"   ✓ record_id={data.get('record_id')} (應與上一筆相同)")
    return 0


def main() -> int:
    # Windows 主控台常是 cp932 / cp950,避免中文輸出炸掉
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

    base = ask("伺服器網址", DEFAULT_SERVER).rstrip("/") + "/"
    place = ask("場域 place_id", "demo")
    images_dir = Path(ask("照片資料夾", "test_images"))
    images = sorted(p for p in images_dir.iterdir()
                    if p.suffix.lower() in {".jpg", ".jpeg", ".png"}) if images_dir.is_dir() else []
    if not images:
        print(f"{images_dir} 裡沒有 JPG / PNG")
        return 1

    choice = menu("要怎麼取得 token?", ["配對 (取配對碼 → 請管理員在網頁核准)", "我已經有 device_token", "離開"])
    if choice == 2:
        return 0
    if choice == 0:
        token = pair(base)
        if not token:
            return 1
    else:
        token = ask("device_token")
        ok, _, me, _ = call(base, ME, token=token)
        if not ok:
            return 1
        print(f"   ✓ token 有效:device_id={me.get('device_id')} device_name={me.get('device_name')} location={me.get('location')}")

    weight = float(ask("餐前重量 (g)", "420"))
    bed_filter = None
    if menu("床位", ["自動取第一個有住民的床", "指定 bed_id"]) == 1:
        bed_filter = ask("bed_id")
    return sync_and_upload(base, token, place, images, weight, bed_filter)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n已取消")
        sys.exit(130)

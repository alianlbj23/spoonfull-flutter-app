#!/usr/bin/env python3
"""Intel RealSense D435f 相機維護工具:深度自我校正、RGB 內參校正、校正表備份 / 還原。

為什麼需要這支程式:機台用 D435f 量食物體積 (工作距離約 25～35 cm,RGB 1280x720、深度 848x480),
量測準度取決於相機校正。校正是低頻率的維護操作,只由維護人員透過 SSH 手動執行,App 不會呼叫。

用法 (互動選單,不需要記參數):
  python3 deploy/spoonfull.py → 相機 → 相機校正   (會先問要不要關掉 App,做完再開回來)
  也可以直接 python3 deploy/realsense_tool.py;這時要自己先關掉 App,否則相機會被占用。

做什麼 / 存在哪裡:
  深度 (On-Chip / Focal Length / Tare):用 pyrealsense2 的 auto_calibrated_device API,
      校正完詢問才寫入相機;寫入前自動把原本的校正表備份到 ~/.config/spoonfull/realsense_backup/
  RGB 內參:SDK 對 D400 回報的 RGB 畸變係數全為 0,所以另外用 OpenCV + ChArUco 校正,
      結果存到 ~/.config/spoonfull/rgb_intrinsics.json 供軟體使用,不寫入相機。

參數來源 (不要自己改):
  串流設定與 JSON 參數照官方範例
    https://github.com/IntelRealSense/librealsense/blob/master/wrappers/python/examples/depth_auto_calibration_example.py
  距離、health 判讀、標靶列印照官方白皮書「Self-Calibration for D400 Series」
    https://dev.intelrealsense.com/docs/self-calibration-for-depth-cameras

安裝相依 (Raspberry Pi 5 / Pi OS Bookworm):
  sudo apt install python3-numpy python3-opencv      (Debian 的 python3-opencv 含 aruco 模組)
  librealsense + pyrealsense2 要從原始碼建:見 deploy/build-librealsense.sh

測試 (不需要相機):python3 -m unittest discover -s deploy/tests -v
"""
from __future__ import annotations

import json
import math
import os
import re
import select
import shutil
import subprocess
import sys
import time
import traceback
import unicodedata
import zlib
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "spoonfull"
BACKUP_DIR = CONFIG_DIR / "realsense_backup"
RGB_INTRINSICS_PATH = CONFIG_DIR / "rgb_intrinsics.json"

TARGET_PDF_URL = "https://librealsense.intel.com/Releases/UCAL/Calibration_Target_v1.pdf"
WHITEPAPER_URL = "https://intelrealsense.com/download/9277"
WHITEPAPER_WEB_URL = "https://dev.intelrealsense.com/docs/self-calibration-for-depth-cameras"

RGB_SIZE = (1280, 720)
DEPTH_SIZE = (848, 480)

# 官方標靶設計值:圓點中心間距 175 mm x 100 mm (官方範例 --target-width / --target-height 預設值)
TARGET_DESIGN_MM = (175.0, 100.0)

# ChArUco 板 (由選項 8 產生)
CHARUCO_SQUARES = (7, 5)  # (橫向格數, 縱向格數)
CHARUCO_SQUARE_MM = 30.0
CHARUCO_MARKER_MM = 22.0
CHARUCO_DICT_NAME = "DICT_5X5_100"
CHARUCO_PX_PER_MM = 20  # PDF 內嵌圖的解析度 (約 508 dpi)
RGB_TARGET_VIEWS = 20
RGB_MIN_VIEWS = 10
RGB_MIN_CORNERS = 8

# 官方範例的對應表 (depth_auto_calibration_example.py)
OCC_SPEED_MEDIUM = 2  # occ_speed_map['medium'],範例預設
SCAN_INTRINSIC = 0  # scan_map['intrinsic'],範例預設
SCAN_EXTRINSIC = 1  # scan_map['extrinsic']
TARE_ACCURACY_MEDIUM = 2  # tare_accuracy_map['medium'],範例預設
FL_ADJUST_RIGHT_ONLY = 0  # fl_adjust_map['right_only'],範例預設
FL_ADJUST_BOTH_SIDES = 1  # fl_adjust_map['both_sides']
FL_NUM_FRAMES = 25
CALIB_TIMEOUT_MS = 30000
FRAME_TIMEOUT_S = 30
TARE_GT_RANGE_MM = (60.0, 10000.0)  # rs_device.hpp:"Ground truth in mm must be between 60 and 10000"

# 白皮書:絕對值 < 0.25 近乎最佳;以上可改善;> 1 不重新校正基本上無法使用
HEALTH_GOOD = 0.25
HEALTH_REQUIRED = 1.0

# A4 橫向 (pt)
A4_LANDSCAPE_PT = (841.89, 595.28)
PT_PER_MM = 72.0 / 25.4

KIOSK_HINT = "若 App 正在使用相機,請先關閉 App (spoonfull.py 主選單「關閉 App」)"


class ToolError(Exception):
    """可預期的錯誤 (沒接相機、缺套件、輸入錯誤…),訊息直接顯示給使用者。"""


# ---------------------------------------------------------------- 匯入相依
def import_rs():
    try:
        import pyrealsense2 as rs
    except ImportError as e:
        raise ToolError(
            f"找不到 pyrealsense2 ({e})。\n"
            "請先在機台執行 ./deploy/build-librealsense.sh 安裝 librealsense 與 Python binding;\n"
            "開發電腦可用 pip install pyrealsense2。"
        ) from e
    return rs


def import_cv2():
    try:
        import cv2
    except ImportError as e:
        raise ToolError(
            f"找不到 OpenCV ({e})。\n"
            "機台請執行:sudo apt install python3-opencv\n"
            "開發電腦可用:pip install opencv-contrib-python"
        ) from e
    if not hasattr(cv2, "aruco"):
        raise ToolError(
            f"目前的 OpenCV ({cv2.__version__}) 沒有 aruco 模組,無法使用 ChArUco 板。\n"
            "請改裝 python3-opencv (Debian 版含 aruco) 或 pip install opencv-contrib-python。"
        )
    return cv2


def import_np():
    try:
        import numpy as np
    except ImportError as e:
        raise ToolError(f"找不到 numpy ({e})。請執行:sudo apt install python3-numpy") from e
    return np


# ---------------------------------------------------------------- 輸入 / 輸出小工具
def ask_yes_no(question: str, default: bool = False, input_fn: Callable[[str], str] = input) -> bool:
    while True:
        ans = input_fn(f"{question} ").strip().lower()
        if not ans:
            return default
        if ans in ("y", "yes"):
            return True
        if ans in ("n", "no"):
            return False
        print("請輸入 y 或 n。")


def parse_mm(text: str, lo: float, hi: float) -> float:
    try:
        value = float(text.strip())
    except ValueError:
        raise ValueError(f"「{text.strip()}」不是數字,請輸入以 mm 為單位的數值。") from None
    if not math.isfinite(value) or not lo <= value <= hi:
        raise ValueError(f"數值必須介於 {lo:g}～{hi:g} mm。")
    return value


def ask_mm(prompt: str, lo: float, hi: float, design: float | None = None,
           input_fn: Callable[[str], str] = input) -> float | None:
    """問一個 mm 數值;空白 = 取消 (回傳 None)。與設計值差 3% 以上時再確認一次。"""
    while True:
        text = input_fn(f"{prompt} (直接按 Enter 取消):")
        if not text.strip():
            return None
        try:
            value = parse_mm(text, lo, hi)
        except ValueError as e:
            print(e)
            continue
        if design and abs(value - design) / design > 0.03:
            pct = (value - design) / design * 100
            print(f"注意:與設計值 {design:g} mm 相差 {pct:+.1f}%,請確認列印時是 100% 縮放、沒有「符合頁面」。")
            if not ask_yes_no("確定使用這個數值嗎?(y/N)", input_fn=input_fn):
                continue
        return value


def _disp_width(s: str) -> int:
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def _pad(s: str, width: int, right: bool = False) -> str:
    fill = " " * max(0, width - _disp_width(s))
    return fill + s if right else s + fill


def _fmt(v: Any) -> str:
    if v is None:
        return "-"
    if isinstance(v, float):
        return f"{v:.4f}"
    return str(v)


def format_side_by_side(before: dict, after: dict, left: str = "校正前", right: str = "校正後") -> str:
    keys = list(before) + [k for k in after if k not in before]
    kw = max([_disp_width(k) for k in keys] + [4]) + 2
    lines = [_pad("項目", kw) + _pad(left, 16, True) + _pad(right, 16, True)]
    for k in keys:
        lines.append(_pad(k, kw) + _pad(_fmt(before.get(k)), 16, True) + _pad(_fmt(after.get(k)), 16, True))
    return "\n".join(lines)


def _progress(p: float) -> None:
    print(f"\r  進度 {float(p):5.1f}%   ", end="", flush=True)


def _title(text: str) -> None:
    print(f"\n==== {text} ====")


# ---------------------------------------------------------------- Health 判讀
def classify_health(value: float) -> tuple[str, str]:
    """依白皮書判讀 health-check 數值。回傳 (等級, 中文說明)。"""
    if value is None or not math.isfinite(value):
        return "invalid", "數值無效,無法判讀"
    a = abs(value)
    if a < HEALTH_GOOD:
        return "good", "良好,不需校正"
    if a <= HEALTH_REQUIRED:
        return "recommend", "建議重新校正"
    return "required", "必須重新校正"


def _health_text(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value:+.4f} ({classify_health(value)[1]})"


def first_health(health: Any) -> float:
    """run_on_chip_calibration 在 SDK 2.53.1 起回傳 (health, 0.0),更舊版是單一 float。"""
    if isinstance(health, (tuple, list)):
        return float(health[0])
    return float(health)


# ---------------------------------------------------------------- 相機
@dataclass
class Camera:
    rs: Any
    ctx: Any
    dev: Any
    auto: Any
    serial: str
    name: str
    firmware: str
    usb: str


def _info(rs, dev, key) -> str:
    """讀 camera_info;相機不支援該欄位時回傳空字串 (官方範例先 supports() 再 get_info())。
    其他讀取錯誤 (USB 斷線等) 照樣往上拋,不當成「沒有這個欄位」。"""
    if not dev.supports(key):
        return ""
    return str(dev.get_info(key))


def check_d400(rs, dev) -> None:
    name = _info(rs, dev, rs.camera_info.name) or "未知型號"
    line = _info(rs, dev, rs.camera_info.product_line)
    if line == "D400" or (not line and " D4" in name):
        return
    raise ToolError(f"接上的相機是「{name}」,本工具只支援 Intel RealSense D400 系列 (例如 D435f)。")


def open_camera(serial: str | None = None) -> Camera:
    rs = import_rs()
    ctx = rs.context()
    try:
        devices = list(ctx.query_devices())
    except RuntimeError as e:
        raise ToolError(f"列舉 RealSense 裝置失敗:{e}") from e
    if serial:
        devices = [d for d in devices if _info(rs, d, rs.camera_info.serial_number) == serial]
    if not devices:
        raise ToolError(
            "找不到 RealSense 相機。請確認:\n"
            "  1. D435f 接在 USB 3 埠 (藍色)\n"
            "  2. 執行 rs-enumerate-devices 看得到相機\n"
            f"  3. 沒有其他程式正在使用相機 ({KIOSK_HINT})"
        )
    dev = devices[0]
    check_d400(rs, dev)
    sn = _info(rs, dev, rs.camera_info.serial_number) or "unknown"
    if len(devices) > 1:
        print(f"偵測到 {len(devices)} 台相機,使用第一台 (序號 {sn})。")
    if not dev.is_auto_calibrated_device():
        raise ToolError("這台相機不支援自我校正 API (auto_calibrated_device),請先更新韌體。")
    return Camera(
        rs=rs, ctx=ctx, dev=dev, auto=dev.as_auto_calibrated_device(), serial=sn,
        name=_info(rs, dev, rs.camera_info.name),
        firmware=_info(rs, dev, rs.camera_info.firmware_version),
        usb=_info(rs, dev, rs.camera_info.usb_type_descriptor),
    )


def _find_profile(sensor, stream, index, width, height, fmt=None):
    best = None
    for p in sensor.get_stream_profiles():
        if p.stream_type() != stream or (index is not None and p.stream_index() != index):
            continue
        if fmt is not None and p.format() != fmt:
            continue
        if not p.is_video_stream_profile():
            continue
        v = p.as_video_stream_profile()
        if (v.width(), v.height()) != (width, height):
            continue
        if best is None or p.fps() == 30:
            best = v
    if best is None:
        raise ToolError(f"相機沒有 {stream} {width}x{height} 的串流設定。")
    return best


def _intr_dict(i) -> dict:
    return {
        "width": i.width, "height": i.height, "fx": i.fx, "fy": i.fy, "ppx": i.ppx, "ppy": i.ppy,
        "model": str(i.model).split(".")[-1], "coeffs": [float(c) for c in i.coeffs],
    }


def read_intrinsics(cam: Camera) -> dict:
    """從 SDK 讀深度 (左紅外線,深度圖與左 IR 對齊)、RGB 內參與深度→RGB 外參。不需要開串流。"""
    rs = cam.rs
    try:
        dsens = cam.dev.first_depth_sensor()
        csens = cam.dev.first_color_sensor()
        ir = _find_profile(dsens, rs.stream.infrared, 1, *DEPTH_SIZE, rs.format.y8)
        depth = _find_profile(dsens, rs.stream.depth, None, *DEPTH_SIZE, rs.format.z16)
        color = _find_profile(csens, rs.stream.color, None, *RGB_SIZE)
        ext = depth.get_extrinsics_to(color)
        return {
            "depth": _intr_dict(ir.get_intrinsics()),
            "rgb": _intr_dict(color.get_intrinsics()),
            "extrinsics": {"rotation": [float(x) for x in ext.rotation],
                           "translation_m": [float(x) for x in ext.translation]},
        }
    except RuntimeError as e:
        raise ToolError(f"讀取內參失敗:{e}") from e


def summary_values(intr: dict, health: float | None = None) -> dict:
    d: dict[str, Any] = {}
    for key, label in (("depth", "深度"), ("rgb", "RGB")):
        i = intr[key]
        for f in ("fx", "fy", "ppx", "ppy"):
            d[f"{label} {f}"] = float(i[f])
    t = intr["extrinsics"]["translation_m"]
    for axis, v in zip("xyz", t):
        d[f"外參 t{axis} (mm)"] = v * 1000.0
    if health is not None:
        d["health"] = health
    return d


def print_intrinsics(intr: dict) -> None:
    for key, label in (("depth", "深度 (左紅外線)"), ("rgb", "RGB")):
        i = intr[key]
        print(f"{label}:{i['width']}x{i['height']}")
        print(f"  fx={i['fx']:.4f}  fy={i['fy']:.4f}  ppx={i['ppx']:.4f}  ppy={i['ppy']:.4f}")
        print(f"  畸變模型 {i['model']},係數 {[round(c, 6) for c in i['coeffs']]}")
    e = intr["extrinsics"]
    r = e["rotation"]
    print("深度 → RGB 外參:")
    # rs2_extrinsics.rotation 是 column-major 3x3
    for row in range(3):
        print("  R " + "  ".join(f"{r[col * 3 + row]:+.6f}" for col in range(3)))
    print("  t (mm) " + "  ".join(f"{v * 1000:+.3f}" for v in e["translation_m"]))


@contextmanager
def streaming(cam: Camera, streams: list[tuple], callback=None):
    rs = cam.rs
    pipe = rs.pipeline(cam.ctx)
    cfg = rs.config()
    cfg.enable_device(cam.serial)
    for s in streams:
        cfg.enable_stream(*s)
    try:
        profile = pipe.start(cfg, callback) if callback else pipe.start(cfg)
    except RuntimeError as e:
        raise ToolError(f"無法啟動相機串流:{e}\n{KIOSK_HINT}") from e
    try:
        yield pipe, profile
    finally:
        pipe.stop()


@contextmanager
def calibration_mode(cam: Camera):
    """官方範例:校正時關 emitter、關 thermal compensation、用自動曝光;結束後還原原本的設定。"""
    rs = cam.rs
    sensor = cam.dev.first_depth_sensor()
    saved = {}
    try:
        for opt, value in ((rs.option.emitter_enabled, 0), (rs.option.thermal_compensation, 0),
                           (rs.option.enable_auto_exposure, 1)):
            if sensor.supports(opt):
                saved[opt] = sensor.get_option(opt)  # 先記下原值,set 失敗時也會被還原
                sensor.set_option(opt, value)
        yield
    finally:
        failed = []
        for opt, value in saved.items():
            try:
                sensor.set_option(opt, value)
            except RuntimeError as e:
                failed.append(f"{opt} = {value}:{e}")
        if failed:
            # 不在 finally 裡丟例外 (會蓋掉原本的錯誤);明確報告並告訴使用者怎麼恢復
            print("\n錯誤:無法還原下列相機設定,深度可能異常 (例如 emitter 維持關閉):\n  "
                  + "\n  ".join(failed)
                  + "\n請拔插相機 USB 線或重開機,相機會回到預設設定。", file=sys.stderr)


def require_depth_ready(cam: Camera, input_fn: Callable[[str], str] = input) -> bool:
    """官方範例的前置條件:USB3、Advanced Mode。"""
    if not cam.usb.startswith("3."):
        raise ToolError(f"相機目前是 USB {cam.usb or '?'} 連線,深度校正需要 USB 3。請改接藍色 USB 3 埠。")
    am = cam.rs.rs400_advanced_mode(cam.dev)
    if am.is_enabled():
        return True
    print("深度校正需要開啟相機的 Advanced Mode (官方範例的前置條件)。")
    if ask_yes_no("要現在開啟嗎?相機會重新啟動,調整過的設定會回到預設值。(y/N)", input_fn=input_fn):
        am.toggle_advanced_mode(True)
        print("已送出開啟指令,相機正在重新啟動。請等約 10 秒後再執行一次這個項目。")
    return False


# ---------------------------------------------------------------- 備份 / 寫入
def backup_calibration(auto, serial: str, directory: Path | None = None, when: datetime | None = None,
                       table: list[int] | None = None) -> Path:
    """把校正表存成 JSON。table 沒給時從相機讀目前的表。檔名含日期時間與序號,不覆蓋舊檔。"""
    when = when or datetime.now()
    directory = directory or BACKUP_DIR
    try:
        data = list(table) if table is not None else list(auto.get_calibration_table())
        directory.mkdir(parents=True, exist_ok=True)
        base = f"calib_{when:%Y%m%d-%H%M%S}_{serial}"
        path = directory / f"{base}.json"
        n = 1
        while path.exists():
            path = directory / f"{base}_{n}.json"
            n += 1
        payload = {"format": "spoonfull-realsense-calib-backup/1", "serial": serial,
                   "created": when.isoformat(timespec="seconds"), "table": [int(b) for b in data]}
        # 先寫暫存檔並 fsync,再改名;讀回比對成功才算備份完成 (機台可能突然斷電)
        tmp = path.with_suffix(".json.tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(json.dumps(payload, indent=1))
            f.flush()
            os.fsync(f.fileno())
        tmp.replace(path)
        if json.loads(path.read_text(encoding="utf-8")).get("table") != payload["table"]:
            raise OSError("讀回的備份內容與相機校正表不一致")
    except (OSError, RuntimeError, ValueError) as e:
        raise ToolError(f"備份校正表失敗,不會寫入相機:{e}") from e
    return path


def write_to_camera(auto, table: list[int], original_table: list[int], serial: str,
                    backup_dir: Path | None = None) -> Path:
    """先備份 original_table (校正開始前讀到的表),成功後才 set + write。回傳備份檔路徑。

    original_table 是必填:暫時套用新表後再讀相機,讀到的可能已經是新表,備份就沒有意義了。
    """
    path = backup_calibration(auto, serial, backup_dir, table=original_table)
    try:
        auto.set_calibration_table(table)
        auto.write_calibration()
    except RuntimeError as e:
        raise ToolError(
            f"寫入相機失敗:{e}\n相機 flash 的狀態不確定 (可能已寫入一部分)。"
            f"原本的校正表備份在 {path};必要時可用選項 12 恢復出廠校正後重新校正。"
        ) from e
    return path


def offer_write(auto, table: list[int], original_table: list[int], serial: str, backup_dir: Path | None = None,
                input_fn: Callable[[str], str] = input) -> bool:
    if not ask_yes_no("是否寫入相機?(y/N)", input_fn=input_fn):
        print("未寫入相機。")
        return False
    path = write_to_camera(auto, table, original_table, serial, backup_dir)
    print(f"已寫入相機。原本的校正表備份在:{path}")
    return True


# ---------------------------------------------------------------- 深度校正
def _run_occ(cam: Camera, scan: int) -> tuple[list[int], float]:
    """On-Chip:深度 256x144 Z16 @90,JSON 與官方範例相同。"""
    rs = cam.rs
    params = json.dumps({"calib type": 0, "speed": OCC_SPEED_MEDIUM, "scan parameter": scan})
    with calibration_mode(cam), streaming(cam, [(rs.stream.depth, 256, 144, rs.format.z16, 90)]) as (pipe, prof):
        pipe.wait_for_frames(5000)
        adev = prof.get_device().as_auto_calibrated_device()
        table, health = adev.run_on_chip_calibration(params, _progress, CALIB_TIMEOUT_MS)
    print()
    return list(table), first_health(health)


def health_check(cam: Camera, restore_table: list[int]) -> float:
    """沒有獨立的 health-check API:跑一次 On-Chip 取 health,丟掉新表並把 restore_table 設回 (不寫入)。

    白皮書:ASIC 會讓新校正保持生效但不燒進 flash,所以要自己還原成原本生效的表。
    """
    print("執行 health check (On-Chip,不寫入)…")
    try:
        _, health = _run_occ(cam, SCAN_INTRINSIC)
    finally:
        cam.auto.set_calibration_table(restore_table)
    return health


def _depth_flow(cam: Camera, label: str, run: Callable[[], tuple[list[int], dict]],
                input_fn: Callable[[str], str] = input) -> str:
    """共用流程:校正前 health → 校正 → 暫時套用 → 校正後內參與 health → 並排比較 → 詢問寫入。"""
    original = list(cam.auto.get_calibration_table())
    before = summary_values(read_intrinsics(cam))
    before["health"] = health_check(cam, original)
    print(f"校正前 health:{_health_text(before['health'])}")

    print(f"開始 {label}…")
    try:
        # 白皮書:校正後 ASIC 會讓新校正保持生效 (未燒進 flash),所以從這裡開始任何中斷都要還原
        new_table, reported = run()
        if not new_table:
            raise ToolError(f"{label} 失敗:相機沒有回傳新的校正表。")
        cam.auto.set_calibration_table(new_table)  # 暫時套用 (RAM),沒寫入前拔插相機就會回到原本的
        after = summary_values(read_intrinsics(open_camera(cam.serial)))
        after["health"] = health_check(cam, new_table)
        print(f"\n{label} 回報:" + ",".join(f"{k} = {_fmt(v)}" for k, v in reported.items()))
        print(format_side_by_side(before, after))
        print(f"校正前 health:{_health_text(before['health'])}")
        print(f"校正後 health:{_health_text(after['health'])}")
        if abs(after["health"]) > abs(before["health"]):
            print("注意:校正後的 health 比校正前差,建議不要寫入,檢查標靶與擺放後重做。")
        wrote = offer_write(cam.auto, new_table, original, cam.serial, input_fn=input_fn)
    except BaseException:
        # 只還原「目前生效」(RAM) 的表;flash 是否寫入由 write_to_camera 的錯誤訊息說明
        cam.auto.set_calibration_table(original)
        print("已把目前生效的校正設回原本的表。")
        raise
    if not wrote:
        cam.auto.set_calibration_table(original)
        print("已還原為原本的校正。")
    return (f"health {before['health']:+.3f} → {after['health']:+.3f};"
            + ("已寫入相機" if wrote else "未寫入相機"))


def run_health_check(input_fn: Callable[[str], str] = input) -> str:
    _title("Health check (只檢查、不寫入)")
    if not confirm_preparation("health", input_fn):
        return "取消"
    cam = open_camera()
    if not require_depth_ready(cam, input_fn):
        return "未執行 (需要 Advanced Mode)"
    original = list(cam.auto.get_calibration_table())
    health = health_check(cam, original)
    print(f"Health:{_health_text(health)}  (未寫入相機)")
    return f"health {health:+.3f} ({classify_health(health)[1]})"


def run_on_chip(input_fn: Callable[[str], str] = input) -> str:
    _title("On-Chip 自我校正")
    print("模式:1) 內參模式 (預設,官方範例預設)  2) 外參模式")
    scan = SCAN_EXTRINSIC if input_fn("請選擇 (Enter = 1):").strip() == "2" else SCAN_INTRINSIC
    if not confirm_preparation("onchip", input_fn):
        return "取消"
    cam = open_camera()
    if not require_depth_ready(cam, input_fn):
        return "未執行 (需要 Advanced Mode)"

    def run():
        table, health = _run_occ(cam, scan)
        return table, {"On-Chip health": health}

    return _depth_flow(cam, "On-Chip 校正", run, input_fn)


def _run_focal(cam: Camera, width_mm: float, height_mm: float, adjust: int) -> tuple[list[int], dict]:
    """Focal Length:左右 IR 1280x720 Y8 @30 各收 25 張,寫法照官方範例。"""
    rs = cam.rs
    lq = rs.frame_queue(capacity=FL_NUM_FRAMES, keep_frames=True)
    rq = rs.frame_queue(capacity=FL_NUM_FRAMES, keep_frames=True)
    counter = 0

    def cb(frame):
        nonlocal counter
        if counter > FL_NUM_FRAMES:
            return
        flags = [False, False]
        for f in frame.as_frameset():
            idx = f.get_profile().stream_index()
            if idx == 1:
                lq.enqueue(f)
                flags[0] = True
            if idx == 2:
                rq.enqueue(f)
                flags[1] = True
            if all(flags):
                counter += 1

    streams = [(rs.stream.infrared, 1, 1280, 720, rs.format.y8, 30),
               (rs.stream.infrared, 2, 1280, 720, rs.format.y8, 30)]
    with calibration_mode(cam), streaming(cam, streams, cb) as (_, prof):
        start = time.monotonic()
        while counter < FL_NUM_FRAMES:
            time.sleep(0.5)
            if time.monotonic() - start > FRAME_TIMEOUT_S:
                raise ToolError(f"{FRAME_TIMEOUT_S} 秒內只收到 {counter}/{FL_NUM_FRAMES} 組影像。")
        adev = prof.get_device().as_auto_calibrated_device()
        table, ratio, angle = adev.run_focal_length_calibration(lq, rq, width_mm, height_mm, adjust, _progress)
    print()
    return list(table), {"ratio": float(ratio), "angle": float(angle)}


def run_focal_length(input_fn: Callable[[str], str] = input) -> str:
    _title("Focal Length 校正")
    if not confirm_preparation("focal", input_fn):
        return "取消"
    print("請輸入官方標靶上實測的圓點中心間距 (設計值 175 mm x 100 mm)。")
    w = ask_mm("左右圓點中心間距 (mm)", 100, 250, TARGET_DESIGN_MM[0], input_fn)
    if w is None:
        return "取消"
    h = ask_mm("上下圓點中心間距 (mm)", 50, 150, TARGET_DESIGN_MM[1], input_fn)
    if h is None:
        return "取消"
    print("調整方式:1) 只調整右側 (預設,官方範例預設)  2) 左右兩側都調整")
    adjust = FL_ADJUST_BOTH_SIDES if input_fn("請選擇 (Enter = 1):").strip() == "2" else FL_ADJUST_RIGHT_ONLY
    cam = open_camera()
    if not require_depth_ready(cam, input_fn):
        return "未執行 (需要 Advanced Mode)"
    return _depth_flow(cam, "Focal Length 校正", lambda: _run_focal(cam, w, h, adjust), input_fn)


def _run_tare(cam: Camera, ground_truth_mm: float) -> tuple[list[int], dict]:
    """Tare:深度 256x144 Z16 @90,JSON 與官方範例相同。"""
    rs = cam.rs
    params = json.dumps({"scan parameter": SCAN_INTRINSIC, "accuracy": TARE_ACCURACY_MEDIUM})
    with calibration_mode(cam), streaming(cam, [(rs.stream.depth, 256, 144, rs.format.z16, 90)]) as (pipe, prof):
        pipe.wait_for_frames(5000)
        adev = prof.get_device().as_auto_calibrated_device()
        table, health = adev.run_tare_calibration(ground_truth_mm, params, _progress, CALIB_TIMEOUT_MS)
    print()
    reported = {"真實距離 (mm)": ground_truth_mm}
    if isinstance(health, (tuple, list)) and len(health) >= 2:
        # d400-auto-calibration.cpp:health[0] = 校正前、health[1] = 校正後
        reported.update({"Tare health 前": float(health[0]), "Tare health 後": float(health[1])})
    else:
        reported["Tare health"] = first_health(health)
    return list(table), reported


def run_tare(input_fn: Callable[[str], str] = input) -> str:
    _title("Tare 校正")
    if not confirm_preparation("tare", input_fn):
        return "取消"
    gt = ask_mm("相機到標靶平面的真實距離 (mm)", *TARE_GT_RANGE_MM, input_fn=input_fn)
    if gt is None:
        return "取消"
    cam = open_camera()
    if not require_depth_ready(cam, input_fn):
        return "未執行 (需要 Advanced Mode)"
    return _depth_flow(cam, "Tare 校正", lambda: _run_tare(cam, gt), input_fn)


UV_MAP_REASON = (
    "官方 Python 範例 (depth_auto_calibration_example.py)、官方 Python unit test 與白皮書\n"
    "「Self-Calibration for D400 Series」都沒有說明 Python 要怎麼呼叫 run_uv_map_calibration\n"
    "(三個 frame queue 要放什麼格式、幾張、py_px_only 的意義),只有 C++ 的 RealSense Viewer 用到。\n"
    "另外 pyrealsense2 binding 回傳 UV map health 的寫法疑似有問題,結果無法可靠判讀。\n"
    "為了不用猜的參數去改寫相機的 RGB 校正,這個項目暫不實作;需要時請用 realsense-viewer。"
)


def run_uv_map(input_fn: Callable[[str], str] = input) -> str:
    _title("深度對齊 RGB 校正 (UV map) - 尚未實作")
    print(UV_MAP_REASON)
    return "尚未實作 (官方沒有 Python 用法)"


# ---------------------------------------------------------------- 準備事項
PREP_COMMON_STATIC = [
    "標靶要平貼在硬板上,並正對相機。",
    "校正中相機與標靶都不能移動。",
    KIOSK_HINT,
]

PREPARATION = {
    "health": [
        f"標靶:官方深度校正標靶 {TARGET_PDF_URL}",
        "     (或任何有紋理、平整的表面)",
        "距離:超過相機最短量測距離 (MinZ),且標靶紋理至少占畫面 35% (白皮書)。",
    ],
    "onchip": [
        f"標靶:官方深度校正標靶 {TARGET_PDF_URL}",
        "     (或任何有紋理、平整的表面)",
        "距離:超過相機最短量測距離 (MinZ),且標靶紋理至少占畫面 35% (白皮書)。",
        "流程:先做一次 health check → 校正 → 再做一次 health check,約需 1 分鐘。",
    ],
    "focal": [
        f"標靶:官方深度校正標靶 {TARGET_PDF_URL}",
        "     四個圓點都要在畫面中;需要輸入實測的圓點中心間距 (mm)。",
        "距離:D435 約 0.65～2.0 m 可用,官方建議 0.8～1 m (白皮書)。",
    ],
    "tare": [
        f"標靶:官方深度校正標靶 {TARGET_PDF_URL}",
        "距離:D435 建議約 0.65～1.8 m (白皮書);需要輸入相機到平面的真實距離 (mm)。",
    ],
    "rgb": [
        "標靶:ChArUco 板 (請先用選項 8 產生 PDF 並列印、貼在硬板上)。",
        "需要輸入實測的方格邊長與標記邊長 (mm)。",
        f"距離:25～40 cm;共拍 {RGB_TARGET_VIEWS} 張,每張變換角度、距離,並讓板子出現在畫面四角與邊緣。",
        "按空白鍵拍照的那一刻,板子要拿穩不能晃 (避免模糊)。",
        KIOSK_HINT,
    ],
}


def confirm_preparation(kind: str, input_fn: Callable[[str], str] = input) -> bool:
    print("準備事項:")
    lines = PREPARATION[kind] + (PREP_COMMON_STATIC if kind != "rgb" else [])
    for line in lines:
        print(f"  - {line}")
    ans = input_fn("準備好後按 Enter 開始 (輸入 q 取消):").strip().lower()
    return ans != "q"


# ---------------------------------------------------------------- ChArUco
class CharucoHelper:
    """包裝 OpenCV 4.7 以後 (CharucoDetector) 與舊版 (CharucoBoard_create / interpolateCornersCharuco) 的 API。"""

    def __init__(self, cv2):
        self.cv2 = cv2
        self.aruco = cv2.aruco
        self.new_api = hasattr(self.aruco, "CharucoDetector")
        self.dictionary = self.aruco.getPredefinedDictionary(getattr(self.aruco, CHARUCO_DICT_NAME))
        self._detectors: dict[int, Any] = {}

    def make_board(self, square_mm: float, marker_mm: float):
        cols, rows = CHARUCO_SQUARES
        if self.new_api:
            board = self.aruco.CharucoBoard((cols, rows), square_mm, marker_mm, self.dictionary)
            self._detectors[id(board)] = self.aruco.CharucoDetector(board)
        else:
            board = self.aruco.CharucoBoard_create(cols, rows, square_mm, marker_mm, self.dictionary)
        return board

    @staticmethod
    def corner_count() -> int:
        return (CHARUCO_SQUARES[0] - 1) * (CHARUCO_SQUARES[1] - 1)

    def board_image(self, board, size: tuple[int, int]):
        if self.new_api:
            return board.generateImage(size, marginSize=0, borderBits=1)
        return board.draw(size, marginSize=0, borderBits=1)

    def detect(self, board, gray):
        """回傳 (charuco 角點 Nx1x2, ids Nx1);沒偵測到時回傳 (None, None)。"""
        if self.new_api:
            corners, ids, _, _ = self._detectors[id(board)].detectBoard(gray)
        else:
            marker_corners, marker_ids, _ = self.aruco.detectMarkers(
                gray, self.dictionary, parameters=self.aruco.DetectorParameters_create())
            if marker_ids is None or len(marker_ids) == 0:
                return None, None
            _, corners, ids = self.aruco.interpolateCornersCharuco(marker_corners, marker_ids, gray, board)
        if ids is None or len(ids) == 0:
            return None, None
        return corners, ids

    def object_points(self, board, ids):
        np = import_np()
        all_corners = board.getChessboardCorners() if self.new_api else board.chessboardCorners
        return np.asarray(all_corners, dtype=np.float64).reshape(-1, 3)[np.asarray(ids).ravel()]


def calibrate_rgb(views: list, image_size: tuple[int, int]) -> dict:
    """views: [(物件點 Nx3 mm, 影像點 Nx2 px)]。用 cv2.calibrateCamera (k1 k2 p1 p2 k3)。"""
    cv2 = import_cv2()
    np = import_np()
    obj = [np.asarray(o, dtype=np.float32).reshape(-1, 3) for o, _ in views]
    img = [np.asarray(i, dtype=np.float32).reshape(-1, 1, 2) for _, i in views]
    rms, k, dist, _, _ = cv2.calibrateCamera(obj, img, image_size, None, None)
    return {"rms": float(rms), "camera_matrix": k, "dist": np.asarray(dist, dtype=np.float64).ravel()[:5]}


def region_errors(observed, projected, image_size: tuple[int, int]) -> dict:
    """重投影誤差 RMS (px)。中央 = 畫面中間 50% x 50% 的區域,邊緣 = 其餘部分。"""
    np = import_np()
    obs = np.asarray(observed, dtype=np.float64).reshape(-1, 2)
    proj = np.asarray(projected, dtype=np.float64).reshape(-1, 2)
    d2 = np.sum((proj - obs) ** 2, axis=1)
    w, h = image_size
    u = np.abs(obs[:, 0] - w / 2) / (w / 2)
    v = np.abs(obs[:, 1] - h / 2) / (h / 2)
    center = np.maximum(u, v) <= 0.5

    def rms(mask):
        return float(np.sqrt(d2[mask].mean())) if mask.any() else None

    return {"all": rms(np.ones_like(center)), "center": rms(center), "edge": rms(~center),
            "n_center": int(center.sum()), "n_edge": int((~center).sum())}


def evaluate_intrinsics(views: list, camera_matrix, dist, image_size: tuple[int, int]) -> dict:
    """用指定內參對每張照片做 solvePnP,再算全部角點的重投影誤差。"""
    cv2 = import_cv2()
    np = import_np()
    k = np.asarray(camera_matrix, dtype=np.float64)
    d = np.asarray(dist, dtype=np.float64)
    observed, projected = [], []
    for obj, img in views:
        obj = np.asarray(obj, dtype=np.float64).reshape(-1, 3)
        img = np.asarray(img, dtype=np.float64).reshape(-1, 2)
        ok, rvec, tvec = cv2.solvePnP(obj, img, k, d)
        if not ok:
            continue
        proj, _ = cv2.projectPoints(obj, rvec, tvec, k, d)
        observed.append(img)
        projected.append(proj.reshape(-1, 2))
    if not observed:
        raise ToolError("所有照片都無法估計板子的姿態,請重新拍攝。")
    return region_errors(np.vstack(observed), np.vstack(projected), image_size)


def recommend_rgb(err_sdk: dict, err_cv: dict) -> str:
    a, b = err_sdk["all"], err_cv["all"]
    if b > 1.0:
        return (f"OpenCV 校正的誤差偏高 ({b:.3f} px > 1 px),建議重新拍攝:"
                "板子要平、對焦清楚、光線均勻,拍照時不要晃。")
    if b < a * 0.7:
        return f"建議採用 B (OpenCV 校正結果):誤差 {b:.3f} px,明顯低於出廠內參的 {a:.3f} px。"
    return f"兩者差異不大 (A {a:.3f} px / B {b:.3f} px),可以不儲存,繼續使用 SDK 出廠內參。"


def build_rgb_record(serial: str, image_size: tuple[int, int], camera_matrix, dist, err_sdk: dict, err_cv: dict,
                     n_images: int, square_mm: float, marker_mm: float, when: datetime | None = None) -> dict:
    np = import_np()
    when = when or datetime.now()
    return {
        "format": "spoonfull-rgb-intrinsics/1",
        "serial": serial,
        "resolution": {"width": int(image_size[0]), "height": int(image_size[1])},
        "date": when.isoformat(timespec="seconds"),
        "camera_matrix": np.asarray(camera_matrix, dtype=np.float64).tolist(),
        "distortion_model": "opencv (k1, k2, p1, p2, k3)",
        "dist_coeffs": np.asarray(dist, dtype=np.float64).ravel().tolist(),
        "reprojection_error_px": {"sdk_factory": dict(err_sdk), "opencv": dict(err_cv)},
        "n_images": int(n_images),
        "board": {"type": "charuco", "squares": list(CHARUCO_SQUARES), "dictionary": CHARUCO_DICT_NAME,
                  "square_mm": float(square_mm), "marker_mm": float(marker_mm)},
        "note": "只存檔供軟體使用,沒有寫入相機。",
    }


def load_rgb_record(path: Path = RGB_INTRINSICS_PATH) -> dict | None:
    if not path.exists():
        return None
    try:
        rec = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as e:
        raise ToolError(f"RGB 校正檔 {path} 無法讀取:{e}") from e
    def numbers(xs) -> bool:
        return isinstance(xs, list) and all(isinstance(x, (int, float)) and math.isfinite(x) for x in xs)

    k = rec.get("camera_matrix") if isinstance(rec, dict) else None
    dist = rec.get("dist_coeffs") if isinstance(rec, dict) else None
    if not (isinstance(k, list) and len(k) == 3 and all(numbers(row) and len(row) == 3 for row in k)
            and numbers(dist) and len(dist) >= 4):
        raise ToolError(f"RGB 校正檔 {path} 格式不正確 (camera_matrix 要 3x3、dist_coeffs 至少 4 個數值)。")
    return rec


def save_rgb_record(rec: dict, path: Path = RGB_INTRINSICS_PATH) -> Path | None:
    """原子寫入;已有舊檔時先複製一份到 realsense_backup/。回傳舊檔備份路徑。"""
    old_copy = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            BACKUP_DIR.mkdir(parents=True, exist_ok=True)
            old_copy = BACKUP_DIR / f"rgb_intrinsics_{datetime.now():%Y%m%d-%H%M%S}.json"
            shutil.copy2(path, old_copy)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(rec, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(path)
    except OSError as e:
        raise ToolError(f"儲存 {path} 失敗:{e}") from e
    return old_copy


def print_rgb_record(rec: dict) -> None:
    k = rec["camera_matrix"]
    print(f"OpenCV RGB 校正檔 ({RGB_INTRINSICS_PATH}):序號 {rec.get('serial')},日期 {rec.get('date')}")
    res = rec.get("resolution", {})
    print(f"  解析度 {res.get('width')}x{res.get('height')}")
    print(f"  fx={k[0][0]:.4f}  fy={k[1][1]:.4f}  ppx={k[0][2]:.4f}  ppy={k[1][2]:.4f}")
    print(f"  畸變模型 {rec.get('distortion_model')},係數 {[round(c, 6) for c in rec['dist_coeffs']]}")
    errs = rec.get("reprojection_error_px", {})
    for key, label in (("sdk_factory", "A) SDK 出廠"), ("opencv", "B) OpenCV")):
        if key in errs:
            print(f"  重投影誤差 {label}:{_fmt(errs[key].get('all'))} px")


# ---------------------------------------------------------------- 拍攝 (RGB 內參)
_ESC_SEQ = re.compile(rb"\x1b(\[[0-9;]*[A-Za-z~]|O[A-Za-z]|.)?", re.S)


def decode_terminal_keys(chunk: bytes) -> str | None:
    """終端機讀到的位元組 → "capture" / "quit" / None。方向鍵等 ESC 序列一律忽略。"""
    rest = _ESC_SEQ.sub(b"", chunk)
    if b" " in rest:
        return "capture"
    if b"q" in rest or b"Q" in rest:
        return "quit"
    return None


def decode_gui_key(code: int) -> str | None:
    """cv2.waitKeyEx 的完整按鍵碼 → "capture" / "quit" / None。

    要用 waitKeyEx:cv2.waitKey 只回傳低 8 位,GTK 的方向鍵 0xFF51 會變成 0x51 = 'Q'。
    """
    if code == 32:
        return "capture"
    if code in (ord("q"), 27):
        return "quit"
    return None


class KeyReader:
    """不用按 Enter 就能讀按鍵 (SSH 終端機)。用 os.read 直接讀,避免 Python 的文字緩衝吃掉按鍵。"""

    def __enter__(self):
        if not sys.stdin.isatty():
            raise ToolError("需要互動式終端機才能拍照 (請直接在 SSH 中執行)。")
        if os.name == "nt":
            import msvcrt
            self._msvcrt = msvcrt
        else:
            import termios
            import tty
            self._termios = termios
            self._fd = sys.stdin.fileno()
            self._old = termios.tcgetattr(self._fd)
            tty.setcbreak(self._fd)
        return self

    def get(self) -> str | None:
        """回傳 "capture" / "quit" / None (沒按或按了其他鍵)。"""
        if os.name == "nt":
            chunk = b""
            while self._msvcrt.kbhit():
                chunk += self._msvcrt.getwch().encode("utf-8", "replace")
            return decode_terminal_keys(chunk) if chunk else None
        ready, _, _ = select.select([self._fd], [], [], 0)
        return decode_terminal_keys(os.read(self._fd, 64)) if ready else None

    def __exit__(self, *exc):
        if os.name != "nt":
            self._termios.tcsetattr(self._fd, self._termios.TCSADRAIN, self._old)


def can_show_preview(input_fn: Callable[[str], str] = input) -> bool:
    """確認 OpenCV 能不能開視窗;透過 SSH 時可選擇顯示在機台螢幕 (DISPLAY=:0)。不能就用文字模式。"""
    if sys.platform.startswith("linux") and not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        if not ask_yes_no("目前沒有圖形畫面 (例如透過 SSH)。要把預覽視窗顯示在機台螢幕上嗎?(Y/n)",
                          default=True, input_fn=input_fn):
            return False
        os.environ["DISPLAY"] = ":0"
    # 在子行程試開視窗:某些 GUI 後端開不了畫面會直接結束整個行程
    probe = "import cv2; cv2.namedWindow('probe'); cv2.waitKey(1); cv2.destroyAllWindows()"
    try:
        r = subprocess.run([sys.executable, "-c", probe], capture_output=True, timeout=15)
    except subprocess.TimeoutExpired:
        print("開啟預覽視窗逾時,改用文字模式 (終端機顯示角點數)。")
        return False
    if r.returncode != 0:
        err = r.stderr.decode(errors="replace").strip().splitlines()
        print(f"無法開啟預覽視窗 ({err[-1] if err else '未知原因'}),改用文字模式 (終端機顯示角點數)。")
        return False
    return True


REGION_NAMES = ["左上", "上方", "右上", "左側", "中央", "右側", "左下", "下方", "右下"]


def _cells_hit(points, image_size) -> set[int]:
    w, h = image_size
    cells = set()
    for x, y in points:
        cx = min(2, max(0, int(x / w * 3)))
        cy = min(2, max(0, int(y / h * 3)))
        cells.add(cy * 3 + cx)
    return cells


def capture_charuco_views(cam: Camera, helper: CharucoHelper, board, use_gui: bool) -> list:
    cv2 = import_cv2()
    np = import_np()
    rs = cam.rs
    total = helper.corner_count()
    views: list = []
    coverage = [0] * 9
    window = "RGB 內參校正 - 空白鍵拍照,q 結束"
    print(f"\n開始預覽。空白鍵 = 拍一張,q = 結束。目標 {RGB_TARGET_VIEWS} 張 (最少 {RGB_MIN_VIEWS} 張)。")
    print("每張請變換角度 (傾斜 20～40 度)、距離 (25～40 cm),並讓板子輪流出現在畫面四角與邊緣。")
    with streaming(cam, [(rs.stream.color, *RGB_SIZE, rs.format.bgr8, 30)]) as (pipe, _), KeyReader() as keys:
        if use_gui:
            cv2.namedWindow(window, cv2.WINDOW_NORMAL)
        last_status = 0.0
        try:
            while len(views) < RGB_TARGET_VIEWS:
                try:
                    frames = pipe.wait_for_frames(5000)
                except RuntimeError as e:
                    raise ToolError(f"讀取 RGB 影像失敗:{e}") from e
                color = frames.get_color_frame()
                if not color:
                    continue
                img = np.asanyarray(color.get_data())
                gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
                corners, ids = helper.detect(board, gray)
                n = 0 if ids is None else len(ids)

                key = None
                if use_gui:
                    vis = img.copy()
                    w, h = RGB_SIZE
                    for i in (1, 2):
                        cv2.line(vis, (w * i // 3, 0), (w * i // 3, h), (90, 90, 90), 1)
                        cv2.line(vis, (0, h * i // 3), (w, h * i // 3), (90, 90, 90), 1)
                    for c in range(9):
                        cv2.putText(vis, str(coverage[c]), ((c % 3) * w // 3 + 10, (c // 3) * h // 3 + 30),
                                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 200, 255) if coverage[c] else (0, 0, 255), 2)
                    if n:
                        cv2.aruco.drawDetectedCornersCharuco(vis, corners, ids, (0, 255, 0))
                    cv2.putText(vis, f"{n}/{total}   {len(views)}/{RGB_TARGET_VIEWS}", (w // 2 - 120, h - 20),
                                cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 255, 0) if n >= RGB_MIN_CORNERS else (0, 0, 255), 2)
                    cv2.imshow(window, vis)
                    key = decode_gui_key(cv2.waitKeyEx(1))
                key = keys.get() or key

                now = time.monotonic()
                if now - last_status > 0.3:
                    status = f"目前角點 {n:2d}/{total}  已拍 {len(views):2d}/{RGB_TARGET_VIEWS}"
                    print(f"\r{status}  (空白鍵 = 拍照,q = 結束)  ", end="", flush=True)
                    last_status = now

                if key == "capture":
                    if n < RGB_MIN_CORNERS:
                        print(f"\n角點只有 {n} 個 (至少 {RGB_MIN_CORNERS} 個),這張不採用,請調整板子位置。")
                        continue
                    pts = corners.reshape(-1, 2)
                    views.append((helper.object_points(board, ids), pts.astype(np.float64)))
                    for c in _cells_hit(pts, RGB_SIZE):
                        coverage[c] += 1
                    missing = [REGION_NAMES[c] for c in range(9) if coverage[c] == 0]
                    hint = f"還沒拍到的區域:{'、'.join(missing)}" if missing else ""
                    print(f"\n第 {len(views)} 張:{n} 個角點。{hint}")
                elif key == "quit":
                    break
        finally:
            if use_gui:
                cv2.destroyAllWindows()
    print()
    return views


def run_rgb_calibration(input_fn: Callable[[str], str] = input) -> str:
    _title("RGB 內參校正 (OpenCV + ChArUco)")
    cv2 = import_cv2()
    np = import_np()
    if not confirm_preparation("rgb", input_fn):
        return "取消"
    square = ask_mm("實測方格邊長 (mm)", 5, 100, CHARUCO_SQUARE_MM, input_fn)
    if square is None:
        return "取消"
    while True:
        marker = ask_mm("實測標記邊長 (mm)", 3, 100, CHARUCO_MARKER_MM, input_fn)
        if marker is None:
            return "取消"
        if marker < square:
            break
        print("標記邊長必須小於方格邊長,請重新輸入。")

    cam = open_camera()
    sdk = read_intrinsics(cam)["rgb"]
    k_sdk = np.array([[sdk["fx"], 0, sdk["ppx"]], [0, sdk["fy"], sdk["ppy"]], [0, 0, 1]], dtype=np.float64)
    helper = CharucoHelper(cv2)
    board = helper.make_board(square, marker)
    print(f"OpenCV {cv2.__version__} ({'CharucoDetector' if helper.new_api else '舊版 aruco'} API)")
    views = capture_charuco_views(cam, helper, board, can_show_preview(input_fn))
    if len(views) < RGB_MIN_VIEWS:
        raise ToolError(f"只拍了 {len(views)} 張,至少需要 {RGB_MIN_VIEWS} 張,請重新執行。")

    print("計算中…")
    result = calibrate_rgb(views, RGB_SIZE)
    err_sdk = evaluate_intrinsics(views, k_sdk, np.zeros(5), RGB_SIZE)
    err_cv = evaluate_intrinsics(views, result["camera_matrix"], result["dist"], RGB_SIZE)

    print(f"\n重投影誤差 (px,{len(views)} 張照片;中央 = 畫面中間 50%x50%,邊緣 = 其餘)")
    print(_pad("區域", 8) + _pad("點數", 8, True) + _pad("A) SDK 出廠", 16, True) + _pad("B) OpenCV", 16, True))
    for key, label, cnt in (("all", "整體", err_sdk["n_center"] + err_sdk["n_edge"]),
                            ("center", "中央", err_sdk["n_center"]), ("edge", "邊緣", err_sdk["n_edge"])):
        print(_pad(label, 8) + _pad(str(cnt), 8, True)
              + _pad(_fmt(err_sdk[key]), 16, True) + _pad(_fmt(err_cv[key]), 16, True))
    print("說明:B 是用同一批照片算出來的,誤差會略為樂觀。")

    k = result["camera_matrix"]
    dist = result["dist"]
    before = {"fx": sdk["fx"], "fy": sdk["fy"], "ppx": sdk["ppx"], "ppy": sdk["ppy"]}
    after = {"fx": float(k[0, 0]), "fy": float(k[1, 1]), "ppx": float(k[0, 2]), "ppy": float(k[1, 2])}
    for i, name in enumerate(("k1", "k2", "p1", "p2", "k3")):
        before[name] = 0.0
        after[name] = float(dist[i])
    print("\n" + format_side_by_side(before, after, "A) SDK 出廠", "B) OpenCV"))
    print("\n" + recommend_rgb(err_sdk, err_cv))

    if not ask_yes_no(f"是否儲存到 {RGB_INTRINSICS_PATH}?(不會寫入相機)(y/N)", input_fn=input_fn):
        print("未儲存。")
        return f"誤差 A {err_sdk['all']:.3f} px / B {err_cv['all']:.3f} px;未儲存"
    rec = build_rgb_record(cam.serial, RGB_SIZE, k, dist, err_sdk, err_cv, len(views), square, marker)
    old = save_rgb_record(rec)
    print(f"已儲存:{RGB_INTRINSICS_PATH}" + (f"(舊檔備份在 {old})" if old else ""))
    return f"誤差 A {err_sdk['all']:.3f} px / B {err_cv['all']:.3f} px;已儲存"


# ---------------------------------------------------------------- ChArUco PDF
def _pdf_text(s: str) -> bytes:
    s = s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    return s.encode("latin-1", "replace")


def build_board_pdf(image, board_w_mm: float, board_h_mm: float, caption: list[str]) -> bytes:
    """產生 A4 橫向、單頁的 PDF:灰階圖片以精確的實體尺寸 (mm) 置中。不需要額外套件。"""
    page_w, page_h = A4_LANDSCAPE_PT
    bw, bh = board_w_mm * PT_PER_MM, board_h_mm * PT_PER_MM
    margin = 10 * PT_PER_MM
    if bw > page_w - 2 * margin or bh > page_h - 2 * margin:
        raise ValueError(f"板子 {board_w_mm:g}x{board_h_mm:g} mm 放不進 A4 橫向 (含 10 mm 邊界)。")
    h_px, w_px = image.shape[:2]
    x = (page_w - bw) / 2
    y = (page_h - bh) / 2 + 10

    content = f"q {bw:.2f} 0 0 {bh:.2f} {x:.2f} {y:.2f} cm /Im0 Do Q\n".encode()
    for i, line in enumerate(caption):
        content += f"BT /F1 9 Tf {x:.2f} {y - 20 - i * 12:.2f} Td (".encode() + _pdf_text(line) + b") Tj ET\n"

    img_data = zlib.compress(bytes(image.tobytes()), 9)
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R /ViewerPreferences << /PrintScaling /None >> >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {page_w:.2f} {page_h:.2f}] "
         "/Resources << /XObject << /Im0 4 0 R >> /Font << /F1 5 0 R >> >> /Contents 6 0 R >>").encode(),
        (f"<< /Type /XObject /Subtype /Image /Width {w_px} /Height {h_px} /ColorSpace /DeviceGray "
         f"/BitsPerComponent 8 /Filter /FlateDecode /Interpolate false /Length {len(img_data)} >>\nstream\n").encode()
        + img_data + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        f"<< /Length {len(content)} >>\nstream\n".encode() + content + b"\nendstream",
    ]
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    out += "".join(f"{o:010d} 00000 n \n" for o in offsets).encode()
    out += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return bytes(out)


def run_generate_charuco_pdf(input_fn: Callable[[str], str] = input) -> str:
    _title("產生 ChArUco 板 PDF")
    cv2 = import_cv2()
    helper = CharucoHelper(cv2)
    board = helper.make_board(CHARUCO_SQUARE_MM, CHARUCO_MARKER_MM)
    cols, rows = CHARUCO_SQUARES
    w_mm, h_mm = cols * CHARUCO_SQUARE_MM, rows * CHARUCO_SQUARE_MM
    image = helper.board_image(board, (int(w_mm * CHARUCO_PX_PER_MM), int(h_mm * CHARUCO_PX_PER_MM)))
    caption = [
        f"Spoonfull RGB calibration board: ChArUco {cols}x{rows} squares, square {CHARUCO_SQUARE_MM:g} mm, "
        f"marker {CHARUCO_MARKER_MM:g} mm, {CHARUCO_DICT_NAME} (OpenCV {cv2.__version__})",
        "Print at 100% / Actual size - do NOT use 'Fit to page'. Matte paper, mount flat on a rigid board.",
        "After printing, measure one square edge and one marker edge (mm) and enter them in realsense_tool.py.",
    ]
    pdf = build_board_pdf(image, w_mm, h_mm, caption)

    default = Path.home() / f"spoonfull_charuco_{cols}x{rows}_{CHARUCO_SQUARE_MM:g}mm.pdf"
    text = input_fn(f"PDF 存檔位置 (Enter 使用 {default}):").strip()
    path = Path(text).expanduser() if text else default
    if path.suffix.lower() != ".pdf":
        path = path.with_suffix(".pdf")
    if not path.parent.is_dir():
        raise ToolError(f"資料夾 {path.parent} 不存在。")
    try:
        tmp = path.with_suffix(".pdf.tmp")
        tmp.write_bytes(pdf)
        tmp.replace(path)
    except OSError as e:
        raise ToolError(f"寫入 {path} 失敗:{e}") from e
    print(f"已產生:{path}")
    print(f"板子尺寸 {w_mm:g} x {h_mm:g} mm,A4 橫向。")
    print("列印:100% 縮放 (實際大小),不可「符合頁面」;霧面紙;貼在平整的硬板上。")
    print("印好後用尺量方格邊長與標記邊長,在選項 9 開始時輸入。")
    return f"已產生 {path}"


# ---------------------------------------------------------------- 其他選單項目
def show_camera_info(input_fn: Callable[[str], str] = input) -> str:
    _title("相機資訊")
    cam = open_camera()
    rs = cam.rs
    print(f"型號:{cam.name}")
    print(f"序號:{cam.serial}")
    print(f"韌體版本:{cam.firmware}")
    recommended = _info(rs, cam.dev, rs.camera_info.recommended_firmware_version)
    if recommended:
        print(f"建議韌體版本:{recommended}")
    print(f"USB:{cam.usb or '未知'}" + ("" if cam.usb.startswith("3.") else "  (請改接 USB 3 埠)"))
    try:
        am = rs.rs400_advanced_mode(cam.dev).is_enabled()
        print(f"Advanced Mode:{'已開啟' if am else '未開啟 (深度校正前會詢問是否開啟)'}")
    except RuntimeError as e:
        print(f"Advanced Mode:無法讀取 ({e})")
    return f"{cam.name} / {cam.serial} / FW {cam.firmware}"


def show_intrinsics(input_fn: Callable[[str], str] = input) -> str:
    _title("目前內參")
    cam = open_camera()
    print(f"相機 {cam.name},序號 {cam.serial} (SDK 回報值)")
    print_intrinsics(read_intrinsics(cam))
    rec = load_rgb_record()
    print()
    if rec is None:
        print(f"尚無 OpenCV RGB 校正檔 ({RGB_INTRINSICS_PATH})。")
    else:
        print_rgb_record(rec)
        if rec.get("serial") != cam.serial:
            print(f"注意:校正檔的序號 {rec.get('serial')} 與目前相機 {cam.serial} 不同,這份校正不適用。")
    return "已顯示"


def run_backup(input_fn: Callable[[str], str] = input) -> str:
    _title("備份校正表")
    cam = open_camera()
    path = backup_calibration(cam.auto, cam.serial)
    print(f"已備份到:{path}")
    return f"已備份到 {path}"


def run_factory_reset(input_fn: Callable[[str], str] = input) -> str:
    _title("恢復出廠校正")
    cam = open_camera()
    print("這會把相機的深度校正恢復成出廠值,之前做過的 On-Chip / Focal Length / Tare 校正都會被覆蓋。")
    print(f"執行前會先把目前的校正表備份到 {BACKUP_DIR}。")
    if not ask_yes_no("確定要恢復出廠校正嗎?(y/N)", input_fn=input_fn):
        print("已取消。")
        return "取消"
    before = summary_values(read_intrinsics(cam))
    path = backup_calibration(cam.auto, cam.serial)
    print(f"已備份到:{path}")
    try:
        cam.auto.reset_to_factory_calibration()
    except RuntimeError as e:
        raise ToolError(f"恢復出廠校正失敗:{e}") from e
    after = summary_values(read_intrinsics(open_camera(cam.serial)))
    print("已恢復出廠校正。")
    print(format_side_by_side(before, after, "恢復前", "恢復後"))
    return "已恢復出廠校正"


def show_targets(input_fn: Callable[[str], str] = input) -> str:
    _title("校正標靶下載與列印方式")
    print("深度校正 (On-Chip / Focal Length / Tare 共用):")
    print(f"  官方標靶 PDF:{TARGET_PDF_URL}")
    print("  低對比紋理背景 + 四個模糊圓點;圓點中心設計間距 175 mm x 100 mm。")
    print(f"  官方白皮書 (附錄 A 有標靶與列印說明):{WHITEPAPER_URL}")
    print(f"  網頁版:{WHITEPAPER_WEB_URL}")
    print("RGB 內參:ChArUco 板,用選項 8 產生 PDF")
    print(f"  {CHARUCO_SQUARES[0]}x{CHARUCO_SQUARES[1]} 格、方格 {CHARUCO_SQUARE_MM:g} mm、"
          f"標記 {CHARUCO_MARKER_MM:g} mm、字典 {CHARUCO_DICT_NAME},A4 橫向。")
    print("列印方式:")
    print("  1. 100% 縮放 (實際大小),不可選「符合頁面」。")
    print("  2. 霧面紙 (低反光),厚一點的紙較好。")
    print("  3. 貼在平整的硬板上,不能翹曲。")
    print("  4. 印好後實測:深度標靶量圓點中心間距;ChArUco 板量方格邊長與標記邊長。執行校正時輸入實測值。")
    return "已顯示"


# ---------------------------------------------------------------- 引導模式
GUIDED_STEPS: list[tuple[str, str, Callable[..., str]]] = [
    ("Health check (校正前)", "先檢查目前的深度校正狀態,只檢查不寫入。", lambda f: run_health_check(f)),
    ("On-Chip 自我校正", "改善深度雜訊 (平面擬合 RMS)。用官方標靶或有紋理的平面。", lambda f: run_on_chip(f)),
    ("Focal Length 校正", "用官方標靶的四個圓點校正焦距,距離 0.8～1 m。", lambda f: run_focal_length(f)),
    ("Tare 校正", "用已知的真實距離校正絕對深度。", lambda f: run_tare(f)),
    ("RGB 內參校正", "用 ChArUco 板以 OpenCV 校正 RGB 內參與畸變,存檔不寫入相機。", lambda f: run_rgb_calibration(f)),
    ("深度對齊 RGB 校正 (UV map)", "目前尚未實作,會說明原因。", lambda f: run_uv_map(f)),
    ("Health check (校正後)", "最後再檢查一次,確認 health 數值變小。", lambda f: run_health_check(f)),
]


def run_guided(input_fn: Callable[[str], str] = input) -> str:
    _title("完整校正流程 (引導模式)")
    print("依序:" + " → ".join(t for t, _, _ in GUIDED_STEPS))
    summary: list[tuple[str, str]] = []
    for i, (title, desc, fn) in enumerate(GUIDED_STEPS, 1):
        _title(f"步驟 {i}/{len(GUIDED_STEPS)}:{title}")
        print(desc)
        ans = input_fn("按 Enter 開始,輸入 s 略過,q 結束引導:").strip().lower()
        if ans == "q":
            summary.extend((t, "未執行") for t, _, _ in GUIDED_STEPS[i - 1:])
            break
        if ans == "s":
            summary.append((title, "略過"))
            continue
        ok = True
        try:
            result = fn(input_fn) or "完成"
        except ToolError as e:
            print(f"\n錯誤:{e}")
            result, ok = f"失敗:{e}".splitlines()[0], False
        except RuntimeError as e:
            print(f"\n相機操作失敗:{e}")
            result, ok = f"失敗:{e}", False
        except Exception as e:  # noqa: BLE001 - 例如 cv2.error;印完整錯誤並記入摘要,讓引導可以繼續
            print("\n發生未預期的錯誤,詳細內容如下 (請回報):", file=sys.stderr)
            traceback.print_exc()
            result, ok = f"失敗:{type(e).__name__}: {e}".splitlines()[0], False
        summary.append((title, result))
        if not ok and not ask_yes_no("要繼續下一步嗎?(Y/n)", default=True, input_fn=input_fn):
            summary.extend((t, "未執行") for t, _, _ in GUIDED_STEPS[i:])
            break
    _title("摘要")
    width = max(_disp_width(t) for t, _ in summary) + 2 if summary else 0
    for title, result in summary:
        print(f"  {_pad(title, width)}{result}")
    return "引導模式結束"


# ---------------------------------------------------------------- 主選單
MENU: list[tuple[str, str, str]] = [
    ("1", "完整校正流程 (引導模式)", "run_guided"),
    ("2", "顯示相機資訊 (型號、序號、韌體版本)", "show_camera_info"),
    ("3", "顯示目前內參", "show_intrinsics"),
    ("4", "Health check (只檢查、不寫入)", "run_health_check"),
    ("5", "On-Chip 自我校正", "run_on_chip"),
    ("6", "Focal Length 校正", "run_focal_length"),
    ("7", "Tare 校正", "run_tare"),
    ("8", "產生 ChArUco 板 PDF", "run_generate_charuco_pdf"),
    ("9", "RGB 內參校正 (OpenCV + ChArUco)", "run_rgb_calibration"),
    ("10", "深度對齊 RGB 校正 (UV map) - 尚未實作", "run_uv_map"),
    ("11", "備份目前的校正表到檔案", "run_backup"),
    ("12", "恢復出廠校正", "run_factory_reset"),
    ("13", "顯示校正標靶下載連結與列印方式", "show_targets"),
    ("0", "離開", ""),
]


def main_menu(input_fn: Callable[[str], str] = input) -> int:
    while True:
        _title("Spoonfull RealSense 相機維護工具")
        for key, label, _ in MENU:
            print(f"  {key:>2}) {label}")
        try:
            choice = input_fn("請選擇:").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if choice == "0":
            return 0
        handler = next((globals()[name] for key, _, name in MENU if key == choice and name), None)
        if handler is None:
            print(f"無效的選項「{choice}」,請輸入 0～13。")
            continue
        try:
            handler(input_fn)
        except ToolError as e:
            print(f"\n錯誤:{e}")
        except KeyboardInterrupt:
            print("\n已中斷,回到主選單。")
        except RuntimeError as e:
            print(f"\n相機操作失敗:{e}")
        except Exception:  # noqa: BLE001 - 印出完整錯誤後回到選單,不讓維護工具整個掛掉
            print("\n發生未預期的錯誤,詳細內容如下 (請回報):", file=sys.stderr)
            traceback.print_exc()
        try:
            input_fn("\n按 Enter 回到主選單…")
        except (EOFError, KeyboardInterrupt):
            return 0


if __name__ == "__main__":
    sys.exit(main_menu())

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
    https://dev.realsenseai.com/docs/intel-realsense-self-calibration-for-d400-series-depth-cameras/
  emitter 開關照官方 realsense-viewer (common/on-chip-calib.cpp),見 calibration_mode 說明

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
# 舊網域 intelrealsense.com 已連不上 (2026-11 實測),白皮書搬到 dev.realsenseai.com
WHITEPAPER_URL = "https://dev.realsenseai.com/docs/intel-realsense-self-calibration-for-d400-series-depth-cameras/"

RGB_SIZE = (1280, 720)
DEPTH_SIZE = (848, 480)

# 官方標靶設計值:圓點中心間距 175 mm x 100 mm (官方範例 --target-width / --target-height 預設值)
TARGET_DESIGN_MM = (175.0, 100.0)
# 官方標靶 PDF 實測為 US Letter 橫向 (MediaBox 792x612 pt = 279.4x215.9 mm),不是 A4。
# A4 (210 mm 高) 選「實際大小」:上下各裁掉約 3 mm 背景,圓點離紙邊 ≥ 37 mm 不受影響;
# 印表機若「縮小超出的頁面」會縮成 210/215.9 ≈ 97.3%。
TARGET_PAPER = "US Letter 橫向 (279.4 x 215.9 mm)"
# 實測值與設計值差超過這個比例就請使用者確認。白皮書:不同印表機約有 0.5% 誤差;
# Letter 縮到 A4 是 -2.7%,門檻要比它小才抓得到。
PRINT_SCALE_WARN = 0.015
RULER_RESOLUTION_MM = 0.5  # 直尺刻度;差距在這以內不警告 (方格 30 mm 量成 30.5 mm 是正常讀數誤差)

# ChArUco 板 (由選項 8 產生)
CHARUCO_SQUARES = (7, 5)  # (橫向格數, 縱向格數)
CHARUCO_SQUARE_MM = 30.0
CHARUCO_MARKER_MM = 22.0
CHARUCO_DICT_NAME = "DICT_5X5_100"
CHARUCO_PX_PER_MM = 20  # PDF 內嵌圖的解析度 (約 508 dpi)
RGB_TARGET_VIEWS = 20
RGB_MIN_VIEWS = 10
RGB_MIN_CORNERS = 8
# 自動拍照:角點夠、拿穩一段時間、和已拍的每一張都不一樣才拍 (不用按空白鍵)
RGB_AUTO_MIN_CORNERS = 12  # 7x5 板共 24 個內角點,至少一半
RGB_STILL_PX = 2.0  # 相鄰兩張畫面角點移動的中位數 (px) 小於這個 = 沒在動
RGB_STILL_S = 0.6  # 要穩定這麼久才拍 (避免模糊)
RGB_NOVEL_FRAC = 0.06  # 與已拍的每一張,共同角點平均位移要超過畫面對角線的 6% (約 88 px)
RGB_COOLDOWN_S = 1.0  # 拍完後等一下,讓使用者換位置

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
FL_RANGE_MM = (650, 2000)  # Focal Length 標靶距離,白皮書:D435 約 0.65～2.0 m
FL_BEST_MM = (800, 1000)  # 白皮書建議
TARE_FRONT_GLASS_MM = 4.7  # D400 資料表 Table 4-17:D435f 前玻璃到深度原點 Z' = -4.7 mm
TARE_MISMATCH_WARN = 0.05  # 輸入的真實距離與預覽量到的差超過 5% 就再確認

# 白皮書:絕對值 < 0.25 近乎最佳;以上可改善;> 1 不重新校正基本上無法使用
HEALTH_GOOD = 0.25
HEALTH_REQUIRED = 1.0

# A4 橫向 (pt)
A4_LANDSCAPE_PT = (841.89, 595.28)
PT_PER_MM = 72.0 / 25.4

KIOSK_HINT = "若 App 正在使用相機,請先關閉 App (spoonfull.py 主選單「關閉 App」)"


class ToolError(Exception):
    """可預期的錯誤 (沒接相機、缺套件、輸入錯誤…),訊息直接顯示給使用者。"""


# ---------------------------------------------------------------- 結束信號
def install_exit_signals() -> None:
    """SSH 斷線 (SIGHUP) 或 kill (SIGTERM) 時改成丟 KeyboardInterrupt。

    Python 對這兩個信號的預設行為是直接結束,所有 finally 都不會跑:相機的 emitter 等設定、
    暫時套用的校正表、spoonfull.py 把 App 開回來都會被跳過。SSH 斷線後終端機已經不在,
    先把 stdin/stdout/stderr 接到 /dev/null,讓後續的 print / input 不會因為寫不出去而出錯
    (input 會得到 EOF,各選單都會當成離開)。
    """
    import signal

    def handler(signum, _frame):
        if signum == getattr(signal, "SIGHUP", None):
            try:
                fd = os.open(os.devnull, os.O_RDWR)
                for target in (0, 1, 2):
                    os.dup2(fd, target)
            except OSError:
                pass
        raise KeyboardInterrupt

    for name in ("SIGHUP", "SIGTERM"):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), handler)


@contextmanager
def signals_deferred():
    """區塊執行期間先記下 Ctrl-C / SSH 斷線 / kill,做完再處理。

    用在「寫入 flash」與「還原相機設定 / 校正表」這種做一半最糟的步驟:中斷落在中間會讓
    flash 與畫面上說的不一致,或只還原一部分。區塊結束後依序交給原本的處理方式
    (通常是丟 KeyboardInterrupt)。不在主執行緒時無法改信號處理,就直接執行。
    """
    import signal
    import threading
    if threading.current_thread() is not threading.main_thread():
        yield
        return
    names = [n for n in ("SIGINT", "SIGHUP", "SIGTERM") if hasattr(signal, n)]
    pending: list[int] = []
    old = {}
    for n in names:
        num = getattr(signal, n)
        old[num] = signal.signal(num, lambda signum, _frame: pending.append(signum))
    try:
        yield
    finally:
        for num, handler in old.items():
            signal.signal(num, handler)
    for signum in pending:  # 區塊正常結束才會到這裡
        handler = old[signum]
        if callable(handler):
            handler(signum, None)
        else:
            raise KeyboardInterrupt


class InterruptedAfterWrite(KeyboardInterrupt):
    """寫入 flash 期間收到中斷:寫入已經完成,中斷延到寫入之後才生效。"""

    def __init__(self, path: Path):
        super().__init__()
        self.path = path


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
    """問一個 mm 數值。與設計值差 3% 以上時再確認一次。

    有設計值時:直接按 Enter = 用設計值 (照 100% 列印就是設計值,不用每次量),q = 取消。
    沒有設計值時 (例如 Tare 的真實距離,一定要量):直接按 Enter = 取消。
    """
    while True:
        if design:
            text = input_fn(f"{prompt} (直接按 Enter = 設計值 {design:g} mm,q 取消):")
            if not text.strip():
                return float(design)
            if text.strip().lower() == "q":
                return None
        else:
            text = input_fn(f"{prompt} (直接按 Enter 取消):")
            if not text.strip():
                return None
        try:
            value = parse_mm(text, lo, hi)
        except ValueError as e:
            print(e)
            continue
        if design and abs(value - design) > max(design * PRINT_SCALE_WARN, RULER_RESOLUTION_MM):
            pct = (value - design) / design * 100
            print(f"注意:與設計值 {design:g} mm 相差 {pct:+.1f}%,請確認列印時是 100% 縮放 (實際大小)、"
                  "沒有「符合頁面」或「縮小超出的頁面」(被縮小時通常會小約 3%)。")
            print("如果數值是用尺仔細量的,照實輸入即可,校正會以實測值為準。")
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
    """run_on_chip_calibration 在 SDK 2.52.1 起回傳 (health, 0.0),更舊版是單一 float。"""
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


# ---------------------------------------------------------------- USB 供電 (Pi 5)
# Pi 5 沒偵測到 5V/5A 電源時,所有 USB 埠合計只給 600 mA (usb_max_current_enable = 0)。
# D435 開投射器時接近這個上限,再加上其他 USB 裝置 (例如觸控螢幕) 就會過電流,整排 USB 一起斷電:
# 核心記錄「usb usbX-portY: over-current change」,librealsense 回報 usb device disconnected /
# failed to set power state。2026-11 實機確認 (3A 電源 + D435 + WaveShare 觸控)。
DT_POWER = Path("/proc/device-tree/chosen/power")
USB_POWER_HINT = (
    "原因多半是 USB 供電不足:Pi 5 沒用 5V/5A 電源時,所有 USB 埠合計只給 600 mA,\n"
    "相機開投射器時加上其他 USB 裝置 (例如觸控螢幕) 就會過電流,整排 USB 一起斷電。\n"
    "解法 (擇一):\n"
    "  1. 換官方 27W (5V/5A) USB-C 電源 (根本解法,Pi 會自動放寬到 1.6 A)\n"
    "  2. 相機改接有獨立供電的 USB 3 hub\n"
    "  3. 確定電源供得起時,在 /boot/firmware/config.txt 加 usb_max_current_enable=1 後重開機\n"
    "     (電源不夠力會變成整台 Pi 電壓不足,不建議長期使用)\n"
    "斷電後相機會自動重新連線並回到預設設定 (emitter 開),不需要拔插。"
)


def _dt_u32(name: str) -> int | None:
    try:
        return int.from_bytes((DT_POWER / name).read_bytes()[:4], "big")
    except (OSError, ValueError):
        return None


def usb_current_limited() -> bool:
    """Pi 5 目前是否把 USB 合計電流限制在 600 mA (非 Pi 5 或讀不到時回傳 False)。"""
    enabled, psu_ma = _dt_u32("usb_max_current_enable"), _dt_u32("max_current")
    return enabled == 0 and psu_ma is not None and psu_ma < 5000


def recent_usb_overcurrent(minutes: int = 10) -> bool:
    """最近的核心記錄裡有沒有 USB 過電流。讀不到記錄 (沒權限、沒 journalctl) 就回傳 False。"""
    try:
        out = subprocess.run(["journalctl", "-k", "--since", f"-{minutes}min", "--no-pager", "-q"],
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return "over-current" in out


def explain_camera_error(err: Exception) -> None:
    """相機斷線類錯誤時,檢查是不是 USB 過電流,是的話直接說明原因與解法。"""
    text = str(err).lower()
    if any(k in text for k in ("disconnected", "power state", "no device", "no such device")):
        if recent_usb_overcurrent():
            print("\n系統記錄有 USB 過電流 (over-current):相機是被斷電的,不是程式或線材問題。")
            print(USB_POWER_HINT)
        elif usb_current_limited():
            print("\n相機在操作中斷線。這台 Pi 的 USB 只有 600 mA 可用,可能是供電不足:")
            print(USB_POWER_HINT)


_power_warned = False


def warn_usb_power_once() -> None:
    global _power_warned
    if _power_warned or not usb_current_limited():
        return
    _power_warned = True
    print(f"注意:這台 Pi 的電源只回報 {_dt_u32('max_current')} mA,USB 合計被限制在 600 mA;"
          "相機開投射器時可能被斷電。")
    print("  建議改用 5V/5A 電源 (或相機接有供電的 USB hub)。詳細:出錯時會顯示解法。")


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
    warn_usb_power_once()
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


EMITTER_ON = 1
EMITTER_OFF = 0


@contextmanager
def calibration_mode(cam: Camera, emitter: int):
    """校正時設定 emitter、關 thermal compensation、用自動曝光;結束後還原原本的設定。

    emitter 依官方 realsense-viewer (common/on-chip-calib.cpp,v2.53.1 起):
    On-Chip / Tare / health check 開 emitter,Focal Length (要辨識標靶圓點) 關 emitter。
    官方 Python 範例三種都關,但那是最簡範例;D435f 有 IR 濾鏡,關掉 emitter 時室內幾乎看不到紋理,
    韌體會回報 low fill factor (資料表:D400f 自我校正「May need additional IR light」;
    白皮書:low fill factor 時「turning the projector on will provide the necessary texture」)。
    """
    rs = cam.rs
    sensor = cam.dev.first_depth_sensor()
    saved = {}
    try:
        for opt, value in ((rs.option.emitter_enabled, emitter), (rs.option.thermal_compensation, 0),
                           (rs.option.enable_auto_exposure, 1)):
            if sensor.supports(opt):
                saved[opt] = sensor.get_option(opt)  # 先記下原值,set 失敗時也會被還原
                sensor.set_option(opt, value)
        yield
    finally:
        failed = []
        with signals_deferred():  # 還原到一半被中斷的話,emitter 等設定會停在校正用的值
            for opt, value in saved.items():
                try:
                    sensor.set_option(opt, value)
                except RuntimeError as e:
                    failed.append(f"{opt} = {value}:{e}")
        if failed:
            # 不在 finally 裡丟例外 (會蓋掉原本的錯誤);明確報告並告訴使用者怎麼恢復
            if all("power state" in f or "disconnected" in f or "No such device" in f for f in failed):
                # 相機已斷線 (例如 USB 過電流被斷電):重新連線後本來就是預設設定,不用拔插
                print("\n相機在操作中斷線,沒辦法還原設定;相機重新連線後會自動回到預設設定。", file=sys.stderr)
            else:
                print("\n錯誤:無法還原下列相機設定,深度可能異常 (例如 emitter 維持關閉):\n  "
                      + "\n  ".join(failed)
                      + "\n請拔插相機 USB 線或重開機,相機會回到預設設定。", file=sys.stderr)


def require_depth_ready(cam: Camera, input_fn: Callable[[str], str] = input) -> bool:
    """前置條件:USB3 (官方範例會檢查)、Advanced Mode (Tare 由 SDK 自動切 High Accuracy preset 時需要)。"""
    if not cam.usb.startswith("3."):
        raise ToolError(f"相機目前是 USB {cam.usb or '?'} 連線,深度校正需要 USB 3。請改接藍色 USB 3 埠。")
    try:
        warn_if_firmware_outdated(cam)
    except RuntimeError:
        pass  # 只是提醒,讀不到版本不影響校正
    am = cam.rs.rs400_advanced_mode(cam.dev)
    if am.is_enabled():
        return True
    print("深度校正需要開啟相機的 Advanced Mode (SDK 套用校正用的 preset 時需要)。")
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
        with signals_deferred():
            auto.set_calibration_table(table)
            auto.write_calibration()
    except RuntimeError as e:
        raise ToolError(
            f"寫入相機失敗:{e}\n相機 flash 的狀態不確定 (可能已寫入一部分)。"
            f"原本的校正表備份在 {path};可用選項 14 從備份還原,或選項 12 恢復出廠校正後重新校正。"
        ) from e
    except KeyboardInterrupt:
        raise InterruptedAfterWrite(path) from None  # 中斷是寫入完成後才生效的
    return path


def offer_write(auto, table: list[int], original_table: list[int], serial: str, backup_dir: Path | None = None,
                input_fn: Callable[[str], str] = input) -> bool:
    if not ask_yes_no("是否寫入相機?(y/N)", input_fn=input_fn):
        print("未寫入相機。")
        return False
    path = write_to_camera(auto, table, original_table, serial, backup_dir)
    print(f"已寫入相機。原本的校正表備份在:{path}")
    return True


# ---------------------------------------------------------------- 深度預覽 (校正前對準標靶)
# 韌體回報「Not enough depth pixels! - low fill factor」= 有效深度像素太少。
# 256x144 是校正專用模式:韌體把感測器中央 20% 區域裁切後輸出 (白皮書:「zoomed-in central ROI」),
# 所以整張 256x144 就是校正看的範圍。韌體的實際門檻沒有公開;白皮書準則是「>35% 深度非零」。
PREVIEW_ZOOM = 3  # 256x144 太小,放大 3 倍顯示
PREVIEW_RANGE_M = 1.5  # 色彩對應 0～1.5 m
FILL_MIN = 0.35  # 白皮書:「it is important to have >35% of the depth map show depth values」
FILL_GOOD = 0.7  # 自訂:越滿越好,這以上顯示綠色


def depth_fill_stats(depth, depth_scale: float) -> dict:
    """深度圖 (uint16,0 = 無效) → 有效比例與有效深度的中位數距離 (m)。"""
    np = import_np()
    valid = depth[depth > 0]
    return {
        "fill": float(valid.size) / depth.size,
        "dist_m": float(np.median(valid)) * depth_scale if valid.size else None,
    }


def fill_level(fill: float) -> str:
    if fill >= FILL_GOOD:
        return "ok"
    if fill > FILL_MIN:
        return "warn"
    return "bad"


def _stats_text(s: dict) -> str:
    dist = f"{s['dist_m'] * 100:.0f} cm" if s["dist_m"] is not None else "量不到"
    return f"有效深度 {s['fill'] * 100:3.0f}%  距離 {dist}"


def preview_depth_target(cam: Camera, input_fn: Callable[[str], str] = input) -> dict | None:
    """校正前的即時深度預覽,讓使用者看到相機量得到多少深度、距離多遠。

    用與 On-Chip / Tare 相同的串流 (256x144 Z16 @90) 與 calibration_mode (emitter 開),
    看到的就是校正時韌體看到的。回傳最後一張的統計 (開始校正),None = 取消。
    """
    cv2 = import_cv2()
    np = import_np()
    rs = cam.rs
    scale = cam.dev.first_depth_sensor().get_depth_scale()
    print("\n開始深度預覽。空白鍵 = 開始,q = 取消。")
    print("畫面就是校正時韌體看的範圍 (相機視野中央約 20%)。黑色 = 量不到深度。")
    print(f"請移動標靶 / 調整距離,讓畫面幾乎沒有黑色 (官方準則有效深度 > {FILL_MIN * 100:.0f}%,越滿越好),"
          "確定後相機與標靶不要再動。")
    print("提示:標靶太近 (小於最短量測距離) 也會整片黑;有光澤、反光的表面會讓結果不準。")
    stats = None
    with open_preview("深度預覽", input_fn) as preview, calibration_mode(cam, EMITTER_ON), \
            streaming(cam, [(rs.stream.depth, 256, 144, rs.format.z16, 90)]) as (pipe, _), \
            KeyReader() as keys:
        last_status = 0.0
        while True:
            try:
                frames = pipe.wait_for_frames(5000)
            except RuntimeError as e:
                raise ToolError(f"讀取深度影像失敗:{e}") from e
            depth_frame = frames.get_depth_frame()
            if not depth_frame:
                continue
            depth = np.asanyarray(depth_frame.get_data())
            stats = depth_fill_stats(depth, scale)

            key = None
            if preview.active:
                meters = depth.astype(np.float32) * scale
                vis = cv2.applyColorMap(
                    np.clip(meters / PREVIEW_RANGE_M * 255, 0, 255).astype(np.uint8), cv2.COLORMAP_JET)
                vis[depth == 0] = 0
                vis = cv2.resize(vis, None, fx=PREVIEW_ZOOM, fy=PREVIEW_ZOOM, interpolation=cv2.INTER_NEAREST)
                color = {"ok": (0, 255, 0), "warn": (0, 200, 255), "bad": (0, 0, 255)}[fill_level(stats["fill"])]
                h, w = vis.shape[:2]
                cv2.rectangle(vis, (0, 0), (w - 1, h - 1), color, 3)
                dist = f"{stats['dist_m'] * 100:.0f} cm" if stats["dist_m"] is not None else "--"
                for i, text in enumerate((f"depth fill {stats['fill'] * 100:.0f}%  (need > {FILL_MIN * 100:.0f}%)",
                                          f"distance {dist}",
                                          "SPACE = start   q = cancel")):
                    cv2.putText(vis, text, (10, 28 + i * 28), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 0), 4)
                    cv2.putText(vis, text, (10, 28 + i * 28), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                                color if i == 0 else (255, 255, 255), 2)
                key = preview.show(vis)
            key = keys.get() or key

            now = time.monotonic()
            if now - last_status > 0.3:
                print(f"\r{_stats_text(stats)}  (空白鍵 = 開始,q = 取消)  ", end="", flush=True)
                last_status = now

            if key == "quit":
                print("\n已取消。")
                return None
            if key == "capture":
                break
    print()
    if fill_level(stats["fill"]) == "bad":
        print(f"注意:有效深度只有 {stats['fill'] * 100:.0f}% (官方準則 > {FILL_MIN * 100:.0f}%),"
              "校正很可能會失敗 (low fill factor)。")
        if not ask_yes_no("仍要開始嗎?(y/N)", input_fn=input_fn):
            return None
    return stats


# ---------------------------------------------------------------- 深度校正
def _run_occ(cam: Camera, scan: int) -> tuple[list[int], float]:
    """On-Chip:深度 256x144 Z16 @90,JSON 與官方範例相同。"""
    rs = cam.rs
    params = json.dumps({"calib type": 0, "speed": OCC_SPEED_MEDIUM, "scan parameter": scan})
    with calibration_mode(cam, EMITTER_ON), \
            streaming(cam, [(rs.stream.depth, 256, 144, rs.format.z16, 90)]) as (pipe, prof):
        pipe.wait_for_frames(5000)
        adev = prof.get_device().as_auto_calibrated_device()
        table, health = adev.run_on_chip_calibration(params, _progress, CALIB_TIMEOUT_MS)
    print()
    return list(table), first_health(health)


# 引導模式中:校正表 (bytes) → health。同一份表的 health 不用重量;一般選單模式是 None (每次都量,
# 因為兩次操作之間相機可能被碰歪)。引導模式原本要跑約 9 次 On-Chip,沿用後約 5 次。
_guided_health: dict[tuple, float] | None = None


def health_check(cam: Camera, restore_table: list[int]) -> float:
    """沒有獨立的 health-check API:跑一次 On-Chip 取 health,丟掉新表並把 restore_table 設回 (不寫入)。

    白皮書:ASIC 會讓新校正保持生效但不燒進 flash,所以要自己還原成原本生效的表。
    """
    key = tuple(restore_table)
    if _guided_health is not None and key in _guided_health:
        health = _guided_health[key]
        print(f"沿用引導模式中剛才量的 health (同一份校正表):{_health_text(health)}")
        return health
    print("執行 health check (On-Chip,不寫入)…")
    try:
        _, health = _run_occ(cam, SCAN_INTRINSIC)
    finally:
        with signals_deferred():
            cam.auto.set_calibration_table(restore_table)
    if _guided_health is not None:
        _guided_health[key] = health
    return health


# ---------------------------------------------------------------- 失敗時的引導與重試
# (錯誤訊息關鍵字, 標題, 建議步驟)。錯誤字串來自韌體 / SDK (ds-calib-common.cpp 等)。
FAILURE_GUIDES: list[tuple[tuple[str, ...], str, list[str]]] = [
    (("failed to extract target",), "相機在左右 IR 畫面裡找不到標靶的 4 個圓點", [
        "標靶固定在支架或牆上,不要用手拿 (校正要連續收 25 組畫面,晃動就會失敗)",
        f"距離拉到 {FL_BEST_MM[0] // 10}～{FL_BEST_MM[1] // 10} cm (預覽畫面會顯示估計距離)",
        "標靶正對相機、不要傾斜,4 個圓點都要在畫面正中央的白框裡 (相機只在這個範圍找點)",
        "照亮標靶:這步會關投射器,室內 LED 燈幾乎沒有紅外光。用白熾燈 / 鹵素燈、窗邊日光,"
        "或 850 nm 紅外線補光燈照在標靶上,光線均勻、不要有反光",
        "重試時會再開 IR 預覽:等畫面顯示 READY (左右都連續找到) 再按空白鍵",
    ]),
    (("not enough depth pixels", "low fill factor"), "有效深度太少 (low fill factor)", [
        "標靶 / 有紋理的平面要填滿預覽畫面,畫面裡的黑色 (量不到) 越少越好 (要 > 35%)",
        "不要太近:小於最短量測距離會整片黑;先拉遠一點再慢慢靠近",
        "避免有光澤、會反光的表面,也不要對著窗戶或強光",
        "重試時會再開深度預覽:有效深度數字變綠再按空白鍵",
    ]),
    (("timed out", "timeout"), "校正逾時", [
        "校正中相機與標靶都不能動,也不要有人在畫面前走動",
        "確認相機接在藍色 USB 3 孔,線不要太長或經過沒供電的 hub",
    ]),
]


def print_failure_guide(err: Exception) -> None:
    """依錯誤內容印出「發生什麼事 + 該怎麼調整」;USB 斷線另外檢查是不是供電不足。"""
    text = str(err).lower()
    for keys, title, steps in FAILURE_GUIDES:
        if any(k in text for k in keys):
            print(f"\n原因:{title}。請這樣調整:")
            for i, step in enumerate(steps, 1):
                print(f"  {i}. {step}")
            return
    if any(k in text for k in ("disconnected", "power state", "no such device", "找不到 realsense")):
        explain_camera_error(err)
        print("確認相機重新出現 (rs-enumerate-devices 看得到) 後就可以重試。")
        return
    print("\n請檢查標靶擺放、光線與相機連線後重試;若一直出現同樣的錯誤,請把上面的訊息回報。")


def run_with_retry(label: str, attempt: Callable[[], str], input_fn: Callable[[str], str] = input) -> str:
    """執行一次校正;失敗時說明原因與調整方式,問要不要再試 (預設要)。

    每次重試都重新開相機、重新預覽,所以使用者可以邊看畫面邊調整。
    Ctrl-C (KeyboardInterrupt) 不在這裡處理,照常中斷。
    """
    tries = 1
    while True:
        try:
            return attempt()
        except (ToolError, RuntimeError) as e:
            print(f"\n{label} 失敗:{e}")
            print_failure_guide(e)
            if not ask_yes_no("\n照上面調整好之後,要再試一次嗎?(Y/n)", default=True, input_fn=input_fn):
                return f"失敗:{str(e).splitlines()[0]}"
            tries += 1
            _title(f"{label}:第 {tries} 次嘗試")


def try_health_check(cam: Camera, restore_table: list[int]) -> float | None:
    """health check 失敗 (例如 low fill factor) 時不中止整個校正流程:印出原因並回傳 None。"""
    try:
        return health_check(cam, restore_table)
    except RuntimeError as e:
        print(f"\nhealth check 失敗:{e}")
        print_failure_guide(e)
        return None


def _health_change(before: float | None, after: float | None) -> str:
    f = lambda v: "失敗" if v is None else f"{v:+.3f}"
    return f"health {f(before)} → {f(after)}"


def _depth_flow(cam: Camera, label: str, run: Callable[[], tuple[list[int], dict]],
                input_fn: Callable[[str], str] = input) -> str:
    """共用流程:校正前 health → 校正 → 暫時套用 → 校正後 health → 比較 → 詢問寫入。

    不比較校正前後的內參:暫時套用的新表只在相機 RAM,SDK 回報的內參 (包括重新開 context)
    仍是 flash 裡的舊值 (2026-11 實機確認),比較出來永遠一樣,會誤導。用 health 判斷校正效果。
    """
    original = list(cam.auto.get_calibration_table())
    before = {"health": try_health_check(cam, original)}
    print(f"校正前 health:{_health_text(before['health'])}")
    if before["health"] is None and not ask_yes_no(f"校正前的 health check 失敗,仍要繼續 {label} 嗎?(y/N)",
                                                   input_fn=input_fn):
        return "取消 (校正前 health check 失敗)"

    print(f"開始 {label}…")
    try:
        # 白皮書:校正後 ASIC 會讓新校正保持生效 (未燒進 flash),所以從這裡開始任何中斷都要還原
        new_table, reported = run()
        if not new_table:
            raise ToolError(f"{label} 失敗:相機沒有回傳新的校正表。")
        cam.auto.set_calibration_table(new_table)  # 暫時套用 (RAM),沒寫入前拔插相機就會回到原本的
        after = {"health": try_health_check(cam, new_table)}
        print(f"\n{label} 回報:" + ",".join(f"{k} = {_fmt(v)}" for k, v in reported.items()))
        print(f"校正前 health:{_health_text(before['health'])}")
        print(f"校正後 health:{_health_text(after['health'])}")
        if after["health"] is None:
            print("注意:校正後無法做 health check,無法確認校正結果;除非確定擺放正確,建議不要寫入。")
        elif before["health"] is not None and abs(after["health"]) > abs(before["health"]):
            print("注意:校正後的 health 比校正前差,建議不要寫入,檢查標靶與擺放後重做。")
        wrote = offer_write(cam.auto, new_table, original, cam.serial, input_fn=input_fn)
    except InterruptedAfterWrite as e:
        # 新表已寫進 flash 且正在生效,不能再設回原本的表 (那會讓 RAM 與 flash 不一致)
        print(f"\n已寫入相機 (寫入期間收到中斷,等寫入完成才停止)。原本的校正表備份在:{e.path}")
        raise
    except BaseException:
        # 只還原「目前生效」(RAM) 的表;flash 是否寫入由 write_to_camera 的錯誤訊息說明
        with signals_deferred():
            cam.auto.set_calibration_table(original)
        print("已把目前生效的校正設回原本的表。")
        raise
    if wrote:
        _report_flash(cam.serial, expected=new_table)
        print("新的內參要等相機重新連線 (拔插 USB 或重開機) 後,才會出現在選單 3「顯示目前內參」。")
    else:
        cam.auto.set_calibration_table(original)
        print("已還原為原本的校正。")
    return _health_change(before["health"], after["health"]) + (";已寫入相機" if wrote else ";未寫入相機")


def run_health_check(input_fn: Callable[[str], str] = input) -> str:
    _title("Health check (只檢查、不寫入)")
    if not confirm_preparation("health", input_fn):
        return "取消"
    if not require_depth_ready(open_camera(), input_fn):
        return "未執行 (需要 Advanced Mode)"

    def attempt() -> str:
        cam = open_camera()
        if preview_depth_target(cam, input_fn) is None:
            return "取消"
        health = health_check(cam, list(cam.auto.get_calibration_table()))
        print(f"Health:{_health_text(health)}  (未寫入相機)")
        return f"health {health:+.3f} ({classify_health(health)[1]})"

    return run_with_retry("Health check", attempt, input_fn)


def run_on_chip(input_fn: Callable[[str], str] = input) -> str:
    _title("On-Chip 自我校正")
    print("模式:1) 內參模式 (預設,官方範例預設)  2) 外參模式")
    scan = SCAN_EXTRINSIC if input_fn("請選擇 (Enter = 1):").strip() == "2" else SCAN_INTRINSIC
    if not confirm_preparation("onchip", input_fn):
        return "取消"
    if not require_depth_ready(open_camera(), input_fn):
        return "未執行 (需要 Advanced Mode)"

    def attempt() -> str:
        cam = open_camera()  # 每次重試都重開:上次失敗可能是 USB 斷線,舊的裝置物件已失效
        if preview_depth_target(cam, input_fn) is None:
            return "取消"

        def run():
            table, health = _run_occ(cam, scan)
            return table, {"On-Chip health": health}

        return _depth_flow(cam, "On-Chip 校正", run, input_fn)

    return run_with_retry("On-Chip 校正", attempt, input_fn)


# ---------------------------------------------------------------- IR 預覽 (Focal Length 校正前)
# Focal Length 要在左右 IR 影像裡找到標靶的 4 個圓點,而且必須關 emitter (投射光點會干擾)。
# D435f 有 IR 濾鏡,室內 LED 燈幾乎沒有紅外光 → 畫面很暗、圓點對比低;手拿、太近、傾斜也會讓
# 韌體回報「Failed to extract target information from the captured frames!」(2026-11 實機)。
IR_DARK_EXPOSURE_US = 30000  # 30 fps 的曝光上限約 33 ms;自動曝光拉到這裡 + 高增益 = 環境紅外光不夠
IR_DARK_GAIN = 200
IR_PREVIEW_SCALE = 0.5
IR_DETECT_INTERVAL_S = 0.2


def find_dark_blobs(img) -> list[tuple[float, float, float]]:
    """找比周圍暗的小圓點 (官方標靶的圓點是模糊的深色圓)。回傳 (x, y, 對比),對比高的在前。

    用「和局部背景比較」而不是固定門檻:IR 畫面很暗、亮度不均時圓點只比背景暗 15～25 灰階。
    """
    cv2 = import_cv2()
    np = import_np()
    g = cv2.GaussianBlur(img, (5, 5), 0).astype(np.float32)
    diff = cv2.blur(g, (61, 61)) - g
    noise = max(float(np.std(diff)), 1.0)
    mask = (diff > max(4 * noise, 6.0)).astype(np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    n, labels, stats, cents = cv2.connectedComponentsWithStats(mask)
    blobs = []
    for i in range(1, n):
        _, _, w, h, area = stats[i]
        if not 12 <= area <= 4000 or not 0.6 <= w / h <= 1.6 or area / (w * h) < 0.5:
            continue
        blobs.append((float(cents[i][0]), float(cents[i][1]), float(diff[labels == i].mean())))
    return sorted(blobs, key=lambda b: -b[2])


def find_target_dots(img, ratio: float = TARGET_DESIGN_MM[0] / TARGET_DESIGN_MM[1], candidates: int = 12):
    """在 IR 影像裡找標靶的 4 個圓點 (排成寬:高 = ratio 的長方形)。

    回傳 (左上, 右上, 左下, 右下) 或 None。手指陰影等其他深色點會被長方形條件排除。
    傾斜 / 透視會讓比例變形,所以容許 ±30%。
    """
    from itertools import combinations
    blobs = find_dark_blobs(img)[:candidates]
    best, best_score = None, None
    for quad in combinations(blobs, 4):
        pts = sorted(((b[0], b[1]) for b in quad), key=lambda p: p[1])
        top, bottom = sorted(pts[:2]), sorted(pts[2:])
        tl, tr, bl, br = top[0], top[1], bottom[0], bottom[1]
        w_top, w_bot = tr[0] - tl[0], br[0] - bl[0]
        h_left, h_right = bl[1] - tl[1], br[1] - tr[1]
        if min(w_top, w_bot, h_left, h_right) < 20:
            continue
        w, h = (w_top + w_bot) / 2, (h_left + h_right) / 2
        r = w / h
        parallel = abs(w_top - w_bot) / w + abs(h_left - h_right) / h
        skew = (abs(tl[0] - bl[0]) + abs(tr[0] - br[0])) / w + (abs(tl[1] - tr[1]) + abs(bl[1] - br[1])) / h
        if abs(r / ratio - 1) > 0.3 or parallel > 0.4 or skew > 0.4:
            continue
        score = abs(r / ratio - 1) + parallel + skew
        if best_score is None or score < best_score:
            best, best_score = (tl, tr, bl, br), score
    return best


def target_distance_mm(dots, fx: float, width_mm: float) -> float:
    """由左右圓點的像素間距估算標靶距離 (針孔模型:距離 = fx × 實際寬 / 像素寬)。"""
    tl, tr, bl, br = dots
    px = ((tr[0] - tl[0]) + (br[0] - bl[0])) / 2
    return fx * width_mm / px


# SDK 找標靶的範圍 (src/algo.h):1280x720 畫面中 x 480～800、y 240～480 的中央方框,邊緣再留 20 px。
# 4 個圓點都要在這裡面;找點用固定 28x28 的模糊圓點模板比對 (所以距離不能差太多)。
SDK_TARGET_ROI = (480, 240, 800, 480)
SDK_TARGET_MARGIN = 20
IR_STABLE_NEEDED = 8  # 校正時 25 組畫面只要一張找不到就整個失敗 → 預覽要連續找到這麼多次才算 READY


def sdk_find_target(frame, rs) -> list[tuple[float, float]] | None:
    """用 SDK 自己的偵測 (和 Focal Length 校正同一個函式) 找 4 個圓點;找不到回傳 None。"""
    try:
        d = frame.extract_target_dimensions(rs.calib_target_type.pos_gaussian_dot_vertices)
    except RuntimeError:
        return None
    pts = [(float(d[i]), float(d[i + 1])) for i in range(0, 8, 2)]
    pts.sort(key=lambda p: p[1])
    top, bottom = sorted(pts[:2]), sorted(pts[2:])
    return [top[0], top[1], bottom[0], bottom[1]]


def dots_inside_sdk_roi(dots) -> bool:
    x0, y0, x1, y1 = SDK_TARGET_ROI
    m = SDK_TARGET_MARGIN
    return all(x0 + m <= x <= x1 - m and y0 + m <= y <= y1 - m for x, y in dots)


def ir_target_status(sdk_l, sdk_r, my_l, my_r, dist_mm: float | None, exposure: float | None,
                     gain: float | None) -> tuple[list[str], list[str]]:
    """預覽狀態 → (擋住開始的問題, 只是提醒)。能不能開始只看 SDK 自己找不找得到。"""
    blocking, hints = [], []
    for side, sdk, mine in (("左", sdk_l, my_l), ("右", sdk_r, my_r)):
        if sdk is not None:
            continue
        if mine is None:
            blocking.append(f"{side}鏡頭找不到 4 個圓點 (整張標靶要在畫面內、正對相機)")
        elif not dots_inside_sdk_roi(mine):
            blocking.append(f"{side}鏡頭的圓點不在中央方框內 (把標靶移到畫面正中央,4 個點都要在白框裡)")
        else:
            blocking.append(f"{side}鏡頭:圓點在框內但 SDK 認不出來 (多半是太暗、太糊或距離不對)")
    if dist_mm is not None and not FL_BEST_MM[0] <= dist_mm <= FL_BEST_MM[1]:
        hints.append(f"距離約 {dist_mm / 10:.0f} cm,建議 {FL_BEST_MM[0] / 10:.0f}～{FL_BEST_MM[1] / 10:.0f} cm")
    if exposure is not None and gain is not None and exposure >= IR_DARK_EXPOSURE_US and gain >= IR_DARK_GAIN:
        hints.append("IR 畫面很暗 (自動曝光已到極限),雜訊多;加紅外光 (白熾燈 / 日光 / 850 nm 補光) 會穩很多")
    return blocking, hints


def preview_ir_target(cam: Camera, width_mm: float, input_fn: Callable[[str], str] = input) -> bool:
    """Focal Length 校正前的 IR 預覽。回傳 True = 開始。

    串流與 emitter 設定和 _run_focal 相同 (左右 IR 1280x720 Y8 @30,emitter 關),
    並用 SDK 自己的找點函式判斷:預覽連續找得到,校正時才找得到。
    """
    cv2 = import_cv2()
    np = import_np()
    rs = cam.rs
    streams = [(rs.stream.infrared, 1, 1280, 720, rs.format.y8, 30),
               (rs.stream.infrared, 2, 1280, 720, rs.format.y8, 30)]
    print("\n開始 IR 預覽 (和校正時一樣:投射器關閉)。空白鍵 = 開始,q = 取消。")
    print("  - 標靶固定在支架或牆上 (不要手拿,校正要連續收 25 組畫面),正對相機")
    print("  - 4 個圓點要在畫面正中央的白框裡 (相機只在這個範圍找點),左右兩個畫面都要")
    print(f"  - 距離 {FL_BEST_MM[0] / 10:.0f}～{FL_BEST_MM[1] / 10:.0f} cm 最好")
    print("  - 這一步不能開投射器,要靠環境的紅外光。D435f 在室內 LED 燈下很暗:可用白熾燈 / 鹵素燈、"
          "窗邊的日光,或 850 nm 紅外線補光燈照在標靶上 (光線均勻、不要反光)")
    print(f"  - 左右都連續 {IR_STABLE_NEEDED} 次找到 (畫面顯示 READY) 再按空白鍵")
    md = rs.frame_metadata_value
    blocking: list[str] = ["還沒有畫面"]
    hints: list[str] = []
    stable = 0
    with open_preview("Focal Length IR 預覽", input_fn) as preview, calibration_mode(cam, EMITTER_OFF), \
            streaming(cam, streams) as (pipe, _), KeyReader() as keys:
        fx = None
        last_detect = last_status = 0.0
        sdk_l = sdk_r = dist = None
        while True:
            try:
                frames = pipe.wait_for_frames(5000)
            except RuntimeError as e:
                raise ToolError(f"讀取 IR 影像失敗:{e}") from e
            fl, fr = frames.get_infrared_frame(1), frames.get_infrared_frame(2)
            if not fl or not fr:
                continue
            if fx is None:
                fx = fl.get_profile().as_video_stream_profile().get_intrinsics().fx
            left, right = np.asanyarray(fl.get_data()), np.asanyarray(fr.get_data())
            exposure = fl.get_frame_metadata(md.actual_exposure) if fl.supports_frame_metadata(md.actual_exposure) else None
            gain = fl.get_frame_metadata(md.gain_level) if fl.supports_frame_metadata(md.gain_level) else None
            now = time.monotonic()
            if now - last_detect >= IR_DETECT_INTERVAL_S:  # 偵測比較花時間,不用每張都做
                last_detect = now
                sdk_l, sdk_r = sdk_find_target(fl, rs), sdk_find_target(fr, rs)
                stable = stable + 1 if sdk_l and sdk_r else 0
                my_l = my_r = None
                if not (sdk_l and sdk_r):  # 只有 SDK 找不到時才用自己的偵測來說明原因
                    my_l, my_r = find_target_dots(left), find_target_dots(right)
                ref = sdk_l or my_l
                dist = target_distance_mm(ref, fx, width_mm) if ref else None
                blocking, hints = ir_target_status(sdk_l, sdk_r, my_l, my_r, dist, exposure, gain)
                if not blocking and stable < IR_STABLE_NEEDED:
                    blocking = [f"左右都找到了,確認穩定中 ({stable}/{IR_STABLE_NEEDED}),標靶不要動"]
            ready = not blocking

            key = None
            if preview.active:
                vis = cv2.cvtColor(np.hstack([left, right]), cv2.COLOR_GRAY2BGR)
                vis = cv2.normalize(vis, None, 0, 255, cv2.NORM_MINMAX)  # 太暗時也看得清楚 (只影響顯示)
                x0, y0, x1, y1 = SDK_TARGET_ROI
                for offset, dots in ((0, sdk_l), (left.shape[1], sdk_r)):
                    cv2.rectangle(vis, (x0 + offset, y0), (x1 + offset, y1),
                                  (0, 255, 0) if dots else (255, 255, 255), 3)
                    for x, y in dots or ():
                        cv2.circle(vis, (int(x) + offset, int(y)), 14, (0, 255, 0), 3)
                vis = cv2.resize(vis, None, fx=IR_PREVIEW_SCALE, fy=IR_PREVIEW_SCALE)
                color = (0, 255, 0) if ready else (0, 0, 255)
                lines = [f"SDK target  L:{'OK' if sdk_l else '--'}  R:{'OK' if sdk_r else '--'}"
                         f"  stable {min(stable, IR_STABLE_NEEDED)}/{IR_STABLE_NEEDED}",
                         f"distance {dist / 10:.0f} cm (best {FL_BEST_MM[0] // 10}-{FL_BEST_MM[1] // 10})"
                         if dist else "distance --",
                         f"exposure {exposure / 1000:.0f} ms  gain {gain:.0f}" if exposure and gain else "",
                         "READY - press SPACE" if ready else "put the 4 dots inside the white boxes"]
                for i, text in enumerate(t for t in lines if t):
                    cv2.putText(vis, text, (10, 26 + i * 26), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 0, 0), 4)
                    cv2.putText(vis, text, (10, 26 + i * 26), cv2.FONT_HERSHEY_SIMPLEX, 0.65,
                                color if i in (0, 3) else (255, 255, 255), 2)
                key = preview.show(vis)
            key = keys.get() or key

            if now - last_status > 0.5:
                status = "READY,可以按空白鍵開始" if ready else ";".join(blocking)
                if hints:
                    status += "(提醒:" + ";".join(hints) + ")"
                print(f"\r{status}  (空白鍵 = 開始,q = 取消)" + " " * 10, end="", flush=True)
                last_status = now
            if key == "quit":
                print("\n已取消。")
                return False
            if key == "capture":
                break
    print()
    if blocking:
        print("注意:相機還沒穩定找到標靶,校正很可能失敗 (Failed to extract target information):")
        for p in blocking + hints:
            print(f"  - {p}")
        if not ask_yes_no("仍要開始嗎?(y/N)", input_fn=input_fn):
            return False
    elif hints:
        print("提醒:" + ";".join(hints))
    return True


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
    with calibration_mode(cam, EMITTER_OFF), streaming(cam, streams, cb) as (_, prof):
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
    print(f"官方標靶的圓點中心間距設計值是 {TARGET_DESIGN_MM[0]:g} x {TARGET_DESIGN_MM[1]:g} mm。"
          "照 100% (實際大小) 列印的話直接按 Enter;印表機有縮放時才輸入用尺量的值。")
    w = ask_mm("左右圓點中心間距 (mm)", 100, 250, TARGET_DESIGN_MM[0], input_fn)
    if w is None:
        return "取消"
    h = ask_mm("上下圓點中心間距 (mm)", 50, 150, TARGET_DESIGN_MM[1], input_fn)
    if h is None:
        return "取消"
    print("調整方式:1) 只調整右側 (預設,官方範例預設)  2) 左右兩側都調整")
    adjust = FL_ADJUST_BOTH_SIDES if input_fn("請選擇 (Enter = 1):").strip() == "2" else FL_ADJUST_RIGHT_ONLY
    if not require_depth_ready(open_camera(), input_fn):
        return "未執行 (需要 Advanced Mode)"

    def attempt() -> str:
        cam = open_camera()
        if not preview_ir_target(cam, w, input_fn):
            return "取消"
        return _depth_flow(cam, "Focal Length 校正", lambda: _run_focal(cam, w, h, adjust), input_fn)

    return run_with_retry("Focal Length 校正", attempt, input_fn)


def _run_tare(cam: Camera, ground_truth_mm: float) -> tuple[list[int], dict]:
    """Tare:深度 256x144 Z16 @90,JSON 與官方範例相同。"""
    rs = cam.rs
    params = json.dumps({"scan parameter": SCAN_INTRINSIC, "accuracy": TARE_ACCURACY_MEDIUM})
    with calibration_mode(cam, EMITTER_ON), \
            streaming(cam, [(rs.stream.depth, 256, 144, rs.format.z16, 90)]) as (pipe, prof):
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
    if not require_depth_ready(open_camera(), input_fn):
        return "未執行 (需要 Advanced Mode)"

    def attempt() -> str:
        cam = open_camera()
        # 先預覽擺好標靶,之後不能再動,才量真實距離 (反過來的話,預覽中移動標靶會讓輸入的距離失效)。
        # 重試時標靶可能移動過,所以每次都重新量。
        stats = preview_depth_target(cam, input_fn)
        if stats is None:
            return "取消"
        print("現在請量相機到標靶平面的真實距離。相機與標靶都不要再動。")
        print(f"  距離要量到左鏡頭的光學原點:從相機前玻璃量的話,D435f 要再加 {TARE_FRONT_GLASS_MM} mm"
              " (資料表 Front Glass Z')。")
        gt = ask_tare_distance(stats.get("dist_m"), input_fn)
        if gt is None:
            return "取消"
        return _depth_flow(cam, "Tare 校正", lambda: _run_tare(cam, gt), input_fn)

    return run_with_retry("Tare 校正", attempt, input_fn)


def ask_tare_distance(measured_m: float | None, input_fn: Callable[[str], str] = input) -> int | None:
    """問 Tare 的真實距離;與預覽量到的距離差太多時再確認。SDK 只吃整數 mm,先四捨五入。"""
    while True:
        gt = ask_mm("相機到標靶平面的真實距離 (mm)", *TARE_GT_RANGE_MM, input_fn=input_fn)
        if gt is None:
            return None
        gt = int(round(gt))
        if measured_m:
            diff = (gt - measured_m * 1000) / (measured_m * 1000)
            if abs(diff) > TARE_MISMATCH_WARN:
                print(f"注意:輸入 {gt} mm,預覽量到約 {measured_m * 1000:.0f} mm (相差 {diff * 100:+.1f}%)。"
                      "Tare 用來修正的誤差通常只有幾 %,差這麼多多半是量錯或標靶動過。")
                if not ask_yes_no(f"確定用 {gt} mm 嗎?(y/N)", input_fn=input_fn):
                    continue
        return gt


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
        "     四個圓點都要在畫面中;圓點間距照 100% 列印就直接按 Enter 用設計值。",
        "距離:D435 約 0.65～2.0 m 可用,官方建議 0.8～1 m (白皮書)。",
        "標靶固定在支架 / 牆上,不要手拿;這步要關投射器,需要白熾燈、日光或紅外線補光照亮標靶。",
    ],
    "tare": [
        f"標靶:官方深度校正標靶 {TARGET_PDF_URL}",
        "距離:標靶要填滿預覽畫面且距離量得準 (白皮書用標靶量真實距離時建議 0.65～1.8 m)。",
        "流程:先預覽擺好標靶 → 量真實距離並輸入 (mm) → health check → Tare → 再 health check。",
    ],
    "rgb": [
        "標靶:ChArUco 板 (請先用選項 8 產生 PDF 並列印、貼在硬板上)。",
        f"距離:25～40 cm;共拍 {RGB_TARGET_VIEWS} 張,每張變換角度、距離,並讓板子出現在畫面四角與邊緣。",
        "會自動拍照:板子拿穩約 0.6 秒、角點夠、和拍過的不一樣就拍;拍到後換下一個位置即可。",
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
            try:
                # TCSAFLUSH:丟掉還沒讀的按鍵,避免多按的 q / 空白鍵被下一個 input() 讀走 (畫面上看不到)
                self._termios.tcsetattr(self._fd, self._termios.TCSAFLUSH, self._old)
            except (self._termios.error, OSError):
                pass  # SSH 斷線後 stdin 已不是終端機


# ---------------------------------------------------------------- 預覽畫面 (視窗 / 瀏覽器 / 純文字)
# 啟動時就有圖形畫面 = 在機台桌面或本機執行;沒有 = 透過 SSH,視窗會開在機台螢幕上,遠端的人看不到。
_HAS_LOCAL_GUI = (not sys.platform.startswith("linux")
                  or bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")))
WEB_PREVIEW_PORT = 8765
WEB_PREVIEW_FPS = 15  # 瀏覽器不需要 90 fps,限制編碼次數省 CPU
_web_token: str | None = None


WEB_TOKEN_PATH = CONFIG_DIR / "preview_token"


def web_token() -> str:
    """網址裡的隨機路徑:同網段的人不知道網址就看不到相機畫面。

    第一次產生後存在 ~/.config/spoonfull/preview_token (只有本人可讀),之後一直沿用,
    網址固定不變,可以存成書籤。要換網址就刪掉這個檔。存檔失敗時這次執行內仍固定。
    """
    global _web_token
    if _web_token is not None:
        return _web_token
    try:
        saved = WEB_TOKEN_PATH.read_text(encoding="utf-8").strip()
        if re.fullmatch(r"[A-Za-z0-9_-]{8,64}", saved):
            _web_token = saved
            return _web_token
    except OSError:
        pass
    import secrets
    _web_token = secrets.token_urlsafe(9)
    try:
        WEB_TOKEN_PATH.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(WEB_TOKEN_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(_web_token + "\n")
    except OSError as e:
        print(f"注意:無法保存預覽網址 ({e}),下次執行網址會不同。")
    return _web_token


class _PreviewBase:
    """with 區塊結束 (包括串流啟動失敗) 一定會 close;close 可重複呼叫。"""
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


class NoPreview(_PreviewBase):
    """不顯示畫面,只在終端機顯示數值。"""
    active = False

    def show(self, img) -> str | None:
        return None

    def close(self) -> None:
        pass


class GuiPreview(_PreviewBase):
    """OpenCV 視窗 (本機或機台螢幕)。按鍵可在視窗或終端機按。"""
    active = True

    def __init__(self, title: str):
        self._cv2 = import_cv2()
        self._window = title
        self._cv2.namedWindow(title, self._cv2.WINDOW_NORMAL)

    def show(self, img) -> str | None:
        self._cv2.imshow(self._window, img)
        return decode_gui_key(self._cv2.waitKeyEx(1))

    def close(self) -> None:
        self._cv2.destroyAllWindows()
        self._cv2.waitKey(1)  # GTK 要跑一次事件迴圈視窗才會真的關掉


def _preview_page(title: str) -> bytes:
    import html
    t = html.escape(title)
    return (
        "<!doctype html><html><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width,initial-scale=1'>"
        f"<title>{t}</title><style>body{{margin:0;padding:12px;background:#111;color:#eee;"
        "font-family:sans-serif}img{max-width:100%;height:auto;image-rendering:pixelated;"
        "display:block;margin:8px auto}p{text-align:center}</style></head><body>"
        f"<p><b>{t}</b></p><img src='stream' alt='相機畫面'>"
        "<p>按鍵請在 SSH 終端機操作。畫面停住 = 這個步驟已結束,下次預覽時重新整理本頁即可。</p>"
        "</body></html>"
    ).encode("utf-8")


def _machine_ip() -> str:
    """遠端要連的 IP:SSH_CONNECTION 的第 3 欄就是機台被連進來的那個位址。"""
    parts = os.environ.get("SSH_CONNECTION", "").split()
    if len(parts) >= 3:
        return f"[{parts[2]}]" if ":" in parts[2] else parts[2]  # IPv6 在網址裡要加中括號
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=5).stdout.split()
        if out:
            return out[0]
    except (OSError, subprocess.SubprocessError):
        pass
    return "<機台 IP>"


class WebPreview(_PreviewBase):
    """在機台開一個小 HTTP 伺服器,用瀏覽器看即時畫面 (MJPEG)。透過 SSH 操作時用。

    按鍵仍由 SSH 終端機讀取 (KeyReader);只在預覽期間開著,結束就關掉。
    """
    active = True

    def __init__(self, title: str, port: int = WEB_PREVIEW_PORT):
        import http.server
        import threading
        self._cv2 = import_cv2()
        self._cond = threading.Condition()
        self._jpeg = b""
        self._seq = 0
        self._closed = False
        self._last = 0.0
        preview, page = self, _preview_page(title)
        base = f"/{web_token()}/"

        class Handler(http.server.BaseHTTPRequestHandler):
            timeout = 10  # 瀏覽器卡住不讀時,寫入逾時讓連線結束,不會留下卡住的執行緒

            def log_message(self, *args):  # 不要把連線紀錄印在終端機上蓋掉狀態列
                pass

            def do_GET(self):
                if self.path == base + "stream":
                    preview._stream(self)
                    return
                if self.path != base:
                    self.send_error(404)  # 不知道隨機路徑就看不到畫面
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(page)))
                self.end_headers()
                self.wfile.write(page)

        self._server = None
        for p in (port, 0):  # 預設 port 被占用就隨便挑一個
            try:
                self._server = http.server.ThreadingHTTPServer(("0.0.0.0", p), Handler)
                break
            except OSError as e:
                err = e
        if self._server is None:
            raise ToolError(f"無法開啟網頁預覽:{err}")
        self.port = self._server.server_address[1]
        self.url = f"http://{_machine_ip()}:{self.port}{base}"
        threading.Thread(target=self._server.serve_forever, daemon=True).start()

    def _stream(self, h) -> None:
        h.send_response(200)
        h.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        h.send_header("Cache-Control", "no-store")
        h.end_headers()
        seq = -1
        try:
            while True:
                with self._cond:
                    self._cond.wait_for(lambda: self._closed or self._seq != seq, timeout=1.0)
                    if self._closed:
                        return
                    if self._seq == seq:
                        continue
                    seq, jpeg = self._seq, self._jpeg
                if not jpeg:
                    continue  # 還沒有任何畫面
                h.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
                              + str(len(jpeg)).encode() + b"\r\n\r\n" + jpeg + b"\r\n")
                h.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass  # 瀏覽器關掉分頁

    def show(self, img) -> str | None:
        now = time.monotonic()
        if now - self._last >= 1.0 / WEB_PREVIEW_FPS:
            self._last = now
            ok, buf = self._cv2.imencode(".jpg", img, [self._cv2.IMWRITE_JPEG_QUALITY, 75])
            if ok:
                with self._cond:
                    self._jpeg = buf.tobytes()
                    self._seq += 1
                    self._cond.notify_all()
        return None

    def close(self) -> None:
        if self._closed:
            return
        with self._cond:
            self._closed = True
            self._cond.notify_all()
        self._server.shutdown()
        self._server.server_close()


def _gui_works() -> bool:
    """在子行程試開視窗:某些 GUI 後端開不了畫面會直接結束整個行程。"""
    probe = "import cv2; cv2.namedWindow('probe'); cv2.waitKey(1); cv2.destroyAllWindows()"
    try:
        r = subprocess.run([sys.executable, "-c", probe], capture_output=True, timeout=15)
    except subprocess.TimeoutExpired:
        print("開啟預覽視窗逾時,改用文字模式 (只在終端機顯示數值)。")
        return False
    if r.returncode != 0:
        err = r.stderr.decode(errors="replace").strip().splitlines()
        print(f"無法開啟預覽視窗 ({err[-1] if err else '未知原因'}),改用文字模式 (只在終端機顯示數值)。")
        return False
    return True


_preview_choice: str | None = None  # 同一次執行只問一次 (引導模式每一步都會預覽)


def open_preview(title: str, input_fn: Callable[[str], str] = input):
    """依環境選擇預覽方式。透過 SSH 時預設用瀏覽器,因為機台螢幕上的視窗遠端看不到。"""
    global _preview_choice
    if not _HAS_LOCAL_GUI:
        ans = _preview_choice
        if ans is None:
            print("目前透過 SSH 連線,預覽畫面要顯示在哪裡?")
            print("  1) 用你電腦的瀏覽器看 (預設)")
            print("  2) 機台本身接的螢幕")
            print("  3) 不顯示畫面,只在終端機顯示數值")
            ans = input_fn("請選擇 (Enter = 1):").strip()
            ans = ans if ans in ("2", "3") else "1"
            _preview_choice = ans
        if ans == "3":
            return NoPreview()
        if ans != "2":
            try:
                web = WebPreview(title)
            except ToolError as e:
                print(f"{e}\n改用文字模式 (只在終端機顯示數值)。")
                return NoPreview()
            print(f"\n>>> 請在你電腦的瀏覽器打開:{web.url}")
            print("    (網址固定不變,可存成書籤;要和機台在同一個網路;按鍵仍然在這個 SSH 視窗按)")
            return web
        os.environ["DISPLAY"] = ":0"
    return GuiPreview(title) if _gui_works() else NoPreview()


REGION_NAMES = ["左上", "上方", "右上", "左側", "中央", "右側", "左下", "下方", "右下"]


def _cells_hit(points, image_size) -> set[int]:
    w, h = image_size
    cells = set()
    for x, y in points:
        cx = min(2, max(0, int(x / w * 3)))
        cy = min(2, max(0, int(y / h * 3)))
        cells.add(cy * 3 + cx)
    return cells


class AutoCapture:
    """決定 ChArUco 什麼時候自動拍。step() 每張畫面呼叫一次,回傳 (要不要拍, 狀態, 穩定進度 0～1)。"""

    def __init__(self, image_size: tuple[int, int], min_corners: int = RGB_AUTO_MIN_CORNERS):
        self.diag = math.hypot(*image_size)
        self.min_corners = min_corners
        self.prev: dict[int, tuple[float, float]] = {}
        self.still_since: float | None = None
        self.last_capture = -1e9
        self.taken: list[dict[int, tuple[float, float]]] = []

    @staticmethod
    def _as_dict(ids, pts) -> dict[int, tuple[float, float]]:
        if ids is None:
            return {}
        return {int(i): (float(x), float(y)) for i, (x, y) in zip(ids.reshape(-1), pts.reshape(-1, 2))}

    @staticmethod
    def _shift(a: dict, b: dict) -> float | None:
        """共同角點的位移 (中位數);共同角點太少回傳 None (視為完全不同的畫面)。"""
        common = a.keys() & b.keys()
        if len(common) < 4:
            return None
        d = sorted(math.hypot(a[k][0] - b[k][0], a[k][1] - b[k][1]) for k in common)
        return d[len(d) // 2]

    def novelty(self, cur: dict) -> float:
        """和最像的那一張已拍畫面差多少 (以畫面對角線為單位);還沒拍過回傳無限大。"""
        best = math.inf
        for old in self.taken:
            s = self._shift(cur, old)
            if s is not None:
                best = min(best, s / self.diag)
        return best

    def step(self, ids, pts, now: float) -> tuple[bool, str, float]:
        cur = self._as_dict(ids, pts)
        moved = self._shift(cur, self.prev)
        self.prev = cur
        if len(cur) < self.min_corners:
            self.still_since = None
            return False, f"角點 {len(cur)} 個,至少要 {self.min_corners} 個:板子整面朝向相機、別被手擋住", 0.0
        if moved is None or moved > RGB_STILL_PX:
            self.still_since = None
            return False, "拿穩不要動…", 0.0
        if self.still_since is None:
            self.still_since = now
        if now - self.last_capture < RGB_COOLDOWN_S:
            return False, "已拍,請換下一個位置 / 角度", 0.0
        if self.novelty(cur) < RGB_NOVEL_FRAC:
            return False, "和拍過的太像:換位置、距離或傾斜角度", 0.0
        progress = min(1.0, (now - self.still_since) / RGB_STILL_S)
        if progress < 1.0:
            return False, "拿穩不要動…", progress
        return True, "拍了!", 1.0

    def mark_taken(self, ids, pts, now: float) -> None:
        self.taken.append(self._as_dict(ids, pts))
        self.last_capture = now
        self.still_since = None


def capture_charuco_views(cam: Camera, helper: CharucoHelper, board, preview) -> list:
    cv2 = import_cv2()
    np = import_np()
    rs = cam.rs
    total = helper.corner_count()
    views: list = []
    coverage = [0] * 9
    auto = AutoCapture(RGB_SIZE)
    print(f"\n開始預覽。會自動拍照:板子拿穩、角點夠、和拍過的不一樣時就拍。目標 {RGB_TARGET_VIEWS} 張"
          f" (最少 {RGB_MIN_VIEWS} 張)。")
    print("拍到一張後換下一個位置:變換角度 (傾斜 20～40 度)、距離 (25～40 cm),"
          "並讓板子輪流出現在畫面四角與邊緣 (畫面上的 9 格數字 = 每格拍到幾張)。")
    print("空白鍵 = 手動補拍一張,q = 提早結束。")
    with preview, streaming(cam, [(rs.stream.color, *RGB_SIZE, rs.format.bgr8, 30)]) as (pipe, _), \
            KeyReader() as keys:
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
                now = time.monotonic()
                shoot, auto_status, progress = auto.step(ids, corners if n else None, now)

                key = None
                if preview.active:
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
                                cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 255, 0) if n >= RGB_AUTO_MIN_CORNERS else (0, 0, 255), 2)
                    if progress > 0:  # 穩定進度條:滿了就自動拍
                        cv2.rectangle(vis, (w // 2 - 150, h - 70), (w // 2 - 150 + int(300 * progress), h - 55),
                                      (0, 255, 0), -1)
                        cv2.rectangle(vis, (w // 2 - 150, h - 70), (w // 2 + 150, h - 55), (255, 255, 255), 1)
                    if now - auto.last_capture < 0.3:  # 拍到時整個畫面閃一下框
                        cv2.rectangle(vis, (0, 0), (w - 1, h - 1), (0, 255, 0), 12)
                    key = preview.show(vis)
                key = keys.get() or key

                if now - last_status > 0.3:
                    status = f"角點 {n:2d}/{total}  已拍 {len(views):2d}/{RGB_TARGET_VIEWS}  {auto_status}"
                    print(f"\r{status}  (q = 結束)" + " " * 10, end="", flush=True)
                    last_status = now

                if shoot and key != "quit":
                    key = "capture"
                if key == "capture":
                    if n < RGB_MIN_CORNERS:
                        print(f"\n角點只有 {n} 個 (至少 {RGB_MIN_CORNERS} 個),這張不採用,請調整板子位置。")
                        continue
                    pts = corners.reshape(-1, 2)
                    views.append((helper.object_points(board, ids), pts.astype(np.float64)))
                    auto.mark_taken(ids, corners, now)
                    for c in _cells_hit(pts, RGB_SIZE):
                        coverage[c] += 1
                    missing = [REGION_NAMES[c] for c in range(9) if coverage[c] == 0]
                    hint = f"還沒拍到的區域:{'、'.join(missing)}" if missing else ""
                    print(f"\n第 {len(views)} 張:{n} 個角點。{hint}")
                elif key == "quit":
                    break
        finally:
            preview.close()
    print()
    return views


def run_rgb_calibration(input_fn: Callable[[str], str] = input) -> str:
    _title("RGB 內參校正 (OpenCV + ChArUco)")
    cv2 = import_cv2()
    np = import_np()
    if not confirm_preparation("rgb", input_fn):
        return "取消"
    # 不問實測尺寸:板子整體等比例縮放時,算出來的內參 (fx/fy/cx/cy/畸變) 完全不變,只影響板子的
    # 距離估計 (沒用到);標記/方格的比例 (偵測用) 等比例縮放也不變。所以直接用產生 PDF 時的設計值。
    square, marker = CHARUCO_SQUARE_MM, CHARUCO_MARKER_MM

    cam = open_camera()
    sdk = read_intrinsics(cam)["rgb"]
    k_sdk = np.array([[sdk["fx"], 0, sdk["ppx"]], [0, sdk["fy"], sdk["ppy"]], [0, 0, 1]], dtype=np.float64)
    helper = CharucoHelper(cv2)
    board = helper.make_board(square, marker)
    print(f"OpenCV {cv2.__version__} ({'CharucoDetector' if helper.new_api else '舊版 aruco'} API)")
    views = capture_charuco_views(cam, helper, board, open_preview("RGB 內參校正", input_fn))
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
def _version_tuple(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in re.findall(r"\d+", v)) if isinstance(v, str) else ()


def firmware_outdated(current: str, recommended: str) -> bool:
    """目前韌體比 SDK 建議的舊。任一個讀不到就當成不知道 (False)。"""
    cur, rec = _version_tuple(current), _version_tuple(recommended)
    return bool(cur) and bool(rec) and cur < rec


# SDK v2.59 起不再回報「建議韌體版本」,最新版要看官網列表 (2026-11 確認)
FIRMWARE_PAGE_URL = "https://dev.realsenseai.com/docs/firmware-releases-d400/"
FIRMWARE_UPDATE_HINT = (
    "韌體比這版 SDK 建議的舊。舊韌體的自我校正可能比較不穩,建議更新:\n"
    f"  1. 到官網下載 D400 韌體 (需同意授權條款):{FIRMWARE_PAGE_URL}\n"
    "  2. 把下載的 zip 或 .bin 放到機台,用選單 15「更新相機韌體」。"
)


def warn_if_firmware_outdated(cam: Camera) -> None:
    rec = _info(cam.rs, cam.dev, cam.rs.camera_info.recommended_firmware_version)
    if firmware_outdated(cam.firmware, rec):
        print(f"注意:相機韌體 {cam.firmware},建議 {rec}。")
        print(FIRMWARE_UPDATE_HINT)


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
        if firmware_outdated(cam.firmware, recommended):
            print(FIRMWARE_UPDATE_HINT)
    else:
        print(f"最新韌體版本請看官網:{FIRMWARE_PAGE_URL} (更新用選單 15)")
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


def read_flash_table(serial: str) -> list[int]:
    """重新開一個 context 讀校正表。實機確認:這讀到的是 flash 裡的表 (不是 RAM 暫時套用的),
    所以可以用來確認寫入 / 恢復是否真的進了 flash。"""
    return list(open_camera(serial).auto.get_calibration_table())


def _report_flash(serial: str, expected: list[int] | None = None, previous: list[int] | None = None) -> bool:
    """讀回 flash 確認;回傳是否符合預期。讀不到時只警告,不當成失敗。"""
    try:
        now = read_flash_table(serial)
    except (ToolError, RuntimeError) as e:
        print(f"注意:無法讀回相機確認 ({e});請拔插 USB 後用選單 3 確認。")
        return False
    if expected is not None:
        ok = now == list(expected)
    else:
        ok = previous is not None and now != list(previous)
    print("已讀回相機確認:flash 裡是新的校正表。" if ok else
          "警告:讀回的校正表與預期不同,寫入可能沒有成功;請拔插 USB 後再確認一次。")
    return ok


def run_factory_reset(input_fn: Callable[[str], str] = input) -> str:
    _title("恢復出廠校正")
    cam = open_camera()
    print("這會把相機的深度校正恢復成出廠值,之前做過的 On-Chip / Focal Length / Tare 校正都會被覆蓋。")
    print(f"執行前會先把目前的校正表備份到 {BACKUP_DIR} (之後可用選項 14 還原)。")
    if not ask_yes_no("確定要恢復出廠校正嗎?(y/N)", input_fn=input_fn):
        print("已取消。")
        return "取消"
    before = list(cam.auto.get_calibration_table())
    path = backup_calibration(cam.auto, cam.serial, table=before)
    print(f"已備份到:{path}")
    try:
        with signals_deferred():
            cam.auto.reset_to_factory_calibration()
    except RuntimeError as e:
        raise ToolError(f"恢復出廠校正失敗:{e}") from e
    print("已恢復出廠校正。")
    # 不比較內參:SDK 回報的內參在相機重新連線前不會更新 (實機確認),兩欄會一樣而誤導
    if read_flash_table(cam.serial) == before:
        print("校正表沒有改變:這台相機目前本來就是出廠校正。")
    else:
        print("已讀回相機確認:校正表已改成出廠值。")
    print("新的內參要等相機重新連線 (拔插 USB 或重開機) 後,才會出現在選單 3「顯示目前內參」。")
    return "已恢復出廠校正"


def list_backups(serial: str, directory: Path | None = None) -> list[Path]:
    """這台相機的備份檔,新的在前 (檔名含日期時間)。"""
    directory = directory or BACKUP_DIR
    return sorted(directory.glob(f"calib_*_{serial}*.json"), key=lambda p: p.name, reverse=True)


def load_backup(path: Path, serial: str, table_len: int) -> dict:
    """讀備份並檢查格式、序號、長度;不對就丟 ToolError,不會寫進相機。"""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise ToolError(f"讀不到備份 {path.name}:{e}") from e
    if not isinstance(data, dict) or data.get("format") != "spoonfull-realsense-calib-backup/1":
        raise ToolError(f"{path.name} 不是本工具產生的備份檔。")
    table = data.get("table")
    if data.get("serial") != serial:
        raise ToolError(f"{path.name} 是序號 {data.get('serial')} 的相機的備份,不是這台 ({serial})。")
    if (not isinstance(table, list) or len(table) != table_len
            or not all(isinstance(b, int) and 0 <= b <= 255 for b in table)):
        raise ToolError(f"{path.name} 的校正表內容不正確 (長度或數值不符),不會寫入。")
    return data


FW_UPDATE_TIMEOUT_S = 600
FW_REENUMERATE_TIMEOUT_S = 60


def firmware_version_from_name(name: str) -> str:
    """官方檔名 Signed_Image_UVC_5_17_3_10.bin / D4XX_FW_Image-5.17.3.10.bin → "5.17.3.10";認不出來回傳空字串。"""
    m = re.search(r"(\d+)[._](\d+)[._](\d+)[._](\d+)", Path(name).name)
    return ".".join(m.groups()) if m else ""


def extract_firmware(path: Path, workdir: Path) -> Path:
    """接受 .bin 或官方 zip (內含一個 .bin 與說明文件)。zip 只取出那個 .bin,檔名自己決定 (不信任 zip 內的路徑)。"""
    import zipfile
    if path.suffix.lower() == ".bin":
        return path
    if path.suffix.lower() != ".zip":
        raise ToolError(f"{path.name} 不是 .bin 或 .zip 韌體檔。")
    try:
        with zipfile.ZipFile(path) as z:
            bins = [i for i in z.infolist() if i.filename.lower().endswith(".bin") and not i.is_dir()]
            if len(bins) != 1:
                raise ToolError(f"{path.name} 裡有 {len(bins)} 個 .bin,應該只有一個;請解壓後直接指定 .bin。")
            info = bins[0]
            if info.file_size > 64 * 1024 * 1024:
                raise ToolError(f"{info.filename} 大小不合理 ({info.file_size} bytes)。")
            out = workdir / (Path(info.filename).name or "firmware.bin")
            with z.open(info) as src, open(out, "wb") as dst:
                shutil.copyfileobj(src, dst)
    except zipfile.BadZipFile as e:
        raise ToolError(f"{path.name} 不是正確的 zip:{e}") from e
    return out


def _wait_for_camera(serial: str, timeout_s: float) -> Camera | None:
    """韌體更新後相機會重新啟動、重新列舉;等它回來。"""
    end = time.monotonic() + timeout_s
    while time.monotonic() < end:
        try:
            return open_camera(serial)
        except (ToolError, RuntimeError):
            time.sleep(2)
    return None


def run_firmware_update(input_fn: Callable[[str], str] = input) -> str:
    """用官方 rs-fw-update 更新相機韌體。

    rs-fw-update 放在新的 session 執行:終端機的 Ctrl-C / SSH 斷線不會傳給它,
    燒錄中途被中斷可能讓相機無法開機。本程式在燒錄期間也延後處理這些信號。
    """
    _title("更新相機韌體")
    tool = shutil.which("rs-fw-update")
    if not tool:
        raise ToolError("找不到 rs-fw-update;請先用 build-librealsense.sh 安裝 librealsense。")
    cam = open_camera()
    print(f"相機:{cam.name}  序號 {cam.serial}  目前韌體 {cam.firmware}")
    print(f"韌體請從官網下載 (需同意授權條款):{FIRMWARE_PAGE_URL}")
    text = input_fn("韌體檔路徑 (.zip 或 .bin,直接按 Enter 取消):").strip().strip("'\"")
    if not text:
        return "取消"
    src = Path(text).expanduser()
    if not src.is_file():
        raise ToolError(f"找不到檔案:{src}")
    import tempfile
    with tempfile.TemporaryDirectory(prefix="rs-fw-") as tmp:
        fw = extract_firmware(src, Path(tmp))
        target = firmware_version_from_name(fw.name) or firmware_version_from_name(src.name)
        print(f"韌體檔:{fw.name}" + (f" (版本 {target})" if target else ""))
        if target and _version_tuple(target) == _version_tuple(cam.firmware):
            print("相機已經是這個版本,不需要更新。")
            return "不需要更新"
        if target and _version_tuple(target) < _version_tuple(cam.firmware):
            print(f"注意:這是比目前 ({cam.firmware}) 舊的版本 (降級)。")
        backup = backup_calibration(cam.auto, cam.serial)
        print(f"已先備份目前的校正表:{backup}")
        print("更新約需 1～2 分鐘。過程中不可拔 USB 線、不可斷電、不可關機。")
        if not ask_yes_no("確定要更新韌體嗎?(y/N)", input_fn=input_fn):
            return "取消"
        serial, old_fw = cam.serial, cam.firmware
        del cam  # 釋放相機,rs-fw-update 才開得到
        cmd = [tool, "-f", str(fw), "-s", serial]
        print("執行:" + " ".join(cmd))
        with signals_deferred():
            try:
                r = subprocess.run(cmd, start_new_session=True, timeout=FW_UPDATE_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                raise ToolError(f"rs-fw-update 超過 {FW_UPDATE_TIMEOUT_S} 秒沒有結束。請不要拔線,"
                                "等相機指示燈穩定後執行 rs-fw-update -l 查看狀態。") from None
    # 不能只看結束碼:rs-fw-update 2.59.1 實測會在印出「successfully updated」之後才 segfault (-11),
    # 所以以「相機重新出現後回報的版本」為準
    print("等待相機重新啟動…")
    new = _wait_for_camera(serial, FW_REENUMERATE_TIMEOUT_S)
    rescue = "相機若進入 recovery 模式,用 rs-fw-update -r -f <韌體檔> 救回。"
    if new is None:
        raise ToolError(f"rs-fw-update 結束碼 {r.returncode},而且相機沒有重新出現。請拔插 USB 後執行 "
                        f"rs-enumerate-devices 確認;{rescue}")
    print(f"目前韌體:{new.firmware}")
    updated = (_version_tuple(new.firmware) == _version_tuple(target) if target
               else _version_tuple(new.firmware) != _version_tuple(old_fw))
    if not updated:
        raise ToolError(f"更新沒有成功 (rs-fw-update 結束碼 {r.returncode},相機仍是 {new.firmware})。"
                        f"請看上面的訊息;{rescue}")
    if r.returncode != 0:
        print(f"(rs-fw-update 結束碼 {r.returncode},但相機已確認是新版本,更新成功。)")
    print("建議接著做一次 Health check (選單 4) 確認深度品質。")
    return f"韌體 {old_fw} → {new.firmware}"


def run_restore_backup(input_fn: Callable[[str], str] = input) -> str:
    _title("從備份還原校正表")
    cam = open_camera()
    backups = list_backups(cam.serial)
    if not backups:
        print(f"{BACKUP_DIR} 裡沒有這台相機 (序號 {cam.serial}) 的備份。")
        return "沒有備份"
    shown = backups[:15]
    print(f"這台相機 (序號 {cam.serial}) 的備份,新的在前:")
    for i, p in enumerate(shown, 1):
        print(f"  {i:2d}) {p.name}")
    if len(backups) > len(shown):
        print(f"  (另有 {len(backups) - len(shown)} 個較舊的備份未列出)")
    ans = input_fn("要還原哪一個?輸入編號 (直接按 Enter 取消):").strip()
    if not ans:
        return "取消"
    if not ans.isdigit() or not 1 <= int(ans) <= len(shown):
        print(f"無效的編號「{ans}」。")
        return "取消"
    path = shown[int(ans) - 1]
    current = list(cam.auto.get_calibration_table())
    data = load_backup(path, cam.serial, len(current))
    if data["table"] == current:
        print("這個備份和相機目前的校正表完全一樣,不需要還原。")
        return "不需要還原"
    print(f"將把相機的深度校正改成 {path.name} (建立於 {data.get('created', '?')}) 的內容。")
    print("寫入前會先備份目前的校正表。")
    if not ask_yes_no("確定要寫入相機嗎?(y/N)", input_fn=input_fn):
        print("已取消。")
        return "取消"
    backup = write_to_camera(cam.auto, data["table"], current, cam.serial)
    print(f"已寫入相機。寫入前的校正表備份在:{backup}")
    _report_flash(cam.serial, expected=data["table"])
    print("新的內參要等相機重新連線 (拔插 USB 或重開機) 後,才會出現在選單 3「顯示目前內參」。")
    return f"已還原 {path.name}"


# 進入選單時先列出來,讓使用者一次把要印的、要準備的東西備齊
MATERIALS: list[tuple[str, list[str]]] = [
    ("要列印的 (一次印好)", [
        f"深度校正標靶 Calibration_Target_v1.pdf (官方):{TARGET_PDF_URL}",
        "    用於 Health check / On-Chip / Focal Length / Tare",
        f"    PDF 是 {TARGET_PAPER},不是 A4。用 A4 紙印也可以:選「實際大小」,",
        "    上下各裁掉約 3 mm 背景,四個圓點不受影響;但不能讓印表機「縮小超出的頁面」(會縮成約 97%)",
        f"ChArUco 板 (A4 橫向,{CHARUCO_SQUARES[0]}x{CHARUCO_SQUARES[1]} 格、方格 {CHARUCO_SQUARE_MM:g} mm、"
        f"標記 {CHARUCO_MARKER_MM:g} mm):本工具產生,下面輸入 p 或選單 8",
        "    用於 RGB 內參",
    ]),
    ("列印方式 (兩張都一樣)", [
        "100% 縮放 (實際大小),不可選「符合頁面」",
        "霧面 (低反光) 紙,厚一點較好",
    ]),
    ("要準備的工具", [
        "平整硬板 2 塊 (比標靶大、不會彎) + 膠水或雙面膠:兩張標靶各貼一塊,不能翹曲",
        f"(選用) 尺:印完量一下深度標靶左右圓點中心間距是否為 {TARGET_DESIGN_MM[0]:g} mm,"
        "確認印表機沒有縮放;沒縮放就不用再量",
        "捲尺:Tare 要量相機到標靶平面的真實距離 (約 0.65～1.8 m)",
        "能把深度標靶立著固定的支架或牆面:Focal Length 放 0.8～1 m、Tare 放 0.65～1.8 m,校正中不能動",
        "RGB 內參不用支架:手持 ChArUco 板,距離 25～40 cm",
    ]),
]


def _print_materials() -> None:
    _title("相機校正所需材料")
    for heading, items in MATERIALS:
        print(f"{heading}:")
        for item in items:
            print(f"  {item}" if item.startswith("    ") else f"  [ ] {item}")


def show_targets(input_fn: Callable[[str], str] = input) -> str:
    _print_materials()
    print("\n參考資料:")
    print("  深度標靶:低對比紋理背景 + 四個模糊圓點。")
    print(f"  官方白皮書 (附錄 A 有標靶與列印說明):{WHITEPAPER_URL}")
    print("  印好後實測的數值,在執行對應的校正時輸入。")
    return "已顯示"


# ---------------------------------------------------------------- 引導模式
GUIDED_STEPS: list[tuple[str, str, Callable[..., str]]] = [
    ("Health check (校正前)", "先檢查目前的深度校正狀態,只檢查不寫入。", lambda f: run_health_check(f)),
    ("On-Chip 自我校正", "改善深度雜訊 (平面擬合 RMS)。用官方標靶或有紋理的平面。", lambda f: run_on_chip(f)),
    ("Focal Length 校正", "用官方標靶的四個圓點校正焦距,距離 0.8～1 m。", lambda f: run_focal_length(f)),
    ("Tare 校正", "用已知的真實距離校正絕對深度。", lambda f: run_tare(f)),
    ("RGB 內參校正", "用 ChArUco 板以 OpenCV 校正 RGB 內參與畸變,存檔不寫入相機。", lambda f: run_rgb_calibration(f)),
    ("深度對齊 RGB 校正 (UV map)", "目前尚未實作,會說明原因。", lambda f: run_uv_map(f)),
]  # 不另外做「校正後 health check」:每個深度校正結束時都已經量過校正後的 health


def run_guided(input_fn: Callable[[str], str] = input) -> str:
    global _guided_health
    _guided_health = {}
    try:
        return _run_guided_steps(input_fn)
    finally:
        _guided_health = None


def _run_guided_steps(input_fn: Callable[[str], str]) -> str:
    _title("完整校正流程 (引導模式)")
    print("依序:" + " → ".join(t for t, _, _ in GUIDED_STEPS))
    print("每個深度校正都會在校正前後量 health,同一份校正表的 health 會沿用,不重複量。")
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
            explain_camera_error(e)
            result, ok = f"失敗:{e}", False
        except KeyboardInterrupt:
            print("\n已中斷引導模式。")
            summary.append((title, "已中斷"))
            summary.extend((t, "未執行") for t, _, _ in GUIDED_STEPS[i:])
            break
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
    ("13", "顯示所需材料、標靶下載連結與列印方式", "show_targets"),
    ("14", "從備份還原校正表", "run_restore_backup"),
    ("15", "更新相機韌體 (rs-fw-update)", "run_firmware_update"),
    ("0", "離開", ""),
]


def main_menu(input_fn: Callable[[str], str] = input) -> int:
    _print_materials()
    try:
        ans = input_fn("\n準備好後按 Enter 進入選單;輸入 p 先產生 ChArUco 板 PDF;q 離開:").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return 0
    if ans == "q":
        return 0
    if ans == "p":
        try:
            run_generate_charuco_pdf(input_fn)
        except ToolError as e:
            print(f"\n錯誤:{e}")
        except KeyboardInterrupt:
            print("\n已中斷。")
        except Exception:  # noqa: BLE001 - 例如 cv2.error;印出後照樣進選單
            print("\n發生未預期的錯誤,詳細內容如下 (請回報):", file=sys.stderr)
            traceback.print_exc()
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
            print(f"無效的選項「{choice}」,請輸入 0～{max(int(k) for k, _, _ in MENU)}。")
            continue
        try:
            handler(input_fn)
        except ToolError as e:
            print(f"\n錯誤:{e}")
        except KeyboardInterrupt:
            print("\n已中斷,回到主選單。")
        except RuntimeError as e:
            print(f"\n相機操作失敗:{e}")
            explain_camera_error(e)
        except Exception:  # noqa: BLE001 - 印出完整錯誤後回到選單,不讓維護工具整個掛掉
            print("\n發生未預期的錯誤,詳細內容如下 (請回報):", file=sys.stderr)
            traceback.print_exc()
        try:
            input_fn("\n按 Enter 回到主選單…")
        except (EOFError, KeyboardInterrupt):
            return 0


if __name__ == "__main__":
    install_exit_signals()
    sys.exit(main_menu())

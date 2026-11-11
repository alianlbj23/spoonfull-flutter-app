#!/usr/bin/env python3
"""Spoonfull 機台管理工具:安裝、開關 App、相機、HX711 秤,全部用互動選單,不用記指令。

用法 (一般使用者執行;需要權限的步驟程式會自己呼叫 sudo):
  python3 deploy/spoonfull.py              在專案資料夾
  python3 /opt/spoonfull/spoonfull.py      安裝後,任何地方都可以

這支取代了舊的 install-device.sh、hx711_bridge.py、spoonfull-kiosk.service、
spoonfull-hx711.service、99-spoonfull-hardware.rules (服務與 udev 規則的內容在下面的範本)。
仍然是獨立檔案的:
  spoonfull-recover.sh   自動更新的退路,kiosk 服務每次啟動 App 前執行 (CI 也會打包它)
  realsense_bridge.py    App 拍照時呼叫
  realsense_tool.py      相機校正 (從選單「相機」進入)
  build-librealsense.sh  編譯相機驅動 (從選單「相機」進入)

給 systemd 用、不需要手動執行的模式:
  spoonfull.py hx711-bridge [--port 9100] [--print] [--fake]
  HX711 load cell → TCP 文字串流,每行 `ST,GS, 123.4 g` / `US,GS, 120.1 g` (App 的 LineScaleReader 解析)。
  腳位與校正值存在 ~/.config/spoonfull/hx711.json (選單「HX711 秤」設定)。

HX711 接線 (預設 BCM 編號,Jetson.GPIO 亦相容):DT → GPIO 5、SCK → GPIO 6、VCC → 3.3V / 5V、GND → GND
  Raspberry Pi 5:sudo apt install python3-lgpio && pip3 install rpi-lgpio   (RPi.GPIO 相容層)
  Raspberry Pi 4:sudo apt install python3-rpi.gpio
  Jetson:已內建 Jetson.GPIO

測試 (不需要硬體):python3 -m unittest discover -s deploy/tests -v
"""
from __future__ import annotations

import argparse
import getpass
import json
import math
import os
import platform
import re
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from pathlib import Path
from typing import Any, Callable

HERE = Path(__file__).resolve().parent
INSTALL_DIR = Path("/opt/spoonfull")
APP_BINARY = INSTALL_DIR / "spoonfull_flutter_app"
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "spoonfull"
HX711_CONFIG = CONFIG_DIR / "hx711.json"
RELEASE_URL = os.environ.get(
    "SPOONFULL_RELEASE_URL", "https://github.com/alianlbj23/spoonfull-flutter-app/releases/latest/download")

KIOSK = "spoonfull-kiosk"
HX711_SVC = "spoonfull-hx711"
UDEV_PATH = "/etc/udev/rules.d/99-spoonfull-hardware.rules"
UNIT_DIR = "/etc/systemd/system"
HX711_UNIT_PATH = Path(f"{UNIT_DIR}/spoonfull-hx711.service")
HX711_PORT = 9100

# 安裝時從專案 deploy/ 複製到 /opt/spoonfull 的檔案
SUPPORT_FILES = ("spoonfull-recover.sh", "realsense_bridge.py", "realsense_tool.py", "spoonfull.py")

APT_PACKAGES = ["python3", "python3-numpy", "python3-opencv", "libsecret-1-0", "libjsoncpp25", "libgtk-3-0",
                "libusb-1.0-0", "systemd-timesyncd", "curl"]
# 舊版系統沒有 libjsoncpp25 / systemd-timesyncd 套件名稱時改用這組
APT_FALLBACK = ["python3", "python3-numpy", "python3-opencv", "libsecret-1-0", "libgtk-3-0", "libusb-1.0-0",
                "curl"]

CMD_TIMEOUT_S = 600  # 一般系統指令 (apt 可能較久)
DOWNLOAD_TIMEOUT_S = 900

# ---------------------------------------------------------------- 範本
UDEV_RULES = """\
# Spoonfull 機台硬體權限 (ARCHITECTURE.md §5.1)
# USB HID 秤 (USB HID POS Scale,usage page 0x8D):讓 App 可以直接讀 /dev/hidrawN
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", MODE="0660", GROUP="plugdev", TAG+="uaccess"
# 序列埠秤 / HX711 微控制器 (USB serial)
KERNEL=="ttyUSB*", MODE="0660", GROUP="dialout"
KERNEL=="ttyACM*", MODE="0660", GROUP="dialout"
# Intel RealSense D435f (USB,vendor 8086、D400 系列 product 0bxx):realsense_bridge.py 用 libusb 直接開。
# deploy/build-librealsense.sh 另外會裝 librealsense 自己的 99-realsense-libusb.rules,這條是保險。
SUBSYSTEM=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b[0-9a-f][0-9a-f]", MODE="0660", GROUP="plugdev", TAG+="uaccess"
"""  # noqa: E501

KIOSK_UNIT = """\
[Unit]
Description=Spoonfull meal cart kiosk (Flutter app, fullscreen)
After=graphical.target network-online.target
Wants=network-online.target

[Service]
User=__USER__
# 讓 App 看到桌面 session (X11 或 Wayland)。Pi OS / Ubuntu Desktop 的自動登入 session 會建立這些。
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=WAYLAND_DISPLAY=wayland-0
# 全螢幕、無標題列、隱藏游標 (linux/runner/my_application.cc)
Environment=SPOONFULL_KIOSK=1
# 自動更新後 App 會直接結束,由下面的 Restart=always 帶起新版 (lib/services/update_service.dart)
Environment=SPOONFULL_SUPERVISED=1
# 沒有 keyring 時 flutter_secure_storage 會失敗,App 會自動退回檔案儲存 (lib/data/local/secure_token_storage.dart)
WorkingDirectory=/opt/spoonfull
# 自動更新的退路:上次更新被中斷,或新版連續啟動失敗,就換回上一版 (deploy/spoonfull-recover.sh)
ExecStartPre=-/bin/sh /opt/spoonfull/spoonfull-recover.sh /opt/spoonfull
ExecStartPre=/bin/sh -c 'for i in $(seq 1 30); do [ -S "/tmp/.X11-unix/X0" ] && exit 0; sleep 1; done; exit 0'
ExecStart=/opt/spoonfull/spoonfull_flutter_app
Restart=always
RestartSec=3

[Install]
WantedBy=graphical.target
"""

HX711_UNIT = """\
[Unit]
Description=Spoonfull HX711 load-cell bridge (GPIO -> TCP 127.0.0.1:9100)
After=multi-user.target

[Service]
User=__USER__
ExecStart=/usr/bin/python3 /opt/spoonfull/spoonfull.py hx711-bridge --port 9100
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
"""

_USER_RE = re.compile(r"[a-z_][a-z0-9_-]{0,31}")  # 用 fullmatch:「$」會放過結尾的換行


class ToolError(Exception):
    """可預期的錯誤,訊息直接顯示給使用者。"""


def render_unit(template: str, user: str) -> str:
    if not _USER_RE.fullmatch(user or ""):
        raise ToolError(f"帳號名稱「{user!r}」不合法 (只能用小寫英文、數字、底線、減號)。")
    return template.replace("__USER__", user)


def user_exists(user: str) -> bool:
    try:
        import pwd
    except ImportError:  # Windows 開發機沒有 pwd;機台 (Linux) 一定有
        return True
    try:
        pwd.getpwnam(user)
    except KeyError:
        return False
    return True


def unit_user(path: Path) -> str | None:
    """讀已安裝的 systemd 服務檔裡的 User=;檔案不存在時回傳 None。"""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except OSError as e:
        raise ToolError(f"讀不到 {path}:{e}") from e
    m = re.search(r"^User=(\S+)$", text, re.M)
    return m.group(1) if m else None


# ---------------------------------------------------------------- 輸入小工具
def ask_yes_no(question: str, default: bool = False, input_fn: Callable[[str], str] = input) -> bool:
    hint = "(Y/n)" if default else "(y/N)"
    while True:
        ans = input_fn(f"{question} {hint} ").strip().lower()
        if not ans:
            return default
        if ans in ("y", "yes"):
            return True
        if ans in ("n", "no"):
            return False
        print("請輸入 y 或 n。")


def ask_number(prompt: str, lo: float, hi: float, default: float | None = None,
               input_fn: Callable[[str], str] = input) -> float | None:
    """空白:有預設值就用預設值,沒有就回傳 None (取消)。"""
    hint = f" (Enter = {default:g})" if default is not None else " (Enter 取消)"
    while True:
        text = input_fn(f"{prompt}{hint}:").strip()
        if not text:
            return default
        try:
            value = float(text)
        except ValueError:
            print(f"「{text}」不是數字。")
            continue
        if not math.isfinite(value) or not lo <= value <= hi:
            print(f"請輸入 {lo:g}～{hi:g} 之間的數字。")
            continue
        return value


def _title(text: str) -> None:
    print(f"\n==== {text} ====")


# ---------------------------------------------------------------- 執行系統指令
class Runner:
    """執行系統指令 (不經過 shell);sudo=True 且不是 root 時自動加 sudo。"""

    def __init__(self, euid: int | None = None):
        if euid is None:
            euid = os.geteuid() if hasattr(os, "geteuid") else 1000  # Windows 開發機沒有 geteuid
        self.euid = euid

    def command(self, args: list[str], sudo: bool = False) -> list[str]:
        return (["sudo"] if sudo and self.euid != 0 else []) + list(args)

    def run(self, args: list[str], sudo: bool = False, check: bool = True,
            timeout: float | None = CMD_TIMEOUT_S) -> bool:
        cmd = self.command(args, sudo)
        print("$ " + " ".join(cmd), flush=True)
        try:
            result = subprocess.run(cmd, timeout=timeout)
        except FileNotFoundError as e:
            raise ToolError(f"找不到程式 {cmd[0]};這個功能只能在機台 (Linux) 上使用。") from e
        except subprocess.TimeoutExpired as e:
            msg = f"指令超過 {timeout:g} 秒沒有完成:{' '.join(cmd)}"
            if check:
                raise ToolError(msg) from e
            print(f"   {msg}")
            return False
        if result.returncode != 0:
            if check:
                raise ToolError(f"指令失敗 (結束碼 {result.returncode}):{' '.join(cmd)}")
            return False
        return True

    def capture(self, args: list[str], timeout: float = 15) -> str:
        """讀取指令輸出 (查狀態用);程式不存在或失敗時回傳空字串。"""
        try:
            r = subprocess.run(list(args), capture_output=True, text=True, timeout=timeout)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return ""
        return r.stdout.strip()

    def install_text(self, content: str, dest: str, mode: str = "644") -> None:
        """把文字寫成系統檔案 (例如 /etc/systemd/system/*.service)。"""
        fd, tmp = tempfile.mkstemp(prefix="spoonfull-")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(content)
            self.run(["install", "-m", mode, tmp, dest], sudo=True)
        finally:
            os.unlink(tmp)


def service_state(runner: Runner, name: str) -> tuple[str, str]:
    """(active 狀態, enabled 狀態)。服務沒安裝或 systemctl 不存在時 enabled 是空字串。"""
    enabled = runner.capture(["systemctl", "is-enabled", f"{name}.service"])
    if enabled == "not-found":  # 較新的 systemd 對不存在的服務會在 stdout 印 not-found
        enabled = ""
    return runner.capture(["systemctl", "is-active", f"{name}.service"]), enabled


# ---------------------------------------------------------------- HX711
class HX711:
    """最小 HX711 驅動 (channel A, gain 128)。"""

    def __init__(self, dout: int, sck: int):
        import RPi.GPIO as GPIO  # Jetson.GPIO / rpi-lgpio 都提供這個模組名稱

        self.GPIO = GPIO
        self.dout = dout
        self.sck = sck
        GPIO.setwarnings(False)
        GPIO.setmode(GPIO.BCM)
        GPIO.setup(self.sck, GPIO.OUT)
        GPIO.setup(self.dout, GPIO.IN)
        GPIO.output(self.sck, False)

    def _ready(self) -> bool:
        return self.GPIO.input(self.dout) == 0

    def read_raw(self, timeout: float = 1.0) -> int | None:
        deadline = time.monotonic() + timeout
        while not self._ready():
            if time.monotonic() > deadline:
                return None
            time.sleep(0.001)
        value = 0
        for _ in range(24):
            self.GPIO.output(self.sck, True)
            value = (value << 1) | self.GPIO.input(self.dout)
            self.GPIO.output(self.sck, False)
        # 第 25 個脈衝:下次維持 channel A gain 128
        self.GPIO.output(self.sck, True)
        self.GPIO.output(self.sck, False)
        if value & 0x800000:  # 24-bit 二補數
            value -= 0x1000000
        return value

    def read_median(self, n: int = 5) -> int | None:
        samples = [v for v in (self.read_raw() for _ in range(n)) if v is not None]
        return int(statistics.median(samples)) if samples else None

    def close(self) -> None:
        self.GPIO.cleanup((self.dout, self.sck))


class FakeHX711:
    """沒有 GPIO 時 (在電腦上測試) 產生假資料:約 420 g,開頭幾筆會晃動。"""

    def __init__(self, grams: float = 420.0):
        self.grams = grams
        self.t = 0

    def read_median(self, n: int = 5) -> int:
        self.t += 1
        wobble = 20 if self.t < 10 else 0
        return int(8000 + self.grams * 100 + (wobble if self.t % 2 else -wobble))

    def close(self) -> None:
        pass


FAKE_CONFIG = {"offset": 8000, "scale": 100.0}


def open_hx711(cfg: dict):
    try:
        return HX711(int(cfg["dout"]), int(cfg["sck"]))
    except Exception as e:  # noqa: BLE001 - GPIO 函式庫的例外型別各家不同,統一轉成說明
        raise ToolError(
            f"無法初始化 GPIO:{e}\n"
            "請確認已安裝 RPi.GPIO / Jetson.GPIO / rpi-lgpio (見本檔開頭說明),或用「假資料測試」。"
        ) from e


def load_hx711_config() -> dict:
    cfg: dict[str, Any] = {"offset": 0, "scale": 1.0, "dout": 5, "sck": 6}
    if HX711_CONFIG.exists():
        try:
            saved = json.loads(HX711_CONFIG.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as e:
            raise ToolError(f"HX711 設定檔 {HX711_CONFIG} 無法讀取:{e}") from e
        if not isinstance(saved, dict):
            raise ToolError(f"HX711 設定檔 {HX711_CONFIG} 格式不正確。")
        cfg.update(saved)
    try:
        scale = float(cfg["scale"])
        float(cfg["offset"])
        pins = int(cfg["dout"]), int(cfg["sck"])
    except (TypeError, ValueError) as e:
        raise ToolError(f"HX711 設定檔 {HX711_CONFIG} 數值不正確:{e}") from e
    if not math.isfinite(scale) or scale == 0 or not all(0 <= p <= 40 for p in pins):
        raise ToolError(f"HX711 設定檔 {HX711_CONFIG} 數值不正確 (scale 不可為 0,腳位 0～40)。")
    return cfg


def save_hx711_config(cfg: dict) -> None:
    try:
        HX711_CONFIG.parent.mkdir(parents=True, exist_ok=True)
        tmp = HX711_CONFIG.with_suffix(".json.tmp")
        with open(tmp, "w", encoding="utf-8") as f:  # fsync:斷電後不會只剩空檔讓服務起不來
            f.write(json.dumps(cfg, indent=2))
            f.flush()
            os.fsync(f.fileno())
        tmp.replace(HX711_CONFIG)
    except OSError as e:
        raise ToolError(f"寫入 {HX711_CONFIG} 失敗:{e}") from e


def calibrate_hx711(sensor, known_grams: float, cfg: dict, input_fn: Callable[[str], str] = input) -> dict:
    input_fn("秤上保持淨空,按 Enter 讀取零點…")
    offset = sensor.read_median(15)
    input_fn(f"放上 {known_grams:g} g 的砝碼,按 Enter…")
    loaded = sensor.read_median(15)
    if offset is None or loaded is None:
        raise ToolError("讀不到 HX711 的數值,請檢查接線 (DT / SCK / 電源)。")
    if loaded == offset:
        raise ToolError("放上砝碼前後讀數沒有變化,請檢查 load cell 接線。")
    new = dict(cfg)
    new.update({"offset": offset, "scale": (loaded - offset) / known_grams})
    save_hx711_config(new)
    print(f"offset={offset} scale={new['scale']:.4f} counts/g → 已寫入 {HX711_CONFIG}")
    return new


def format_reading(grams: float, stable: bool) -> str:
    """App 的 LineScaleReader 依這個格式解析,不要改。"""
    return f"{'ST' if stable else 'US'},GS,{grams:8.1f} g"


def is_stable(recent: list[float], stable_g: float) -> bool:
    return len(recent) >= 5 and (max(recent[-5:]) - min(recent[-5:])) <= stable_g


def bridge_loop(sensor, cfg: dict, send: Callable[[str], None], period: float, stable_g: float,
                iterations: int | None = None, sleep: Callable[[float], None] = time.sleep) -> None:
    recent: list[float] = []
    n = 0
    while iterations is None or n < iterations:
        n += 1
        raw = sensor.read_median(5)
        if raw is None:
            send("ERR,HX711 not ready")
            sleep(period)
            continue
        grams = (raw - float(cfg["offset"])) / float(cfg["scale"])
        recent.append(grams)
        del recent[:-5]
        send(format_reading(grams, is_stable(recent, stable_g)))
        sleep(period)


class Broadcaster:
    def __init__(self, host: str, port: int):
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind((host, port))
        self.server.listen(4)
        self.clients: list[socket.socket] = []
        self.lock = threading.Lock()
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self) -> None:
        while True:
            conn, _ = self.server.accept()
            conn.settimeout(2.0)  # 卡住的 client 不能拖住整個 bridge
            with self.lock:
                self.clients.append(conn)

    def send(self, line: str) -> None:
        data = (line + "\n").encode()
        with self.lock:
            for c in list(self.clients):
                try:
                    c.sendall(data)
                except OSError:
                    self.clients.remove(c)
                    c.close()


def run_hx711_bridge(argv: list[str]) -> int:
    """systemd (spoonfull-hx711.service) 用的模式:HX711 → TCP 文字串流。"""
    ap = argparse.ArgumentParser(prog="spoonfull.py hx711-bridge", description="HX711 → TCP 文字串流")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=HX711_PORT)
    ap.add_argument("--hz", type=float, default=10.0, help="每秒輸出次數")
    ap.add_argument("--stable-g", type=float, default=2.0, help="最近 5 筆差距在此以內視為穩定")
    ap.add_argument("--print", action="store_true", help="同時印到 stdout")
    ap.add_argument("--fake", action="store_true", help="不用 GPIO,輸出假資料")
    args = ap.parse_args(argv)
    try:
        cfg = FAKE_CONFIG | {"dout": 5, "sck": 6} if args.fake else load_hx711_config()
        sensor = FakeHX711() if args.fake else open_hx711(cfg)
    except ToolError as e:
        print(e, file=sys.stderr)
        return 1
    if not args.fake and float(cfg["scale"]) == 1.0:
        print("尚未校正 (scale=1.0),讀數將不是公克。請用選單「HX711 秤 → 校正」。", file=sys.stderr)
    try:
        bc = Broadcaster(args.host, args.port)
        print(f"HX711 bridge 於 {args.host}:{args.port},每行 'ST,GS, <g> g'", file=sys.stderr)

        def send(line: str) -> None:
            bc.send(line)
            if args.print:
                print(line, flush=True)

        bridge_loop(sensor, cfg, send, 1.0 / max(args.hz, 0.5), args.stable_g)
    except KeyboardInterrupt:
        return 0
    except OSError as e:
        print(f"HX711 bridge 無法啟動:{e}", file=sys.stderr)
        return 1
    finally:
        sensor.close()
    return 0


# ---------------------------------------------------------------- 安裝
def app_installed() -> bool:
    return os.access(APP_BINARY, os.X_OK)


def pyrealsense_available() -> bool:
    try:
        r = subprocess.run([sys.executable, "-c", "import pyrealsense2"], capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0


def _arch() -> str:
    machine = platform.machine().lower()
    if machine in ("aarch64", "arm64"):
        return "arm64"
    if machine in ("x86_64", "amd64"):
        return "x64"
    raise ToolError(f"不支援的 CPU 架構 {machine or '未知'}。")


def download_app(runner: Runner) -> None:
    url = f"{RELEASE_URL}/spoonfull-linux-{_arch()}.tar.gz"
    tmp = Path(tempfile.mkdtemp(prefix="spoonfull-dl-"))
    try:
        archive = tmp / "app.tar.gz"
        runner.run(["curl", "-fL", "--retry", "3", "--connect-timeout", "20", "-o", str(archive), url],
                   timeout=DOWNLOAD_TIMEOUT_S)
        runner.run(["tar", "-xzf", str(archive), "-C", str(tmp)])
        runner.run(["cp", "-a", f"{tmp}/bundle/.", f"{INSTALL_DIR.as_posix()}/"], sudo=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def install_device(runner: Runner, input_fn: Callable[[str], str] = input, current_user: str | None = None) -> str:
    """取代 install-device.sh:套件、udev、NTP、App、kiosk 服務、(選用) HX711 服務。"""
    _title("安裝 / 更新機台")
    missing = [n for n in SUPPORT_FILES if not (HERE / n).is_file()]
    if missing:
        raise ToolError(f"找不到 {', '.join(missing)}。請在專案資料夾執行:python3 deploy/spoonfull.py")

    default_user = current_user or getpass.getuser()
    user = input_fn(f"執行 App 的登入帳號 (Enter = {default_user}):").strip() or default_user
    render_unit(KIOSK_UNIT, user)  # 先驗證帳號名稱,任何系統變更之前
    if user == "root":
        raise ToolError("App 不能用 root 執行,請輸入一般登入帳號。")
    if not user_exists(user):
        raise ToolError(f"這台機器沒有帳號「{user}」。")
    autostart = ask_yes_no("開機自動全螢幕啟動 App?(正式上線的機台選 y)", input_fn=input_fn)
    with_hx711 = ask_yes_no("HX711 秤直接接在 GPIO 上嗎?(要的話會裝開機服務)", input_fn=input_fn)
    download = False
    if not app_installed():
        download = ask_yes_no(f"{INSTALL_DIR} 還沒有 App,要從 GitHub Release 下載最新版嗎?",
                              default=True, input_fn=input_fn)
    print(f"\n將安裝:帳號 {user};開機自動啟動 {'是' if autostart else '否'};HX711 服務 {'是' if with_hx711 else '否'}"
          + (";下載 App" if download else ""))
    if not ask_yes_no("開始安裝?", default=True, input_fn=input_fn):
        return "取消"

    print("\n== 1/5 套件")
    # apt 不設 timeout:被逾時砍掉只會殺到 sudo,背後的 dpkg 會留下鎖;慢的話使用者自己 Ctrl-C
    runner.run(["apt-get", "update"], sudo=True, timeout=None)
    if not runner.run(["apt-get", "install", "-y", *APT_PACKAGES], sudo=True, check=False, timeout=None):
        runner.run(["apt-get", "install", "-y", *APT_FALLBACK], sudo=True, timeout=None)
    if not pyrealsense_available():
        print("   注意:找不到 pyrealsense2。RealSense D435f 需要它:選單「相機 → 編譯 / 安裝相機驅動」"
              "(約 30–45 分鐘),或 sudo dpkg -i 之前機台編好的 librealsense2-*.deb。")

    print("\n== 2/5 裝置權限 (udev)")
    runner.install_text(UDEV_RULES, UDEV_PATH)
    if not runner.run(["usermod", "-aG", "video,dialout,plugdev", user], sudo=True, check=False):
        runner.run(["usermod", "-aG", "video,dialout", user], sudo=True)
    runner.run(["udevadm", "control", "--reload-rules"], sudo=True)
    runner.run(["udevadm", "trigger"], sudo=True)

    print("\n== 3/5 NTP 校時")
    if not runner.run(["timedatectl", "set-ntp", "true"], sudo=True, check=False):
        print("   注意:無法開啟 NTP 自動校時,capture_time 可能不準;請手動確認 timedatectl status。")

    print("\n== 4/5 App 與 kiosk 服務")
    runner.run(["mkdir", "-p", INSTALL_DIR.as_posix()], sudo=True)
    if download:
        download_app(runner)
    if not app_installed() and not download:
        print(f"   注意:{INSTALL_DIR} 裡還沒有 App。請把 bundle/* 複製進去 (見 docs/DEPLOY_NOTES.md §2)。")
    for name in SUPPORT_FILES:
        src, dest = HERE / name, INSTALL_DIR / name
        if src.resolve() == dest.resolve():
            continue  # 正在執行 /opt/spoonfull 裡的這份,不用自己複製自己
        runner.run(["install", "-m", "755", str(src), dest.as_posix()], sudo=True)
    # App 以這個帳號執行,自動更新要能替換這個資料夾裡的檔案 (lib/services/update_service.dart)
    runner.run(["chown", "-R", user, INSTALL_DIR.as_posix()], sudo=True)
    runner.install_text(render_unit(KIOSK_UNIT, user), f"{UNIT_DIR}/{KIOSK}.service")
    runner.run(["systemctl", "daemon-reload"], sudo=True)
    if autostart:
        runner.run(["systemctl", "enable", f"{KIOSK}.service"], sudo=True)
    else:
        # 之前裝過且 enable 的機台一併關掉,避免一登入就跳出 App
        runner.run(["systemctl", "disable", "--now", f"{KIOSK}.service"], sudo=True, check=False)

    if with_hx711:
        print("\n== 5/5 HX711 GPIO bridge")
        runner.install_text(render_unit(HX711_UNIT, user), f"{UNIT_DIR}/{HX711_SVC}.service")
        runner.run(["systemctl", "daemon-reload"], sudo=True)
        runner.run(["systemctl", "enable", "--now", f"{HX711_SVC}.service"], sudo=True)
    else:
        print("\n== 5/5 (略過 HX711 bridge)")

    print("\n完成。")
    print(f"請重新登入 {user} 讓群組 (plugdev / video / dialout) 生效。")
    print("開 App:主選單「開啟 App」。相機:主選單「相機 → 偵測相機」應印出序號。")
    if with_hx711:
        print("HX711:服務已啟動;校正後讀數才是公克。再到 App 硬體設定選「HX711 (GPIO bridge)」,位址 127.0.0.1:9100。")
        if user != getpass.getuser():
            print(f"HX711 服務以 {user} 執行,請用 {user} 登入後再到選單「HX711 秤 → 校正」。")
        elif ask_yes_no("要現在校正 HX711 嗎?", input_fn=input_fn):
            hx711_calibrate(runner, input_fn)
    return "安裝完成"


# ---------------------------------------------------------------- App 開關
def start_app(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    runner.run(["systemctl", "start", f"{KIOSK}.service"], sudo=True)
    return "已開啟 App"


def stop_app(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    runner.run(["systemctl", "stop", f"{KIOSK}.service"], sudo=True)
    return "已關閉 App"


def toggle_autostart(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    _, enabled = service_state(runner, KIOSK)
    if enabled == "enabled":
        if ask_yes_no("目前開機會自動啟動 App。要關閉自動啟動嗎?", input_fn=input_fn):
            runner.run(["systemctl", "disable", f"{KIOSK}.service"], sudo=True)
            return "已關閉開機自動啟動"
    elif ask_yes_no("目前開機不會自動啟動 App。要開啟自動啟動嗎?", input_fn=input_fn):
        runner.run(["systemctl", "enable", f"{KIOSK}.service"], sudo=True)
        return "已開啟開機自動啟動"
    return "未變更"


def show_app_status(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    _title("App 狀態與 log")
    runner.run(["systemctl", "status", f"{KIOSK}.service", "--no-pager"], check=False)
    runner.run(["journalctl", "-u", f"{KIOSK}.service", "-n", "50", "--no-pager"], sudo=True, check=False)
    print("App 自己的紀錄檔:~/.local/share/com.example.spoonfull_flutter_app/logs/spoonfull.log")
    if ask_yes_no("要持續看新的 log 嗎?(Ctrl-C 結束)", input_fn=input_fn):
        try:
            runner.run(["journalctl", "-u", f"{KIOSK}.service", "-f"], sudo=True, check=False, timeout=None)
        except KeyboardInterrupt:
            print()
    return "已顯示"


def restore_previous_app(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    """執行 spoonfull-recover.sh (自動更新的退路)。它只在更新中斷或新版還沒確認正常時才會換回舊版。"""
    _title("還原上一版 App")
    script = INSTALL_DIR / "spoonfull-recover.sh"
    if not script.is_file():
        raise ToolError(f"找不到 {script},請先執行「安裝 / 更新機台」。")
    markers = [p for p in (".update-in-progress", ".update-pending") if (INSTALL_DIR / p).exists()]
    has_old = any(INSTALL_DIR.rglob("*.spoonfull-old"))
    if not markers or not has_old:
        print("目前沒有「更新中斷」或「新版尚未確認」的紀錄,沒有可以還原的舊版。")
        print("(新版順利跑滿 60 秒後舊檔就會刪除;之後只能等 GitHub 推出修正版自動更新。)")
        return "沒有可還原的版本"
    print(f"偵測到 {', '.join(markers)},可以換回上一版。會先關閉 App。")
    if not ask_yes_no("確定要還原嗎?", input_fn=input_fn):
        return "取消"
    stop_app(runner)
    pending = INSTALL_DIR / ".update-pending"
    try:
        if pending.exists():
            # 和 recover.sh 第 4 次啟動的退回一樣:把這版記成壞版本,否則 App 之後又會自動裝回來
            # (lib/services/update_service.dart 只跳過 .update-bad-build 裡的版本)
            pending.replace(INSTALL_DIR / ".update-bad-build")
            (INSTALL_DIR / ".boot-count").unlink(missing_ok=True)
        # recover.sh 看到 .update-in-progress 就會把 *.spoonfull-old 換回來
        (INSTALL_DIR / ".update-in-progress").touch()
    except OSError as e:
        raise ToolError(f"無法寫入 {INSTALL_DIR} 的更新紀錄:{e}") from e
    runner.run(["sh", script.as_posix(), INSTALL_DIR.as_posix()])
    if ask_yes_no("已還原。要現在開啟 App 嗎?", default=True, input_fn=input_fn):
        start_app(runner)
    return "已還原上一版"


# ---------------------------------------------------------------- 相機
def _bridge_path() -> Path:
    for p in (HERE / "realsense_bridge.py", INSTALL_DIR / "realsense_bridge.py"):
        if p.is_file():
            return p
    raise ToolError("找不到 realsense_bridge.py,請先執行「安裝 / 更新機台」。")


def _release_camera(runner: Runner, input_fn: Callable[[str], str]) -> bool:
    """App 開著會占用相機;問要不要先關。回傳是否有關掉 (結束後要不要開回來)。"""
    if service_state(runner, KIOSK)[0] != "active":
        return False
    if ask_yes_no("App 正在執行,會占用相機。要先關閉 App 嗎?", default=True, input_fn=input_fn):
        stop_app(runner)
        return True
    return False


def camera_probe(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    _title("偵測相機")
    reopen = _release_camera(runner, input_fn)
    try:
        ok = runner.run([sys.executable, str(_bridge_path()), "--probe"], check=False, timeout=60)
    finally:
        if reopen:
            start_app(runner)
    if not ok:
        print("找不到相機:確認接在 USB 3 埠 (藍色)、rs-enumerate-devices 看得到、重新登入讓 plugdev 群組生效。")
    return "找到相機" if ok else "找不到相機"


def camera_test_shot(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    _title("拍一張測試照")
    out = Path(tempfile.mkdtemp(prefix="spoonfull-test-"))  # 0700 的新資料夾,不用 /tmp 下的固定檔名
    rgb, depth, meta = out / "test.jpg", out / "test_depth.png", out / "test.json"
    reopen = _release_camera(runner, input_fn)
    try:
        runner.run([sys.executable, str(_bridge_path()), "--once", str(rgb), str(depth), str(meta)], timeout=90)
    finally:
        if reopen:
            start_app(runner)
    try:
        stats = json.loads(meta.read_text(encoding="utf-8")).get("stats", {})
    except (OSError, json.JSONDecodeError) as e:
        raise ToolError(f"讀不到拍照結果 {meta}:{e}") from e
    print(f"已存:{rgb}、{depth}、{meta}")
    print(f"深度有效比例 {stats.get('valid_ratio')},中央距離 {stats.get('center_median_mm')} mm")
    return "已拍照"


def camera_calibration(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    tool = HERE / "realsense_tool.py"
    if not tool.is_file():
        raise ToolError("找不到 realsense_tool.py,請在專案資料夾執行或先「安裝 / 更新機台」。")
    reopen = _release_camera(runner, input_fn)
    try:
        if str(HERE) not in sys.path:
            sys.path.insert(0, str(HERE))
        import realsense_tool

        realsense_tool.main_menu(input_fn)
    finally:
        if reopen and ask_yes_no("校正結束,要把 App 開回來嗎?", default=True, input_fn=input_fn):
            start_app(runner)
    return "已離開相機校正"


def build_camera_driver(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    _title("編譯 / 安裝相機驅動 (librealsense + pyrealsense2)")
    script = HERE / "build-librealsense.sh"
    if not script.is_file():
        raise ToolError("找不到 build-librealsense.sh,請在專案資料夾執行:python3 deploy/spoonfull.py")
    print("第一台機台約 30–45 分鐘 (Pi 4 約 1–1.5 小時)。完成後會在 ~/librealsense/build/ 產生 .deb,")
    print("下一台機台可以直接 sudo dpkg -i librealsense2-*.deb,不用再編。")
    small = ask_yes_no("是記憶體 2 GB 以下的 Pi 嗎?(會減少同時編譯數,避免記憶體不足)", input_fn=input_fn)
    if not ask_yes_no("開始編譯?", default=True, input_fn=input_fn):
        return "取消"
    args = ["bash", str(script)] + (["--jobs", "2"] if small else [])
    runner.run(args, timeout=None)
    return "編譯完成"


# ---------------------------------------------------------------- HX711 選單
def _load_my_hx711_config() -> dict:
    """設定檔在「執行服務的帳號」的家目錄;用別的帳號登入時改的是另一份,服務讀不到,所以直接擋下。"""
    owner = unit_user(HX711_UNIT_PATH)
    me = getpass.getuser()
    if owner and owner != me:
        raise ToolError(f"HX711 服務以帳號 {owner} 執行,設定存在 {owner} 的 ~/.config/spoonfull/hx711.json;"
                        f"目前登入的是 {me}。請用 {owner} 登入後再操作。")
    return load_hx711_config()


def _with_hx711_service_paused(runner: Runner, input_fn: Callable[[str], str], action: Callable[[], Any]) -> Any:
    """開機服務在跑時會占用 GPIO;先停下來,做完再開回去。"""
    active = service_state(runner, HX711_SVC)[0] == "active"
    if active:
        if not ask_yes_no("HX711 開機服務正在使用 GPIO,要暫停它嗎?(做完會自動重新啟動)", default=True,
                          input_fn=input_fn):
            raise ToolError("服務占用 GPIO,無法讀取 HX711。")
        runner.run(["systemctl", "stop", f"{HX711_SVC}.service"], sudo=True)
    try:
        return action()
    finally:
        if active:
            runner.run(["systemctl", "start", f"{HX711_SVC}.service"], sudo=True)


def hx711_calibrate(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    _title("HX711 校正")
    cfg = _load_my_hx711_config()
    grams = ask_number("砝碼重量 (g)", 1, 100000, 500, input_fn)
    if grams is None:
        return "取消"

    def action():
        sensor = open_hx711(cfg)
        try:
            return calibrate_hx711(sensor, grams, cfg, input_fn)
        finally:
            sensor.close()

    _with_hx711_service_paused(runner, input_fn, action)
    return "已校正"


def _print_readings(sensor, cfg: dict) -> None:
    print("即時讀數 (Ctrl-C 結束):")
    try:
        bridge_loop(sensor, cfg, lambda line: print(line, flush=True), period=0.2, stable_g=2.0)
    except KeyboardInterrupt:
        print()


def hx711_watch(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    _title("HX711 即時讀數")
    cfg = _load_my_hx711_config()
    if float(cfg["scale"]) == 1.0:
        print("注意:還沒校正,讀數不是公克。")

    def action():
        sensor = open_hx711(cfg)
        try:
            _print_readings(sensor, cfg)
        finally:
            sensor.close()

    _with_hx711_service_paused(runner, input_fn, action)
    return "已顯示"


def hx711_pins(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    _title("HX711 腳位 (BCM 編號)")
    cfg = _load_my_hx711_config()
    dout = ask_number("DT 腳位", 0, 40, int(cfg["dout"]), input_fn)
    sck = ask_number("SCK 腳位", 0, 40, int(cfg["sck"]), input_fn)
    if dout is None or sck is None or int(dout) == int(sck):
        raise ToolError("DT 與 SCK 必須是兩個不同的腳位。")
    cfg.update({"dout": int(dout), "sck": int(sck)})
    save_hx711_config(cfg)
    if service_state(runner, HX711_SVC)[0] == "active":
        runner.run(["systemctl", "restart", f"{HX711_SVC}.service"], sudo=True)
    return f"DT={int(dout)} SCK={int(sck)}"


def hx711_service(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    _title("HX711 開機服務")
    active, enabled = service_state(runner, HX711_SVC)
    if not enabled:
        print("還沒安裝 HX711 開機服務。請到「安裝 / 更新機台」,在 HX711 問題回答 y。")
        return "未安裝"
    runner.run(["systemctl", "status", f"{HX711_SVC}.service", "--no-pager"], check=False)
    if ask_yes_no("要重新啟動服務嗎?", input_fn=input_fn):
        runner.run(["systemctl", "restart", f"{HX711_SVC}.service"], sudo=True)
    print(f"App 硬體設定選「HX711 (GPIO bridge)」,位址 127.0.0.1:{HX711_PORT}。")
    return f"服務 {active or '未知'}"


def hx711_fake(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    _title("HX711 假資料測試 (不用 GPIO)")
    _print_readings(FakeHX711(), FAKE_CONFIG)
    return "已顯示"


# ---------------------------------------------------------------- 選單
MenuItem = tuple[str, str, Callable[..., str]]


def run_menu(title: str, items: list[MenuItem], runner: Runner, input_fn: Callable[[str], str],
             status: Callable[[], str] | None = None) -> int:
    while True:
        _title(title)
        if status:
            print(status())
        for key, label, _ in items:
            print(f"  {key:>2}) {label}")
        print("   0) " + ("離開" if title.startswith("Spoonfull") else "回上一層"))
        try:
            choice = input_fn("請選擇:").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if choice == "0":
            return 0
        handler = next((fn for key, _, fn in items if key == choice), None)
        if handler is None:
            print(f"無效的選項「{choice}」。")
            continue
        try:
            handler(runner, input_fn)
        except ToolError as e:
            print(f"\n錯誤:{e}")
        except KeyboardInterrupt:
            print("\n已中斷。")
        except Exception:  # noqa: BLE001 - 印出完整錯誤後回到選單,不讓維護工具整個掛掉
            print("\n發生未預期的錯誤,詳細內容如下 (請回報):", file=sys.stderr)
            traceback.print_exc()
        try:
            input_fn("\n按 Enter 繼續…")
        except (EOFError, KeyboardInterrupt):
            return 0


def camera_menu(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    run_menu("相機 (RealSense D435f)", [
        ("1", "偵測相機 (序號、韌體、USB 版本)", camera_probe),
        ("2", "拍一張測試照 (看深度有效比例與距離)", camera_test_shot),
        ("3", "相機校正 (深度自我校正、RGB 內參、標靶 PDF…)", camera_calibration),
        ("4", "編譯 / 安裝相機驅動 (新機台第一次,約 30–45 分鐘)", build_camera_driver),
    ], runner, input_fn)
    return ""


def hx711_menu(runner: Runner, input_fn: Callable[[str], str] = input) -> str:
    def status() -> str:
        try:
            cfg = load_hx711_config()
            cal = "未校正" if float(cfg["scale"]) == 1.0 else f"已校正 (scale {float(cfg['scale']):.2f})"
            pins = f"DT={cfg['dout']} SCK={cfg['sck']}"
        except ToolError as e:
            cal, pins = f"設定檔有問題:{e}", "?"
        active, enabled = service_state(runner, HX711_SVC)
        svc = "未安裝" if not enabled else f"{active or '未知'} / 開機{'會' if enabled == 'enabled' else '不會'}啟動"
        return f"腳位 {pins};{cal};開機服務 {svc}"

    run_menu("HX711 秤 (直接接 GPIO)", [
        ("1", "校正 (放已知重量的砝碼)", hx711_calibrate),
        ("2", "看即時讀數", hx711_watch),
        ("3", "設定腳位", hx711_pins),
        ("4", "開機服務狀態 / 重新啟動", hx711_service),
        ("5", "假資料測試 (沒有 GPIO 的電腦)", hx711_fake),
    ], runner, input_fn, status)
    return ""


def main_menu(runner: Runner, input_fn: Callable[[str], str] = input) -> int:
    def status() -> str:
        active, enabled = service_state(runner, KIOSK)
        if not enabled:
            return "App 服務:尚未安裝 (先選 1)"
        return (f"App:{'執行中' if active == 'active' else '沒有執行'};"
                f"開機自動啟動:{'開' if enabled == 'enabled' else '關'}")

    return run_menu("Spoonfull 機台管理", [
        ("1", "安裝 / 更新機台 (新機台第一次,或要更新服務時)", install_device),
        ("2", "開啟 App", start_app),
        ("3", "關閉 App", stop_app),
        ("4", "開機自動啟動 App (開 / 關)", toggle_autostart),
        ("5", "查看 App 狀態與 log", show_app_status),
        ("6", "相機 (偵測、測試拍照、校正、編譯驅動)", camera_menu),
        ("7", "HX711 秤 (校正、讀數、腳位、開機服務)", hx711_menu),
        ("8", "還原上一版 App (自動更新出問題時)", restore_previous_app),
    ], runner, input_fn, status)


def main(argv: list[str] | None = None, euid: int | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["hx711-bridge"]:
        return run_hx711_bridge(argv[1:])
    runner = Runner(euid)
    if runner.euid == 0:
        print("請用一般使用者執行 (不要加 sudo):python3 deploy/spoonfull.py\n需要權限的步驟程式會自己呼叫 sudo。")
        return 1
    return main_menu(runner)


if __name__ == "__main__":
    sys.exit(main())

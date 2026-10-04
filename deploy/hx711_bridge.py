#!/usr/bin/env python3
"""HX711 load cell → 文字行 TCP 串流,給 Spoonfull App 的「HX711 (GPIO bridge)」秤模式讀取。

為什麼需要這支程式:HX711 用 GPIO bit-bang 讀取,需要微秒級時序,Dart 不適合直接做;
這支小服務在機台本機讀 HX711,每次讀數輸出一行 `ST,GS, 123.4 g` / `US,GS, 120.1 g`
(與序列埠秤相同格式,App 的 LineScaleReader 直接解析)。

接線 (預設 BCM 編號,Jetson.GPIO 亦相容):
  HX711 DT  → GPIO 5
  HX711 SCK → GPIO 6
  VCC → 3.3V / 5V (依模組),GND → GND

安裝相依:
  Raspberry Pi 5:  sudo apt install python3-lgpio && pip3 install rpi-lgpio   (RPi.GPIO 相容層)
  Raspberry Pi 4:  sudo apt install python3-rpi.gpio
  Jetson:          已內建 Jetson.GPIO (import RPi.GPIO 會對應到它)

校正 (放一個已知重量,例如 500 g 的砝碼):
  python3 hx711_bridge.py --calibrate 500
會把 offset / scale 寫到 ~/.config/spoonfull/hx711.json,之後直接執行即可。

測試:
  python3 hx711_bridge.py --print        # 直接印到終端
  nc 127.0.0.1 9100                      # 看 TCP 輸出
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import statistics
import sys
import threading
import time
from pathlib import Path

CONFIG_PATH = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "spoonfull" / "hx711.json"


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
    """沒有 GPIO 時 (在電腦上測試 bridge 本身) 產生假資料。"""

    def __init__(self, grams: float = 420.0):
        self.grams = grams
        self.t = 0

    def read_median(self, n: int = 5) -> int:
        self.t += 1
        wobble = 20 if self.t < 10 else 0
        return int(8000 + self.grams * 100 + (wobble if self.t % 2 else -wobble))

    def close(self) -> None:
        pass


def load_config() -> dict:
    if CONFIG_PATH.exists():
        return json.loads(CONFIG_PATH.read_text())
    return {"offset": 0, "scale": 1.0}


def save_config(cfg: dict) -> None:
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2))


def calibrate(sensor, known_grams: float) -> dict:
    input("秤上保持淨空,按 Enter 讀取零點…")
    offset = sensor.read_median(15)
    input(f"放上 {known_grams:g} g 的砝碼,按 Enter…")
    loaded = sensor.read_median(15)
    scale = (loaded - offset) / known_grams
    cfg = {"offset": offset, "scale": scale}
    save_config(cfg)
    print(f"offset={offset} scale={scale:.4f} counts/g → 已寫入 {CONFIG_PATH}")
    return cfg


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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dout", type=int, default=5, help="HX711 DT 腳位 (BCM)")
    ap.add_argument("--sck", type=int, default=6, help="HX711 SCK 腳位 (BCM)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9100)
    ap.add_argument("--hz", type=float, default=10.0, help="每秒輸出次數")
    ap.add_argument("--stable-g", type=float, default=2.0, help="最近 5 筆差距在此以內視為穩定")
    ap.add_argument("--calibrate", type=float, metavar="GRAMS", help="以已知重量校正後離開")
    ap.add_argument("--print", action="store_true", help="同時印到 stdout")
    ap.add_argument("--fake", action="store_true", help="不用 GPIO,輸出假資料 (電腦上測試)")
    args = ap.parse_args()

    try:
        sensor = FakeHX711() if args.fake else HX711(args.dout, args.sck)
    except Exception as e:  # noqa: BLE001
        print(f"無法初始化 GPIO: {e}\n請確認已安裝 RPi.GPIO / Jetson.GPIO / rpi-lgpio,或加 --fake 測試。", file=sys.stderr)
        return 1

    try:
        if args.calibrate:
            calibrate(sensor, args.calibrate)
            return 0

        cfg = load_config()
        if cfg.get("scale", 1.0) == 1.0 and not args.fake:
            print("尚未校正 (scale=1.0),讀數將不是公克。請先執行 --calibrate <已知重量>。", file=sys.stderr)
        if args.fake:
            cfg = {"offset": 8000, "scale": 100.0}

        bc = Broadcaster(args.host, args.port)
        print(f"HX711 bridge 於 {args.host}:{args.port},每行 'ST,GS, <g> g'", file=sys.stderr)
        recent: list[float] = []
        period = 1.0 / max(args.hz, 0.5)
        while True:
            raw = sensor.read_median(5)
            if raw is None:
                bc.send("ERR,HX711 not ready")
                time.sleep(period)
                continue
            grams = (raw - cfg["offset"]) / cfg["scale"]
            recent.append(grams)
            del recent[:-5]
            stable = len(recent) == 5 and (max(recent) - min(recent)) <= args.stable_g
            line = f"{'ST' if stable else 'US'},GS,{grams:8.1f} g"
            bc.send(line)
            if args.print:
                print(line, flush=True)
            time.sleep(period)
    except KeyboardInterrupt:
        return 0
    finally:
        sensor.close()


if __name__ == "__main__":
    sys.exit(main())

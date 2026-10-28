#!/usr/bin/env python3
"""Intel RealSense D435f → RGB-D 單張擷取,給 Spoonfull App 的「RealSense D435f」相機來源呼叫。

為什麼需要這支程式:D435f 走 UVC 只拿得到沒對齊的 Z16 原始深度,沒有內參、沒有 depth_scale;
要得到「對齊到彩色、同解析度、單位 mm」的深度圖必須經過 librealsense。App (Dart) 不直接
連結 librealsense,改由這支小程式 (pyrealsense2) 拍一張後寫成三個檔案,App 再讀檔上傳。

用法:
  realsense_bridge.py --probe                       偵測相機:stdout 印 JSON (序號 / 韌體 / USB),找不到回 2
  realsense_bridge.py --once RGB.jpg DEPTH.png META.json [--width 1280 --height 720] [--warmup 15]
                      [--serial <序號>] [--timeout 10]
  realsense_bridge.py --mock --once ...             沒有相機時產生合成餐盒 RGB-D (測 App 串接用)
  realsense_bridge.py --mock --probe                假裝找到一台相機

輸出格式 (ARCHITECTURE.md §5.1,PROGRESS.md):
  RGB   : JPEG (品質 92),彩色相機原始解析度
  DEPTH : 16-bit 灰階 PNG,單位 mm,已對齊到彩色影像、同解析度;0 = 沒有深度資料
  META  : JSON,含 serial、彩色內參 (fx fy ppx ppy)、depth_unit_m (PNG 數值 × 此值 = 公尺)

結束碼:0 成功;1 參數錯誤或 pyrealsense2 沒裝;2 找不到相機;3 擷取失敗 / 逾時。

安裝相依 (Raspberry Pi 5 / Pi OS Bookworm):
  sudo apt install python3-numpy python3-opencv      (或 python3-pil;兩者擇一即可)
  librealsense + pyrealsense2 要從原始碼建:見 deploy/build-librealsense.sh
Ubuntu x86_64 開發機:pip install pyrealsense2 numpy opencv-python-headless
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

FORMAT = "spoonfull-rgbd/1"
EXIT_USAGE = 1
EXIT_NO_DEVICE = 2
EXIT_CAPTURE = 3

# D435 系列 depth 最高 1280x720;color 可到 1920x1080,但對齊後深度會被放大,沒有意義。
SUPPORTED = {(640, 480), (848, 480), (1280, 720)}


def log(msg: str) -> None:
    print(f"[realsense] {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------- 影像寫檔
def _import_np():
    try:
        import numpy as np
    except ImportError:
        log("需要 numpy:sudo apt install python3-numpy")
        sys.exit(EXIT_USAGE)
    return np


def write_images(rgb, depth_mm, rgb_path: Path, depth_path: Path) -> None:
    """rgb: HxWx3 uint8 (RGB 順序);depth_mm: HxW uint16。優先用 OpenCV,沒有就用 Pillow。"""
    rgb_path.parent.mkdir(parents=True, exist_ok=True)
    depth_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        import cv2

        ok1 = cv2.imwrite(str(rgb_path), rgb[:, :, ::-1], [int(cv2.IMWRITE_JPEG_QUALITY), 92])
        ok2 = cv2.imwrite(str(depth_path), depth_mm)
        if not (ok1 and ok2):
            raise RuntimeError("cv2.imwrite 失敗")
        return
    except ImportError:
        pass
    try:
        from PIL import Image
    except ImportError:
        log("需要 python3-opencv 或 python3-pil 其中之一才能寫 JPEG / PNG")
        sys.exit(EXIT_USAGE)
    Image.fromarray(rgb).save(str(rgb_path), "JPEG", quality=92)
    # uint16 陣列 Pillow 會自動用 I;16 模式,存成 16-bit 灰階 PNG。
    Image.fromarray(depth_mm).save(str(depth_path), "PNG")


def write_meta(meta: dict, meta_path: Path) -> None:
    meta_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = meta_path.with_suffix(meta_path.suffix + ".tmp")
    tmp.write_text(json.dumps(meta, ensure_ascii=False, indent=2))
    tmp.replace(meta_path)


# ---------------------------------------------------------------- 真相機
def _import_rs():
    try:
        import pyrealsense2 as rs
    except ImportError:
        log("找不到 pyrealsense2。Raspberry Pi 請執行 deploy/build-librealsense.sh;x86_64 可 pip install pyrealsense2。")
        sys.exit(EXIT_USAGE)
    # pip 的 wheel 多一層 pyrealsense2.pyrealsense2 (__version__ 也只在裡面那層)
    if not hasattr(rs, "pipeline") and hasattr(rs, "pyrealsense2"):
        rs = rs.pyrealsense2
    return rs


def _rs_version(rs) -> str | None:
    for m in (rs, getattr(rs, "pyrealsense2", None)):
        v = getattr(m, "__version__", None)
        if v:
            return str(v)
    return None


def _info(dev, rs, key: str) -> str | None:
    try:
        info = getattr(rs.camera_info, key)
        return dev.get_info(info) if dev.supports(info) else None
    except Exception:  # noqa: BLE001
        return None


def describe_device(dev, rs) -> dict:
    return {
        "serial": _info(dev, rs, "serial_number"),
        "name": _info(dev, rs, "name"),
        "firmware": _info(dev, rs, "firmware_version"),
        "usb_type": _info(dev, rs, "usb_type_descriptor"),
        "product_line": _info(dev, rs, "product_line"),
        "product_id": _info(dev, rs, "product_id"),
    }


def find_devices(rs, serial: str | None = None) -> list:
    ctx = rs.context()
    devices = list(ctx.query_devices())
    if serial:
        devices = [d for d in devices if _info(d, rs, "serial_number") == serial]
    return devices


def probe(args) -> int:
    rs = _import_rs()
    devices = find_devices(rs, args.serial)
    if not devices:
        print(json.dumps({"found": False, "devices": []}))
        log("找不到 RealSense 相機" + (f" (序號 {args.serial})" if args.serial else ""))
        return EXIT_NO_DEVICE
    described = [describe_device(d, rs) for d in devices]
    print(json.dumps({"found": True, "librealsense": _rs_version(rs), **described[0],
                      "devices": described}, ensure_ascii=False))
    return 0


def capture_real(args, rgb_path: Path, depth_path: Path, meta_path: Path) -> int:
    np = _import_np()
    rs = _import_rs()
    devices = find_devices(rs, args.serial)
    if not devices:
        log("找不到 RealSense 相機" + (f" (序號 {args.serial})" if args.serial else "") + ",請確認 USB 3 線已接好")
        return EXIT_NO_DEVICE
    dev = devices[0]
    info = describe_device(dev, rs)
    serial = info["serial"]

    pipeline = rs.pipeline()
    profile = None
    last_error: Exception | None = None
    # USB 2 線材 / 埠時 1280x720@30 開不起來,往下試較低 fps。
    for fps in (30, 15, 6):
        cfg = rs.config()
        if serial:
            cfg.enable_device(serial)
        cfg.enable_stream(rs.stream.color, args.width, args.height, rs.format.rgb8, fps)
        cfg.enable_stream(rs.stream.depth, args.width, args.height, rs.format.z16, fps)
        try:
            if not cfg.can_resolve(rs.pipeline_wrapper(pipeline)):
                last_error = RuntimeError(f"{args.width}x{args.height}@{fps} 不支援")
                continue
            profile = pipeline.start(cfg)
            break
        except Exception as e:  # noqa: BLE001
            last_error = e
            continue
    if profile is None:
        log(f"無法啟動串流:{last_error}")
        return EXIT_CAPTURE

    deadline = time.monotonic() + args.timeout
    try:
        depth_sensor = profile.get_device().first_depth_sensor()
        depth_scale = float(depth_sensor.get_depth_scale())
        align = rs.align(rs.stream.color)

        frames = None
        # 暖機:自動曝光 / 深度自動調整需要幾張才穩定,只保留最後一組。
        for i in range(args.warmup + 1):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                log("等待影格逾時")
                return EXIT_CAPTURE
            frames = pipeline.wait_for_frames(int(min(remaining, 5.0) * 1000))
        frames = align.process(frames)
        color = frames.get_color_frame()
        depth = frames.get_depth_frame()
        if not color or not depth:
            log("沒有拿到完整的彩色 + 深度影格")
            return EXIT_CAPTURE

        rgb = np.asanyarray(color.get_data()).copy()
        raw = np.asanyarray(depth.get_data())
        factor = depth_scale * 1000.0
        if abs(factor - 1.0) < 1e-9:
            depth_mm = raw.astype(np.uint16, copy=True)
        else:
            depth_mm = np.clip(np.rint(raw.astype(np.float32) * factor), 0, 65535).astype(np.uint16)
        if rgb.shape[:2] != depth_mm.shape[:2]:
            log(f"對齊後尺寸不一致:rgb {rgb.shape[:2]} depth {depth_mm.shape[:2]}")
            return EXIT_CAPTURE

        intr = color.profile.as_video_stream_profile().intrinsics
        meta = {
            "format": FORMAT,
            "mock": False,
            **info,
            "librealsense": _rs_version(rs),
            "width": int(intr.width),
            "height": int(intr.height),
            "depth_unit_m": 0.001,
            "depth_aligned_to": "color",
            "device_depth_scale": depth_scale,
            "intrinsics": {
                "fx": float(intr.fx),
                "fy": float(intr.fy),
                "ppx": float(intr.ppx),
                "ppy": float(intr.ppy),
                "model": str(intr.model).split(".")[-1],
                "coeffs": [float(c) for c in intr.coeffs],
            },
            "frame_number": int(color.get_frame_number()),
            "timestamp_ms": float(color.get_timestamp()),
            "fps": int(color.profile.fps()),
            "warmup_frames": args.warmup,
            "captured_at": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "depth_valid_ratio": round(float(np.count_nonzero(depth_mm)) / depth_mm.size, 4),
        }
    except Exception as e:  # noqa: BLE001
        log(f"擷取失敗:{e}")
        return EXIT_CAPTURE
    finally:
        try:
            pipeline.stop()
        except Exception:  # noqa: BLE001
            pass

    write_images(rgb, depth_mm, rgb_path, depth_path)
    write_meta(meta, meta_path)
    print(json.dumps({k: meta[k] for k in ("serial", "width", "height", "depth_valid_ratio", "fps")}))
    return 0


# ---------------------------------------------------------------- 模擬
def render_mock(np, width: int, height: int, seed: int = 42):
    """畫一個放在秤面上的四格餐盒 (與 App 的 MockCameraService 構圖相同),加上對應的深度。"""
    rnd = np.random.default_rng(seed)
    rgb = np.full((height, width, 3), (196, 198, 204), dtype=np.uint8)
    # 秤面:相機距離 600 mm 的平面,邊角稍微遠一點模擬透視。
    yy, xx = np.mgrid[0:height, 0:width]
    depth = 600.0 + ((xx - width / 2) ** 2 + (yy - height / 2) ** 2) / (width * height) * 40.0
    x0, y0 = int(width * 0.22), int(height * 0.18)
    x1, y1 = int(width * 0.78), int(height * 0.82)
    rgb[y0:y1, x0:x1] = (245, 245, 240)
    depth[y0:y1, x0:x1] -= 40.0  # 餐盒邊緣高 40 mm
    rim = (70, 70, 75)
    t = 3
    rgb[y0:y0 + t, x0:x1] = rim
    rgb[y1 - t:y1, x0:x1] = rim
    rgb[y0:y1, x0:x0 + t] = rim
    rgb[y0:y1, x1 - t:x1] = rim
    mx, my = (x0 + x1) // 2, (y0 + y1) // 2
    rgb[y0:y1, mx - 1:mx + 2] = rim
    rgb[my - 1:my + 2, x0:x1] = rim
    pad = int(width * 0.015)
    colors = [(230, 226, 210), (96, 150, 70), (180, 110, 70), (220, 170, 60)]
    heights = [18.0, 25.0, 30.0, 12.0]  # 食物高度 (mm)
    cells = [
        (x0 + pad, y0 + pad, mx - pad, my - pad),
        (mx + pad, y0 + pad, x1 - pad, my - pad),
        (x0 + pad, my + pad, mx - pad, y1 - pad),
        (mx + pad, my + pad, x1 - pad, y1 - pad),
    ]
    for (cx0, cy0, cx1, cy1), color, h in zip(cells, colors, heights):
        rgb[cy0:cy1, cx0:cx1] = color
        # 餐盒底部比邊緣低 30 mm,食物再往上凸 (中央最高)
        cy, cx = np.mgrid[cy0:cy1, cx0:cx1]
        dome = 1.0 - ((cx - (cx0 + cx1) / 2) / ((cx1 - cx0) / 2)) ** 2 * 0.5 \
            - ((cy - (cy0 + cy1) / 2) / ((cy1 - cy0) / 2)) ** 2 * 0.5
        depth[cy0:cy1, cx0:cx1] = 600.0 - 40.0 + 30.0 - h * dome
        # 食物紋理
        n = (cx1 - cx0) * (cy1 - cy0) // 60
        ys = rnd.integers(cy0, cy1, n)
        xs = rnd.integers(cx0, cx1, n)
        shade = rnd.integers(-70, 70, (n, 1))
        rgb[ys, xs] = np.clip(np.array(color) + shade, 0, 255)
    noise = rnd.integers(-6, 7, rgb.shape)
    rgb = np.clip(rgb.astype(np.int16) + noise, 0, 255).astype(np.uint8)
    depth += rnd.normal(0, 1.5, depth.shape)
    depth_mm = np.clip(np.rint(depth), 0, 65535).astype(np.uint16)
    # 真相機在物體邊緣會有洞 (0):餐盒外框四周挖掉幾個像素
    depth_mm[y0 - 2:y0 + 2, x0:x1] = 0
    depth_mm[y1 - 2:y1 + 2, x0:x1] = 0
    depth_mm[y0:y1, x0 - 2:x0 + 2] = 0
    depth_mm[y0:y1, x1 - 2:x1 + 2] = 0
    return rgb, depth_mm


def capture_mock(args, rgb_path: Path, depth_path: Path, meta_path: Path) -> int:
    np = _import_np()
    rgb, depth_mm = render_mock(np, args.width, args.height)
    f = args.width * 0.72  # D435 彩色相機 69° 水平視角的近似焦距
    meta = {
        "format": FORMAT,
        "mock": True,
        "serial": "MOCK000000",
        "name": "Intel RealSense D435f (mock)",
        "firmware": None,
        "usb_type": None,
        "product_line": "D400",
        "product_id": None,
        "librealsense": None,
        "width": args.width,
        "height": args.height,
        "depth_unit_m": 0.001,
        "depth_aligned_to": "color",
        "device_depth_scale": 0.001,
        "intrinsics": {
            "fx": f, "fy": f, "ppx": args.width / 2, "ppy": args.height / 2,
            "model": "brown_conrady", "coeffs": [0.0, 0.0, 0.0, 0.0, 0.0],
        },
        "frame_number": 0,
        "timestamp_ms": time.time() * 1000,
        "fps": 30,
        "warmup_frames": args.warmup,
        "captured_at": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "depth_valid_ratio": round(float(np.count_nonzero(depth_mm)) / depth_mm.size, 4),
    }
    write_images(rgb, depth_mm, rgb_path, depth_path)
    write_meta(meta, meta_path)
    print(json.dumps({k: meta[k] for k in ("serial", "width", "height", "depth_valid_ratio", "fps")}))
    return 0


# ---------------------------------------------------------------- main
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--probe", action="store_true", help="偵測相機並印出 JSON")
    mode.add_argument("--once", nargs=3, metavar=("RGB", "DEPTH", "META"), help="拍一張 RGB-D 寫到三個檔案")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--warmup", type=int, default=15, help="丟掉的暖機影格數 (自動曝光收斂)")
    ap.add_argument("--serial", help="指定相機序號 (接多台時)")
    ap.add_argument("--timeout", type=float, default=10.0, help="等待影格的總秒數")
    ap.add_argument("--mock", action="store_true", help="不用相機,輸出合成 RGB-D")
    args = ap.parse_args(argv)

    if (args.width, args.height) not in SUPPORTED:
        log(f"解析度 {args.width}x{args.height} 不在支援清單 {sorted(SUPPORTED)}")
        return EXIT_USAGE
    if args.warmup < 0:
        args.warmup = 0

    if args.probe:
        if args.mock:
            print(json.dumps({"found": True, "serial": "MOCK000000", "name": "Intel RealSense D435f (mock)",
                              "firmware": None, "usb_type": None, "product_line": "D400", "mock": True,
                              "devices": []}))
            return 0
        return probe(args)

    rgb_path, depth_path, meta_path = (Path(p) for p in args.once)
    if args.mock:
        return capture_mock(args, rgb_path, depth_path, meta_path)
    return capture_real(args, rgb_path, depth_path, meta_path)


if __name__ == "__main__":
    sys.exit(main())

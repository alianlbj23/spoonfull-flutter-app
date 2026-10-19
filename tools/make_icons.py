#!/usr/bin/env python3
"""由吉祥物 (assets/images/mascot_face_blue.png) 產生各平台的 App 圖示。

    python tools/make_icons.py

產出 (全部已納入版控,改了吉祥物或配色後重跑即可):
- assets/icon/app_icon.png                      1024x1024 原圖,Linux 視窗圖示由此載入
- windows/runner/resources/app_icon.ico          Windows exe / 工作列圖示
- macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{16..1024}.png

需要 Pillow:`pip install pillow`。
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/images/mascot_face_blue.png"
SIZE = 1024
# lib/core/theme/app_colors.dart:periwinkle 背景、navy 線條 (原圖自帶)。
BACKGROUND = (0x8C, 0xA4, 0xF9, 255)
FILL = (255, 255, 255, 255)
CORNER = SIZE * 0.22
MASCOT_WIDTH = SIZE * 0.78


def filled_mascot() -> Image.Image:
    """把線稿碗身內部填白 (由圖中央往外填,線條當邊界),線條蓋在上面。"""
    outline = Image.open(SOURCE).convert("RGBA")
    alpha = outline.getchannel("A")
    # 線條 = 不透明像素;其餘區域從中央 flood fill 就是碗的內部。
    interior = Image.new("L", outline.size, 0)
    boundary = alpha.point(lambda a: 255 if a > 40 else 0)
    canvas = Image.merge("RGB", (boundary, boundary, boundary))
    ImageDraw.floodfill(canvas, (outline.width // 2, outline.height // 2), (255, 0, 0))
    interior = canvas.getchannel("R").point(lambda r: 255 if r == 255 else 0)
    # 填色區域比線條內緣小一點點,避免在線條外露出白邊。
    interior = Image.composite(interior, Image.new("L", outline.size, 0), boundary.point(lambda b: 0 if b else 255))
    fill = Image.new("RGBA", outline.size, FILL)
    fill.putalpha(interior)
    return Image.alpha_composite(fill, outline)


def build_master() -> Image.Image:
    icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(icon).rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=CORNER, fill=BACKGROUND)
    mascot = filled_mascot()
    scale = MASCOT_WIDTH / mascot.width
    mascot = mascot.resize((round(mascot.width * scale), round(mascot.height * scale)), Image.LANCZOS)
    icon.alpha_composite(mascot, ((SIZE - mascot.width) // 2, (SIZE - mascot.height) // 2))
    return icon


def main() -> None:
    master = build_master()
    out = ROOT / "assets/icon/app_icon.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    master.save(out)

    mac_dir = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for s in (16, 32, 64, 128, 256, 512, 1024):
        master.resize((s, s), Image.LANCZOS).save(mac_dir / f"app_icon_{s}.png")

    ico_sizes = [(s, s) for s in (16, 24, 32, 48, 64, 128, 256)]
    master.save(ROOT / "windows/runner/resources/app_icon.ico", sizes=ico_sizes)
    print("icons written:", out.relative_to(ROOT), "+ macOS appiconset + windows app_icon.ico")


if __name__ == "__main__":
    main()

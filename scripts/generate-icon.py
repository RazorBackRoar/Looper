#!/Users/home/.local/bin/python3.14
"""Build Looper.icns + asset catalog from IconSource.png."""
from __future__ import annotations

import math
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "IconSource.png"
CANVAS = 1024
# Match MetaBurn / Libra Finder scale (~82% opaque fill).
FILL = 0.82
SQUIRCLE_N = 4.5


def clean_background(im: Image.Image) -> Image.Image:
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 20:
                px[x, y] = (0, 0, 0, 0)
                continue
            gray = abs(r - g) < 10 and abs(g - b) < 10
            if gray and 160 <= r <= 220:
                px[x, y] = (0, 0, 0, 0)
            elif r + g + b < 40:
                px[x, y] = (0, 0, 0, 0)
            elif r > 230 and g > 230 and b > 230:
                px[x, y] = (0, 0, 0, 0)
            elif r > 210 and g > 210 and b > 210 and max(r, g, b) - min(r, g, b) < 25:
                px[x, y] = (0, 0, 0, 0)
    return im


def content_bbox(im: Image.Image) -> tuple[int, int, int, int]:
    px = im.load()
    w, h = im.size
    minx, miny, maxx, maxy = w, h, 0, 0
    for y in range(h):
        for x in range(w):
            if px[x, y][3] > 10:
                minx = min(minx, x)
                miny = min(miny, y)
                maxx = max(maxx, x)
                maxy = max(maxy, y)
    if maxx < minx:
        raise ValueError("icon artwork is empty after background cleanup")
    return minx, miny, maxx, maxy


def is_orange(r: int, g: int, b: int, a: int) -> bool:
    return a > 50 and r > 125 and g > 50 and b < 115 and r > g * 1.02 and (r - b) > 40


def chrome_metal_grade(im: Image.Image) -> Image.Image:
    """Lift knot shadows from black into reflective chrome tones."""
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 20 or is_orange(r, g, b, a):
                continue

            lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            t = max(0.0, min(1.0, lum / 255.0))

            # Darkest chrome ~118; keep bright speculars near white.
            lifted = 118 + 137 * (t**0.5)
            nr = lifted * 0.9 + 18
            ng = lifted * 0.95 + 14
            nb = lifted * 1.08 + 22

            blend = 0.82
            px[x, y] = (
                int(min(255, blend * nr + (1 - blend) * r)),
                int(min(255, blend * ng + (1 - blend) * g)),
                int(min(255, blend * nb + (1 - blend) * b)),
                a,
            )
    return im


def apply_squircle_mask(im: Image.Image, half: float) -> Image.Image:
    px = im.load()
    cx = cy = CANVAS / 2
    for y in range(CANVAS):
        for x in range(CANVAS):
            dx, dy = x - cx, y - cy
            theta = math.atan2(dy, dx)
            ct, st = math.cos(theta), math.sin(theta)
            edge = ((abs(ct) / half) ** SQUIRCLE_N + (abs(st) / half) ** SQUIRCLE_N) ** (-1.0 / SQUIRCLE_N)
            r = math.hypot(dx, dy)
            if r > edge:
                px[x, y] = (0, 0, 0, 0)
            elif r > edge - 2:
                t = max(0.0, min(1.0, (edge - r) / 2.0))
                c = px[x, y]
                px[x, y] = (c[0], c[1], c[2], int(c[3] * t))
    return im


def master_from_source(path: Path) -> Image.Image:
    im = clean_background(Image.open(path).convert("RGBA"))
    minx, miny, maxx, maxy = content_bbox(im)
    cropped = im.crop((minx, miny, maxx + 1, maxy + 1))

    target = int(CANVAS * FILL)
    cw, ch = cropped.size
    scale = min(target / cw, target / ch)
    new_size = (max(1, int(cw * scale)), max(1, int(ch * scale)))
    resized = cropped.resize(new_size, Image.Resampling.LANCZOS)

    master = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    master.paste(resized, ((CANVAS - new_size[0]) // 2, (CANVAS - new_size[1]) // 2), resized)
    master = chrome_metal_grade(master)
    return apply_squircle_mask(master, half=CANVAS * FILL / 2)


def write_png(img: Image.Image, size: int, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    out = img if img.width == size else img.resize((size, size), Image.Resampling.LANCZOS)
    out.save(path, optimize=True)


def main() -> int:
    if not SOURCE.exists():
        raise SystemExit(f"Missing {SOURCE}")

    master = master_from_source(SOURCE)
    master.save(ROOT / "Looper-1024.png", optimize=True)

    asset_sizes = {
        "icon_16.png": 16,
        "icon_16@2x.png": 32,
        "icon_32.png": 32,
        "icon_32@2x.png": 64,
        "icon_128.png": 128,
        "icon_128@2x.png": 256,
        "icon_256.png": 256,
        "icon_256@2x.png": 512,
        "icon_512.png": 512,
        "icon_512@2x.png": 1024,
    }
    asset_dir = ROOT / "Looper/Assets.xcassets/AppIcon.appiconset"
    for name, px in asset_sizes.items():
        write_png(master, px, asset_dir / name)

    iconset = Path("/tmp/Looper.iconset")
    iconset.mkdir(parents=True, exist_ok=True)
    for name, px in {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }.items():
        write_png(master, px, iconset / name)

    icns = ROOT / "Looper.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)
    print(f"Icon written: {icns}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

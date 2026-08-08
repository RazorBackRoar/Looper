#!/usr/bin/env python3.14
"""Build Looper.icns + asset catalog from IconSource.png.

IconSource.png is a 1024x1024 RGB export with a checkerboard "transparency"
pattern baked in, and its squircle only covers ~676px of that canvas. The body
is isolated from the checkerboard, scaled onto the 824x824 macOS icon grid and
re-shadowed so Looper sits at the same visual weight as the sibling apps
(MetaBurn / L!bra) in the Dock.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "IconSource.png"

CANVAS = 1024
BODY = 824  # Apple's macOS grid: an 824x824 squircle inside a 1024 canvas.
MARGIN = (CANVAS - BODY) // 2

# The baked checkerboard is achromatic and light; artwork is neither.
BG_CHROMA = 18
BG_VALUE = 200

# Drop shadow matched to MetaBurn / L!bra.
SHADOW_BLUR = 5
SHADOW_OFFSET = 10
SHADOW_ALPHA = 80


def background_mask(im: Image.Image) -> Image.Image:
    """White where a pixel looks like the baked checkerboard."""
    r, g, b = im.split()
    hi = ImageChops.lighter(ImageChops.lighter(r, g), b)
    lo = ImageChops.darker(ImageChops.darker(r, g), b)
    flat = ImageChops.subtract(hi, lo).point(lambda v: 255 if v <= BG_CHROMA else 0)
    light = lo.point(lambda v: 255 if v >= BG_VALUE else 0)
    return ImageChops.multiply(flat, light)


def body_mask(im: Image.Image) -> Image.Image:
    """White over the squircle, including its specular highlights."""
    outside = background_mask(im)
    # Only checkerboard reachable from a corner is really outside; the chrome
    # knot's near-white speculars are enclosed by the squircle and must stay.
    ImageDraw.floodfill(outside, (0, 0), 64, thresh=0)
    mask = outside.point(lambda v: 0 if v == 64 else 255)

    # Keep just the component under the centre so shadow/compression specks
    # cannot inflate the bounding box.
    ImageDraw.floodfill(mask, (im.width // 2, im.height // 2), 100, thresh=0)
    mask = mask.point(lambda v: 255 if v == 100 else 0)

    # Erode 1px to drop the row of pixels the export blended into the checker.
    return mask.filter(ImageFilter.MinFilter(3))


def master_from_source(path: Path) -> Image.Image:
    src = Image.open(path).convert("RGB")
    mask = body_mask(src)
    box = mask.getbbox()
    if box is None:
        raise ValueError("icon artwork is empty after background cleanup")

    art = src.crop(box).resize((BODY, BODY), Image.Resampling.LANCZOS)
    alpha = mask.crop(box).resize((BODY, BODY), Image.Resampling.LANCZOS)
    art.putalpha(alpha)

    shadow = Image.new("L", (CANVAS, CANVAS), 0)
    shadow.paste(alpha.point(lambda v: v * SHADOW_ALPHA // 255), (MARGIN, MARGIN + SHADOW_OFFSET))
    shadow = shadow.filter(ImageFilter.GaussianBlur(SHADOW_BLUR))
    below = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    below.putalpha(shadow)

    above = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    above.paste(art, (MARGIN, MARGIN))
    return Image.alpha_composite(below, above)


def write_png(img: Image.Image, size: int, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    out = img if img.width == size else img.resize((size, size), Image.Resampling.LANCZOS)
    out.save(path, optimize=True)


def main() -> int:
    if not SOURCE.exists():
        raise SystemExit(f"Missing {SOURCE}")

    master = master_from_source(SOURCE)

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

#!/usr/bin/env python3
"""generate-app-icons.py — render the Qwave app icons and hero from one SVG.

The icon is the MEM|8 wave: a ribbon across the rounded square, a dot for
the Q's tail. One 1024px master renders per size via sips; Contents.json
files are written for the macOS and iOS asset catalogs. The hero reuses the
same mark on a wide canvas with the wordmark.

Usage:
    uv run python scripts/generate-app-icons.py
"""

import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAC_SET = ROOT / "Resources/Qwave/Assets.xcassets/AppIcon.appiconset"
IOS_SET = ROOT / "Resources/QwaveIOS/Assets.xcassets/AppIcon.appiconset"
HERO = ROOT / "docs/assets/hero-v2.jpg"

ICON_SVG = """<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#0b1030"/>
      <stop offset="0.55" stop-color="#12204d"/>
      <stop offset="1" stop-color="#0a2e33"/>
    </linearGradient>
    <linearGradient id="ribbon" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#00ff9f"/>
      <stop offset="0.5" stop-color="#3ddcff"/>
      <stop offset="1" stop-color="#ff5c8a"/>
    </linearGradient>
  </defs>
  <rect x="32" y="32" width="960" height="960" rx="224" fill="url(#bg)"/>
  <path d="M 168 512
           C 240 380, 352 380, 416 512
           S 592 644, 664 512
           S 816 380, 872 428
           L 872 428" fill="none" stroke="url(#ribbon)" stroke-width="96"
        stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="794" cy="540" r="84" fill="#ff5c8a"/>
</svg>"""

HERO_SVG = """<svg xmlns="http://www.w3.org/2000/svg" width="2400" height="1200" viewBox="0 0 2400 1200">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#0b1030"/>
      <stop offset="0.55" stop-color="#12204d"/>
      <stop offset="1" stop-color="#0a2e33"/>
    </linearGradient>
    <linearGradient id="ribbon" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#00ff9f"/>
      <stop offset="0.5" stop-color="#3ddcff"/>
      <stop offset="1" stop-color="#ff5c8a"/>
    </linearGradient>
  </defs>
  <rect width="2400" height="1200" fill="url(#bg)"/>
  <path d="M 300 600
           C 480 320, 780 320, 960 600
           S 1440 880, 1620 600
           S 1980 320, 2120 420" fill="none" stroke="url(#ribbon)" stroke-width="150"
        stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="2020" cy="700" r="130" fill="#ff5c8a"/>
  <text x="1200" y="1010" font-family="Helvetica, Arial, sans-serif" font-size="150"
        font-weight="700" fill="#eaf6ff" text-anchor="middle" letter-spacing="26">QWAVE</text>
  <text x="1200" y="1120" font-family="Helvetica, Arial, sans-serif" font-size="52"
        fill="#8fb8d8" text-anchor="middle" letter-spacing="10">A BROWSER THAT PROVES WHAT IT SENDS</text>
</svg>"""

# macOS: (pixels @1x, pixels @2x) as (filename, size)
MAC_SIZES = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

# iOS: (filename, pixels, idiom, scale, size-pts, subtype)
IOS_SIZES = [
    ("20@2x.png", 40, "iphone", "2x", "20x20", None),
    ("20@3x.png", 60, "iphone", "3x", "20x20", None),
    ("29@2x.png", 58, "iphone", "2x", "29x29", None),
    ("29@3x.png", 87, "iphone", "3x", "29x29", None),
    ("40@2x.png", 80, "iphone", "2x", "40x40", None),
    ("40@3x.png", 120, "iphone", "3x", "40x40", None),
    ("60@2x.png", 120, "iphone", "2x", "60x60", None),
    ("60@3x.png", 180, "iphone", "3x", "60x60", None),
    ("1024.png", 1024, "ios-marketing", "1x", "1024x1024", None),
]


def render_svg(svg: str, out_png: Path):
    with tempfile.TemporaryDirectory() as tmp:
        svg_path = Path(tmp) / "icon.svg"
        svg_path.write_text(svg)
        subprocess.run(
            ["qlmanage", "-t", "-s", "1024", "-o", tmp, str(svg_path)],
            check=True, capture_output=True,
        )
        rendered = Path(tmp) / "icon.svg.png"
        rendered.rename(out_png)


def main():
    master = ROOT / "build/icons-master.png"
    master.parent.mkdir(parents=True, exist_ok=True)
    render_svg(ICON_SVG, master)

    # macOS set
    mac_contents = {"images": [], "info": {"author": "xcode", "version": 1}}
    for filename, size in MAC_SIZES:
        out = MAC_SET / filename
        if size != 1024:
            subprocess.run(["sips", "-z", str(size), str(size), str(master), "--out", str(out)],
                           check=True, capture_output=True)
        else:
            subprocess.run(["cp", str(master), str(out)], check=True)
        scale = "2x" if "@2x" in filename else "1x"
        base = filename.replace(".png", "").replace("@2x", "").replace("icon_", "")
        mac_contents["images"].append({
            "filename": filename,
            "idiom": "mac",
            "scale": scale,
            "size": base,
        })
    (MAC_SET / "Contents.json").write_text(json.dumps(mac_contents, indent=2) + "\n")

    # iOS set
    ios_contents = {"images": [], "info": {"author": "xcode", "version": 1}}
    for filename, px, idiom, scale, size, subtype in IOS_SIZES:
        out = IOS_SET / filename
        if px != 1024:
            subprocess.run(["sips", "-z", str(px), str(px), str(master), "--out", str(out)],
                           check=True, capture_output=True)
        else:
            subprocess.run(["cp", str(master), str(out)], check=True)
        image = {"filename": filename, "idiom": idiom, "scale": scale, "size": size}
        if subtype:
            image["subtype"] = subtype
        ios_contents["images"].append(image)
    (IOS_SET / "Contents.json").write_text(json.dumps(ios_contents, indent=2) + "\n")

    # hero: 2400×1200 raster built with numpy + Pillow (qlmanage caps at
    # 1024, too small for a hero). Graphics only — no font dependency.
    try:
        from PIL import Image, ImageDraw, ImageFont
        import numpy as np

        W, H = 2400, 1200
        img = np.zeros((H, W, 3), dtype=np.float64)
        for y in range(H):
            t = y / H
            img[y, :, 0] = np.interp(t, [0, 0.6, 1], [11, 18, 10]) / 255
            img[y, :, 1] = np.interp(t, [0, 0.6, 1], [16, 32, 46]) / 255
            img[y, :, 2] = np.interp(t, [0, 0.6, 1], [48, 77, 51]) / 255

        def wave_y(x, amp=260.0):
            return H * 0.5 + amp * np.sin(2 * np.pi * x / 1500) - 40

        band = np.zeros((H, W, 3), dtype=np.float64)
        for x in range(W):
            y = int(wave_y(x))
            y0, y1 = max(0, y - 75), min(H, y + 75)
            t = x / W
            band[y0:y1, x, 0] = np.interp(t, [0, 0.5, 1], [0, 61, 255]) / 255
            band[y0:y1, x, 1] = np.interp(t, [0, 0.5, 1], [255, 220, 92]) / 255
            band[y0:y1, x, 2] = np.interp(t, [0, 0.5, 1], [159, 255, 138]) / 255

        for _ in range(3):
            padded = np.pad(band, ((1, 1), (0, 0), (0, 0)), mode="edge")
            band = (padded[:-2] + padded[1:-1] + padded[2:]) / 3
        img = img * (1 - np.clip(band, 0, 1)) + band

        yy, xx = np.mgrid[0:H, 0:W]
        dist = np.sqrt((xx - 2020) ** 2 + (yy - 700) ** 2)
        dot = np.clip(1 - (dist - 90) / 40, 0, 1)
        for c, v in ((0, 255), (1, 92), (2, 138)):
            img[..., c] = img[..., c] * (1 - dot) + (v / 255) * dot

        im = Image.fromarray((img * 255).astype(np.uint8))
        draw = ImageDraw.Draw(im)
        try:
            big = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 150)
            small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 52)
        except Exception:
            big = ImageFont.load_default()
            small = ImageFont.load_default()
        draw.text((W / 2, 980), "QWAVE", font=big, fill=(234, 246, 255), anchor="mm")
        draw.text(
            (W / 2, 1110), "A BROWSER THAT PROVES WHAT IT SENDS",
            font=small, fill=(143, 184, 216), anchor="mm",
        )
        im.save(HERO, quality=90)
    except ImportError:
        # Pillow absent: fall back to a 1024px qlmanage render.
        hero_png = ROOT / "build/hero-v2.png"
        render_svg(HERO_SVG, hero_png)
        subprocess.run(
            ["sips", "-s", "format", "jpeg", "-s", "formatOptions", "90",
             str(hero_png), "--out", str(HERO)],
            check=True, capture_output=True,
        )

    print(f"macOS: {len(MAC_SIZES)} icons → {MAC_SET}")
    print(f"iOS:   {len(IOS_SIZES)} icons → {IOS_SET}")
    print(f"hero:  {HERO}")


if __name__ == "__main__":
    main()

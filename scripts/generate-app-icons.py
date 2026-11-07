#!/usr/bin/env python3
"""generate-app-icons.py — manipulate the 3 master brand artworks into native
assets across macOS, iOS, iPadOS, AUv3 Audio Unit Extensions, Docs, and Linux.

Master artworks in Resources/Branding/:
  1. magnific__qwave-browser-icon__43728.png (4096x4096) — Sculpted Crystalline Q-WAVE
  2. magnific__qwave-browser-icon__43727.png (4096x4096) — Luminous Neon-Ribbon Q-WAVE
  3. magnific__the-logo-for-the-phoenix-audio-restore-engine-that__19265.png (1376x768)
     — PHOENIX AUDIO RESTORE (Ultra HD Sound Engine)
"""

import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "Resources/Branding"

MAC_ASSETS = ROOT / "Resources/Qwave/Assets.xcassets"
IOS_ASSETS = ROOT / "Resources/QwaveIOS/Assets.xcassets"
PHX_ASSETS = ROOT / "Resources/PhoenixAudioExtension/Assets.xcassets"
DOCS_ASSETS = ROOT / "docs/assets"

# macOS: (filename, pixels, size-pts, scale)
MAC_SIZES = [
    ("icon_16x16.png", 16, "16x16", "1x"),
    ("icon_16x16@2x.png", 32, "16x16", "2x"),
    ("icon_32x32.png", 32, "32x32", "1x"),
    ("icon_32x32@2x.png", 64, "32x32", "2x"),
    ("icon_128x128.png", 128, "128x128", "1x"),
    ("icon_128x128@2x.png", 256, "128x128", "2x"),
    ("icon_256x256.png", 256, "256x256", "1x"),
    ("icon_256x256@2x.png", 512, "256x256", "2x"),
    ("icon_512x512.png", 512, "512x512", "1x"),
    ("icon_512x512@2x.png", 1024, "512x512", "2x"),
]

# iOS & iPadOS: (filename, pixels, idiom, scale, size-pts)
IOS_SIZES = [
    ("20@2x.png", 40, "iphone", "2x", "20x20"),
    ("20@3x.png", 60, "iphone", "3x", "20x20"),
    ("29@2x.png", 58, "iphone", "2x", "29x29"),
    ("29@3x.png", 87, "iphone", "3x", "29x29"),
    ("40@2x.png", 80, "iphone", "2x", "40x40"),
    ("40@3x.png", 120, "iphone", "3x", "40x40"),
    ("60@2x.png", 120, "iphone", "2x", "60x60"),
    ("60@3x.png", 180, "iphone", "3x", "60x60"),
    ("1024.png", 1024, "ios-marketing", "1x", "1024x1024"),
    ("ipad-20@1x.png", 20, "ipad", "1x", "20x20"),
    ("ipad-20@2x.png", 40, "ipad", "2x", "20x20"),
    ("ipad-29@1x.png", 29, "ipad", "1x", "29x29"),
    ("ipad-29@2x.png", 58, "ipad", "2x", "29x29"),
    ("ipad-40@1x.png", 40, "ipad", "1x", "40x40"),
    ("ipad-40@2x.png", 80, "ipad", "2x", "40x40"),
    ("ipad-76@1x.png", 76, "ipad", "1x", "76x76"),
    ("ipad-76@2x.png", 152, "ipad", "2x", "76x76"),
    ("ipad-83.5@2x.png", 167, "ipad", "2x", "83.5x83.5"),
]


def make_roundrect_mask(size: int, box_size: int, radius_ratio: float = 0.205) -> Image.Image:
    """Create a 4x supersampled anti-aliased rounded-rectangle mask."""
    ss = 4
    S = size * ss
    B = box_size * ss
    R = int(B * radius_ratio)
    pad = (S - B) // 2
    mask_hi = Image.new("L", (S, S), 0)
    draw = ImageDraw.Draw(mask_hi)
    draw.rounded_rectangle([pad, pad, pad + B - 1, pad + B - 1], radius=R, fill=255)
    return mask_hi.resize((size, size), Image.Resampling.LANCZOS)


def make_macos_icon(
    cropped_sq: Image.Image,
    out_size: int = 1024,
    box_size: int = 844,
    radius_ratio: float = 0.205,
) -> Image.Image:
    """Render a floating macOS squircle icon with transparent margins and drop shadow."""
    canvas = Image.new("RGBA", (out_size, out_size), (0, 0, 0, 0))
    mask = make_roundrect_mask(out_size, box_size, radius_ratio=radius_ratio)

    shadow = Image.new("RGBA", (out_size, out_size), (0, 0, 0, 0))
    sh_alpha = mask.filter(ImageFilter.GaussianBlur(radius=out_size * 0.018))
    sh_arr = (np.array(sh_alpha).astype(float) * 0.55).astype(np.uint8)
    shadow.putalpha(Image.fromarray(sh_arr, mode="L"))
    canvas.alpha_composite(shadow, dest=(0, int(out_size * 0.012)))

    art_resized = cropped_sq.resize((box_size, box_size), Image.Resampling.LANCZOS).convert("RGBA")
    art_layer = Image.new("RGBA", (out_size, out_size), (0, 0, 0, 0))
    pad = (out_size - box_size) // 2
    art_layer.paste(art_resized, (pad, pad))
    art_layer.putalpha(mask)
    canvas.alpha_composite(art_layer)
    return canvas


def clean_28_interior(im: Image.Image, remove_text: bool = False) -> Image.Image:
    """Prepare 43728 for full-bleed iOS/iPadOS icons or small text-free macOS icons."""
    arr = np.array(im).copy()
    if remove_text:
        y0, y1, x0, x1 = 3165, 3395, 1580, 2520
        top_strip = arr[y0 - 12 : y0, x0:x1].mean(axis=0)
        bot_strip = arr[y1 : y1 + 12, x0:x1].mean(axis=0)
        for idx, y in enumerate(range(y0, y1)):
            t = idx / max(1, (y1 - y0 - 1))
            arr[y, x0:x1] = ((1.0 - t) * top_strip + t * bot_strip).astype(np.uint8)

    inner_mask = Image.new("L", (4096, 4096), 0)
    ImageDraw.Draw(inner_mask).rounded_rectangle([585, 575, 3510, 3500], radius=590, fill=255)
    inner_mask_blur = np.array(inner_mask.filter(ImageFilter.GaussianBlur(radius=8))).astype(float) / 255.0

    yy, _ = np.mgrid[0:4096, 0:4096]
    t_y = np.clip((yy - 600) / 2900.0, 0.0, 1.0)
    top_col = np.array([54.0, 74.0, 106.0])
    bot_col = np.array([15.0, 21.0, 40.0])
    bg_grad = ((1.0 - t_y[..., None]) * top_col + t_y[..., None] * bot_col).astype(np.uint8)
    m3 = inner_mask_blur[..., None]
    out = (arr.astype(float) * m3 + bg_grad.astype(float) * (1.0 - m3)).astype(np.uint8)
    return Image.fromarray(out)


def clean_27_interior(im: Image.Image, remove_text: bool = False) -> Image.Image:
    """Prepare 43727 for full-bleed iOS/iPadOS icons or small text-free macOS icons."""
    arr = np.array(im).copy()
    if remove_text:
        y0, y1, x0, x1 = 3150, 3520, 950, 3150
        top_strip = arr[y0 - 16 : y0, x0:x1].mean(axis=0)
        bot_strip = arr[y1 : y1 + 16, x0:x1].mean(axis=0)
        for idx, y in enumerate(range(y0, y1)):
            t = idx / max(1, (y1 - y0 - 1))
            arr[y, x0:x1] = ((1.0 - t) * top_strip + t * bot_strip).astype(np.uint8)

    inner_mask = Image.new("L", (4096, 4096), 0)
    ImageDraw.Draw(inner_mask).rounded_rectangle([435, 430, 3660, 3655], radius=640, fill=255)
    inner_mask_blur = np.array(inner_mask.filter(ImageFilter.GaussianBlur(radius=10))).astype(float) / 255.0

    yy, _ = np.mgrid[0:4096, 0:4096]
    t_y = np.clip((yy - 450) / 3200.0, 0.0, 1.0)
    top_col = np.array([32.0, 49.0, 82.0])
    bot_col = np.array([8.0, 8.0, 24.0])
    bg_grad = ((1.0 - t_y[..., None]) * top_col + t_y[..., None] * bot_col).astype(np.uint8)
    m3 = inner_mask_blur[..., None]
    out = (arr.astype(float) * m3 + bg_grad.astype(float) * (1.0 - m3)).astype(np.uint8)
    return Image.fromarray(out)


def clean_phoenix_emblem(im: Image.Image) -> Image.Image:
    """Extract the Phoenix bird + spectrum emblem without the bottom PHOENIX text."""
    # Crop 480x480 centered at x=688, y=245 -> x=448..928, y=5..485 (above the PHOENIX text and lens flare)
    arr = np.array(im).copy()
    # Gently fade only the very bottom 6px (y=479..485) where the tip of the tail meets the dark canvas
    for y in range(476, 490):
        row_bg = arr[440, 460:520, :].mean(axis=0)
        t = min(1.0, (y - 476) / 12.0)
        # Keep bright cyan tail pixels (where blue > 80), blend only dark/orange flare pixels
        mask_tail = (arr[y, :, 2] > 90).astype(float)[:, None]
        blended = (1.0 - t) * arr[y].astype(float) + t * row_bg
        arr[y] = (mask_tail * arr[y].astype(float) + (1.0 - mask_tail) * blended).astype(np.uint8)
    return Image.fromarray(arr).crop((443, 10, 933, 500)).resize((1024, 1024), Image.Resampling.LANCZOS)


def write_mac_appiconset(dest_dir: Path, mac_large: Image.Image, mac_small: Image.Image):
    dest_dir.mkdir(parents=True, exist_ok=True)
    contents = {"images": [], "info": {"author": "xcode", "version": 1}}
    for filename, px, size_str, scale in MAC_SIZES:
        src = mac_small if px <= 64 else mac_large
        img = src if px == 1024 else src.resize((px, px), Image.Resampling.LANCZOS)
        img.save(dest_dir / filename, format="PNG")
        contents["images"].append({
            "filename": filename,
            "idiom": "mac",
            "scale": scale,
            "size": size_str,
        })
    (dest_dir / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def write_ios_appiconset(dest_dir: Path, ios_large: Image.Image, ios_small: Image.Image):
    dest_dir.mkdir(parents=True, exist_ok=True)
    contents = {"images": [], "info": {"author": "xcode", "version": 1}}
    for filename, px, idiom, scale, size_str in IOS_SIZES:
        src = ios_small if px <= 87 else ios_large
        # Ensure 100% opaque RGB for iOS/App Store compliance
        img = (src if px == 1024 else src.resize((px, px), Image.Resampling.LANCZOS)).convert("RGB")
        img.save(dest_dir / filename, format="PNG")
        contents["images"].append({
            "filename": filename,
            "idiom": idiom,
            "scale": scale,
            "size": size_str,
        })
    (dest_dir / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def write_universal_appiconset(
    dest_dir: Path,
    mac_large: Image.Image,
    mac_small: Image.Image,
    ios_large: Image.Image,
    ios_small: Image.Image,
):
    dest_dir.mkdir(parents=True, exist_ok=True)
    contents = {"images": [], "info": {"author": "xcode", "version": 1}}
    for filename, px, size_str, scale in MAC_SIZES:
        src = mac_small if px <= 64 else mac_large
        img = src if px == 1024 else src.resize((px, px), Image.Resampling.LANCZOS)
        img.save(dest_dir / filename, format="PNG")
        contents["images"].append({
            "filename": filename,
            "idiom": "mac",
            "scale": scale,
            "size": size_str,
        })
    for filename, px, idiom, scale, size_str in IOS_SIZES:
        src = ios_small if px <= 87 else ios_large
        img = (src if px == 1024 else src.resize((px, px), Image.Resampling.LANCZOS)).convert("RGB")
        img.save(dest_dir / filename, format="PNG")
        contents["images"].append({
            "filename": filename,
            "idiom": idiom,
            "scale": scale,
            "size": size_str,
        })
    (dest_dir / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def write_imageset(dest_dir: Path, base_name: str, master_img: Image.Image, sizes_1x_2x_3x: list[tuple[int, int]]):
    imgset = dest_dir / f"{base_name}.imageset"
    imgset.mkdir(parents=True, exist_ok=True)
    scales = ["1x", "2x", "3x"]
    images_meta = []
    for scale, (w, h) in zip(scales, sizes_1x_2x_3x):
        fn = f"{base_name}@{scale}.png" if scale != "1x" else f"{base_name}.png"
        resized = master_img.resize((w, h), Image.Resampling.LANCZOS)
        resized.save(imgset / fn, format="PNG")
        images_meta.append({
            "filename": fn,
            "idiom": "universal",
            "scale": scale,
        })
    (imgset / "Contents.json").write_text(
        json.dumps({"images": images_meta, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
    )


def main():
    im28 = Image.open(BRAND / "magnific__qwave-browser-icon__43728.png").convert("RGB")
    im27 = Image.open(BRAND / "magnific__qwave-browser-icon__43727.png").convert("RGB")
    im_phx = Image.open(BRAND / "magnific__the-logo-for-the-phoenix-audio-restore-engine-that__19265.png").convert("RGB")

    # --- 1. Prepare Q-WAVE Primary (43728: Sculpted Crystalline Wave Q) ---
    im28_notext_raw = im28.copy()
    arr28_nt = np.array(im28_notext_raw)
    y0, y1, x0, x1 = 3165, 3395, 1580, 2520
    top_s = arr28_nt[y0 - 12 : y0, x0:x1].mean(axis=0)
    bot_s = arr28_nt[y1 : y1 + 12, x0:x1].mean(axis=0)
    for idx, y in enumerate(range(y0, y1)):
        t = idx / max(1, (y1 - y0 - 1))
        arr28_nt[y, x0:x1] = ((1.0 - t) * top_s + t * bot_s).astype(np.uint8)
    im28_notext_raw = Image.fromarray(arr28_nt)

    mac_28_large = make_macos_icon(im28.crop((540, 530, 3556, 3546)), 1024, 844, radius_ratio=0.205)
    mac_28_small = make_macos_icon(im28_notext_raw.crop((540, 530, 3556, 3546)), 1024, 844, radius_ratio=0.205)

    ios_28_large = clean_28_interior(im28, remove_text=False).crop((620, 610, 3476, 3466)).resize((1024, 1024), Image.Resampling.LANCZOS)
    ios_28_small = clean_28_interior(im28, remove_text=True).crop((720, 580, 3440, 3300)).resize((1024, 1024), Image.Resampling.LANCZOS)

    # --- 2. Prepare Q-WAVE Neon (43727: Luminous Neon-Ribbon Wave Q) ---
    arr27_nt = np.array(im27).copy()
    y0, y1, x0, x1 = 3150, 3520, 950, 3150
    top_s27 = arr27_nt[y0 - 16 : y0, x0:x1].mean(axis=0)
    bot_s27 = arr27_nt[y1 : y1 + 16, x0:x1].mean(axis=0)
    for idx, y in enumerate(range(y0, y1)):
        t = idx / max(1, (y1 - y0 - 1))
        arr27_nt[y, x0:x1] = ((1.0 - t) * top_s27 + t * bot_s27).astype(np.uint8)
    im27_notext_raw = Image.fromarray(arr27_nt)

    mac_27_large = make_macos_icon(im27.crop((398, 394, 3698, 3694)), 1024, 844, radius_ratio=0.205)
    mac_27_small = make_macos_icon(im27_notext_raw.crop((398, 394, 3698, 3694)), 1024, 844, radius_ratio=0.205)

    ios_27_large = clean_27_interior(im27, remove_text=False).crop((480, 476, 3616, 3612)).resize((1024, 1024), Image.Resampling.LANCZOS)
    ios_27_small = clean_27_interior(im27, remove_text=True).crop((580, 460, 3560, 3440)).resize((1024, 1024), Image.Resampling.LANCZOS)

    # --- 3. Prepare PHOENIX AUDIO RESTORE (19265) ---
    phx_sq_full = im_phx.crop((304, 0, 1072, 768)).resize((1024, 1024), Image.Resampling.LANCZOS)
    phx_sq_emblem = clean_phoenix_emblem(im_phx)
    mac_phx_large = make_macos_icon(phx_sq_full, 1024, 844, radius_ratio=0.220)
    mac_phx_small = make_macos_icon(phx_sq_emblem, 1024, 844, radius_ratio=0.220)

    # Write macOS Qwave Assets.xcassets
    MAC_ASSETS.mkdir(parents=True, exist_ok=True)
    (MAC_ASSETS / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    write_mac_appiconset(MAC_ASSETS / "AppIcon.appiconset", mac_28_large, mac_28_small)
    write_mac_appiconset(MAC_ASSETS / "AppIconNeon.appiconset", mac_27_large, mac_27_small)
    write_imageset(MAC_ASSETS, "QwaveLogo", mac_28_large, [(128, 128), (256, 256), (512, 512)])
    write_imageset(MAC_ASSETS, "QwaveNeonLogo", mac_27_large, [(128, 128), (256, 256), (512, 512)])
    write_imageset(MAC_ASSETS, "PhoenixAudioLogo", im_phx, [(458, 256), (917, 512), (1376, 768)])
    write_imageset(MAC_ASSETS, "PhoenixEmblem", mac_phx_small, [(128, 128), (256, 256), (512, 512)])

    # Write iOS/iPadOS QwaveIOS Assets.xcassets
    IOS_ASSETS.mkdir(parents=True, exist_ok=True)
    (IOS_ASSETS / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    write_ios_appiconset(IOS_ASSETS / "AppIcon.appiconset", ios_28_large, ios_28_small)
    write_ios_appiconset(IOS_ASSETS / "AppIconNeon.appiconset", ios_27_large, ios_27_small)
    write_imageset(IOS_ASSETS, "QwaveLogo", mac_28_large, [(128, 128), (256, 256), (512, 512)])
    write_imageset(IOS_ASSETS, "QwaveNeonLogo", mac_27_large, [(128, 128), (256, 256), (512, 512)])
    write_imageset(IOS_ASSETS, "PhoenixAudioLogo", im_phx, [(458, 256), (917, 512), (1376, 768)])
    write_imageset(IOS_ASSETS, "PhoenixEmblem", mac_phx_small, [(128, 128), (256, 256), (512, 512)])

    # Write AUv3 PhoenixAudioExtension Assets.xcassets (macOS + iOS)
    PHX_ASSETS.mkdir(parents=True, exist_ok=True)
    (PHX_ASSETS / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    write_universal_appiconset(
        PHX_ASSETS / "AppIcon.appiconset",
        mac_phx_large,
        mac_phx_small,
        phx_sq_full,
        phx_sq_emblem,
    )
    write_imageset(PHX_ASSETS, "PhoenixBanner", im_phx, [(458, 256), (917, 512), (1376, 768)])
    write_imageset(PHX_ASSETS, "PhoenixEmblem", mac_phx_small, [(64, 64), (128, 128), (256, 256)])
    write_imageset(PHX_ASSETS, "QwaveLogo", mac_28_large, [(64, 64), (128, 128), (256, 256)])

    # Write Docs, Web & Linux Desktop Assets
    DOCS_ASSETS.mkdir(parents=True, exist_ok=True)
    mac_28_large.resize((512, 512), Image.Resampling.LANCZOS).save(DOCS_ASSETS / "qwave-icon.png")
    mac_27_large.resize((512, 512), Image.Resampling.LANCZOS).save(DOCS_ASSETS / "qwave-neon-icon.png")
    im_phx.save(DOCS_ASSETS / "phoenix-audio-restore.png")
    mac_phx_small.resize((512, 512), Image.Resampling.LANCZOS).save(DOCS_ASSETS / "phoenix-emblem.png")
    mac_28_small.resize((64, 64), Image.Resampling.LANCZOS).save(ROOT / "docs/favicon.png")

    # Build 2400x1200 hero-v2.jpg showcasing Q-WAVE + PHOENIX AUDIO RESTORE
    yy, xx = np.mgrid[0:1200, 0:2400]
    bg = np.zeros((1200, 2400, 4), dtype=np.uint8)
    bg[..., 0] = np.clip(9 + (yy / 1200.0) * 8, 0, 255).astype(np.uint8)
    bg[..., 1] = np.clip(13 + (xx / 2400.0) * 10, 0, 255).astype(np.uint8)
    bg[..., 2] = np.clip(20 + (yy / 1200.0) * 14, 0, 255).astype(np.uint8)
    bg[..., 3] = 255
    hero = Image.fromarray(bg, mode="RGBA")
    phx_w, phx_h = 1040, 580
    phx_banner = im_phx.resize((phx_w, phx_h), Image.Resampling.LANCZOS).convert("RGBA")
    # Feather outer 18% of phx_banner so it blends seamlessly into the hero canvas
    by, bx = np.mgrid[0:phx_h, 0:phx_w]
    dx = np.abs(bx - phx_w / 2.0) / (phx_w / 2.0)
    dy = np.abs(by - phx_h / 2.0) / (phx_h / 2.0)
    edge_d = np.maximum(dx, dy)
    feather_alpha = np.clip((1.0 - edge_d) / 0.22, 0.0, 1.0)
    phx_banner.putalpha(Image.fromarray((feather_alpha * 255).astype(np.uint8), mode="L"))
    hero.alpha_composite(phx_banner, dest=((2400 - phx_w) // 2, (1200 - phx_h) // 2))
    hero.alpha_composite(mac_28_large.resize((620, 620), Image.Resampling.LANCZOS), dest=(90, 290))
    hero.alpha_composite(mac_27_large.resize((620, 620), Image.Resampling.LANCZOS), dest=(1690, 290))
    hero.convert("RGB").save(DOCS_ASSETS / "hero-v2.jpg", quality=92)

    # Install Linux desktop icons
    linux_icon_dir = Path.home() / ".local/share/icons/hicolor/512x512/apps"
    linux_icon_dir.mkdir(parents=True, exist_ok=True)
    mac_28_large.resize((512, 512), Image.Resampling.LANCZOS).save(linux_icon_dir / "qwave.png")
    mac_27_large.resize((512, 512), Image.Resampling.LANCZOS).save(linux_icon_dir / "qwave-neon.png")
    mac_phx_small.resize((512, 512), Image.Resampling.LANCZOS).save(linux_icon_dir / "phoenix-audio.png")

    print("Successfully generated all macOS, iOS, iPadOS, AUv3, Docs, and Linux assets!")


if __name__ == "__main__":
    main()

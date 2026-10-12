#!/usr/bin/env python3
"""Generates the ILWorkbench app icon (gradient squircle + code braces + magnifier)
and writes the macOS AppIcon asset catalog. Run: Scripts/make-icon.py"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSET_DIR = os.path.join(ROOT, "ILWorkbench", "Assets.xcassets", "AppIcon.appiconset")
MASTER = 1024
INSET = 88
RADIUS = 196
TOP = (76, 110, 245)
BOTTOM = (112, 72, 232)
BRACE_FONT = "/System/Library/Fonts/SFNSMono.ttf"


def gradient(size):
    image = Image.new("RGB", (size, size))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        t = y / (size - 1)
        draw.line(
            [(0, y), (size, y)],
            fill=tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)),
        )
    return image


def squircle_mask(size, inset, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [inset, inset, size - inset - 1, size - inset - 1], radius=radius, fill=255
    )
    return mask


def build_master():
    icon = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    mask = squircle_mask(MASTER, INSET, RADIUS)

    # drop shadow
    shadow = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [INSET, INSET + 14, MASTER - INSET - 1, MASTER - INSET + 13],
        radius=RADIUS,
        fill=(16, 18, 40, 110),
    )
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(22)))

    body = gradient(MASTER).convert("RGBA")

    # soft light from the top: a vertical alpha ramp instead of a hard-edged band
    gloss = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    gloss_draw = ImageDraw.Draw(gloss)
    for y in range(INSET, MASTER - INSET):
        t = (y - INSET) / (MASTER - 2 * INSET)
        alpha = int(38 * max(0.0, 1.0 - t / 0.55) ** 2)
        gloss_draw.line([(INSET, y), (MASTER - INSET, y)], fill=(255, 255, 255, alpha))
    body.alpha_composite(Image.composite(gloss, Image.new("RGBA", body.size, (0, 0, 0, 0)), mask))
    body.putalpha(mask)
    icon.alpha_composite(body)

    draw = ImageDraw.Draw(icon)

    # code braces, nudged up-left so the magnifier has room
    font = ImageFont.truetype(BRACE_FONT, size=int(MASTER * 0.44))
    text = "{ }"
    left, top, right, bottom = draw.textbbox((0, 0), text, font=font)
    draw.text(
        ((MASTER - (right - left)) / 2 - left - 46, (MASTER - (bottom - top)) / 2 - top - 56),
        text,
        font=font,
        fill=(255, 255, 255, 242),
    )

    # magnifier: translucent lens, ring and handle, bottom right
    cx, cy, r = int(MASTER * 0.705), int(MASTER * 0.700), int(MASTER * 0.132)
    stroke = int(MASTER * 0.040)
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(214, 240, 255, 58))
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(255, 255, 255, 255), width=stroke)
    handle_start = (cx + int(r * 0.70), cy + int(r * 0.70))
    handle_end = (cx + int(r * 1.70), cy + int(r * 1.70))
    draw.line([handle_start, handle_end], fill=(255, 255, 255, 255), width=int(stroke * 1.2))
    for point in (handle_start, handle_end):
        draw.ellipse([point[0] - stroke * 0.6, point[1] - stroke * 0.6,
                      point[0] + stroke * 0.6, point[1] + stroke * 0.6],
                     fill=(255, 255, 255, 255))
    return icon


def main():
    os.makedirs(ASSET_DIR, exist_ok=True)
    master = build_master()
    # The master PNG lives in docs/ (it is documentation, not a build input).
    docs = os.path.join(ROOT, "docs")
    os.makedirs(docs, exist_ok=True)
    master.save(os.path.join(docs, "icon.png"))

    variants = {
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
    }
    for name, size in variants.items():
        master.resize((size, size), Image.LANCZOS).save(os.path.join(ASSET_DIR, name))

    images = []
    for size, scale in [(16, "1x"), (16, "2x"), (32, "1x"), (32, "2x"), (128, "1x"),
                        (128, "2x"), (256, "1x"), (256, "2x"), (512, "1x"), (512, "2x")]:
        suffix = "" if scale == "1x" else "@2x"
        images.append({
            "idiom": "mac",
            "scale": scale,
            "size": f"{size}x{size}",
            "filename": f"icon_{size}x{size}{suffix}.png",
        })
    with open(os.path.join(ASSET_DIR, "Contents.json"), "w", encoding="utf-8") as handle:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, handle, indent=2)

    catalog = os.path.dirname(ASSET_DIR)
    with open(os.path.join(catalog, "Contents.json"), "w", encoding="utf-8") as handle:
        json.dump({"info": {"author": "xcode", "version": 1}}, handle, indent=2)

    print(f"wrote {len(variants)} icon sizes to {ASSET_DIR}")


if __name__ == "__main__":
    sys.exit(main())

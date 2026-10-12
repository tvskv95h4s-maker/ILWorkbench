#!/usr/bin/env python3
"""Turns the raw window captures into the README images (needs Pillow).

Raw captures come from `ILWorkbench --promoshots`. AppKit's cacheDisplay draws the window
toolbar's vibrancy material as a black strip, so that strip (and the matching bottom band) is
cropped away and replaced by drawn window chrome.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

RAW = sys.argv[1] if len(sys.argv) > 1 else "build/promo-raw"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/screenshots"

BG_TOP = (246, 248, 252)
BG_BOTTOM = (228, 234, 244)
PAD = 48
TITLE_BAR = 28
SHOTS = [
    ("window-csharp.png", "csharp-view.png", "ILWorkbench — SampleLib.dll (C# 视图)"),
    ("window-il.png", "il-view.png", "ILWorkbench — SampleLib.dll (IL 视图)"),
    ("window-assembly.png", "assembly-info.png", "ILWorkbench — 程序集信息"),
    ("window-settings.png", "settings.png", "ILWorkbench — 设置"),
]


def font(size, bold=False, cjk=False):
    """Picks a system font; CJK text needs a font that actually has those glyphs."""
    candidates = (
        ["/System/Library/Fonts/PingFang.ttc",
         "/System/Library/Fonts/STHeiti Medium.ttc",
         "/System/Library/Fonts/Hiragino Sans GB.ttc"]
        if cjk else
        (["/System/Library/Fonts/SFNSDisplay.ttf"] if bold else ["/System/Library/Fonts/SFNS.ttf"]) +
        ["/System/Library/Fonts/Helvetica.ttc"]
    )
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def content(path):
    """Loads a raw capture and removes the black toolbar/bottom strips AppKit cannot render."""
    shot = Image.open(path).convert("RGB")
    if shot.width >= 1200:                      # main window
        shot = shot.crop((0, 53, shot.width, shot.height - 27))
    return shot


def chrome(shot, title):
    """Adds a macOS-like title bar so the image reads as an app window."""
    w, h = shot.size
    frame = Image.new("RGB", (w, h + TITLE_BAR), (236, 238, 241))
    frame.paste(shot, (0, TITLE_BAR))
    draw = ImageDraw.Draw(frame)
    draw.rectangle([0, 0, w, TITLE_BAR], fill=(232, 234, 238))
    draw.line([0, TITLE_BAR, w, TITLE_BAR], fill=(208, 210, 214))
    for i, color in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = 18 + i * 20
        draw.ellipse([cx - 6, 7, cx + 6, 19], fill=color)
    draw.text((w // 2, 14), title, font=font(12, True, cjk=True), fill=(90, 94, 100), anchor="mm")

    mask = Image.new("L", frame.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, frame.size[0] - 1, frame.size[1] - 1], 10, fill=255)
    rounded = Image.new("RGB", frame.size, (255, 255, 255))
    rounded.paste(frame, (0, 0), mask)
    return rounded, mask


def shadowed(image, mask, blur=18, offset=(0, 10)):
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", image.size, (30, 41, 59, 90)), (0, 0), mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    canvas = Image.new("RGBA", image.size, (0, 0, 0, 0))
    canvas.alpha_composite(shadow, offset)
    canvas.paste(image, (0, 0), mask)
    return canvas


def main():
    os.makedirs(OUT, exist_ok=True)
    windows = []
    for raw_name, out_name, title in SHOTS:
        raw = os.path.join(RAW, raw_name)
        if not os.path.exists(raw):
            print("missing", raw)
            continue
        framed, mask = chrome(content(raw), title)
        shadowed(framed, mask).convert("RGB").save(os.path.join(OUT, out_name))
        print("wrote", os.path.join(OUT, out_name), framed.size)
        windows.append((framed, mask, out_name))

    if not windows:
        return

    hero_window, hero_mask = windows[0][0], windows[0][1]
    hero = shadowed(hero_window, hero_mask)
    canvas_w = hero.width + PAD * 2
    canvas_h = hero.height + PAD * 2 + 96
    canvas = Image.new("RGB", (canvas_w, canvas_h), BG_TOP)
    gradient = Image.new("L", (1, canvas_h))
    for y in range(canvas_h):
        gradient.putpixel((0, y), int(255 * y / canvas_h))
    canvas = Image.composite(Image.new("RGB", canvas.size, BG_BOTTOM), canvas,
                             gradient.resize(canvas.size))

    draw = ImageDraw.Draw(canvas)
    title = "ILWorkbench"
    subtitle = "macOS 上的 .NET 反编译 / IL 编辑工作台 · 双击即用 · 无需安装 .NET"
    title_font, sub_font = font(40, True), font(17, cjk=True)
    draw.text(((canvas_w - draw.textlength(title, font=title_font)) / 2, 26),
              title, font=title_font, fill=(17, 24, 39))
    draw.text(((canvas_w - draw.textlength(subtitle, font=sub_font)) / 2, 74),
              subtitle, font=sub_font, fill=(71, 85, 105))
    canvas.paste(hero, (PAD, 96 + PAD), hero)
    canvas.save(os.path.join(OUT, "hero.png"))
    print("wrote", os.path.join(OUT, "hero.png"), canvas.size)


main()

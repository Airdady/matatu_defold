#!/usr/bin/env python3
"""
Generate the Android adaptive + legacy launcher icons from a single SVG.

Feed it the foreground artwork (icon.svg) and it writes, in order:

  bundle/android/res/drawable-nodpi/icon_foreground.png   (1) transparent fg
  bundle/android/res/drawable-nodpi/icon_background.png   (2) background layer
  bundle/android/res/drawable-nodpi/icon.png              (3) legacy composite
  bundle/android/res/drawable-anydpi-v26/icon.xml         (4) adaptive-icon xml

The SVG is treated as the FOREGROUND layer (should have a transparent
background). The background layer is generated from --background, which may be
a hex colour, a two-stop gradient, or another svg/png. On Android 8+ the two
layers are combined by the OS via icon.xml; older devices use the flat
icon.png.

Usage
-----
  python tools/generate_android_icons.py icon.svg
  python tools/generate_android_icons.py icon.svg --background "#C42B2B,#6E1414"
  python tools/generate_android_icons.py logo.svg --background bg.svg
  python tools/generate_android_icons.py icon.svg --size 432 --fg-scale 0.85 --out .

Requirements
------------
  pip install pillow cairosvg
  (or have one of these SVG rasterisers on PATH:
   rsvg-convert / inkscape / resvg / ImageMagick 'magick'|'convert')
"""

import argparse
import io
import os
import shutil
import subprocess
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("This script needs Pillow:  pip install pillow")


# --------------------------------------------------------------------------
# SVG -> PIL.Image rasterisation (cairosvg preferred, CLI tools as fallback)
# --------------------------------------------------------------------------
def rasterize_svg(path, size):
    # 1) cairosvg (pure-Python friendly, no CLI needed)
    try:
        import cairosvg
        png_bytes = cairosvg.svg2png(
            url=path, output_width=size, output_height=size,
            background_color="rgba(0,0,0,0)")
        return Image.open(io.BytesIO(png_bytes)).convert("RGBA")
    except ImportError:
        pass

    # 2) command-line rasterisers
    tmp = path + ".__tmp_icon__.png"
    tools = [
        ("rsvg-convert", ["rsvg-convert", "-w", str(size), "-h", str(size),
                          "-o", tmp, path]),
        ("resvg",        ["resvg", "-w", str(size), "-h", str(size), path, tmp]),
        ("inkscape",     ["inkscape", path, "--export-type=png",
                          "--export-filename=" + tmp,
                          "-w", str(size), "-h", str(size)]),
        ("magick",       ["magick", "-background", "none", "-density", "384",
                          path, "-resize", "%dx%d" % (size, size), tmp]),
        ("convert",      ["convert", "-background", "none", "-density", "384",
                          path, "-resize", "%dx%d" % (size, size), tmp]),
    ]
    for name, cmd in tools:
        if shutil.which(name):
            try:
                subprocess.run(cmd, check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                img = Image.open(tmp).convert("RGBA")
                os.remove(tmp)
                return img
            except Exception:
                if os.path.exists(tmp):
                    os.remove(tmp)

    sys.exit(
        "No SVG rasteriser found.\n"
        "  pip install cairosvg\n"
        "  or install one of: rsvg-convert / inkscape / resvg / ImageMagick")


# --------------------------------------------------------------------------
# Background layer
# --------------------------------------------------------------------------
def _hex(c):
    c = c.strip().lstrip("#")
    return tuple(int(c[i:i + 2], 16) for i in (0, 2, 4)) + (255,)


def make_background(spec, size):
    # An SVG or raster image path
    if os.path.isfile(spec):
        if spec.lower().endswith(".svg"):
            img = rasterize_svg(spec, size)
        else:
            img = Image.open(spec).convert("RGBA").resize((size, size), Image.LANCZOS)
        bg = Image.new("RGBA", (size, size), (0, 0, 0, 255))
        bg.alpha_composite(img)
        return bg

    # "#RRGGBB"  -> solid ;  "#RRGGBB,#RRGGBB" -> diagonal gradient
    parts = [p for p in spec.split(",") if p.strip()]
    if len(parts) == 1:
        return Image.new("RGBA", (size, size), _hex(parts[0]))
    top, bot = _hex(parts[0]), _hex(parts[1])
    bg = Image.new("RGBA", (size, size))
    px = bg.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2.0 * size)
            px[x, y] = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,)
    return bg


# --------------------------------------------------------------------------
# Foreground scaling into the adaptive safe zone (optional)
# --------------------------------------------------------------------------
def scale_foreground(fg, size, scale):
    if scale >= 0.999:
        return fg
    inner = max(1, int(size * scale))
    small = fg.resize((inner, inner), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    off = (size - inner) // 2
    canvas.alpha_composite(small, (off, off))
    return canvas


# --------------------------------------------------------------------------
# Legacy flat icon: composite fg over bg and apply a mask
# --------------------------------------------------------------------------
def make_legacy(fg, bg, size, shape, radius_frac):
    flat = bg.copy()
    flat.alpha_composite(fg)

    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    if shape == "square":
        d.rectangle([0, 0, size - 1, size - 1], fill=255)
    elif shape == "circle":
        d.ellipse([0, 0, size - 1, size - 1], fill=255)
    else:  # rounded
        r = int(size * radius_frac)
        d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=255)

    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(flat, (0, 0), mask)
    return out


ICON_XML = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/icon_background" />
    <foreground android:drawable="@drawable/icon_foreground" />
</adaptive-icon>
"""


def main():
    ap = argparse.ArgumentParser(
        description="Generate Android adaptive + legacy launcher icons from an SVG.")
    ap.add_argument("svg", help="foreground artwork (icon.svg, transparent bg)")
    ap.add_argument("--background", default="#C42B2B,#6E1414",
                    help='background: "#RRGGBB", "#RRGGBB,#RRGGBB" gradient, '
                         'or a path to an svg/png (default: red gradient)')
    ap.add_argument("--out", default=".",
                    help="project root; assets go under <out>/bundle/... (default: .)")
    ap.add_argument("--size", type=int, default=432,
                    help="icon size in px, 432 = 108dp @ 4x (default: 432)")
    ap.add_argument("--fg-scale", type=float, default=1.0,
                    help="shrink fg into the adaptive safe zone, e.g. 0.66-0.9 "
                         "(default: 1.0 = author sizing in the SVG)")
    ap.add_argument("--legacy-shape", choices=["rounded", "circle", "square"],
                    default="rounded", help="mask for the flat icon.png (default: rounded)")
    ap.add_argument("--legacy-radius", type=float, default=0.18,
                    help="corner radius fraction for rounded legacy icon (default: 0.18)")
    args = ap.parse_args()

    size = args.size
    nodpi = os.path.join(args.out, "bundle", "android", "res", "drawable-nodpi")
    v26 = os.path.join(args.out, "bundle", "android", "res", "drawable-anydpi-v26")
    os.makedirs(nodpi, exist_ok=True)
    os.makedirs(v26, exist_ok=True)

    fg = scale_foreground(rasterize_svg(args.svg, size), size, args.fg_scale)
    bg = make_background(args.background, size)
    legacy = make_legacy(fg, bg, size, args.legacy_shape, args.legacy_radius)

    outputs = [
        (os.path.join(nodpi, "icon_foreground.png"), fg),
        (os.path.join(nodpi, "icon_background.png"), bg),
        (os.path.join(nodpi, "icon.png"), legacy),
    ]
    for path, img in outputs:
        img.save(path)

    xml_path = os.path.join(v26, "icon.xml")
    with open(xml_path, "w") as f:
        f.write(ICON_XML)

    print("Generated (in order):")
    for i, (path, _) in enumerate(outputs, 1):
        print("  %d. %s  (%dx%d)" % (i, path, size, size))
    print("  4. %s" % xml_path)
    print("\nEnsure game.project [project] has:  bundle_resources = /bundle")


if __name__ == "__main__":
    main()

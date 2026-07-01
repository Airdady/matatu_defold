#!/usr/bin/env python3
"""
Scaffold ALL required Android launcher icons from a single SVG — no options
needed. Just run it from the project root:

    python3 ./tools/generate_android_icons.py

It reads tools/icon.svg (the foreground artwork) and writes, in order:

  ADAPTIVE (Android 8.0+):
    bundle/android/res/drawable-anydpi-v26/icon.xml
    bundle/android/res/drawable-nodpi/icon_foreground.png   (transparent fg)
    bundle/android/res/drawable-nodpi/icon_background.png    (background layer)

  LEGACY flat launcher icon @drawable/icon, one per density (pre-8.0):
    bundle/android/res/drawable-mdpi/icon.png      48x48
    bundle/android/res/drawable-hdpi/icon.png      72x72
    bundle/android/res/drawable-xhdpi/icon.png     96x96
    bundle/android/res/drawable-xxhdpi/icon.png   144x144
    bundle/android/res/drawable-xxxhdpi/icon.png  192x192

The default Defold Android manifest references @drawable/icon, which resolves
to the adaptive icon.xml on v26+ and the per-density flat icon.png below that.
Make sure game.project [project] has:  bundle_resources = /bundle

Everything is configurable via flags (see --help) but the defaults reproduce
the shipped Whot icons, so no flags are required.

Requirements:  pip install pillow cairosvg
  (or have rsvg-convert / inkscape / resvg / ImageMagick on PATH)
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

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)          # <root>/tools -> <root>
DEFAULT_SVG = os.path.join(SCRIPT_DIR, "icon.svg")

MASTER = 432                                          # 108dp @ 4x working size
# Legacy launcher densities (dp 48 base): px per density bucket.
LEGACY_DENSITIES = {
    "mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192,
}

ICON_XML = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/icon_background" />
    <foreground android:drawable="@drawable/icon_foreground" />
</adaptive-icon>
"""


# --------------------------------------------------------------------------
# SVG -> PIL.Image (cairosvg preferred, CLI rasterisers as fallback)
# --------------------------------------------------------------------------
def rasterize_svg(path, size):
    try:
        import cairosvg
        png = cairosvg.svg2png(url=path, output_width=size, output_height=size,
                               background_color="rgba(0,0,0,0)")
        return Image.open(io.BytesIO(png)).convert("RGBA")
    except ImportError:
        pass

    tmp = path + ".__tmp_icon__.png"
    tools = [
        ("rsvg-convert", ["rsvg-convert", "-w", str(size), "-h", str(size), "-o", tmp, path]),
        ("resvg",        ["resvg", "-w", str(size), "-h", str(size), path, tmp]),
        ("inkscape",     ["inkscape", path, "--export-type=png",
                          "--export-filename=" + tmp, "-w", str(size), "-h", str(size)]),
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
    sys.exit("No SVG rasteriser found.  pip install cairosvg  (or install "
             "rsvg-convert / inkscape / resvg / ImageMagick).")


def _hex(c):
    c = c.strip().lstrip("#")
    return tuple(int(c[i:i + 2], 16) for i in (0, 2, 4)) + (255,)


def make_background(spec, size):
    if os.path.isfile(spec):
        if spec.lower().endswith(".svg"):
            img = rasterize_svg(spec, size)
        else:
            img = Image.open(spec).convert("RGBA").resize((size, size), Image.LANCZOS)
        bg = Image.new("RGBA", (size, size), (0, 0, 0, 255))
        bg.alpha_composite(img)
        return bg
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


def scale_foreground(fg, size, scale):
    if scale >= 0.999:
        return fg
    inner = max(1, int(size * scale))
    small = fg.resize((inner, inner), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    off = (size - inner) // 2
    canvas.alpha_composite(small, (off, off))
    return canvas


def make_legacy_master(fg, bg, size, shape, radius_frac):
    flat = bg.copy()
    flat.alpha_composite(fg)
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    if shape == "square":
        d.rectangle([0, 0, size - 1, size - 1], fill=255)
    elif shape == "circle":
        d.ellipse([0, 0, size - 1, size - 1], fill=255)
    else:
        d.rounded_rectangle([0, 0, size - 1, size - 1],
                            radius=int(size * radius_frac), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(flat, (0, 0), mask)
    return out


def main():
    ap = argparse.ArgumentParser(
        description="Scaffold all required Android launcher icons from an SVG.")
    ap.add_argument("svg", nargs="?", default=DEFAULT_SVG,
                    help="foreground artwork (default: tools/icon.svg)")
    ap.add_argument("--background", default="#C42B2B,#6E1414",
                    help='background: "#RRGGBB", "#RRGGBB,#RRGGBB" gradient, or an '
                         'svg/png path (default: red gradient)')
    ap.add_argument("--out", default=PROJECT_ROOT,
                    help="project root; assets go under <out>/bundle/... "
                         "(default: the repo root)")
    ap.add_argument("--size", type=int, default=MASTER,
                    help="adaptive-layer size in px (default: 432)")
    ap.add_argument("--fg-scale", type=float, default=1.0,
                    help="shrink fg into the adaptive safe zone, e.g. 0.66-0.9 "
                         "(default: 1.0)")
    ap.add_argument("--legacy-shape", choices=["rounded", "circle", "square"],
                    default="rounded", help="mask for the flat icons (default: rounded)")
    ap.add_argument("--legacy-radius", type=float, default=0.18,
                    help="rounded corner radius fraction (default: 0.18)")
    args = ap.parse_args()

    if not os.path.isfile(args.svg):
        sys.exit("SVG not found: %s\n(place your artwork at tools/icon.svg or pass a path)"
                 % args.svg)

    res = os.path.join(args.out, "bundle", "android", "res")

    def rdir(name):
        p = os.path.join(res, name)
        os.makedirs(p, exist_ok=True)
        return p

    size = args.size
    fg = scale_foreground(rasterize_svg(args.svg, size), size, args.fg_scale)
    bg = make_background(args.background, size)
    legacy_master = make_legacy_master(fg, bg, size, args.legacy_shape, args.legacy_radius)

    written = []

    # 1) adaptive xml
    xml_path = os.path.join(rdir("drawable-anydpi-v26"), "icon.xml")
    with open(xml_path, "w") as f:
        f.write(ICON_XML)
    written.append((xml_path, "adaptive-icon"))

    # 2) adaptive layers (nodpi, full-res)
    fg_path = os.path.join(rdir("drawable-nodpi"), "icon_foreground.png")
    bg_path = os.path.join(rdir("drawable-nodpi"), "icon_background.png")
    fg.save(fg_path)
    bg.save(bg_path)
    written.append((fg_path, "%dx%d" % (size, size)))
    written.append((bg_path, "%dx%d" % (size, size)))

    # 3) legacy flat icon @drawable/icon, per density (downscaled from master)
    for dens, px in LEGACY_DENSITIES.items():
        p = os.path.join(rdir("drawable-" + dens), "icon.png")
        legacy_master.resize((px, px), Image.LANCZOS).save(p)
        written.append((p, "%dx%d" % (px, px)))

    print("Scaffolded Android icons from %s:" % os.path.relpath(args.svg, args.out))
    for i, (path, note) in enumerate(written, 1):
        print("  %2d. %s  (%s)" % (i, os.path.relpath(path, args.out), note))
    print("\nReminder: game.project [project] must have  bundle_resources = /bundle")


if __name__ == "__main__":
    main()

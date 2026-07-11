#!/usr/bin/env python3
"""
Regenerate assets/ui/bg_logo.png (the translucent card-fan watermark used
behind the boot/lobby background) from a per-game SVG — no options needed.
Run it from the project root:

    python3 ./tools/generate_bg_logo.py tools/logos/matatu.svg

It rasterizes the given SVG at bg_logo.png's native size (833x708) and
overwrites assets/ui/bg_logo.png in place — the filename/path stays the
same, so assets/ui/ui.atlas (which references it by path) needs no changes,
exactly like how main/card.script swaps the whole card atlas per game
without any frame-name changes.

Requirements:  pip install pillow cairosvg
  (or have rsvg-convert / inkscape / resvg / ImageMagick on PATH)
"""

import io
import os
import shutil
import subprocess
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("This script needs Pillow:  pip install pillow")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)          # <root>/tools -> <root>
DEFAULT_SVG = os.path.join(SCRIPT_DIR, "logos", "whot.svg")

# Native size of the existing shipped assets/ui/bg_logo.png.
WIDTH, HEIGHT = 833, 708


def rasterize_svg(path, width, height):
    try:
        import cairosvg
        png = cairosvg.svg2png(url=path, output_width=width, output_height=height,
                                background_color="rgba(0,0,0,0)")
        return Image.open(io.BytesIO(png)).convert("RGBA")
    except ImportError:
        pass

    tmp = path + ".__tmp_bg_logo__.png"
    tools = [
        ("rsvg-convert", ["rsvg-convert", "-w", str(width), "-h", str(height), "-o", tmp, path]),
        ("resvg",        ["resvg", "-w", str(width), "-h", str(height), path, tmp]),
        ("inkscape",     ["inkscape", path, "--export-type=png",
                          "--export-filename=" + tmp, "-w", str(width), "-h", str(height)]),
        ("magick",       ["magick", "-background", "none", "-density", "384",
                          path, "-resize", "%dx%d!" % (width, height), tmp]),
        ("convert",      ["convert", "-background", "none", "-density", "384",
                          path, "-resize", "%dx%d!" % (width, height), tmp]),
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


def main():
    svg = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SVG
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        PROJECT_ROOT, "assets", "ui", "bg_logo.png")

    if not os.path.isfile(svg):
        sys.exit("SVG not found: %s" % svg)

    img = rasterize_svg(svg, WIDTH, HEIGHT)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    img.save(out)
    print("Wrote %s (%dx%d) from %s" % (
        os.path.relpath(out, PROJECT_ROOT), WIDTH, HEIGHT,
        os.path.relpath(svg, PROJECT_ROOT)))


if __name__ == "__main__":
    main()

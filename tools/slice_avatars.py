#!/usr/bin/env python3
"""Slice avatars.webp (1920x1864, 8 cols x 8 rows, 240x233 each) into 60 PNGs
for the Defold avatars atlas. Mirrors AvatarSpriteSheet.gd (ids 1..60)."""
import os
from PIL import Image

SRC = "assets/images/avatars.webp"
OUT = "defold/assets/avatars"
COLS, ROWS = 8, 8
SW, SH = 240, 233
TOTAL = 60

def main():
    os.makedirs(OUT, exist_ok=True)
    im = Image.open(SRC).convert("RGBA")
    for i in range(TOTAL):
        row = i // COLS
        col = i % COLS
        x0 = round(col * SW)
        y0 = round(row * SH)
        crop = im.crop((x0, y0, x0 + SW, y0 + SH))
        crop.save(os.path.join(OUT, "avatar_%d.png" % (i + 1)))
    print("wrote", TOTAL, "avatars to", OUT)

if __name__ == "__main__":
    main()

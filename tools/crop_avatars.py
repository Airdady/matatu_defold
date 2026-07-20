#!/usr/bin/env python3
"""Crop 1px off the top and bottom of every avatar_*.png in assets/avatars/
(removes a stray line artifact along those edges) and overwrite the
originals in place."""
import glob
import os
from PIL import Image

DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "avatars")


def main():
    files = sorted(glob.glob(os.path.join(DIR, "avatar_*.png")))
    if not files:
        print("no avatar_*.png files found in", DIR)
        return
    for path in files:
        im = Image.open(path)
        w, h = im.size
        if h <= 2:
            print("skip (too short):", path)
            continue
        cropped = im.crop((0, 1, w, h - 1))
        cropped.save(path)
        print("cropped", os.path.basename(path), "%dx%d -> %dx%d" % (w, h, w, h - 2))
    print("done:", len(files), "files")


if __name__ == "__main__":
    main()

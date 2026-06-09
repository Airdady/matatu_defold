#!/usr/bin/env python3
"""Slice the Matatu card sprite sheet into individual PNGs for a Defold atlas.

The source sheet is a 12-col x 5-row grid (non-integer cell size), matching the
mapping in the original Godot `Card.gd` (CARD_SPRITES). We round per-cell so the
whole image is covered without drift.
"""
import os
from PIL import Image

SRC = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "images", "cards", "default_cards.png")
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "cards")
COLS, ROWS = 12, 5

# value+suit -> (row, col)   (Ace=15, Jack=11, Queen=12, King=13, Jokers=50R/50B)
FACES = {
    "15S": (0, 0), "15C": (0, 1), "15D": (0, 2), "15H": (0, 3),
    "2S": (0, 4), "2C": (0, 5), "2D": (0, 6), "2H": (0, 7),
    "3S": (0, 8), "3C": (0, 9), "3D": (0, 10), "3H": (0, 11),
    "4S": (1, 0), "4C": (1, 1), "4D": (1, 2), "4H": (1, 3),
    "5S": (1, 4), "5C": (1, 5), "5D": (1, 6), "5H": (1, 7),
    "6S": (1, 8), "6C": (1, 9), "6D": (1, 10), "6H": (1, 11),
    "7S": (2, 0), "7C": (2, 1), "7D": (2, 2), "7H": (2, 3),
    "8S": (2, 4), "8C": (2, 5), "8D": (2, 6), "8H": (2, 7),
    "9S": (2, 8), "9C": (2, 9), "9D": (2, 10), "9H": (2, 11),
    "10S": (3, 0), "10C": (3, 1), "10D": (3, 2), "10H": (3, 3),
    "11S": (3, 4), "11C": (3, 5), "11D": (3, 6), "11H": (3, 7),
    "12S": (3, 8), "12C": (3, 9), "12D": (3, 10), "12H": (3, 11),
    "13S": (4, 0), "13C": (4, 1), "13D": (4, 2), "13H": (4, 3),
    "50R": (4, 4), "50B": (4, 5),
}
EXTRA = {"back": (4, 6), "back_blue": (4, 7), "back_black": (4, 8)}


def cell_box(row, col, w, h):
    x0 = round(col * w / COLS)
    x1 = round((col + 1) * w / COLS)
    y0 = round(row * h / ROWS)
    y1 = round((row + 1) * h / ROWS)
    return (x0, y0, x1, y1)


def main():
    img = Image.open(SRC).convert("RGBA")
    w, h = img.size
    os.makedirs(OUT, exist_ok=True)
    count = 0
    allcards = dict(FACES)
    allcards.update(EXTRA)
    for key, (row, col) in allcards.items():
        box = cell_box(row, col, w, h)
        tile = img.crop(box)
        name = "card_%s.png" % key
        tile.save(os.path.join(OUT, name))
        count += 1
    print("sliced %d card images into %s" % (count, os.path.abspath(OUT)))


if __name__ == "__main__":
    main()

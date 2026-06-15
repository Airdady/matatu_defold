#!/bin/bash

# =============================================================================
# App UI Font Minification Script for macOS
# Operation: Retains the full Basic Latin (ASCII) character set.
# Includes A-Z, a-z, 0-9, standard punctuation, and essential UI symbols.
# =============================================================================

OUTPUT_DIR="compress"
mkdir -p "$OUTPUT_DIR"

if ! python3 -c "import fontTools" &> /dev/null; then
    echo "ERROR: fonttools was not found."
    echo "Please install it by running: python3 -m pip install fonttools"
    exit 1
fi

echo "================================================================="
echo " Starting Full UI Font Optimization"
echo " Retaining: Basic Latin (ASCII U+0020-007E)"
echo " Output Destination: ./${OUTPUT_DIR}/"
echo "================================================================="

shopt -s nocaseglob

count=0
for font in *.ttf; do
    [ -e "$font" ] || continue

    filename=$(basename "$font")
    target_path="${OUTPUT_DIR}/${filename}"
    
    echo "Optimizing Standard Font: $filename..."

    # ── FULL APP SUBSET RUN ──
    # U+0020-007E covers all standard English letters, numbers, and punctuation.
    # --layout-features='*' preserves kerning so your words don't look awkwardly spaced.
    python3 -m fontTools.subset "$font" \
               --unicodes="U+0020-007E" \
               --recommended-glyphs \
               --name-IDs='*' \
               --layout-features='*' \
               --output-file="$target_path"

    count=$((count + 1))
done

echo "================================================================="
echo " Complete! Successfully minified $count UI fonts."
echo "================================================================="
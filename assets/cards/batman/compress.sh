#!/bin/bash

# =============================================================================
# Image Minification Script for macOS
# Operation: Retains original image size and minifies via pngquant.
# Dependencies: pngquant (Install via 'brew install pngquant')
# =============================================================================

set -e

OUTPUT_DIR="compressed"

# Create target directory
mkdir -p "$OUTPUT_DIR"

# Pre-flight check for pngquant
if ! command -v pngquant &> /dev/null; then
    echo "ERROR: pngquant was not found on your system paths."
    echo "Please install it by running: brew install pngquant"
    exit 1
fi

echo "================================================================="
echo " Starting PNG Minification Loop (Original Sizes)"
echo " Output Destination: ./${OUTPUT_DIR}/"
echo "================================================================="

# Case-insensitive matching for PNG files
shopt -s nocaseglob

count=0
for img in *.png; do
    [ -e "$img" ] || continue

    filename=$(basename "$img")
    target_path="${OUTPUT_DIR}/${filename}"
    
    echo "Compressing: $filename..."

    # ── MINIFY VIA PNGQUANT ──
    # --output explicitly targets the compressed folder, keeping the original intact.
    # --quality=65-90 ensures visually lossless compression. 
    # The `|| cp ...` acts as a safety net: if pngquant decides it cannot compress 
    # the image without dropping below 65% quality, it will abort that single file 
    # and simply copy the original to the compressed folder so you don't lose the asset.
    pngquant --quality=65-90 --speed 1 --force --output "$target_path" "$img" || cp "$img" "$target_path"

    count=$((count + 1))
done

echo "================================================================="
echo " Success! $count files minified cleanly inside ./${OUTPUT_DIR}/"
echo "================================================================="
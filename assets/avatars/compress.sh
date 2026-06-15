#!/bin/bash

# ============================================
# Resize + Compress Images
# Using FFmpeg + pngquant
# macOS/Linux
#
# - Resize to 100x100
# - Compress PNG heavily with pngquant
# - Compress JPG/WEBP with ffmpeg
# - Preserve filenames
# - Output to ./compressed
# ============================================

mkdir -p compressed
mkdir -p .tmp

# Check dependencies
if ! command -v ffmpeg &> /dev/null; then
    echo "FFmpeg is not installed."
    echo "Install with: brew install ffmpeg"
    exit 1
fi

if ! command -v pngquant &> /dev/null; then
    echo "pngquant is not installed."
    echo "Install with: brew install pngquant"
    exit 1
fi

shopt -s nullglob

for img in *.{png,PNG,jpg,JPG,jpeg,JPEG,webp,WEBP}; do

    filename=$(basename "$img")
    extension="${filename##*.}"
    name="${filename%.*}"

    echo "Processing: $filename"

    tmp=".tmp/${name}.png"

    # Resize first using ffmpeg
    ffmpeg -y -i "$img" \
        -vf "scale=100:100:force_original_aspect_ratio=decrease,pad=100:100:(ow-iw)/2:(oh-ih)/2:color=white" \
        "$tmp" \
        -loglevel error

    # PNG compression with pngquant
    if [[ "$extension" =~ ^(png|PNG)$ ]]; then

        pngquant \
            --quality=70-90 \
            --speed 1 \
            --force \
            --output "compressed/$filename" \
            "$tmp"

    else
        # JPG/WEBP compression using ffmpeg
        ffmpeg -y -i "$tmp" \
            -q:v 3 \
            "compressed/$filename" \
            -loglevel error
    fi

    echo "Saved -> compressed/$filename"

done

rm -rf .tmp

echo "Done."
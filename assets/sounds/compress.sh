#!/bin/bash

# =============================================================================
# Audio Minification Script for macOS (Error-Resistant)
# Operation: Minifies all OGG files. If one fails, it skips and continues.
# =============================================================================

OUTPUT_DIR="compress"

# Create the compress directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Check if FFmpeg is installed
if ! command -v ffmpeg &> /dev/null; then
    echo "ERROR: ffmpeg was not found on your system."
    exit 1
fi

echo "================================================================="
echo " Starting OGG Audio Minification"
echo " Output Destination: ./${OUTPUT_DIR}/"
echo "================================================================="

# Case-insensitive matching for OGG files
shopt -s nocaseglob

count=0
for audio in *.ogg; do
    # Skip if no .ogg files are found
    [ -e "$audio" ] || continue

    filename=$(basename "$audio")
    target_path="${OUTPUT_DIR}/${filename}"
    
    echo "Minifying: $filename..."

    # ── MINIFY VIA FFMPEG ──
    # If ffmpeg fails for any reason (like corrupt metadata), it will catch the 
    # error, copy the original file to the folder instead, and KEEP GOING.
    if ffmpeg -i "$audio" -c:a libvorbis -q:a 5 -y "$target_path" &> /dev/null; then
        count=$((count + 1))
    else
        echo "   ⚠️ Warning on $filename. Copying original file instead."
        cp "$audio" "$target_path"
    fi

done

echo "================================================================="
echo " Done! Successfully processed files into ./${OUTPUT_DIR}/"
echo "================================================================="
#!/bin/bash

OUTPUT_DIR="compress"

mkdir -p "$OUTPUT_DIR"

if ! command -v ffmpeg &> /dev/null; then
    echo "ERROR: ffmpeg is not installed."
    exit 1
fi

echo "======================================================"
echo " Starting Extreme (Vorbis) Audio Compression"
echo "======================================================"

shopt -s nocaseglob

count_compressed=0
count_kept=0
failed=0

for audio in *.ogg; do
    [ -e "$audio" ] || continue

    filename=$(basename "$audio")
    target_path="${OUTPUT_DIR}/${filename}"

    echo ""
    echo "Processing: $filename"

    # Switched to libvorbis for VS Code compatibility
    # -q:a 0 is the lowest Vorbis quality setting for maximum minification
    if ffmpeg -v error \
        -i "$audio" \
        -c:a libvorbis \
        -q:a 0 \
        -map_metadata -1 \
        -y "$target_path"; then

        original_size=$(stat -f%z "$audio" 2>/dev/null || stat -c%s "$audio")
        compressed_size=$(stat -f%z "$target_path" 2>/dev/null || stat -c%s "$target_path")

        # FAIL-SAFE: Did we actually save space?
        if [ "$compressed_size" -ge "$original_size" ]; then
            echo "✓ Kept Original (Already highly compressed)"
            cp "$audio" "$target_path"
            count_kept=$((count_kept + 1))
        else
            echo "✓ Successfully Compressed"
            echo "  Original:   ${original_size} bytes"
            echo "  Compressed: ${compressed_size} bytes"
            count_compressed=$((count_compressed + 1))
        fi
    else
        echo "⚠️ Failed: $filename"
        cp "$audio" "$target_path"
        failed=$((failed + 1))
    fi
done

echo ""
echo "======================================================"
echo " Finished"
echo " Files Compressed:   $count_compressed"
echo " Originals Kept:     $count_kept"
echo " Failed:             $failed"
echo "======================================================"
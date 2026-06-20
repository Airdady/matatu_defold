#!/bin/bash

# ==========================================================
# DEFOLD HTML5 (WEB) DEBUG BUILD + LOCAL SERVER
# BUILDS THE GAME AND SERVES IT LOCALLY FOR TESTING
# ==========================================================

set -e

# ---------------- CONFIG ----------------
BUNDLE_DIR="./bundles/web_debug"
PORT=8080

# ----------------------------------------------------------

echo "=========================================================="
echo "🚀 Starting Defold HTML5 (Web) Debug Build"
echo "=========================================================="

# ==========================================================
# 1. BUILD HTML5 BUNDLE
# ==========================================================

echo ""
echo "=========================================================="
echo "🔨 Building Web Bundle..."
echo "=========================================================="

# Clean previous build to prevent caching issues
rm -rf "$BUNDLE_DIR"

java --enable-native-access=ALL-UNNAMED \
    -jar bob.jar \
    --archive \
    --platform js-web \
    --variant debug \
    --bundle-output "$BUNDLE_DIR" \
    resolve build bundle

echo "✅ Build completed"

# ==========================================================
# 2. FIND PROJECT DIRECTORY
# ==========================================================

echo ""
echo "🔍 Locating index.html..."

# bob.jar outputs the web build into a subfolder named after the project title.
# We find the index.html to dynamically get that folder path.
INDEX_PATH=$(find "$BUNDLE_DIR" -name "index.html" | head -n 1)

if [ -z "$INDEX_PATH" ]; then
    echo "❌ index.html not found! Build may have failed."
    exit 1
fi

WEB_ROOT=$(dirname "$INDEX_PATH")

echo "✅ Web root found:"
echo "$WEB_ROOT"

# ==========================================================
# 3. START LOCAL SERVER & OPEN BROWSER
# ==========================================================

echo ""
echo "=========================================================="
echo "🌐 STARTING LOCAL WEB SERVER"
echo "🔗 URL: http://localhost:$PORT"
echo "🛑 Press Ctrl+C to stop"
echo "=========================================================="
echo ""

# Attempt to open the default web browser automatically
if command -v open > /dev/null; then
    open "http://localhost:$PORT" # macOS
elif command -v xdg-open > /dev/null; then
    xdg-open "http://localhost:$PORT" # Linux
elif command -v start > /dev/null; then
    start "http://localhost:$PORT" # Windows (Git Bash/MSYS)
else
    echo "👉 Please open http://localhost:$PORT in your browser."
fi

# Start a local HTTP server using Python (cross-platform)
if command -v python3 > /dev/null; then
    python3 -m http.server $PORT --directory "$WEB_ROOT"
elif command -v python > /dev/null; then
    # Fallback for Python 2.x
    cd "$WEB_ROOT" && python -m SimpleHTTPServer $PORT
elif command -v npx > /dev/null; then
    # Fallback if Node.js is installed but Python isn't
    npx http-server "$WEB_ROOT" -p $PORT -c-1
else
    echo "❌ Neither Python nor Node.js is installed."
    echo "You must manually run a local web server in the '$WEB_ROOT' directory."
    exit 1
fi
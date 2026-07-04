#!/bin/bash

# ==========================================================
# DEfOLD ANDROID DEBUG BUILD + MULTI-DEVICE INSTALL
# INSTALLS ON ALL CONNECTED DEVICES
# PRESERVES APP DATA/CACHE
#
# USAGE:
#   ./build.sh [whot|matatu|kadi]
#
# The game argument (default: whot) is the single switch for the whole
# build: it patches modules/game_mode.lua's M.GAME so every endpoint,
# card-art path and in-app label follows (see that file's header), and
# sets game.project's [project] title + [android] package to match, so
# each game installs as its own distinct app instead of overwriting
# whichever one was built last.
# ==========================================================

set -e

# ---------------- CONFIG ----------------
GAME="${1:-whot}"
GAME="$(echo "$GAME" | tr '[:upper:]' '[:lower:]')"

case "$GAME" in
    whot)   GAME_UPPER="WHOT";   PACKAGE_NAME="com.matatu.whot";   PROJECT_TITLE="Whot"   ;;
    matatu) GAME_UPPER="MATATU"; PACKAGE_NAME="com.matatu.champ";  PROJECT_TITLE="Matatu" ;;
    kadi)   GAME_UPPER="KADI";   PACKAGE_NAME="com.matatu.kadi";   PROJECT_TITLE="Kadi"   ;;
    *)
        echo "❌ Unknown game '$GAME' — expected: whot | matatu | kadi"
        exit 1
        ;;
esac

BUNDLE_DIR="./bundles/android_debug_${GAME}"

# Optional manual activity
MAIN_ACTIVITY=""

# Log filters
LOG_FILTER="defold|DEBUG|Lua|lua|AndroidRuntime|crash|CRASH|FATAL|Exception"

# Architectures
ARCHITECTURES="armv7-android,arm64-android"

# ----------------------------------------------------------

echo "=========================================================="
echo "🚀 Starting Defold Android Debug Build"
echo "🎮 Game:    $GAME_UPPER"
echo "📦 Package: $PACKAGE_NAME"
echo "=========================================================="

# ==========================================================
# 0. SWITCH THE GAME MODE (modules/game_mode.lua + game.project title)
# ==========================================================

echo ""
echo "🎛️  Setting GAME_MODE to $GAME_UPPER..."

if [ ! -f modules/game_mode.lua ]; then
    echo "❌ modules/game_mode.lua not found — is this the matatu_defold repo root?"
    exit 1
fi

# M.GAME = "WHOT"          -- "MATATU" | "WHOT" | "KADI"
sed -i.bak -E "s/^(M\.GAME[[:space:]]*=[[:space:]]*)\"[A-Z]+\"/\1\"${GAME_UPPER}\"/" modules/game_mode.lua
rm -f modules/game_mode.lua.bak

if ! grep -q "M.GAME = \"${GAME_UPPER}\"" modules/game_mode.lua; then
    echo "❌ Failed to set M.GAME in modules/game_mode.lua"
    exit 1
fi

echo "✅ modules/game_mode.lua -> M.GAME = \"${GAME_UPPER}\""

# [project] title = ...
awk -v t="$PROJECT_TITLE" '
    /^\[project\]/ { print; in_project=1; next }
    /^\[/ && $0 != "[project]" { in_project=0 }
    in_project && /^title[[:space:]]*=/ { print "title = " t; next }
    { print }
' game.project > game.project.tmp && mv game.project.tmp game.project

echo "✅ game.project -> title = $PROJECT_TITLE"

# ==========================================================
# 1. UPDATE PACKAGE NAME
# ==========================================================

echo ""
echo "📝 Updating game.project package..."

if grep -q "\[android\]" game.project; then

    if grep -q "^package =" game.project; then

        awk -v p="$PACKAGE_NAME" '
        BEGIN { in_android=0 }

        /^\[android\]/ {
            in_android=1
            print
            next
        }

        /^\[/ && $0 != "[android]" {
            in_android=0
        }

        in_android && /^package =/ {
            print "package = " p
            next
        }

        {
            print
        }
        ' game.project > game.project.tmp

        mv game.project.tmp game.project

    else

        awk -v p="$PACKAGE_NAME" '
        /^\[android\]/ {
            print
            print "package = " p
            next
        }

        {
            print
        }
        ' game.project > game.project.tmp

        mv game.project.tmp game.project
    fi

else

    echo "" >> game.project
    echo "[android]" >> game.project
    echo "package = $PACKAGE_NAME" >> game.project
fi

echo "✅ Package updated"

# ==========================================================
# 2. BUILD APK
# ==========================================================

echo ""
echo "=========================================================="
echo "🔨 Building APK..."
echo "=========================================================="

java --enable-native-access=ALL-UNNAMED \
    -jar bob.jar \
    --archive \
    --platform armv7-android \
    --architectures "$ARCHITECTURES" \
    --variant debug \
    --bundle-output "$BUNDLE_DIR" \
    resolve build bundle

echo "✅ Build completed"

# ==========================================================
# 3. FIND APK
# ==========================================================

echo ""
echo "🔍 Searching APK..."

APK_PATH=$(find "$BUNDLE_DIR" -name "*.apk" | head -n 1)

if [ -z "$APK_PATH" ]; then
    echo "❌ APK not found!"
    exit 1
fi

echo "✅ APK Found:"
echo "$APK_PATH"

# ==========================================================
# 4. GET CONNECTED DEVICES
# ==========================================================

echo ""
echo "📱 Detecting Android devices..."

DEVICES=$(adb devices | grep -w "device" | cut -f1)

if [ -z "$DEVICES" ]; then
    echo "❌ No Android devices connected"
    exit 1
fi

echo "✅ Connected devices:"
echo "$DEVICES"

# ==========================================================
# 5. INSTALL ON ALL DEVICES
# ==========================================================

for DEVICE in $DEVICES
do
    echo ""
    echo "=========================================================="
    echo "📲 DEVICE: $DEVICE"
    echo "=========================================================="

    # ------------------------------------------------------
    # Clear logs only for this device
    # ------------------------------------------------------

    echo "🧹 Clearing old logs..."
    adb -s "$DEVICE" logcat -c || true

    # ------------------------------------------------------
    # Install APK WITHOUT deleting app data
    # ------------------------------------------------------

    echo "📥 Installing APK..."

    adb -s "$DEVICE" install -r "$APK_PATH"

    echo "✅ APK installed"
    echo "💾 App data/cache preserved"

    # ------------------------------------------------------
    # Force stop previous app instance
    # ------------------------------------------------------

    echo "🛑 Force stopping old app..."

    adb -s "$DEVICE" shell am force-stop "$PACKAGE_NAME" || true

    # ------------------------------------------------------
    # Resolve launch activity
    # ------------------------------------------------------

    echo "🔍 Resolving launch activity..."

    if [ -z "$MAIN_ACTIVITY" ]; then

        LAUNCH_ACTIVITY=$(adb -s "$DEVICE" shell cmd package resolve-activity \
            --brief "$PACKAGE_NAME" | tail -n 1 | tr -d '\r')

    else

        LAUNCH_ACTIVITY="$PACKAGE_NAME/$MAIN_ACTIVITY"
    fi

    if [ -z "$LAUNCH_ACTIVITY" ]; then
        echo "❌ Failed to resolve activity on $DEVICE"
        continue
    fi

    echo "✅ Launch Activity:"
    echo "$LAUNCH_ACTIVITY"

    # ------------------------------------------------------
    # Launch app
    # ------------------------------------------------------

    echo "🚀 Launching app..."

    adb -s "$DEVICE" shell am start -n "$LAUNCH_ACTIVITY"

    echo "✅ App launched"

done

# ==========================================================
# 6. LIVE LOGS FOR ALL DEVICES
# ==========================================================

echo ""
echo "=========================================================="
echo "📡 LIVE DEFOLD LOGS (ALL DEVICES)"
echo "💾 App data preserved"
echo "🛑 Press Ctrl+C to stop"
echo "=========================================================="
echo ""

for DEVICE in $DEVICES
do
(
    adb -s "$DEVICE" logcat | while read -r line
    do
        if echo "$line" | grep -E "$LOG_FILTER" > /dev/null
        then
            echo "[$DEVICE] $line"
        fi
    done
) &
done

wait
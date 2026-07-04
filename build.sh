#!/bin/bash

# ==========================================================
# DEfOLD ANDROID DEBUG BUILD + MULTI-DEVICE INSTALL
# INSTALLS ON ALL CONNECTED DEVICES
# PRESERVES APP DATA/CACHE
#
# USAGE:
#   ./build.sh [whot|matatu|kadi]
#
# The game argument (default: whot) patches modules/game_mode.lua's M.GAME so
# every endpoint, card-art path and in-app label follows (see that file's
# header), and sets game.project's [project] title to match.
#
# IMPORTANT: the Android [android] package name is deliberately NEVER changed
# by game here. Google Sign-In (GPGS) is registered in Google Cloud Console
# against one specific (package name + signing certificate) pair per
# [gpgs] client_id/app_id in game.project; building under a different,
# unregistered package makes on-device Google Sign-In fail with a
# DEVELOPER_ERROR before the request ever reaches the backend — it looks like
# a server/auth bug but is actually a client identity mismatch. All three
# games therefore ship under whatever package is already configured in
# game.project (do not vary it per game unless that package is also
# registered as an Android OAuth client for this project).
# ==========================================================

set -e

# ---------------- CONFIG ----------------
GAME="${1:-whot}"
GAME="$(echo "$GAME" | tr '[:upper:]' '[:lower:]')"

case "$GAME" in
    whot)   GAME_UPPER="WHOT";   PROJECT_TITLE="Whot"   ;;
    matatu) GAME_UPPER="MATATU"; PROJECT_TITLE="Matatu" ;;
    kadi)   GAME_UPPER="KADI";   PROJECT_TITLE="Kadi"   ;;
    *)
        echo "❌ Unknown game '$GAME' — expected: whot | matatu | kadi"
        exit 1
        ;;
esac

# Package name is read from game.project, never written by this script (see
# the GPGS note above) — this keeps Google Sign-In working for every game.
PACKAGE_NAME=$(awk '
    /^\[android\]/ { in_android=1; next }
    /^\[/ { in_android=0 }
    in_android && /^package[[:space:]]*=/ { sub(/^package[[:space:]]*=[[:space:]]*/, ""); print; exit }
' game.project)

if [ -z "$PACKAGE_NAME" ]; then
    echo "❌ Could not read [android] package from game.project"
    exit 1
fi

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
echo "ℹ️  Package left as-is (${PACKAGE_NAME}) — required for Google Sign-In, see note above."

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
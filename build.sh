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
# header), sets game.project's [project] title AND [android] package to
# match, and regenerates the Android launcher icon + bg_logo watermark
# (bundle/android/res/**, assets/ui/bg_logo.png) from tools/icons/<game>.svg
# and tools/logos/<game>.svg — so every visual identity asset matches
# whichever game was just built instead of whatever happened to be baked in
# from the last manual run.
#
# Package names (fixed per game, see the case statement below):
#   matatu -> com.matatu.champ
#   whot   -> com.matatu.pro
#   kadi   -> com.matatu.kadi
#
# IMPORTANT — Google Sign-In (GPGS): it's registered in Google Cloud Console
# against one specific (package name + signing certificate SHA-1) pair per
# [gpgs] client_id/app_id in game.project. Building under a package that
# ISN'T registered as an Android OAuth client makes on-device Google Sign-In
# fail with a DEVELOPER_ERROR before the request ever reaches the backend —
# it looks like a server/auth bug but is actually a client identity
# mismatch. All three packages above are signed with the SAME keystore (one
# Defold bundle config), so the SHA-1 is constant — but EACH package name
# still needs its OWN Android OAuth client entry registered in Google Cloud
# Console before Sign-In will work for that game. If a game's Sign-In starts
# failing right after switching its package here, that registration is the
# first thing to check.
# ==========================================================

set -e

# ---------------- CONFIG ----------------
GAME="${1:-whot}"
GAME="$(echo "$GAME" | tr '[:upper:]' '[:lower:]')"

case "$GAME" in
    whot)   GAME_UPPER="WHOT";   PROJECT_TITLE="Whot"
            PACKAGE_NAME="com.matatu.pro"
            ICON_SVG="tools/icons/whot.svg";   ICON_BG="#C42B2B,#6E1414"
            LOGO_SVG="tools/logos/whot.svg" ;;
    matatu) GAME_UPPER="MATATU"; PROJECT_TITLE="Matatu"
            PACKAGE_NAME="com.matatu.champ"
            ICON_SVG="tools/icons/matatu.svg"; ICON_BG="#4a3020,#2b1810"
            LOGO_SVG="tools/logos/matatu.svg" ;;
    kadi)   GAME_UPPER="KADI";   PROJECT_TITLE="Kadi"
            PACKAGE_NAME="com.matatu.kadi"
            ICON_SVG="tools/icons/kadi.svg";   ICON_BG="#12503a,#0a2e20"
            LOGO_SVG="tools/logos/kadi.svg" ;;
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

# [project] title = ... / [android] package = ...
awk -v t="$PROJECT_TITLE" -v p="$PACKAGE_NAME" '
    /^\[project\]/ { print; in_project=1; in_android=0; next }
    /^\[android\]/ { print; in_android=1; in_project=0; next }
    /^\[/ { in_project=0; in_android=0 }
    in_project && /^title[[:space:]]*=/ { print "title = " t; next }
    in_android && /^package[[:space:]]*=/ { print "package = " p; next }
    { print }
' game.project > game.project.tmp && mv game.project.tmp game.project

echo "✅ game.project -> title = $PROJECT_TITLE"
echo "✅ game.project -> [android] package = $PACKAGE_NAME"
echo "ℹ️  Make sure ${PACKAGE_NAME} is registered as an Android OAuth client for Google Sign-In (see note above) before relying on it for this game."

# ==========================================================
# 1. REGENERATE VISUAL IDENTITY ASSETS FOR $GAME_UPPER
#    (launcher icon: bundle/android/res/** ; bg_logo watermark: assets/ui/)
# ==========================================================

echo ""
echo "🎨 Regenerating launcher icon for $GAME_UPPER..."

# These used to soft-fail and silently keep whatever icon/logo was already on
# disk — which meant a build with missing deps would ship the PREVIOUS game's
# branding (e.g. building matatu on a machine that last successfully
# generated kadi's assets would silently keep showing Kadi's table-center
# logo) with only an easy-to-miss warning as evidence. Hard-failing here
# means the wrong branding can never ship unnoticed.
if [ ! -f "$ICON_SVG" ]; then
    echo "❌ $ICON_SVG not found — cannot regenerate the launcher icon for $GAME_UPPER."
    exit 1
elif ! command -v python3 >/dev/null 2>&1; then
    echo "❌ python3 not found — cannot regenerate the launcher icon for $GAME_UPPER. Install Python 3."
    exit 1
else
    if python3 tools/generate_android_icons.py "$ICON_SVG" --background "$ICON_BG" --out . ; then
        echo "✅ bundle/android/res/** -> ${ICON_SVG}"
    else
        echo "❌ Icon generation failed (see error above) — refusing to continue with a stale/wrong icon. Install deps with: pip install pillow cairosvg"
        exit 1
    fi
fi

echo ""
echo "🎨 Regenerating bg_logo watermark for $GAME_UPPER..."

if [ ! -f "$LOGO_SVG" ]; then
    echo "❌ $LOGO_SVG not found — cannot regenerate the bg_logo watermark for $GAME_UPPER."
    exit 1
elif ! command -v python3 >/dev/null 2>&1; then
    echo "❌ python3 not found — cannot regenerate the bg_logo watermark for $GAME_UPPER. Install Python 3."
    exit 1
else
    if python3 tools/generate_bg_logo.py "$LOGO_SVG" ; then
        echo "✅ assets/ui/bg_logo.png -> ${LOGO_SVG}"
    else
        echo "❌ bg_logo generation failed (see error above) — refusing to continue with a stale/wrong table-center logo. Install deps with: pip install pillow cairosvg"
        exit 1
    fi
fi

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
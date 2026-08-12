#!/bin/bash

# ==========================================================
# DEfOLD ANDROID DEBUG BUILD + MULTI-DEVICE INSTALL
# INSTALLS ON ALL CONNECTED DEVICES
# PRESERVES APP DATA/CACHE
#
# USAGE:
#   ./build.sh [whot|matatu|matatu_nap|kadi] [--version-name <x.x.x>] [--version-code <int>]
#
# --version-name/--version-code stamp game.project's version/version_code
# the same way release.sh does for a real release (see that script's "0c.
# STAMP THE VERSION INTO game.project" step) — so a debug build reports a
# real, comparable version to the backend's version gate instead of
# whatever was last checked in from an unrelated release. Without this, a
# debug build of one target could silently read a stale version stamped by
# a PREVIOUS release of a DIFFERENT target (they all share this one
# game.project), pass or fail that target's floor for reasons that have
# nothing to do with what's actually being tested.
#
# Both optional. Default is 99.99.99 / 999999 — a value obviously synthetic
# (nobody ships that number) and, being a numeric ordering comparison, well
# above any real floor for any target, so an ordinary debug run for
# GAMEPLAY testing is never blocked by the version gate. Pass real-looking
# values explicitly when you actually want to test the gate itself (a
# refusal, an update-required screen, a floor edge case).
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
# Package names (fixed per TARGET, see the case statement below):
#   matatu     -> com.matatu.champ
#   matatu_nap -> com.matatu.nap
#   whot       -> com.matatu.pro
#   kadi       -> com.matatu.kadi
#
# TARGET vs GAME: these were the same thing until matatu_nap. A target is what
# you are shipping — a package name, a keystore, a Play listing. A game is what
# the app IS at runtime (M.GAME), which drives endpoints, rules, currency and
# card art. matatu_nap is a second SHIPPING TARGET for the same GAME: byte for
# byte the same Matatu build, differing only in package name and signing, so
# GAME_UPPER stays MATATU and only the packaging changes.
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
#
# [gpgs] force_refresh_token = 1 asks Play Games for a NEW server auth code
# instead of replaying a cached one. A cached code that has already been
# redeemed, or has expired, comes back as an EMPTY STRING — which on the
# device looks exactly like a successful sign-in with nothing to send to the
# backend ("GPGS success, auth_code_present=false" in the auth debug trail).
# The refresh costs one extra round trip and removes that failure mode.
# It lives in game.project, which has no comment syntax, so the note is here.
# ==========================================================

set -e

# ---------------- CONFIG ----------------
TARGET=""
VERSION_NAME="99.99.99"
VERSION_CODE="999999"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version-name) VERSION_NAME="$2"; shift 2 ;;
        --version-code) VERSION_CODE="$2"; shift 2 ;;
        *)
            if [ -z "$TARGET" ]; then TARGET="$1"; fi
            shift ;;
    esac
done
TARGET="${TARGET:-whot}"
TARGET="$(echo "$TARGET" | tr '[:upper:]' '[:lower:]')"
GAME="$TARGET"

case "$TARGET" in
    whot)   GAME_UPPER="WHOT";   PROJECT_TITLE="Whot"
            PACKAGE_NAME="com.matatu.pro"
            ICON_SVG="tools/icons/whot.svg";   ICON_BG="#C42B2B,#6E1414"
            LOGO_SVG="tools/logos/whot.svg"
            KEYSTORE_PATH="./whot.keystore"; KEYSTORE_PASS="./whot.pass.txt"; KEYSTORE_ALIAS="matatu_alias" ;;
    matatu) GAME_UPPER="MATATU"; PROJECT_TITLE="Matatu"
            PACKAGE_NAME="com.matatu.champ"
            ICON_SVG="tools/icons/matatu.svg"; ICON_BG="#4a3020,#2b1810"
            LOGO_SVG="tools/logos/matatu.svg"
            KEYSTORE_PATH="./champion-keystore.jks"; KEYSTORE_PASS="./champion-keystore.pass.txt"; KEYSTORE_ALIAS="upload" ;;
    # Same GAME as matatu above — same M.GAME, same endpoints, same rules, same
    # gameplay. A separate shipping target: its own package name, its own
    # keystore (see release.sh) and its own launcher icon, so the two Matatu
    # apps are told apart on a home screen that has both installed.
    matatu_nap) GAME_UPPER="MATATU"; PROJECT_TITLE="Matatu"
            PACKAGE_NAME="com.matatu.nap"
            ICON_SVG="tools/icons/matatu_nap.svg"; ICON_BG="#4a3020,#2b1810"
            # No nap-specific watermark yet, so fall back to matatu's. Drop
            # tools/logos/matatu_nap.svg in and this picks it up with no code
            # change — the icon above is already nap's own.
            LOGO_SVG="tools/logos/matatu.svg"
            if [ -f "tools/logos/matatu_nap.svg" ]; then
                LOGO_SVG="tools/logos/matatu_nap.svg"
            fi
            KEYSTORE_PATH="./nap-keystore.jks"; KEYSTORE_PASS="./nap-keystore.pass.txt"
            KEYSTORE_ALIAS="${NAP_KEYSTORE_ALIAS:-upload}" ;;
    kadi)   GAME_UPPER="KADI";   PROJECT_TITLE="Kadi"
            PACKAGE_NAME="com.matatu.kadi"
            ICON_SVG="tools/icons/kadi.svg";   ICON_BG="#12503a,#0a2e20"
            LOGO_SVG="tools/logos/kadi.svg"
            KEYSTORE_PATH="./kadi.keystore"; KEYSTORE_PASS="./kadi.pass.txt"; KEYSTORE_ALIAS="matatu_alias" ;;
    *)
        echo "❌ Unknown target '$TARGET' — expected: whot | matatu | matatu_nap | kadi"
        exit 1
        ;;
esac

# Keyed by TARGET, not GAME: matatu and matatu_nap are both MATATU, and a
# shared directory would have them overwriting each other's bundle.
BUNDLE_DIR="./bundles/android_debug_${TARGET}"

# Optional manual activity
MAIN_ACTIVITY=""

# Log filters
LOG_FILTER="defold|FirebaseAuth|AUTH|DEBUG|Lua|lua|AndroidRuntime|crash|CRASH|FATAL|Exception"

# Architectures
ARCHITECTURES="armv7-android,arm64-android"

# ----------------------------------------------------------

echo "=========================================================="
echo "🚀 Starting Defold Android Debug Build"
echo "🎯 Target:  $TARGET"
echo "🎮 Game:    $GAME_UPPER"
echo "📦 Package: $PACKAGE_NAME"
echo "🏷  Version: $VERSION_NAME ($VERSION_CODE)"
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

# [project] version = ... / [android] version_code = ...
#
# Same stamp release.sh does for a real release (see its "0c. STAMP THE
# VERSION INTO game.project" step) — without it, a debug build reports
# whatever version was last checked in by an unrelated release, which is
# what let a matatu_nap debug build silently fail League's version floor
# while testing something that had nothing to do with versioning.
sed -i.bak -E "s/^(version[[:space:]]*=[[:space:]]*).*/\1${VERSION_NAME}/" game.project
if grep -q "^version_code[[:space:]]*=" game.project; then
    sed -i.bak -E "s/^(version_code[[:space:]]*=[[:space:]]*).*/\1${VERSION_CODE}/" game.project
else
    sed -i.bak -E "/^\[android\]/a version_code = ${VERSION_CODE}" game.project
fi
rm -f game.project.bak

if ! grep -q "^version = ${VERSION_NAME}$" game.project; then
    echo "❌ Failed to stamp version in game.project"
    exit 1
fi
if ! grep -q "^version_code = ${VERSION_CODE}$" game.project; then
    echo "❌ Failed to stamp version_code in game.project"
    exit 1
fi

echo "✅ game.project -> version = $VERSION_NAME"
echo "✅ game.project -> version_code = $VERSION_CODE"

# game.project is NOT an ini file, whatever it looks like. Bob's parser
# (Project.loadPropertiesData) accepts exactly two line shapes — "[section]"
# and "key = value" — and has no comment syntax at all. A "#" or ";" line
# fails the whole build with a bare "Could not parse: .../game.project" and no
# line number, which is a genuinely miserable thing to debug, so catch it here
# where we can say which line is wrong.
#
# This also runs after the rewrites above, so a malformed awk/sed edit is
# caught before bob rather than by it.
bad_line=""
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        # Comment markers first: "; force_refresh_token = 1" contains an "="
        # and would otherwise pass as a key/value line.
        \#*|\;*|" "*\#*|" "*\;*) bad_line="$line"; break ;;
        ""|\[*\])                continue ;;
        *=*)                     continue ;;
        *)                       bad_line="$line"; break ;;
    esac
done < game.project
if [ -n "$bad_line" ]; then
    echo "❌ game.project has a line bob cannot parse:"
    echo "     $bad_line"
    echo "   Only [section] headers and key = value lines are allowed."
    echo "   There is no comment syntax — '#' and ';' lines break the build."
    exit 1
fi
echo "✅ game.project parses"
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

KEYSTORE_ARGS=()
if [ -n "$KEYSTORE_PATH" ] && [ -f "$KEYSTORE_PATH" ] && [ -f "$KEYSTORE_PASS" ]; then
    KEYSTORE_ARGS=(
        -ks "$KEYSTORE_PATH"
        -ksp "$KEYSTORE_PASS"
        -ksa "$KEYSTORE_ALIAS"
    )
    echo "🔑 Signing with keystore: $KEYSTORE_PATH (alias: $KEYSTORE_ALIAS)"
fi

java --enable-native-access=ALL-UNNAMED \
    -jar bob.jar \
    --archive \
    --platform armv7-android \
    --architectures "$ARCHITECTURES" \
    --variant debug \
    --bundle-output "$BUNDLE_DIR" \
    "${KEYSTORE_ARGS[@]}" \
    build bundle

echo "✅ Build completed"

# ==========================================================
# 3. FIND APK
# ==========================================================

echo ""
echo "🔍 Searching APK..."

APK_PATH=$(find "$BUNDLE_DIR" ./build/default -name "*.apk" 2>/dev/null | head -n 1)

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
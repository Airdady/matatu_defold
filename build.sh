#!/bin/bash

# ==========================================================
# DEFOLD ANDROID DEBUG BUILD + MULTI-DEVICE INSTALL
# INSTALLS ON ALL CONNECTED DEVICES
# PRESERVES APP DATA/CACHE
#
# USAGE:
#   ./build.sh [whot|matatu|matatu_nap|kadi] [--version-name <x.x.x>] [--version-code <int>]
#
# ==========================================================

set -e

# ═══════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════
BOB_JAR="bob.jar"

# Default Variables
GAME="whot"
VERSION_NAME="99.99.99"
VERSION_CODE="999999"

# Terminal Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ═══════════════════════════════════════════════════════════
# FUNCTIONS & UX UTILITIES
# ═══════════════════════════════════════════════════════════
print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_usage() {
    echo -e "Usage: ./build.sh [whot|matatu|matatu_nap|kadi] [--version-name <x.x.x>] [--version-code <int>]"
    echo -e "Example: ${YELLOW}./build.sh matatu --version-name \"1.2.0\" --version-code 15${NC}"
}

# ═══════════════════════════════════════════════════════════
# ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version-name) VERSION_NAME="$2"; shift 2 ;;
        --version-code) VERSION_CODE="$2"; shift 2 ;;
        --game)         GAME="$2"; shift 2 ;;
        -*)             print_error "Unknown flag: $1"; print_usage; exit 1 ;;
        *)
            if [ -z "$TARGET" ]; then GAME="$1"; fi
            shift ;;
    esac
done

GAME="$(echo "$GAME" | tr '[:upper:]' '[:lower:]')"
TARGET="$GAME"

# ═══════════════════════════════════════════════════════════
# PER-GAME CONFIG
# ═══════════════════════════════════════════════════════════
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
    matatu_nap) GAME_UPPER="MATATU"; PROJECT_TITLE="Matatu"
            PACKAGE_NAME="com.matatu.nap"
            ICON_SVG="tools/icons/matatu_nap.svg"; ICON_BG="#4a3020,#2b1810"
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
        print_error "Unknown target '$TARGET' — expected: whot | matatu | matatu_nap | kadi"
        print_usage
        exit 1
        ;;
esac

BUNDLE_DIR="./bundles/android_debug_${TARGET}"
MAIN_ACTIVITY=""
LOG_FILTER="defold|FirebaseAuth|AUTH|DEBUG|Lua|lua|AndroidRuntime|crash|CRASH|FATAL|Exception"
ARCHITECTURES="armv7-android,arm64-android"

# ═══════════════════════════════════════════════════════════
# SIGNING IDENTITY PRINT
# ═══════════════════════════════════════════════════════════
if command -v keytool >/dev/null 2>&1 && [ -f "$KEYSTORE_PATH" ] && [ -f "$KEYSTORE_PASS" ]; then
    SHA1=$(keytool -list -v -keystore "$KEYSTORE_PATH" \
             -storepass "$(cat "$KEYSTORE_PASS")" -alias "$KEYSTORE_ALIAS" 2>/dev/null \
           | grep -m1 -oE 'SHA1: [0-9A-F:]+' | cut -d' ' -f2)
    [ -z "$SHA1" ] && SHA1="(could not read — check $KEYSTORE_PASS and alias '$KEYSTORE_ALIAS')"
else
    SHA1="(keytool unavailable or keystore files missing)"
fi

echo ""
print_status "Preparing Defold Debug Build: $GAME_UPPER v$VERSION_NAME (Code: $VERSION_CODE)"
echo "🔐 Signing identity for this build:"
echo "   package : $PACKAGE_NAME"
echo "   keystore: $KEYSTORE_PATH  (alias $KEYSTORE_ALIAS)"
echo "   SHA-1   : $SHA1"
echo ""

# ═══════════════════════════════════════════════════════════
# 0. SWITCH THE GAME MODE (modules/game_mode.lua)
# ═══════════════════════════════════════════════════════════
print_status "Setting GAME_MODE to $GAME_UPPER..."

if [ ! -f modules/game_mode.lua ]; then
    print_error "modules/game_mode.lua not found — is this the matatu_defold repo root?"
    exit 1
fi

sed -i.bak -E "s/^(M\.GAME[[:space:]]*=[[:space:]]*)\"[A-Z]+\"/\1\"${GAME_UPPER}\"/" modules/game_mode.lua
rm -f modules/game_mode.lua.bak

if ! grep -q "M.GAME = \"${GAME_UPPER}\"" modules/game_mode.lua; then
    print_error "Failed to set M.GAME in modules/game_mode.lua"
    exit 1
fi

print_success "modules/game_mode.lua -> M.GAME = \"${GAME_UPPER}\""

# ═══════════════════════════════════════════════════════════
# 0b. STAMP THE VERSION INTO modules/config.lua
# ═══════════════════════════════════════════════════════════
print_status "Stamping version $VERSION_NAME ($VERSION_CODE) into modules/config.lua..."

if [ ! -f modules/config.lua ]; then
    print_error "modules/config.lua not found — is this the matatu_defold repo root?"
    exit 1
fi

sed -i.bak -E \
    -e "s/^(M\.APP_VERSION[[:space:]]*=[[:space:]]*)\".*\"/\1\"${VERSION_NAME}\"/" \
    -e "s/^(M\.APP_BUILD[[:space:]]*=[[:space:]]*).*/\1${VERSION_CODE}/" \
    modules/config.lua
rm -f modules/config.lua.bak

if ! grep -q "^M.APP_VERSION = \"${VERSION_NAME}\"" modules/config.lua; then
    print_error "Failed to stamp M.APP_VERSION in modules/config.lua"
    exit 1
fi
if ! grep -q "^M.APP_BUILD   = ${VERSION_CODE}$" modules/config.lua; then
    print_error "Failed to stamp M.APP_BUILD in modules/config.lua"
    exit 1
fi

print_success "modules/config.lua -> APP_VERSION=${VERSION_NAME} APP_BUILD=${VERSION_CODE}"

# ═══════════════════════════════════════════════════════════
# 0c. STAMP THE VERSION AND TARGET INTO game.project ITSELF
# ═══════════════════════════════════════════════════════════
print_status "Updating game.project title, package, and version ($VERSION_NAME / $VERSION_CODE)..."

if [ ! -f game.project ] || ! grep -q "^\[project\]" game.project; then
    print_error "game.project not found or has no [project] section — is this the matatu_defold repo root?"
    exit 1
fi

# Update project title and package name
awk -v t="$PROJECT_TITLE" -v p="$PACKAGE_NAME" '
    /^\[project\]/ { print; in_project=1; in_android=0; next }
    /^\[android\]/ { print; in_android=1; in_project=0; next }
    /^\[/ { in_project=0; in_android=0 }
    in_project && /^title[[:space:]]*=/ { print "title = " t; next }
    in_android && /^package[[:space:]]*=/ { print "package = " p; next }
    { print }
' game.project > game.project.tmp && mv game.project.tmp game.project

# Update version and version_code
sed -i.bak -E "s/^(version[[:space:]]*=[[:space:]]*).*/\1${VERSION_NAME}/" game.project
if grep -q "^version_code[[:space:]]*=" game.project; then
    sed -i.bak -E "s/^(version_code[[:space:]]*=[[:space:]]*).*/\1${VERSION_CODE}/" game.project
    rm -f game.project.bak
else
    awk -v vc="version_code = ${VERSION_CODE}" '
        /^\[android\]/ { print; print vc; next }
        { print }
    ' game.project > game.project.tmp && mv game.project.tmp game.project
fi

# Verification checks
if ! grep -q "^version = ${VERSION_NAME}$" game.project; then
    print_error "Failed to stamp version in game.project"
    exit 1
fi
if ! grep -q "^version_code = ${VERSION_CODE}$" game.project; then
    print_error "Failed to stamp version_code in game.project"
    exit 1
fi

# game.project Syntax Validation for bob
bad_line=""
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        \#*|\;*|" "*\#*|" "*\;*) bad_line="$line"; break ;;
        ""|\[*\])                continue ;;
        *=*)                     continue ;;
        *)                       bad_line="$line"; break ;;
    esac
done < game.project

if [ -n "$bad_line" ]; then
    print_error "game.project has a line bob cannot parse:"
    echo "     $bad_line"
    exit 1
fi

print_success "game.project -> title=$PROJECT_TITLE, package=$PACKAGE_NAME, version=$VERSION_NAME ($VERSION_CODE)"

# ═══════════════════════════════════════════════════════════
# 1. REGENERATE VISUAL IDENTITY ASSETS
# ═══════════════════════════════════════════════════════════
print_status "Regenerating launcher icon for $GAME_UPPER..."

if [ ! -f "$ICON_SVG" ]; then
    print_error "$ICON_SVG not found — cannot regenerate launcher icon."
    exit 1
elif ! command -v python3 >/dev/null 2>&1; then
    print_error "python3 not found. Install Python 3."
    exit 1
else
    if python3 tools/generate_android_icons.py "$ICON_SVG" --background "$ICON_BG" --out . ; then
        print_success "bundle/android/res/** -> ${ICON_SVG}"
    else
        print_error "Icon generation failed. Install deps with: pip install pillow cairosvg"
        exit 1
    fi
fi

print_status "Regenerating bg_logo watermark for $GAME_UPPER..."

if [ ! -f "$LOGO_SVG" ]; then
    print_error "$LOGO_SVG not found — cannot regenerate bg_logo watermark."
    exit 1
else
    if python3 tools/generate_bg_logo.py "$LOGO_SVG" ; then
        print_success "assets/ui/bg_logo.png -> ${LOGO_SVG}"
    else
        print_error "bg_logo generation failed. Install deps with: pip install pillow cairosvg"
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════════
# 2. BUILD APK
# ═══════════════════════════════════════════════════════════
print_status "Building APK..."

KEYSTORE_ARGS=()
if [ -n "$KEYSTORE_PATH" ] && [ -f "$KEYSTORE_PATH" ] && [ -f "$KEYSTORE_PASS" ]; then
    KEYSTORE_ARGS=(
        -ks "$KEYSTORE_PATH"
        -ksp "$KEYSTORE_PASS"
        -ksa "$KEYSTORE_ALIAS"
    )
    print_status "Signing with keystore: $KEYSTORE_PATH (alias: $KEYSTORE_ALIAS)"
fi

java --enable-native-access=ALL-UNNAMED \
    -jar "$BOB_JAR" \
    --archive \
    --platform armv7-android \
    --architectures "$ARCHITECTURES" \
    --variant debug \
    --bundle-output "$BUNDLE_DIR" \
    "${KEYSTORE_ARGS[@]}" \
    build bundle

print_success "Build completed successfully."

# ═══════════════════════════════════════════════════════════
# 3. FIND APK
# ═══════════════════════════════════════════════════════════
print_status "Searching for output APK..."

APK_PATH=$(find "$BUNDLE_DIR" ./build/default -name "*.apk" 2>/dev/null | head -n 1)

if [ -z "$APK_PATH" ]; then
    print_error "APK not found!"
    exit 1
fi

print_success "APK Found: $APK_PATH"

# ═══════════════════════════════════════════════════════════
# 4. GET CONNECTED DEVICES
# ═══════════════════════════════════════════════════════════
print_status "Detecting Android devices..."

DEVICES=$(adb devices | grep -w "device" | cut -f1)

if [ -z "$DEVICES" ]; then
    print_error "No Android devices connected!"
    exit 1
fi

print_success "Connected devices:"
echo "$DEVICES"

# ═══════════════════════════════════════════════════════════
# 5. INSTALL ON ALL DEVICES
# ═══════════════════════════════════════════════════════════
for DEVICE in $DEVICES
do
    echo ""
    print_status "📲 DEVICE: $DEVICE"

    print_status "🧹 Clearing old logs..."
    adb -s "$DEVICE" logcat -c || true

    print_status "📥 Installing APK (preserving app data)..."
    adb -s "$DEVICE" install -r "$APK_PATH"
    print_success "APK installed on $DEVICE."

    print_status "🛑 Force stopping old app instance..."
    adb -s "$DEVICE" shell am force-stop "$PACKAGE_NAME" || true

    print_status "🔍 Resolving launch activity..."
    if [ -z "$MAIN_ACTIVITY" ]; then
        LAUNCH_ACTIVITY=$(adb -s "$DEVICE" shell cmd package resolve-activity \
            --brief "$PACKAGE_NAME" | tail -n 1 | tr -d '\r')
    else
        LAUNCH_ACTIVITY="$PACKAGE_NAME/$MAIN_ACTIVITY"
    fi

    if [ -z "$LAUNCH_ACTIVITY" ]; then
        print_error "Failed to resolve activity on $DEVICE"
        continue
    fi

    print_success "Launch Activity resolved: $LAUNCH_ACTIVITY"

    print_status "🚀 Launching app..."
    adb -s "$DEVICE" shell am start -n "$LAUNCH_ACTIVITY"
    print_success "App launched on $DEVICE."
done

# ═══════════════════════════════════════════════════════════
# 6. LIVE LOGS FOR ALL DEVICES
# ═══════════════════════════════════════════════════════════
echo ""
print_status "📡 LIVE DEFOLD LOGS (ALL DEVICES)"
print_warning "Press Ctrl+C to stop stream"
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
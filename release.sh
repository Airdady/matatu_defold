#!/bin/bash

# Ensure the script stops if any command fails initially
set -e

# ═══════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════
BOB_JAR="bob.jar"
TMP_SETTINGS="override.ini"

# Default Variables (Overwritten by terminal command flags)
GAME="whot"
VERSION_NAME=""
VERSION_CODE=""

# Terminal Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ═══════════════════════════════════════════════════════════
# FUNCTIONS & UX UTILITIES
# ═══════════════════════════════════════════════════════════
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_usage() {
    echo -e "Usage: ./release.sh --game <whot|matatu|kadi> --version-name <x.x.x> --version-code <int>"
    echo -e "Example: ${YELLOW}./release.sh --game matatu --version-name \"1.2.0\" --version-code 15${NC}"
}

# ═══════════════════════════════════════════════════════════
# ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --game) GAME="$2"; shift ;;
        --version-name) VERSION_NAME="$2"; shift ;;
        --version-code) VERSION_CODE="$2"; shift ;;
        *) print_error "Unknown parameter passed: $1"; print_usage; exit 1 ;;
    esac
    shift
done

GAME="$(echo "$GAME" | tr '[:upper:]' '[:lower:]')"

# Validation Checks
if [ -z "$VERSION_NAME" ] || [ -z "$VERSION_CODE" ]; then
    print_error "Missing required production arguments."
    print_usage
    exit 1
fi

# ═══════════════════════════════════════════════════════════
# PER-GAME CONFIG
# ═══════════════════════════════════════════════════════════
# Package name + visual identity sources mirror build.sh's case statement.
# All three games are currently signed with the SAME keystore/alias — see
# build.sh's Google Sign-In note: each package name still needs its OWN
# Android OAuth client registered against this keystore's SHA-1 in Google
# Cloud Console, so sharing the keystore is intentional, not a placeholder.
# Kept as a per-game case (rather than one top-level constant) so switching
# any single game to its own dedicated keystore later is a one-line change.
case "$GAME" in
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
    kadi)   GAME_UPPER="KADI";   PROJECT_TITLE="Kadi"
            PACKAGE_NAME="com.matatu.kadi"
            ICON_SVG="tools/icons/kadi.svg";   ICON_BG="#12503a,#0a2e20"
            LOGO_SVG="tools/logos/kadi.svg"
            KEYSTORE_PATH="./kadi.keystore"; KEYSTORE_PASS="./kadi.pass.txt"; KEYSTORE_ALIAS="matatu_alias" ;;
    *)
        print_error "Unknown game '$GAME' — expected: whot | matatu | kadi"
        print_usage
        exit 1
        ;;
esac

OUTPUT_DIR="./bundles/android_release_${GAME}"

if [ ! -f "$KEYSTORE_PATH" ]; then
    print_error "Keystore not found at $KEYSTORE_PATH"
    exit 1
fi

if [ ! -f "$KEYSTORE_PASS" ]; then
    print_error "Password file not found at $KEYSTORE_PASS"
    print_warning "Please create this file and add your key password before compiling."
    exit 1
fi

print_status "Preparing Defold Release Build: $GAME_UPPER v$VERSION_NAME (Code: $VERSION_CODE)"

# ═══════════════════════════════════════════════════════════
# 0. SWITCH THE GAME MODE (modules/game_mode.lua)
# ═══════════════════════════════════════════════════════════
# M.GAME drives every endpoint/card-art path/in-app label at runtime, so it
# has to be baked into the Lua source before bob.jar archives it — unlike
# the project title/package below, this can't be done via a --settings
# override.
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
# 1. REGENERATE VISUAL IDENTITY ASSETS FOR $GAME_UPPER
#    (launcher icon: bundle/android/res/** ; bg_logo watermark: assets/ui/)
# ═══════════════════════════════════════════════════════════
print_status "Regenerating launcher icon for $GAME_UPPER..."

# Hard-fail instead of soft-skipping: this used to silently keep whatever
# icon/logo was already on disk when generation couldn't run, which for a
# RELEASE build means shipping the wrong game's branding to the Play Store
# with only an easy-to-miss warning as evidence.
if [ ! -f "$ICON_SVG" ]; then
    print_error "$ICON_SVG not found — cannot regenerate the launcher icon for $GAME_UPPER."
    exit 1
elif ! command -v python3 >/dev/null 2>&1; then
    print_error "python3 not found — cannot regenerate the launcher icon for $GAME_UPPER. Install Python 3."
    exit 1
else
    if python3 tools/generate_android_icons.py "$ICON_SVG" --background "$ICON_BG" --out . ; then
        print_success "bundle/android/res/** -> ${ICON_SVG}"
    else
        print_error "Icon generation failed (see error above) — refusing to release with a stale/wrong icon. Install deps with: pip install pillow cairosvg"
        exit 1
    fi
fi

print_status "Regenerating bg_logo watermark for $GAME_UPPER..."

if [ ! -f "$LOGO_SVG" ]; then
    print_error "$LOGO_SVG not found — cannot regenerate the bg_logo watermark for $GAME_UPPER."
    exit 1
elif ! command -v python3 >/dev/null 2>&1; then
    print_error "python3 not found — cannot regenerate the bg_logo watermark for $GAME_UPPER. Install Python 3."
    exit 1
else
    if python3 tools/generate_bg_logo.py "$LOGO_SVG" ; then
        print_success "assets/ui/bg_logo.png -> ${LOGO_SVG}"
    else
        print_error "bg_logo generation failed (see error above) — refusing to release with a stale/wrong table-center logo. Install deps with: pip install pillow cairosvg"
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════════
# 2. PRE-BUILD CONFIGURATION
# ═══════════════════════════════════════════════════════════
print_status "Generating temporary configuration with ${PACKAGE_NAME} injection..."

# bob.jar requires an actual config file for settings overrides. Title +
# package are applied here (not by editing game.project directly) so a
# release build never leaves the working tree dirty.
echo "[project]" > $TMP_SETTINGS
echo "version = $VERSION_NAME" >> $TMP_SETTINGS
echo "title = $PROJECT_TITLE" >> $TMP_SETTINGS
echo "" >> $TMP_SETTINGS
echo "[android]" >> $TMP_SETTINGS
echo "version_code = $VERSION_CODE" >> $TMP_SETTINGS
echo "package = $PACKAGE_NAME" >> $TMP_SETTINGS

print_status "Configurations updated successfully."

# ═══════════════════════════════════════════════════════════
# 3. COMPILATION PROCESS
# ═══════════════════════════════════════════════════════════
mkdir -p "$OUTPUT_DIR"

print_status "Running Defold bob.jar Engine (AAB Release Mode)..."
echo "-------------------------------------------------------"

# Temporarily disable hard exit so we can cleanly drop the temp file if java errors out
set +e

java --enable-native-access=ALL-UNNAMED -jar "$BOB_JAR" \
  --archive \
  --platform armv7-android \
  --architectures armv7-android,arm64-android \
  --bundle-format aab \
  --variant release \
  -ks "$KEYSTORE_PATH" \
  -ksp "$KEYSTORE_PASS" \
  -ksa "$KEYSTORE_ALIAS" \
  --settings "$TMP_SETTINGS" \
  --bundle-output "$OUTPUT_DIR" \
  resolve build bundle

BUILD_STATUS=$?

# Restore strict code halting
set -e

# Delete the temporary override file to keep directory clean
rm -f "$TMP_SETTINGS"

# ═══════════════════════════════════════════════════════════
# VERIFICATION & OUTPUT LOGGING
# ═══════════════════════════════════════════════════════════
if [ $BUILD_STATUS -eq 0 ]; then
    echo "-------------------------------------------------------"
    print_success "Build Successful!"

    # Locate the compiled bundle package
    RELEASE_PATH=$(find "$OUTPUT_DIR" -name "*.aab" | head -n 1)

    if [ -n "$RELEASE_PATH" ]; then
        echo -e "📁 ${YELLOW}Output Destination:${NC} $RELEASE_PATH"
        echo -e "🎮 ${YELLOW}Game:${NC} $GAME_UPPER"
        echo -e "🆔 ${YELLOW}Package Name:${NC} $PACKAGE_NAME"
        echo -e "🏷  ${YELLOW}App Store Version:${NC} $VERSION_NAME ($VERSION_CODE)"
        echo -e "📦 ${YELLOW}Target Engine Format:${NC} .aab (Android App Bundle)"
        echo ""
        print_success "Ready for Google Play Console upload."
    else
        print_warning "Build processed successfully, but output file couldn't be located automatically inside $OUTPUT_DIR"
    fi
else
    echo "-------------------------------------------------------"
    print_error "Build compilation failed! Please look through the bob.jar error details above."
    exit 1
fi

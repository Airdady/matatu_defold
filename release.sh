#!/bin/bash

# Ensure the script stops if any command fails initially
set -e

# ═══════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════
BOB_JAR="bob.jar"
OUTPUT_DIR="./bundles/android_release"
TMP_SETTINGS="override.ini"

KEYSTORE_PATH="./champion-keystore.jks"
KEYSTORE_PASS="./keystore.pass.txt"
KEYSTORE_ALIAS="upload"

# Default Variables (Overwritten by terminal command flags)
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
    echo -e "Usage: ./release.sh --version-name <x.x.x> --version-code <int>"
    echo -e "Example: ${YELLOW}./release.sh --version-name \"1.2.0\" --version-code 15${NC}"
}

# ═══════════════════════════════════════════════════════════
# ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --version-name) VERSION_NAME="$2"; shift ;;
        --version-code) VERSION_CODE="$2"; shift ;;
        *) print_error "Unknown parameter passed: $1"; print_usage; exit 1 ;;
    esac
    shift
done

# Validation Checks
if [ -z "$VERSION_NAME" ] || [ -z "$VERSION_CODE" ]; then
    print_error "Missing required production arguments."
    print_usage
    exit 1
fi

if [ ! -f "$KEYSTORE_PASS" ]; then
    print_error "Password file not found at $KEYSTORE_PASS"
    print_warning "Please create this file and add your key password before compiling."
    exit 1
fi

print_status "Preparing Defold Release Build: v$VERSION_NAME (Code: $VERSION_CODE)"

# ═══════════════════════════════════════════════════════════
# PRE-BUILD CONFIGURATION
# ═══════════════════════════════════════════════════════════
print_status "Generating temporary configurations with com.matatu.champ injection..."

# bob.jar requires an actual config file for settings overrides
echo "[project]" > $TMP_SETTINGS
echo "version = $VERSION_NAME" >> $TMP_SETTINGS
echo "" >> $TMP_SETTINGS
echo "[android]" >> $TMP_SETTINGS
echo "version_code = $VERSION_CODE" >> $TMP_SETTINGS
echo "package = com.matatu.champ" >> $TMP_SETTINGS

print_status "Configurations updated successfully."

# ═══════════════════════════════════════════════════════════
# COMPILATION PROCESS
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
        echo -e "🆔 ${YELLOW}Package Name:${NC} com.matatu.nap"
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
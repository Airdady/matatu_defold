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
    echo -e "Usage: ./release.sh --game <whot|matatu|matatu_nap|kadi> --version-name <x.x.x> --version-code <int>"
    echo -e "Example: ${YELLOW}./release.sh --game matatu --version-name \"1.2.0\" --version-code 15${NC}"
    echo -e "         ${YELLOW}./release.sh --game matatu_nap --version-name \"1.2.0\" --version-code 15${NC}"
    echo -e "matatu_nap is the same GAME as matatu — same build, own package + keystore."
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
# What is being SHIPPED (package + keystore + output dir) as opposed to what
# the app IS at runtime (GAME_UPPER / M.GAME). matatu and matatu_nap are two
# targets for one game.
TARGET="$GAME"

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
#
# SIGNING: every target has its OWN certificate. An earlier version of this
# comment said whot, matatu and kadi shared one keystore; they do not, and
# believing they did is what let the Google Sign-In breakage go unnoticed.
# Verified fingerprints:
#
#   whot        com.matatu.pro    whot.keystore           E2:BC:73:D8:…:5A:0B
#   matatu      com.matatu.champ  champion-keystore.jks   01:91:F3:04:…:C0:BA
#   matatu_nap  com.matatu.nap    nap-keystore.jks        56:36:F9:1E:…:7C:98
#   kadi        com.matatu.kadi   kadi.keystore           (file is missing)
#
# nap-keystore.jks is byte-identical to the original upload-keystore.jks, so
# com.matatu.nap + 56:36:F9:1E:… is the pair this app shipped under before
# 2026-06-26 — the one that has always worked. matatu moved to a NEW package
# AND a NEW certificate in the same commit, giving it an identity nothing had
# ever registered.
#
# EACH pair needs its own Android OAuth client in Google Cloud Console. When a
# pair is not registered, Play Games still signs the player IN (that needs only
# the app_id) but requestServerAuthCode() returns null — a "successful" sign-in
# with nothing to send to the backend. It does NOT surface as DEVELOPER_ERROR,
# which is why it reads as a server fault.
#
# If the app ships through Play App Signing, the certificate that matters
# on-device is PLAY'S, not the upload keystore above: register the SHA-1 from
# Play Console > Setup > App signing.
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
    # Identical to matatu in every RUNTIME respect — same GAME_UPPER, same
    # title, same rules and endpoints. What differs is what ships: the
    # package, the signing material, and the launcher icon that tells the two
    # apart on a device with both installed.
    # Override the alias with NAP_KEYSTORE_ALIAS if the key inside
    # nap-keystore.jks is not named "upload".
    matatu_nap) GAME_UPPER="MATATU"; PROJECT_TITLE="Matatu"
            PACKAGE_NAME="com.matatu.nap"
            ICON_SVG="tools/icons/matatu_nap.svg"; ICON_BG="#4a3020,#2b1810"
            # No nap-specific watermark yet, so fall back to matatu's. Drop
            # tools/logos/matatu_nap.svg in and this picks it up with no code
            # change — the icon above is already nap's own.
            LOGO_SVG="tools/logos/matatu.svg"
            # `if`, not `[ -f ] && ...`: these scripts run under `set -e`, and a
            # trailing test that fails is a non-zero exit from the case branch,
            # which would abort the whole build whenever the file is absent —
            # i.e. in exactly the normal case this fallback exists for.
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

# Keyed by TARGET: matatu and matatu_nap are both MATATU and would otherwise
# overwrite each other's AAB.
OUTPUT_DIR="./bundles/android_release_${TARGET}"

if [ ! -f "$KEYSTORE_PATH" ]; then
    print_error "Keystore not found at $KEYSTORE_PATH"
    exit 1
fi

if [ ! -f "$KEYSTORE_PASS" ]; then
    print_error "Password file not found at $KEYSTORE_PASS"
    print_warning "Please create this file and add your key password before compiling."
    exit 1
fi

# ═══════════════════════════════════════════════════════════
# SIGNING IDENTITY — print it, because Google Sign-In IS this pair
# ═══════════════════════════════════════════════════════════
# Google Play Games authorises a build by (package name + signing SHA-1). Get
# either one wrong and the failure is silent and misleading: Play Games still
# SIGNS THE PLAYER IN — that part only needs the app_id — but
# requestServerAuthCode() returns null, so the app sees a successful sign-in
# carrying nothing it can send to the backend. On device that reads as
# "GPGS success, auth_code_present=false" and looks for all the world like a
# server problem.
#
# It is invisible at build time unless something prints it, which is how the
# matatu target shipped for a month under a package and certificate that had
# no Android OAuth client registered against them. So: print it every time.
if command -v keytool >/dev/null 2>&1; then
    SHA1=$(keytool -list -v -keystore "$KEYSTORE_PATH" \
             -storepass "$(cat "$KEYSTORE_PASS")" -alias "$KEYSTORE_ALIAS" 2>/dev/null \
           | grep -m1 -oE 'SHA1: [0-9A-F:]+' | cut -d' ' -f2)
    [ -z "$SHA1" ] && SHA1="(could not read — check $KEYSTORE_PASS and alias '$KEYSTORE_ALIAS')"
else
    SHA1="(keytool not on PATH)"
fi
echo ""
echo "🔐 Signing identity for this build"
echo "   package : $PACKAGE_NAME"
echo "   keystore: $KEYSTORE_PATH  (alias $KEYSTORE_ALIAS)"
echo "   SHA-1   : $SHA1"
echo "   This exact pair needs an Android OAuth client in Google Cloud Console."
echo "   If you ship through Play App Signing, register PLAY'S app-signing"
echo "   SHA-1 (Play Console > Setup > App signing), not this upload one."
echo ""

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
# 0b. STAMP THE VERSION INTO modules/config.lua
# ═══════════════════════════════════════════════════════════
# The version/version_code below go to bob.jar as a --settings override, which
# lands in the BUILT game.project — config.lua reads them back at runtime via
# sys.get_config. This stamp is the fallback for when that read comes back
# empty, and it is why it matters: M.APP_VERSION was a hand-edited constant
# that nothing in this script ever touched, so every release since it was last
# edited by hand reported "18.5.9" to the server no matter what was actually
# published. The force-update floor compares against what the client reports,
# so a stale constant there is not cosmetic — it silently disables the gate.
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

# Verify rather than trust: a sed that matched nothing exits 0, so without this
# a renamed field would silently go back to shipping a stale version.
if ! grep -q "^M.APP_VERSION = \"${VERSION_NAME}\"" modules/config.lua; then
    print_error "Failed to stamp M.APP_VERSION in modules/config.lua"
    exit 1
fi
if ! grep -q "^M.APP_BUILD   = ${VERSION_CODE}$" modules/config.lua; then
    print_error "Failed to stamp M.APP_BUILD in modules/config.lua"
    exit 1
fi

# AND THE REPO'S game.project, which is what every OTHER build reports.
#
# The --settings override below only reaches the BUILT game.project, so it is
# true for releases and for nothing else. build.sh passes no settings at all,
# so it builds straight from the file in the repo — and config.lua PREFERS
# what the engine was bundled with over its own stamped constant. The version
# in this file had been left at 18.5.9 while config.lua was stamped 20.9.2, so
# every build.sh build told the server it was 18.5.9, fell under the
# force-update floor, and could not come online at all.
#
# Stamping it here means the repo file is always the last released version,
# which is the right answer for a build that overrides nothing.
print_status "Stamping version $VERSION_NAME ($VERSION_CODE) into game.project..."

sed -i.bak -E \
    -e "s/^(version[[:space:]]*=[[:space:]]*).*/\1${VERSION_NAME}/" \
    -e "s/^(version_code[[:space:]]*=[[:space:]]*).*/\1${VERSION_CODE}/" \
    game.project
rm -f game.project.bak

if ! grep -q "^version = ${VERSION_NAME}$" game.project; then
    print_error "Failed to stamp version in game.project"
    exit 1
fi
if ! grep -q "^version_code = ${VERSION_CODE}$" game.project; then
    print_error "Failed to stamp version_code in game.project"
    exit 1
fi

print_success "modules/config.lua -> APP_VERSION=${VERSION_NAME} APP_BUILD=${VERSION_CODE}"

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

        # ── tell the backend this version exists ────────────────────────────
        #
        # Recorded, NOT activated. The build is minutes old and Play is not
        # serving it yet; forcing everyone onto it now would show every player
        # an update screen pointing at a listing that still offers the version
        # they already have, with no way out.
        #
        # Activating is a separate, deliberate act — POST /app-builds/:id/
        # activate — taken once the release is actually live. That is what
        # raises the floor and forces older installs to update.
        #
        # Best-effort by design: a bundle that built correctly must not be
        # reported as a failed release because a server was unreachable. The
        # curl is bounded so a hung endpoint cannot stall the script, and the
        # outcome is printed either way so it is never silently skipped.
        # /api, not /${GAME}. The route is mounted on the shared router, so it
        # answers under every prefix — but the per-game prefixes only exist for
        # matatu, whot and kadi, and matatu_nap is a TARGET, not a game. A URL
        # built from the target 404s, and one built from the game would then
        # disagree with the target in the body. /api names neither.
        RELEASE_API="${RELEASE_API:-https://champion.matatuleague.com/api/app-builds}"
        print_status "Registering ${TARGET} ${VERSION_NAME} (${VERSION_CODE}) with ${RELEASE_API}..."

        # TARGET, not GAME: matatu and matatu_nap are one game shipped as two
        # binaries with independent versionCode sequences. Filing a nap build
        # as "matatu" and later activating it would raise com.matatu.champ's
        # floor to a number from nap's sequence.
        REG_BODY=$(printf '{"target":"%s","build":%s,"versionName":"%s","notes":"%s"}' \
            "$TARGET" "$VERSION_CODE" "$VERSION_NAME" \
            "$(git rev-parse --short HEAD 2>/dev/null || echo 'no-git')")

        REG_CODE=$(curl -sS -o /tmp/app_build_reg.json -w '%{http_code}' \
            --max-time 20 \
            -X POST "$RELEASE_API" \
            -H 'Content-Type: application/json' \
            -d "$REG_BODY" 2>/dev/null || echo "000")

        if [ "$REG_CODE" = "201" ] || [ "$REG_CODE" = "200" ]; then
            print_success "Registered with the backend — NOT active yet."
            echo -e "   ${YELLOW}Activate it (forces every older install to update) with:${NC}"
            echo -e "   curl -X POST ${RELEASE_API}/<id>/activate"
        else
            print_warning "Could not register the build (HTTP ${REG_CODE}). The bundle is fine;"
            print_warning "register it by hand:"
            print_warning "curl -X POST ${RELEASE_API} -H 'Content-Type: application/json' -d '${REG_BODY}'"
        fi
    else
        print_warning "Build processed successfully, but output file couldn't be located automatically inside $OUTPUT_DIR"
    fi
else
    echo "-------------------------------------------------------"
    print_error "Build compilation failed! Please look through the bob.jar error details above."
    exit 1
fi

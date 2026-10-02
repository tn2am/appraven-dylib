#!/bin/bash
#
# inject.sh — Inject AppRavenPremiumMock.dylib into an AppRaven IPA
#
# Usage:
#   ./inject.sh <input.ipa> [dylib_path]
#
# Requirements:
#   - optool (brew install optool) OR insert_dylib
#   - ldid (brew install ldid) OR codesign
#   - zip/unzip
#
# This script:
#   1. Extracts the IPA
#   2. Copies the dylib into the Frameworks/ directory
#   3. Injects a load command into the main binary
#   4. Re-signs everything
#   5. Repackages into a new IPA
#

set -euo pipefail

# ── Color output ───────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()   { echo -e "${GREEN}[inject]${NC} $*"; }
warn()  { echo -e "${YELLOW}[inject]${NC} $*"; }
error() { echo -e "${RED}[inject]${NC} $*"; exit 1; }

# ── Parse arguments ────────────────────────────────────────────
IPA_INPUT="${1:-}"
DYLIB_PATH="${2:-AppRavenPremiumMock.dylib}"

if [ -z "$IPA_INPUT" ]; then
    echo ""
    echo "Usage: $0 <input.ipa> [dylib_path]"
    echo ""
    echo "  input.ipa   Path to the decrypted AppRaven IPA"
    echo "  dylib_path  Path to the dylib (default: AppRavenPremiumMock.dylib)"
    echo ""
    exit 1
fi

[ -f "$IPA_INPUT" ]  || error "IPA not found: $IPA_INPUT"
[ -f "$DYLIB_PATH" ] || error "Dylib not found: $DYLIB_PATH"

# ── Check tools ────────────────────────────────────────────────
INJECT_TOOL=""
if command -v optool &>/dev/null; then
    INJECT_TOOL="optool"
elif command -v insert_dylib &>/dev/null; then
    INJECT_TOOL="insert_dylib"
else
    error "Neither 'optool' nor 'insert_dylib' found. Install one:\n  brew install optool\n  -or-\n  https://github.com/tyilo/insert_dylib"
fi
log "Using injection tool: $INJECT_TOOL"

SIGN_TOOL=""
if command -v ldid &>/dev/null; then
    SIGN_TOOL="ldid"
elif command -v codesign &>/dev/null; then
    SIGN_TOOL="codesign"
else
    warn "No signing tool found. The IPA will not be signed."
fi
log "Using signing tool: ${SIGN_TOOL:-none}"

# ── Setup working directory ────────────────────────────────────
WORK_DIR=$(mktemp -d)
trap "rm -rf '$WORK_DIR'" EXIT
log "Working directory: $WORK_DIR"

# ── Step 1: Extract IPA ───────────────────────────────────────
log "Extracting IPA..."
unzip -qo "$IPA_INPUT" -d "$WORK_DIR"

# Find the .app bundle
APP_DIR=$(find "$WORK_DIR/Payload" -name "*.app" -maxdepth 1 -type d | head -1)
[ -d "$APP_DIR" ] || error "No .app bundle found in IPA"
APP_NAME=$(basename "$APP_DIR" .app)
log "Found app: $APP_NAME"

# Find the main binary
BINARY="$APP_DIR/$APP_NAME"
[ -f "$BINARY" ] || error "Main binary not found: $BINARY"
log "Main binary: $BINARY"

# ── Step 2: Copy dylib into Frameworks/ ────────────────────────
DYLIB_NAME=$(basename "$DYLIB_PATH")
FRAMEWORKS_DIR="$APP_DIR/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

cp "$DYLIB_PATH" "$FRAMEWORKS_DIR/$DYLIB_NAME"
log "Copied $DYLIB_NAME → Frameworks/"

# ── Step 3: Inject load command ────────────────────────────────
RPATH="@executable_path/Frameworks/$DYLIB_NAME"

log "Injecting load command..."
if [ "$INJECT_TOOL" = "optool" ]; then
    optool install -c load -p "$RPATH" -t "$BINARY"
elif [ "$INJECT_TOOL" = "insert_dylib" ]; then
    insert_dylib --inplace --no-strip-codesig "$RPATH" "$BINARY"
fi
log "Injected: $RPATH"

# ── Step 4: Remove old code signatures ─────────────────────────
log "Removing _CodeSignature directories..."
find "$APP_DIR" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true

# ── Step 5: Re-sign everything ─────────────────────────────────
if [ -n "$SIGN_TOOL" ]; then
    log "Re-signing with $SIGN_TOOL..."

    if [ "$SIGN_TOOL" = "ldid" ]; then
        # Sign frameworks first
        find "$FRAMEWORKS_DIR" -name "*.framework" -type d | while read fw; do
            fw_binary="$fw/$(basename "$fw" .framework)"
            [ -f "$fw_binary" ] && ldid -S "$fw_binary"
        done
        # Sign the injected dylib
        ldid -S "$FRAMEWORKS_DIR/$DYLIB_NAME"
        # Sign extensions
        find "$APP_DIR/PlugIns" -name "*.appex" -type d 2>/dev/null | while read ext; do
            ext_name=$(basename "$ext" .appex)
            ext_binary="$ext/$ext_name"
            [ -f "$ext_binary" ] && ldid -S "$ext_binary"
        done
        # Sign main binary
        ldid -S "$BINARY"

    elif [ "$SIGN_TOOL" = "codesign" ]; then
        # Sign frameworks
        find "$FRAMEWORKS_DIR" -name "*.framework" -o -name "*.dylib" | while read item; do
            codesign --force --sign - "$item"
        done
        # Sign extensions
        find "$APP_DIR/PlugIns" -name "*.appex" -type d 2>/dev/null | while read ext; do
            codesign --force --sign - "$ext"
        done
        # Sign main app
        codesign --force --sign - "$APP_DIR"
    fi

    log "Re-signing complete"
else
    warn "Skipping signing — install ldid or use codesign"
fi

# ── Step 6: Repackage IPA ─────────────────────────────────────
IPA_DIR=$(dirname "$IPA_INPUT")
IPA_BASE=$(basename "$IPA_INPUT" .ipa)
OUTPUT_IPA="$IPA_DIR/${IPA_BASE}_PremiumMock.ipa"

log "Repackaging IPA..."
cd "$WORK_DIR"
zip -qr "$OUTPUT_IPA" Payload/
cd - >/dev/null

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "✅ Done! Output: $OUTPUT_IPA"
log ""
log "Install with:"
log "  • Sideloadly / AltStore / TrollStore"
log "  • Or: ideviceinstaller -i \"$OUTPUT_IPA\""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

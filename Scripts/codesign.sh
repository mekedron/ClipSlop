#!/bin/bash
# Signs the ClipSlop binary with a stable certificate so that macOS
# TCC (Accessibility) and Keychain "Always Allow" grants persist across
# rebuilds instead of re-prompting every launch. `swift build` only
# ad-hoc-signs the binary, and an ad-hoc signature's identity (cdhash) changes
# on every build, so macOS treats each rebuild as a brand new, untrusted app.
#
# Prefers a "Developer ID Application" certificate if one is installed
# (paid Apple Developer account) since it's trusted automatically and is the
# same identity used for notarized releases. Falls back to a self-signed
# "ClipSlop-Dev" cert for contributors without a paid account.
#
# First-time setup without a Developer ID cert:
#   1. Open Keychain Access
#   2. Keychain Access → Certificate Assistant → Create a Certificate…
#   3. Name: "ClipSlop-Dev"  |  Type: Code Signing  |  Let me override defaults: NO
#   4. Create
#   5. Run this script
#
# Export .p12 backup (for 1Password):
#   security export -k login.keychain -t certs -f pkcs12 -o ClipSlop-Dev.p12
#
# Import on another Mac:
#   security import ClipSlop-Dev.p12 -k login.keychain -T /usr/bin/codesign

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Auto-detect: prefer a Developer ID Application identity, else the
# self-signed dev cert.
DEV_ID_NAME=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ "(.+)"$/\1/')
CERT_NAME="${DEV_ID_NAME:-ClipSlop-Dev}"
echo "Using signing identity: $CERT_NAME"

# Find binary: prefer Xcode DerivedData, fall back to SPM .build
XCODE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path "*/ClipSlop-*/Build/Products/Debug/ClipSlop" -type f 2>/dev/null | head -1)
SPM_BIN="$PROJECT_DIR/.build/debug/ClipSlop"

# Signs a .app bundle inside-out, mirroring the order used by the release
# workflow. Nested Sparkle code must be sealed before the outer bundle, or the
# outer signature is invalid the moment it is written.
#
# Unlike the release build this omits --timestamp (needs network on every
# rebuild) and --options runtime (hardened runtime interferes with debugging).
# The stable signing identity is what preserves TCC/Keychain grants, and for a
# bundle TCC keys on the designated requirement rather than the cdhash, so
# grants survive rebuilds by construction.
sign_bundle() {
    local app="$1"
    if [ ! -d "$app" ]; then
        echo "⚠ Bundle not found: $app"
        return 1
    fi

    if ! security find-certificate -c "$CERT_NAME" login.keychain >/dev/null 2>&1; then
        echo "✗ Certificate '$CERT_NAME' not found in keychain."
        exit 1
    fi

    local sparkle="$app/Contents/Frameworks/Sparkle.framework"
    if [ -d "$sparkle" ]; then
        find "$sparkle" -name "*.xpc" -type d -print0 2>/dev/null \
            | while IFS= read -r -d '' xpc; do codesign -f -s "$CERT_NAME" "$xpc"; done
        [ -d "$sparkle/Versions/B/Updater.app" ] && codesign -f -s "$CERT_NAME" "$sparkle/Versions/B/Updater.app"
        [ -f "$sparkle/Versions/B/Autoupdate" ] && codesign -f -s "$CERT_NAME" "$sparkle/Versions/B/Autoupdate"
        codesign -f -s "$CERT_NAME" "$sparkle"
    fi

    codesign -f -s "$CERT_NAME" \
        --entitlements "$PROJECT_DIR/SupportingFiles/ClipSlop.entitlements" \
        "$app"
    echo "✓ Signed bundle with $CERT_NAME: $app"
}

sign_binary() {
    local bin="$1"
    if [ ! -f "$bin" ]; then
        echo "⚠ Binary not found: $bin"
        return 1
    fi

    # Check if certificate exists in keychain
    if security find-certificate -c "$CERT_NAME" login.keychain >/dev/null 2>&1; then
        codesign -f -s "$CERT_NAME" "$bin"
        echo "✓ Signed with $CERT_NAME: $bin"
    else
        echo "✗ Certificate '$CERT_NAME' not found in keychain."
        echo "  Create it: Keychain Access → Certificate Assistant → Create a Certificate"
        echo "  Name: $CERT_NAME  |  Type: Code Signing"
        exit 1
    fi
}

# Explicit paths win: `codesign.sh <path>...` signs exactly what it's given.
# .app arguments are signed as bundles, anything else as a bare binary. With no
# arguments the original auto-detect behaviour is unchanged, so the bare-binary
# dev loop is untouched.
if [ $# -gt 0 ]; then
    for target in "$@"; do
        case "$target" in
            *.app) sign_bundle "$target" ;;
            *)     sign_binary "$target" ;;
        esac
    done
    exit 0
fi

signed=0

if [ -n "${XCODE_BIN:-}" ]; then
    sign_binary "$XCODE_BIN" && signed=1
fi

if [ -f "$SPM_BIN" ]; then
    sign_binary "$SPM_BIN" && signed=1
fi

if [ "$signed" -eq 0 ]; then
    echo "✗ No ClipSlop binary found. Build first."
    exit 1
fi

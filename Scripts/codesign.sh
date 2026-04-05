#!/bin/bash
# Signs the ClipSlop binary with a self-signed certificate so that
# macOS TCC (Accessibility permissions) persists across rebuilds.
#
# First-time setup:
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

CERT_NAME="ClipSlop-Dev"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Find binary: prefer Xcode DerivedData, fall back to SPM .build
XCODE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path "*/ClipSlop-*/Build/Products/Debug/ClipSlop" -type f 2>/dev/null | head -1)
SPM_BIN="$PROJECT_DIR/.build/debug/ClipSlop"

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

#!/bin/bash
# Import ClipSlop-Dev code signing certificate from 1Password into macOS Keychain.
# Use this when setting up development on a new Mac.
set -euo pipefail

CERT_NAME="ClipSlop-Dev"
VAULT="Personal"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Pre-flight checks ---

if security find-certificate -c "$CERT_NAME" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
    echo "⚠ Certificate '$CERT_NAME' already exists in Keychain."

    # Show existing cert expiry for context
    EXISTING_EXPIRY=$(security find-certificate -c "$CERT_NAME" -p ~/Library/Keychains/login.keychain-db \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$EXISTING_EXPIRY" ] && echo "  Existing cert expires: $EXISTING_EXPIRY"

    read -rp "  Replace with the one from 1Password? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        security delete-certificate -c "$CERT_NAME" ~/Library/Keychains/login.keychain-db
        echo "  Deleted old certificate."
    else
        echo "  Kept existing certificate."
        exit 0
    fi
fi

# --- Check 1Password ---

echo "==> Fetching .p12 from 1Password..."
if ! op document get "$CERT_NAME .p12 file" --vault "$VAULT" --out-file "$TMPDIR/$CERT_NAME.p12" 2>/dev/null; then
    echo "✗ '$CERT_NAME .p12 file' not found in 1Password (vault: $VAULT)."
    echo "  Run ./scripts/create-cert.sh first to generate and upload it."
    exit 1
fi

echo "==> Fetching password from 1Password..."
P12_PASS=$(op item get "$CERT_NAME Code Signing Certificate" --vault "$VAULT" --fields password 2>/dev/null) || {
    echo "✗ '$CERT_NAME Code Signing Certificate' not found in 1Password (vault: $VAULT)."
    echo "  The .p12 file exists but the password item is missing."
    exit 1
}

# Show what we're about to import
echo "  Certificate from 1Password:"
openssl pkcs12 -in "$TMPDIR/$CERT_NAME.p12" -passin "pass:$P12_PASS" -nokeys -legacy 2>/dev/null \
    | openssl x509 -noout -subject -enddate 2>/dev/null | sed 's/^/    /'

echo "==> Importing into macOS Keychain..."
security import "$TMPDIR/$CERT_NAME.p12" \
    -k ~/Library/Keychains/login.keychain-db \
    -T /usr/bin/codesign \
    -P "$P12_PASS"

security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" ~/Library/Keychains/login.keychain-db 2>/dev/null || true

echo ""
echo "✓ Certificate '$CERT_NAME' imported. Run ./scripts/codesign.sh after building."

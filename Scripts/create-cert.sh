#!/bin/bash
# One-time script: generate a self-signed code signing certificate,
# import it into the macOS Keychain, and save a .p12 backup to 1Password.
set -euo pipefail

CERT_NAME="ClipSlop-Dev"
VAULT="Personal"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Pre-flight checks ---

# Check Keychain
if security find-certificate -c "$CERT_NAME" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
    echo "⚠ Certificate '$CERT_NAME' already exists in Keychain."
    read -rp "  Delete it and create a new one? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        security delete-certificate -c "$CERT_NAME" ~/Library/Keychains/login.keychain-db
        echo "  Deleted from Keychain."
    else
        echo "  Aborted."
        exit 0
    fi
fi

# Check 1Password
OP_ITEM_EXISTS=false
OP_DOC_EXISTS=false
if op item get "$CERT_NAME Code Signing Certificate" --vault "$VAULT" >/dev/null 2>&1; then
    OP_ITEM_EXISTS=true
fi
if op document get "$CERT_NAME .p12 file" --vault "$VAULT" --out-file /dev/null >/dev/null 2>&1; then
    OP_DOC_EXISTS=true
fi

if $OP_ITEM_EXISTS || $OP_DOC_EXISTS; then
    echo "⚠ Found existing items in 1Password (vault: $VAULT):"
    $OP_ITEM_EXISTS && echo "  - $CERT_NAME Code Signing Certificate (password)"
    $OP_DOC_EXISTS && echo "  - $CERT_NAME .p12 file (document)"
    read -rp "  Delete them and create new ones? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        $OP_ITEM_EXISTS && op item delete "$CERT_NAME Code Signing Certificate" --vault "$VAULT" && echo "  Deleted password item."
        $OP_DOC_EXISTS && op item delete "$CERT_NAME .p12 file" --vault "$VAULT" && echo "  Deleted .p12 document."
    else
        echo "  Aborted."
        exit 0
    fi
fi

# --- Generate ---

echo "==> Generating self-signed code signing certificate..."

cat > "$TMPDIR/codesign.cnf" <<EOF
[req]
distinguished_name = req_dn
x509_extensions    = codesign_ext
prompt             = no

[req_dn]
CN = $CERT_NAME

[codesign_ext]
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 \
    -keyout "$TMPDIR/key.pem" \
    -out "$TMPDIR/cert.pem" \
    -days 3650 \
    -nodes \
    -config "$TMPDIR/codesign.cnf" \
    2>/dev/null

P12_PASS=$(openssl rand -base64 24)

echo "==> Packaging as .p12..."
openssl pkcs12 -export \
    -out "$TMPDIR/$CERT_NAME.p12" \
    -inkey "$TMPDIR/key.pem" \
    -in "$TMPDIR/cert.pem" \
    -passout "pass:$P12_PASS" \
    -legacy \
    2>/dev/null

echo "==> Importing into macOS Keychain..."
security import "$TMPDIR/$CERT_NAME.p12" \
    -k ~/Library/Keychains/login.keychain-db \
    -T /usr/bin/codesign \
    -P "$P12_PASS"

security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" ~/Library/Keychains/login.keychain-db 2>/dev/null || true

echo "==> Saving to 1Password (vault: $VAULT)..."
op item create \
    --vault "$VAULT" \
    --category password \
    --title "$CERT_NAME Code Signing Certificate" \
    --tags "dev,codesign,clipslop" \
    "password=$P12_PASS" \
    "notesPlain=Self-signed code signing certificate for ClipSlop dev builds. Import .p12 with this password: security import ClipSlop-Dev.p12 -k login.keychain-db -T /usr/bin/codesign -P <password>"

op document create "$TMPDIR/$CERT_NAME.p12" \
    --vault "$VAULT" \
    --title "$CERT_NAME .p12 file" \
    --tags "dev,codesign,clipslop"

echo ""
echo "✓ Done!"
echo "  Certificate '$CERT_NAME' is in your Keychain and backed up in 1Password."
echo "  Run ./scripts/codesign.sh after each build to sign the binary."

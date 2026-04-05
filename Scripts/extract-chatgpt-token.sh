#!/bin/bash
# Extracts ChatGPT OAuth tokens from macOS Keychain for use in integration tests.
#
# Usage:
#   eval $(./Scripts/extract-chatgpt-token.sh)
#   swift test --filter ChatGPT
#
# Or run tests directly:
#   ./Scripts/extract-chatgpt-token.sh --run-tests

set -euo pipefail

SERVICE="com.clipslop.app"

# Find the ChatGPT token entry in Keychain
ACCOUNT=$(security dump-keychain -a 2>/dev/null \
    | grep -o '"clipslop\.chatgpt\.tokens\.[^"]*"' \
    | head -1 \
    | tr -d '"' || true)

if [ -z "$ACCOUNT" ]; then
    echo "# No ChatGPT token found in Keychain." >&2
    echo "# Sign in via ClipSlop Settings > Providers > OpenAI (Sign In) first." >&2
    exit 1
fi

# Extract the password (token JSON) from Keychain
TOKEN_JSON=$(security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w 2>/dev/null || true)

if [ -z "$TOKEN_JSON" ]; then
    echo "# Failed to read token from Keychain." >&2
    echo "# You may need to allow access in the Keychain prompt." >&2
    exit 1
fi

# Parse fields from JSON
ACCESS_TOKEN=$(echo "$TOKEN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['accessToken'])" 2>/dev/null || true)
ACCOUNT_ID=$(echo "$TOKEN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('accountID',''))" 2>/dev/null || true)
EMAIL=$(echo "$TOKEN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('email',''))" 2>/dev/null || true)

if [ -z "$ACCESS_TOKEN" ]; then
    echo "# Failed to parse accessToken from token JSON." >&2
    exit 1
fi

echo "# ChatGPT token for: ${EMAIL:-unknown}" >&2

if [ "${1:-}" = "--run-tests" ]; then
    CHATGPT_ACCESS_TOKEN="$ACCESS_TOKEN" \
    CHATGPT_ACCOUNT_ID="$ACCOUNT_ID" \
    swift test --filter ChatGPT 2>&1
else
    # Output export commands for eval
    echo "export CHATGPT_ACCESS_TOKEN='$ACCESS_TOKEN'"
    echo "export CHATGPT_ACCOUNT_ID='$ACCOUNT_ID'"
fi

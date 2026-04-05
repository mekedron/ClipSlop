#!/bin/bash
# Extracts Anthropic API key from macOS Keychain for use in integration tests.
#
# Usage:
#   eval $(./Scripts/extract-anthropic-key.sh)
#   swift test --filter Anthropic
#
# Or run tests directly:
#   ./Scripts/extract-anthropic-key.sh --run-tests
#
# Or provide key via env var directly:
#   ANTHROPIC_API_KEY=sk-ant-... swift test --filter Anthropic

set -euo pipefail

# If already set in env, use that
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "# Using ANTHROPIC_API_KEY from environment" >&2
    if [ "${1:-}" = "--run-tests" ]; then
        ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" swift test --filter Anthropic 2>&1
    else
        echo "export ANTHROPIC_API_KEY='$ANTHROPIC_API_KEY'"
    fi
    exit 0
fi

SERVICE="com.clipslop.app"

# Find an Anthropic provider API key in Keychain
ACCOUNT=$(security dump-keychain -a 2>/dev/null \
    | grep -o '"clipslop\.api-key\.[^"]*"' \
    | tr -d '"' \
    | while read -r acc; do
        key=$(security find-generic-password -s "$SERVICE" -a "$acc" -w 2>/dev/null || true)
        if [ -n "$key" ] && echo "$key" | grep -q "^sk-ant-"; then
            echo "$acc"
            break
        fi
    done || true)

if [ -z "$ACCOUNT" ]; then
    echo "# No Anthropic API key found in Keychain." >&2
    echo "# Set ANTHROPIC_API_KEY env var or add an Anthropic provider in ClipSlop Settings." >&2
    exit 1
fi

API_KEY=$(security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w 2>/dev/null || true)

if [ -z "$API_KEY" ]; then
    echo "# Failed to read API key from Keychain." >&2
    exit 1
fi

echo "# Anthropic API key found (${#API_KEY} chars)" >&2

if [ "${1:-}" = "--run-tests" ]; then
    ANTHROPIC_API_KEY="$API_KEY" swift test --filter Anthropic 2>&1
else
    echo "export ANTHROPIC_API_KEY='$API_KEY'"
fi

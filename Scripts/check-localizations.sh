#!/bin/bash
# Check that all localization keys from en.lproj exist in every other .lproj
# Usage: ./Scripts/check-localizations.sh
# Exit code: 0 if all keys present, 1 if missing keys found

set -euo pipefail

RESOURCES_DIR="Sources/Resources"
EN_FILE="$RESOURCES_DIR/en.lproj/Localizable.strings"

if [ ! -f "$EN_FILE" ]; then
    echo "Error: English strings file not found at $EN_FILE"
    exit 1
fi

# Extract keys: find lines matching "key" = and pull out the key
extract_keys() {
    LC_ALL=C perl -ne 'print "$1\n" if /^"([^"]+)"\s*=/' "$1" | LC_ALL=C sort -u
}

EN_KEYS_FILE=$(mktemp)
extract_keys "$EN_FILE" > "$EN_KEYS_FILE"
EN_COUNT=$(wc -l < "$EN_KEYS_FILE" | tr -d ' ')

MISSING_TOTAL=0
LANGS_WITH_MISSING=0

for LPROJ_DIR in "$RESOURCES_DIR"/*.lproj; do
    LANG=$(basename "$LPROJ_DIR" .lproj)
    [ "$LANG" = "en" ] && continue

    LANG_FILE="$LPROJ_DIR/Localizable.strings"
    if [ ! -f "$LANG_FILE" ]; then
        echo "WARNING: $LANG — file missing entirely!"
        continue
    fi

    LANG_KEYS_FILE=$(mktemp)
    extract_keys "$LANG_FILE" > "$LANG_KEYS_FILE"
    LANG_COUNT=$(wc -l < "$LANG_KEYS_FILE" | tr -d ' ')

    MISSING=$(LC_ALL=C comm -23 "$EN_KEYS_FILE" "$LANG_KEYS_FILE")
    rm -f "$LANG_KEYS_FILE"

    if [ -n "$MISSING" ]; then
        MISSING_COUNT=$(echo "$MISSING" | wc -l | tr -d ' ')
        MISSING_TOTAL=$((MISSING_TOTAL + MISSING_COUNT))
        LANGS_WITH_MISSING=$((LANGS_WITH_MISSING + 1))
        echo ""
        echo "[$LANG] $MISSING_COUNT missing keys (has $LANG_COUNT/$EN_COUNT):"
        echo "$MISSING" | while read -r key; do
            echo "  - \"$key\""
        done
    else
        echo "[$LANG] OK ($LANG_COUNT/$EN_COUNT keys)"
    fi
done

rm -f "$EN_KEYS_FILE"

echo ""
if [ $MISSING_TOTAL -gt 0 ]; then
    echo "RESULT: $MISSING_TOTAL missing translations across $LANGS_WITH_MISSING languages"
    exit 1
else
    echo "RESULT: All translations complete!"
    exit 0
fi

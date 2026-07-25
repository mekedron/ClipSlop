#!/bin/bash
# Check that all localization keys from en.lproj exist in every other .lproj,
# and report how many of those keys are still English text.
#
# Key coverage and translation coverage are different things: a locale can hold
# every key and still be entirely English, which is what an untranslated locale
# looks like on disk. Only missing keys fail the build — an English placeholder
# is a known state, not a regression — but it is counted out loud so a locale
# that ships English to its users cannot look complete.
#
# Usage: ./Scripts/check-localizations.sh
# Exit code: 0 if all keys present, 1 if missing keys found

set -euo pipefail

# A locale at or above this share of English values is reported as a
# placeholder rather than as a translation with gaps.
PLACEHOLDER_PCT=90

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

# How many of $2's values are byte-identical to the English one for the same
# key. Prints "<identical> <compared>".
#
# Identical is a proxy for untranslated, and it over-counts a little: "OK",
# "Ollama", "%@" and other strings are legitimately the same in both languages.
# The residue is small and stable, so the number reads as a trend rather than
# as an exact debt — which is all it needs to do to stop 525/525 from meaning
# "translated".
count_english_values() {
    LC_ALL=C perl -e '
        my $pair = qr/^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;/;
        my %en;
        open(my $e, "<", $ARGV[0]) or die "open $ARGV[0]: $!";
        while (<$e>) { $en{$1} = $2 if /$pair/; }
        close $e;
        my ($same, $total) = (0, 0);
        open(my $l, "<", $ARGV[1]) or die "open $ARGV[1]: $!";
        while (<$l>) {
            next unless /$pair/;
            next unless exists $en{$1};
            $total++;
            $same++ if $en{$1} eq $2;
        }
        close $l;
        print "$same $total\n";
    ' "$1" "$2"
}

EN_KEYS_FILE=$(mktemp)
extract_keys "$EN_FILE" > "$EN_KEYS_FILE"
EN_COUNT=$(wc -l < "$EN_KEYS_FILE" | tr -d ' ')

MISSING_TOTAL=0
LANGS_WITH_MISSING=0
PLACEHOLDER_LANGS=""

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

    read -r SAME COMPARED <<<"$(count_english_values "$EN_FILE" "$LANG_FILE")"
    if [ "$COMPARED" -gt 0 ]; then
        SAME_PCT=$(( SAME * 100 / COMPARED ))
    else
        SAME_PCT=0
    fi

    if [ "$SAME_PCT" -ge "$PLACEHOLDER_PCT" ]; then
        TRANSLATION_NOTE=" — NOT TRANSLATED ($SAME/$COMPARED strings are English)"
        PLACEHOLDER_LANGS="$PLACEHOLDER_LANGS $LANG"
    elif [ "$SAME" -gt 0 ]; then
        TRANSLATION_NOTE=", $SAME still English"
    else
        TRANSLATION_NOTE=""
    fi

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
        echo "[$LANG] OK ($LANG_COUNT/$EN_COUNT keys)$TRANSLATION_NOTE"
    fi
done

rm -f "$EN_KEYS_FILE"

echo ""
if [ -n "$PLACEHOLDER_LANGS" ]; then
    PLACEHOLDER_COUNT=$(echo $PLACEHOLDER_LANGS | wc -w | tr -d ' ')
    echo "PLACEHOLDER LOCALES ($PLACEHOLDER_COUNT):$PLACEHOLDER_LANGS"
    echo "  Keys are complete, values are English — these users see an English UI."
    echo ""
fi

if [ $MISSING_TOTAL -gt 0 ]; then
    echo "RESULT: $MISSING_TOTAL missing keys across $LANGS_WITH_MISSING languages"
    exit 1
else
    echo "RESULT: All keys present in every locale."
    exit 0
fi

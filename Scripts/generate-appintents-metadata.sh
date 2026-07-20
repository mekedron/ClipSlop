#!/bin/bash
# Generate the App Intents metadata bundle (`Metadata.appintents`) for ClipSlop.
#
# Xcode normally does this in a build phase. ClipSlop is a pure SwiftPM package
# with a hand-assembled .app, so we drive the toolchain directly:
#
#   1. `swift build` emits .swiftconstvalues files, because Package.swift passes
#      `-emit-const-values` + `-Xfrontend -const-gather-protocols-file` for the
#      ClipSlop target.
#   2. `appintentsmetadataprocessor` turns those into Metadata.appintents.
#
# The result must land in the .app's Contents/Resources/ BEFORE codesigning, so
# it is covered by the signature seal.
#
# Usage:
#   Scripts/generate-appintents-metadata.sh --output <dir> [options]
#
#   --output <dir>          Directory to write Metadata.appintents into (required)
#   --configuration <cfg>   debug | release          (default: debug)
#   --arch <arch>           arm64 | x86_64           (default: host arch)
#   --module <name>         Swift module name        (default: ClipSlop)
#   --strict                Fail if the processor is unavailable (default: warn+skip)
#
# Without --strict a missing processor is a warning, not an error: contributors
# with only the Command Line Tools installed have no appintentsmetadataprocessor
# and must still be able to run Scripts/run-debug.sh. CI passes --strict, because
# a release that silently ships without App Intents is a bug that reaches users.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

CONFIG="debug"
ARCH="$(uname -m)"
MODULE="ClipSlop"
OUTPUT=""
STRICT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --configuration) CONFIG="$2"; shift 2 ;;
        --arch)          ARCH="$2"; shift 2 ;;
        --module)        MODULE="$2"; shift 2 ;;
        --output)        OUTPUT="$2"; shift 2 ;;
        --strict)        STRICT=1; shift ;;
        *) echo "✗ Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$OUTPUT" ]; then
    echo "✗ --output <dir> is required" >&2
    exit 2
fi

case "$CONFIG" in
    debug|release) ;;
    *) echo "✗ --configuration must be 'debug' or 'release' (got '$CONFIG')" >&2; exit 2 ;;
esac

# Deployment target is pinned to Package.swift's `platforms: [.macOS(.v15)]`.
# If that changes, change this too — the processor bakes it into the metadata.
DEPLOYMENT_TARGET="15.0"

# Resolve the toolchain through xcrun so DEVELOPER_DIR / xcode-select / Xcode-beta
# are all respected. `xcrun --find swiftc` gives <toolchain>/usr/bin/swiftc, so
# three dirnames get us back to the .xctoolchain root.
if ! SWIFTC_PATH="$(xcrun --find swiftc 2>/dev/null)"; then
    echo "✗ Could not locate swiftc via xcrun." >&2
    exit 1
fi
TOOLCHAIN_DIR="$(dirname "$(dirname "$(dirname "$SWIFTC_PATH")")")"
PROCESSOR="$TOOLCHAIN_DIR/usr/bin/appintentsmetadataprocessor"

if [ ! -x "$PROCESSOR" ]; then
    PROCESSOR="$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)"
fi

if [ -z "$PROCESSOR" ] || [ ! -x "$PROCESSOR" ]; then
    MSG="appintentsmetadataprocessor not found in $TOOLCHAIN_DIR (a full Xcode install is required)."
    if [ "$STRICT" -eq 1 ]; then
        echo "✗ $MSG" >&2
        exit 1
    fi
    echo "⚠ $MSG"
    echo "  Skipping App Intents metadata — the app will build and run, but will expose no intents."
    exit 0
fi

# Locate the .swiftconstvalues files. There are three different layouts and the
# right one depends on how `swift build` was invoked — getting this wrong yields
# a structurally valid but EMPTY metadata bundle with no error anywhere, so we
# fail loudly instead of guessing.
#
#   1. Universal build (`--arch arm64 --arch x86_64`, what release CI uses)
#      switches SwiftPM to the Xcode build system entirely.
#   2. Single-arch release uses whole-module optimisation -> one merged file.
#   3. Single-arch debug compiles incrementally -> one file PER SOURCE FILE.
XCODE_CONFIG="$(echo "${CONFIG:0:1}" | tr '[:lower:]' '[:upper:]')${CONFIG:1}"
CANDIDATE_DIRS=(
    ".build/apple/Intermediates.noindex/${MODULE}.build/${XCODE_CONFIG}/${MODULE}.build/Objects-normal/${ARCH}"
    ".build/${ARCH}-apple-macosx/${CONFIG}/${MODULE}.build"
)

CONST_VALUES_DIR=""
for dir in "${CANDIDATE_DIRS[@]}"; do
    if [ -d "$dir" ] && [ -n "$(find "$dir" -name '*.swiftconstvalues' -print -quit 2>/dev/null)" ]; then
        CONST_VALUES_DIR="$dir"
        break
    fi
done

if [ -z "$CONST_VALUES_DIR" ]; then
    echo "✗ No .swiftconstvalues files found for module '$MODULE' ($CONFIG/$ARCH)." >&2
    echo "  Looked in:" >&2
    printf '    %s\n' "${CANDIDATE_DIRS[@]}" >&2
    echo "  Likely causes:" >&2
    echo "    - the build has not run yet for this configuration/arch" >&2
    echo "    - the swiftSettings block was removed from Package.swift" >&2
    echo "    - SupportingFiles/AppIntentsConstValueProtocols.json is missing or malformed" >&2
    echo "      (it must be a BARE JSON ARRAY; Xcode's own copy is a wrapper dict and is rejected)" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# One arch is enough: the metadata describes types, parameters and phrases, not
# code. Verified by diffing arm64 vs x86_64 output — identical apart from the
# serialisation order of one unordered array. Feeding both would define every
# intent twice.
find "$PROJECT_DIR/$CONST_VALUES_DIR" -name '*.swiftconstvalues' | sort > "$WORK_DIR/const-values.txt"

# Source list is derived from the filesystem so newly added intent files are
# picked up without touching this script.
find "$PROJECT_DIR/Sources" -name '*.swift' | sort > "$WORK_DIR/sources.txt"
ACCESSOR="$PROJECT_DIR/$CONST_VALUES_DIR/DerivedSources/resource_bundle_accessor.swift"
[ -f "$ACCESSOR" ] && echo "$ACCESSOR" >> "$WORK_DIR/sources.txt"

SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | tail -1 | awk '{print $3}')"

mkdir -p "$OUTPUT"

echo "Generating App Intents metadata"
echo "  module:       $MODULE ($CONFIG/$ARCH)"
echo "  const values: $CONST_VALUES_DIR ($(wc -l < "$WORK_DIR/const-values.txt" | tr -d ' ') file(s))"
echo "  sources:      $(wc -l < "$WORK_DIR/sources.txt" | tr -d ' ') file(s)"

"$PROCESSOR" \
    --output "$OUTPUT" \
    --toolchain-dir "$TOOLCHAIN_DIR" \
    --module-name "$MODULE" \
    --sdk-root "$SDK_ROOT" \
    --xcode-version "$XCODE_VERSION" \
    --platform-family macOS \
    --deployment-target "$DEPLOYMENT_TARGET" \
    --target-triple "${ARCH}-apple-macos${DEPLOYMENT_TARGET}" \
    --source-file-list "$WORK_DIR/sources.txt" \
    --swift-const-vals-list "$WORK_DIR/const-values.txt" \
    --force

ACTIONS_DATA="$OUTPUT/Metadata.appintents/extract.actionsdata"
if [ ! -f "$ACTIONS_DATA" ]; then
    echo "✗ Processor completed but $ACTIONS_DATA was not produced." >&2
    exit 1
fi

# An empty `actions` map means extraction silently found nothing — the exact
# failure this script exists to make visible.
ACTION_COUNT="$(/usr/bin/python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("actions", {})))' "$ACTIONS_DATA" 2>/dev/null || echo 0)"
if [ "$ACTION_COUNT" -eq 0 ]; then
    echo "✗ Metadata was written but contains 0 intents — extraction found nothing." >&2
    echo "  The app would build and ship with no App Intents at all." >&2
    exit 1
fi

echo "✓ Metadata.appintents written to $OUTPUT ($ACTION_COUNT intent(s))"

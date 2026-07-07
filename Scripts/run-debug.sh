#!/bin/bash
# Build, code-sign, and (re)launch the local debug build in one step.
#
# The sign step (codesign.sh) is what makes macOS Keychain/Accessibility
# "Always Allow" grants survive across rebuilds — skipping it (e.g. running
# `swift build` + `.build/debug/ClipSlop` directly) is why those prompts
# come back on every relaunch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

if pgrep -x "ClipSlop" >/dev/null 2>&1; then
    echo "Stopping running ClipSlop..."
    killall ClipSlop
    sleep 1
fi

echo "Building..."
swift build

"$SCRIPT_DIR/codesign.sh"

echo "Launching..."
.build/debug/ClipSlop &
disown
echo "✓ ClipSlop running (PID $!)"

#!/bin/bash
# Build, code-sign, and (re)launch the local debug build in one step.
#
# The sign step (codesign.sh) is what makes macOS Keychain/Accessibility
# "Always Allow" grants survive across rebuilds — skipping it (e.g. running
# `swift build` + `.build/debug/ClipSlop` directly) is why those prompts
# come back on every relaunch.
#
# Modes:
#   (default)          Launch the bare binary. Fastest loop, console output goes
#                      straight to this terminal.
#   --bundle | -b      Build a real .app, register it with LaunchServices, and
#                      launch that. REQUIRED for anything involving App Intents,
#                      Spotlight or Shortcuts — those only see registered bundles.
#                      Runs as com.mekedron.clipslop.dev with its own data
#                      directory, so it cannot disturb an installed release.
#   --attach           With --bundle, run the bundle's binary in the foreground
#                      instead of via `open`, keeping stdout attached. Skips
#                      LaunchServices activation, so intents may not dispatch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

USE_BUNDLE=0
ATTACH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle|-b) USE_BUNDLE=1; shift ;;
        --attach)    ATTACH=1; shift ;;
        *) echo "✗ Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if pgrep -x "ClipSlop" >/dev/null 2>&1; then
    echo "Stopping running ClipSlop..."
    killall ClipSlop
    sleep 1
fi

echo "Building..."
swift build

if [ "$USE_BUNDLE" -eq 1 ]; then
    "$SCRIPT_DIR/make-app-bundle.sh" --configuration debug
    APP_PATH="$HOME/Applications/ClipSlop-dev.app"
    echo "Launching (bundle)..."
    if [ "$ATTACH" -eq 1 ]; then
        exec "$APP_PATH/Contents/MacOS/ClipSlop"
    fi
    open -n "$APP_PATH"
    echo "✓ ClipSlop running from $APP_PATH"
    echo "  Console output: log stream --predicate 'process == \"ClipSlop\"'"
else
    "$SCRIPT_DIR/codesign.sh"
    echo "Launching..."
    if [ -t 1 ]; then
        .build/debug/ClipSlop &
    else
        # Non-interactive callers (CI, agents) block forever on the stdout
        # pipe the app would inherit — send its output to a file instead.
        LOG_FILE="${TMPDIR:-/tmp}/clipslop-debug.log"
        .build/debug/ClipSlop >"$LOG_FILE" 2>&1 &
        echo "  Console output: $LOG_FILE"
    fi
    disown
    echo "✓ ClipSlop running (PID $!)"
fi

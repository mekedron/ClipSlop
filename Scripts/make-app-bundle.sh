#!/bin/bash
# Assemble a real .app bundle from the local debug build.
#
# Why this exists: App Intents are only discoverable through LaunchServices, which
# registers *bundles*. The normal dev loop runs the bare Mach-O at
# .build/debug/ClipSlop, which LaunchServices never sees — so no amount of correct
# metadata would make an intent show up in Spotlight or Shortcuts.
#
# The bundle ships as `com.mekedron.clipslop.dev`, NOT the release identifier:
#   - an installed /Applications/ClipSlop.app already owns com.mekedron.clipslop,
#     and LaunchServices would resolve intents to *that* app instead of this build
#   - two apps sharing an identifier fight over global hotkeys and the menu bar
#   - a separate identifier gets its own TCC grants, leaving the release app's
#     Accessibility/Screen Recording permissions untouched
#
# Because the identifier differs, so does the UserDefaults domain — which is why
# Constants.appSupportDirectory is bundle-scoped. See the seeding step below.
#
# Usage: Scripts/make-app-bundle.sh [--configuration debug|release]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

CONFIG="debug"
while [ $# -gt 0 ]; do
    case "$1" in
        --configuration) CONFIG="$2"; shift 2 ;;
        *) echo "✗ Unknown argument: $1" >&2; exit 2 ;;
    esac
done

ARCH="$(uname -m)"
BUILD_DIR=".build/${ARCH}-apple-macosx/${CONFIG}"

# The bundle deliberately lives in ~/Applications, NOT inside .build/.
#
# Spotlight does not index the contents of hidden (dot-prefixed) directories, so
# a bundle under .build/ is invisible to it no matter how correct its metadata
# is — verified with `mdfind kMDItemCFBundleIdentifier`, which returns nothing
# for a .build/ bundle and finds it immediately once moved here. Shortcuts still
# works in both places because it reads App Intents metadata through
# LaunchServices rather than the Spotlight index, which is exactly why "works in
# Shortcuts but not Spotlight" is the signature of this problem.
#
# ~/Applications rather than /Applications: no admin rights needed, and it keeps
# an installed release copy of ClipSlop untouched.
APP_PATH="$HOME/Applications/ClipSlop-dev.app"
CONTENTS="$APP_PATH/Contents"
DEV_BUNDLE_ID="com.mekedron.clipslop.dev"

if [ ! -f "$BUILD_DIR/ClipSlop" ]; then
    echo "✗ No binary at $BUILD_DIR/ClipSlop — run 'swift build' first." >&2
    exit 1
fi

rm -rf "$APP_PATH"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"


cp "$BUILD_DIR/ClipSlop" "$CONTENTS/MacOS/ClipSlop"
cp SupportingFiles/Info.plist "$CONTENTS/Info.plist"
cp SupportingFiles/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${DEV_BUNDLE_ID}" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ClipSlop (dev)" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ClipSlop (dev)" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.0-dev" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 0" "$CONTENTS/Info.plist"

# Neutralise Sparkle for dev builds. SparkleUpdater.start() bails early when
# SUFeedURL is absent, so deleting the key is the whole fix — without it a dev
# build would see the live appcast advertising a newer version and offer to
# "update" itself over the top.
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$CONTENTS/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$CONTENTS/Info.plist" 2>/dev/null || true

# SPM resource bundles. This is the step most likely to fail silently: without
# them Bundle.module resolves to nothing, so every Loc.shared.t() call returns its
# raw key and DefaultPrompts.json fails to load. Hard-assert instead.
BUNDLE_COUNT=0
while IFS= read -r bundle; do
    cp -R "$bundle" "$CONTENTS/Resources/"
    BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
done < <(find "$BUILD_DIR" -maxdepth 1 -name '*.bundle' -type d)

if [ ! -d "$CONTENTS/Resources/ClipSlop_ClipSlop.bundle" ]; then
    echo "✗ ClipSlop_ClipSlop.bundle was not copied — Bundle.module would break," >&2
    echo "  meaning every localized string renders as its raw key and the default" >&2
    echo "  prompts fail to load. Refusing to produce a broken bundle." >&2
    exit 1
fi
echo "✓ Copied $BUNDLE_COUNT resource bundle(s)"

# Sparkle is a hard dependency of launching, not an optional extra: the binary
# links @rpath/Sparkle.framework, and once it sits in Contents/MacOS the only
# rpath that can resolve it is @executable_path/../Frameworks. Missing framework
# means dyld aborts at startup.
SPARKLE_FW="$(find .build -name 'Sparkle.framework' -path '*/macos-arm64_x86_64/*' -type d 2>/dev/null | head -1)"
if [ -z "$SPARKLE_FW" ]; then
    SPARKLE_FW="$(find .build -name 'Sparkle.framework' -type d 2>/dev/null | head -1)"
fi
if [ -z "$SPARKLE_FW" ]; then
    echo "✗ Sparkle.framework not found in .build — the app would not launch." >&2
    exit 1
fi
cp -R "$SPARKLE_FW" "$CONTENTS/Frameworks/"

# App Intents metadata. Must land before signing so it is covered by the seal.
"$SCRIPT_DIR/generate-appintents-metadata.sh" \
    --configuration "$CONFIG" \
    --arch "$ARCH" \
    --output "$CONTENTS/Resources"

# Seed the dev data directory from the real one, once. A fresh UserDefaults domain
# means useDefaultPrompts reads back true, so without this the dev app would start
# from the bundled defaults and testing would run against a library that looks
# nothing like the user's. One-way copy — the dev app can never write back.
DEV_SUPPORT="$HOME/Library/Application Support/ClipSlop-dev"
REAL_SUPPORT="$HOME/Library/Application Support/ClipSlop"
if [ ! -d "$DEV_SUPPORT" ] && [ -d "$REAL_SUPPORT" ]; then
    mkdir -p "$DEV_SUPPORT"
    for file in prompts.json providers.json quick-access.json; do
        [ -f "$REAL_SUPPORT/$file" ] && cp "$REAL_SUPPORT/$file" "$DEV_SUPPORT/$file"
    done
    # Mirror the "library is customized" flag so PromptStore.init loads from disk
    # instead of overwriting the seeded copy with the bundled defaults.
    defaults write "$DEV_BUNDLE_ID" useDefaultPrompts -bool false 2>/dev/null || true
    echo "✓ Seeded $DEV_SUPPORT from the release data directory"
fi

"$SCRIPT_DIR/codesign.sh" "$APP_PATH"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$APP_PATH"

echo "✓ Built and registered $APP_PATH ($DEV_BUNDLE_ID)"

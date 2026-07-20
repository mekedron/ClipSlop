#!/bin/bash
#
# Reset ClipSlop to a fresh-install state.
# Removes all UserDefaults, data files, Keychain tokens, and iCloud data.
#
# Usage: ./Scripts/reset.sh
#

set -e

APP_NAME="ClipSlop"
BUNDLE_ID="com.mekedron.clipslop"
LEGACY_BUNDLE_ID="com.clipslop.app"

echo "Resetting ${APP_NAME} to fresh-install state..."
echo ""

# 1. Kill the app if running (either bundle ID)
if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "[1/7] Stopping ${APP_NAME}..."
    killall "$APP_NAME" 2>/dev/null || true
    sleep 1
else
    echo "[1/7] ${APP_NAME} is not running"
fi

# 2. Clear UserDefaults (try all possible domains, current + legacy v1)
echo "[2/7] Clearing UserDefaults..."
for domain in "$BUNDLE_ID" "${BUNDLE_ID}.${APP_NAME}" "$LEGACY_BUNDLE_ID" "${LEGACY_BUNDLE_ID}.${APP_NAME}" "$APP_NAME"; do
    defaults delete "$domain" 2>/dev/null && echo "  Deleted domain: ${domain}" || true
done
# SPM debug builds may use the executable path as domain
for plist in ~/Library/Preferences/*clipslop* ~/Library/Preferences/*ClipSlop* ~/Library/Preferences/*mekedron*; do
    if [ -f "$plist" ]; then
        echo "  Removing: $plist"
        rm -f "$plist"
    fi
done

# 3. Remove Application Support data (prompts.json, providers.json, migration log)
APP_SUPPORT=~/Library/"Application Support"/"${APP_NAME}"
if [ -d "$APP_SUPPORT" ]; then
    echo "[3/7] Removing Application Support data..."
    echo "  Removing: $APP_SUPPORT"
    rm -rf "$APP_SUPPORT"
else
    echo "[3/7] No Application Support data found"
fi

# 4. Remove Keychain items (API keys, ChatGPT OAuth tokens) for both bundle IDs
echo "[4/7] Removing Keychain items..."
for svc in "$BUNDLE_ID" "$LEGACY_BUNDLE_ID"; do
    # Loop because security delete-generic-password only removes one match at a time
    while security delete-generic-password -s "$svc" >/dev/null 2>&1; do :; done
    echo "  Cleared Keychain items for ${svc}"
done

# 5. Remove iCloud container data (optional) for both bundle IDs
echo "[5/7] Removing iCloud sync data..."
for id in "$BUNDLE_ID" "$LEGACY_BUNDLE_ID"; do
    ICLOUD_DIR=~/Library/"Application Support"/CloudDocs/session/containers/"iCloud.${id}"
    ICLOUD_PLIST="${ICLOUD_DIR}.plist"
    if [ -d "$ICLOUD_DIR" ] || [ -f "$ICLOUD_PLIST" ]; then
        rm -rf "$ICLOUD_DIR" 2>/dev/null || true
        rm -f "$ICLOUD_PLIST" 2>/dev/null || true
        echo "  Removed iCloud container data for iCloud.${id}"
    fi
    # Mobile Documents on-disk folder
    MOBILE_DIR=~/Library/"Mobile Documents"/"iCloud~${id//./~}"
    if [ -d "$MOBILE_DIR" ]; then
        rm -rf "$MOBILE_DIR" 2>/dev/null || true
        echo "  Removed Mobile Documents folder: ${MOBILE_DIR}"
    fi
done

# 6. Tear down the locally-built dev bundle (Scripts/make-app-bundle.sh).
# It must be unregistered before deletion, or LaunchServices keeps a dangling
# entry that can still be resolved for App Intents dispatch.
echo "[6/7] Removing locally-built dev app bundle..."
DEV_BUNDLE_ID="${BUNDLE_ID}.dev"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
for DEV_APP in ~/Applications/ClipSlop-dev.app "$(cd "$(dirname "$0")/.." && pwd)/.build/ClipSlop.app"; do
    if [ -d "$DEV_APP" ]; then
        "$LSREGISTER" -u "$DEV_APP" 2>/dev/null || true
        rm -rf "$DEV_APP"
        echo "  Unregistered and removed ${DEV_APP}"
    fi
done
defaults delete "$DEV_BUNDLE_ID" 2>/dev/null && echo "  Cleared UserDefaults for ${DEV_BUNDLE_ID}" || true
DEV_SUPPORT=~/Library/"Application Support"/"${APP_NAME}-dev"
if [ -d "$DEV_SUPPORT" ]; then
    rm -rf "$DEV_SUPPORT"
    echo "  Removed ${DEV_SUPPORT}"
fi

# 7. Revoke privacy grants. Without this the script only *claims* to restore a
# fresh-install state — the onboarding flow would run but Accessibility and
# Screen Recording would still be granted, so the permission steps get skipped.
echo "[7/7] Resetting privacy permissions..."
for id in "$BUNDLE_ID" "$DEV_BUNDLE_ID" "$LEGACY_BUNDLE_ID"; do
    tccutil reset Accessibility "$id" >/dev/null 2>&1 || true
    tccutil reset ScreenCapture "$id" >/dev/null 2>&1 || true
done
echo "  Reset Accessibility and Screen Recording grants"

echo ""
echo "Done! ${APP_NAME} has been reset to a fresh-install state."
echo "Launch the app to see the onboarding flow."

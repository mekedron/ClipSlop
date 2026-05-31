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
    echo "[1/5] Stopping ${APP_NAME}..."
    killall "$APP_NAME" 2>/dev/null || true
    sleep 1
else
    echo "[1/5] ${APP_NAME} is not running"
fi

# 2. Clear UserDefaults (try all possible domains, current + legacy v1)
echo "[2/5] Clearing UserDefaults..."
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
    echo "[3/5] Removing Application Support data..."
    echo "  Removing: $APP_SUPPORT"
    rm -rf "$APP_SUPPORT"
else
    echo "[3/5] No Application Support data found"
fi

# 4. Remove Keychain items (API keys, ChatGPT OAuth tokens) for both bundle IDs
echo "[4/5] Removing Keychain items..."
for svc in "$BUNDLE_ID" "$LEGACY_BUNDLE_ID"; do
    # Loop because security delete-generic-password only removes one match at a time
    while security delete-generic-password -s "$svc" >/dev/null 2>&1; do :; done
    echo "  Cleared Keychain items for ${svc}"
done

# 5. Remove iCloud container data (optional) for both bundle IDs
echo "[5/5] Removing iCloud sync data..."
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

echo ""
echo "Done! ${APP_NAME} has been reset to a fresh-install state."
echo "Launch the app to see the onboarding flow."

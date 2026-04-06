#!/bin/bash
#
# Reset ClipSlop to a fresh-install state.
# Removes all UserDefaults, data files, Keychain tokens, and iCloud data.
#
# Usage: ./Scripts/reset.sh
#

set -e

APP_NAME="ClipSlop"
BUNDLE_ID="com.clipslop.app"

echo "Resetting ${APP_NAME} to fresh-install state..."
echo ""

# 1. Kill the app if running
if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "[1/5] Stopping ${APP_NAME}..."
    killall "$APP_NAME" 2>/dev/null || true
    sleep 1
else
    echo "[1/5] ${APP_NAME} is not running"
fi

# 2. Clear UserDefaults (try all possible domains)
echo "[2/5] Clearing UserDefaults..."
defaults delete "$BUNDLE_ID" 2>/dev/null && echo "  Deleted domain: ${BUNDLE_ID}" || true
defaults delete "${BUNDLE_ID}.${APP_NAME}" 2>/dev/null && echo "  Deleted domain: ${BUNDLE_ID}.${APP_NAME}" || true
defaults delete "$APP_NAME" 2>/dev/null && echo "  Deleted domain: ${APP_NAME}" || true
# SPM debug builds may use the executable path as domain
for plist in ~/Library/Preferences/*clipslop* ~/Library/Preferences/*ClipSlop*; do
    if [ -f "$plist" ]; then
        echo "  Removing: $plist"
        rm -f "$plist"
    fi
done

# 3. Remove Application Support data (prompts.json, providers.json)
APP_SUPPORT=~/Library/"Application Support"/"${APP_NAME}"
if [ -d "$APP_SUPPORT" ]; then
    echo "[3/5] Removing Application Support data..."
    echo "  Removing: $APP_SUPPORT"
    rm -rf "$APP_SUPPORT"
else
    echo "[3/5] No Application Support data found"
fi

# 4. Remove Keychain items (ChatGPT OAuth tokens)
echo "[4/5] Removing Keychain items..."
security delete-generic-password -s "$BUNDLE_ID" 2>/dev/null && echo "  Deleted Keychain items for ${BUNDLE_ID}" || echo "  No Keychain items found"
# Remove all possible token entries
for key in chatgpt-tokens; do
    security delete-generic-password -s "$BUNDLE_ID" -a "$key" 2>/dev/null || true
done

# 5. Remove iCloud container data (optional)
ICLOUD_DIR=~/Library/"Application Support"/CloudDocs/session/containers/"iCloud.${BUNDLE_ID}"
ICLOUD_PLIST="${ICLOUD_DIR}.plist"
if [ -d "$ICLOUD_DIR" ] || [ -f "$ICLOUD_PLIST" ]; then
    echo "[5/5] Removing iCloud sync data..."
    rm -rf "$ICLOUD_DIR" 2>/dev/null || true
    rm -f "$ICLOUD_PLIST" 2>/dev/null || true
    echo "  Removed iCloud container data"
else
    echo "[5/5] No iCloud data found"
fi

echo ""
echo "Done! ${APP_NAME} has been reset to a fresh-install state."
echo "Launch the app to see the onboarding flow."

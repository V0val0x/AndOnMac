#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AndOnMac"
DMG_NAME="${APP_NAME}.dmg"
DIST_DIR="dist"
APP_PATH="${DIST_DIR}/${APP_NAME}.app"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
TEMP_DMG_DIR="${DIST_DIR}/dmg_temp"

if [ ! -d "${APP_PATH}" ]; then
    echo "App bundle not found! Running build_app.sh first..."
    ./scripts/build_app.sh
fi

echo "==> Preparing DMG staging directory..."
rm -rf "${TEMP_DMG_DIR}" "${DMG_PATH}"
mkdir -p "${TEMP_DMG_DIR}"

cp -R "${APP_PATH}" "${TEMP_DMG_DIR}/"
ln -s /Applications "${TEMP_DMG_DIR}/Applications"

echo "==> Generating disk image ${DMG_PATH}..."
hdiutil create -volname "${APP_NAME}" -srcfolder "${TEMP_DMG_DIR}" -ov -format UDZO "${DMG_PATH}"

rm -rf "${TEMP_DMG_DIR}"
echo "✅ DMG successfully generated at ${DMG_PATH}"

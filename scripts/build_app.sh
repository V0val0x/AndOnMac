#!/usr/bin/env bash
set -euo pipefail

echo "==> Building AndOnMac (Release)..."
swift build -c release

APP_NAME="AndOnMac"
BUILD_DIR=".build/release"
OUTPUT_DIR="dist"
APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Creating macOS App Bundle layout at ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy main binary
cp "${BUILD_DIR}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

# Copy AppIcon.icns
if [ -f "Sources/AndOnMac/Resources/AppIcon.icns" ]; then
    echo "==> Bundling AppIcon.icns..."
    cp "Sources/AndOnMac/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# Generate Info.plist with Icon and metadata
cat <<EOF > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.andonmac.app</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

# Copy scrcpy-server if available
SCRCPY_SERVER=$(find /opt/homebrew/Cellar/scrcpy -name "scrcpy-server" 2>/dev/null | head -n 1 || true)
if [ -n "${SCRCPY_SERVER}" ] && [ -f "${SCRCPY_SERVER}" ]; then
    echo "==> Bundling scrcpy-server from ${SCRCPY_SERVER}..."
    cp "${SCRCPY_SERVER}" "${RESOURCES_DIR}/"
fi

# Copy adb if available
ADB_BIN=$(which adb 2>/dev/null || true)
if [ -n "${ADB_BIN}" ] && [ -x "${ADB_BIN}" ]; then
    echo "==> Bundling adb binary from ${ADB_BIN}..."
    cp "${ADB_BIN}" "${RESOURCES_DIR}/adb"
    chmod +x "${RESOURCES_DIR}/adb"
fi

echo "✅ App bundle successfully created at ${APP_BUNDLE}"

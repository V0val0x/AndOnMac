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
RES_BACKUP_DIR="${OUTPUT_DIR}/.res_backup"
rm -rf "${RES_BACKUP_DIR}"
mkdir -p "${RES_BACKUP_DIR}"
if [ -f "${RESOURCES_DIR}/adb" ]; then
    cp "${RESOURCES_DIR}/adb" "${RES_BACKUP_DIR}/adb"
fi
if [ -f "${RESOURCES_DIR}/scrcpy-server" ]; then
    cp "${RESOURCES_DIR}/scrcpy-server" "${RES_BACKUP_DIR}/scrcpy-server"
fi

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
    <string>2.0.11</string>
    <key>CFBundleVersion</key>
    <string>13</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>AndOnMac использует локальную сеть для обнаружения и беспроводного подключения к вашему телефону Android (ADB Wireless Debugging).</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_adb-tls-pairing._tcp</string>
        <string>_adb-tls-connect._tcp</string>
    </array>
</dict>
</plist>
EOF

# Copy scrcpy-server if available
SCRCPY_SERVER=""
if command -v brew >/dev/null 2>&1; then
    BREW_PREFIX=$(brew --prefix scrcpy 2>/dev/null || true)
    if [ -n "${BREW_PREFIX}" ] && [ -d "${BREW_PREFIX}" ]; then
        SCRCPY_SERVER=$(find "${BREW_PREFIX}" -name "scrcpy-server" 2>/dev/null | head -n 1 || true)
    fi
fi
if [ -z "${SCRCPY_SERVER}" ]; then
    SCRCPY_SERVER=$(find /opt/homebrew/Cellar/scrcpy /usr/local/Cellar/scrcpy -name "scrcpy-server" 2>/dev/null | head -n 1 || true)
fi
if [ -n "${SCRCPY_SERVER}" ] && [ -f "${SCRCPY_SERVER}" ]; then
    echo "==> Bundling scrcpy-server from ${SCRCPY_SERVER}..."
    cp "${SCRCPY_SERVER}" "${RESOURCES_DIR}/scrcpy-server" 2>/dev/null || true
fi
if [ ! -f "${RESOURCES_DIR}/scrcpy-server" ] && [ -f "${RES_BACKUP_DIR}/scrcpy-server" ]; then
    echo "==> Restoring existing bundled scrcpy-server..."
    cp "${RES_BACKUP_DIR}/scrcpy-server" "${RESOURCES_DIR}/scrcpy-server"
fi

# Copy adb if available
ADB_BIN=$(which adb 2>/dev/null || true)
if [ -n "${ADB_BIN}" ] && [ -x "${ADB_BIN}" ]; then
    echo "==> Bundling adb binary from ${ADB_BIN}..."
    if cp "${ADB_BIN}" "${RESOURCES_DIR}/adb" 2>/dev/null; then
        chmod +x "${RESOURCES_DIR}/adb"
    fi
fi
if [ ! -x "${RESOURCES_DIR}/adb" ] && [ -f "${RES_BACKUP_DIR}/adb" ]; then
    echo "==> Restoring existing bundled adb binary..."
    cp "${RES_BACKUP_DIR}/adb" "${RESOURCES_DIR}/adb"
    chmod +x "${RESOURCES_DIR}/adb"
fi
rm -rf "${RES_BACKUP_DIR}"

# Bundle license and third-party attribution notices inside .app/Contents/Resources
[ -f "LICENSE" ] && cp "LICENSE" "${RESOURCES_DIR}/LICENSE"
[ -f "THIRD_PARTY_NOTICES.md" ] && cp "THIRD_PARTY_NOTICES.md" "${RESOURCES_DIR}/THIRD_PARTY_NOTICES.md"

# Install to /Applications if writable
if [ -w "/Applications" ]; then
    echo "==> Installing ${APP_BUNDLE} to /Applications/${APP_NAME}.app..."
    rm -rf "/Applications/${APP_NAME}.app" 2>/dev/null || true
    cp -R "${APP_BUNDLE}" "/Applications/${APP_NAME}.app" 2>/dev/null || true
fi

echo "✅ App bundle successfully created at ${APP_BUNDLE}"

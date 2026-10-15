#!/bin/bash
# Builds Founder.app from the SwiftPM executable.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="Founder"
BUILD_DIR=".build/${CONFIG}"
APP_DIR="dist/${APP_NAME}.app"

echo "==> Building (${CONFIG})..."
swift build -c "${CONFIG}"

echo "==> Assembling ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

cat > "${APP_DIR}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Founder</string>
	<key>CFBundleDisplayName</key>
	<string>Founder</string>
	<key>CFBundleIdentifier</key>
	<string>com.dennisfaucher.founder</string>
	<key>CFBundleVersion</key>
	<string>0.2</string>
	<key>CFBundleShortVersionString</key>
	<string>0.2</string>
	<key>CFBundleExecutable</key>
	<string>Founder</string>
	<key>CFBundleIconFile</key>
	<string>Founder</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

# App icon (regenerate with ./make_icon.sh).
if [ -f "Assets/Founder.icns" ]; then
    cp "Assets/Founder.icns" "${APP_DIR}/Contents/Resources/Founder.icns"
else
    echo "    warning: Assets/Founder.icns missing; building without an icon"
fi

# Ad-hoc sign so Gatekeeper/macOS is happy running it locally.
codesign --force --sign - "${APP_DIR}" 2>/dev/null || true

echo "==> Done: ${APP_DIR}"
echo "    open \"${APP_DIR}\""

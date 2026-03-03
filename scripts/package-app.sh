#!/usr/bin/env bash
set -euo pipefail

APP_NAME="indexd"
VERSION="${1:-0.1.0}"
BUILD_NUMBER="${2:-1}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"

swift build -c release

BUNDLE_DIR="dist/${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/arm64-apple-macosx/release/${APP_NAME}" "$MACOS_DIR/${APP_NAME}"
chmod +x "$MACOS_DIR/${APP_NAME}"

ICON_SOURCE="$(find "Sources/ABSClientMac/Resources" -maxdepth 1 -type f -name "*.icns" | head -n 1 || true)"
if [[ -n "${ICON_SOURCE}" ]]; then
  ICON_BASENAME="$(basename "${ICON_SOURCE}" .icns)"
  cp "${ICON_SOURCE}" "${RESOURCES_DIR}/${ICON_BASENAME}.icns"
fi

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.indexd.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

if [[ -n "${ICON_SOURCE}" ]]; then
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "${CONTENTS_DIR}/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string ${ICON_BASENAME}" "${CONTENTS_DIR}/Info.plist"
fi

codesign --force --deep --sign - "$BUNDLE_DIR"
plutil -lint "${CONTENTS_DIR}/Info.plist"

echo "Packaged: ${ROOT_DIR}/${BUNDLE_DIR}"

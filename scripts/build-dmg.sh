#!/usr/bin/env bash
# Build a notarized DMG for Throttle.
# Requires: xcodebuild, create-dmg (brew install create-dmg), notarytool credentials in keychain
# under profile name "throttle-notary" (configured once via:
#   xcrun notarytool store-credentials throttle-notary --apple-id you@example --team-id TDV6D5L785)

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$HOME/GitHub/Throttle}"
cd "$PROJECT_DIR"

echo "→ Generating Xcode project"
xcodegen generate

echo "→ Archiving Release build"
ARCHIVE_PATH="$PROJECT_DIR/build/Throttle.xcarchive"
rm -rf "$ARCHIVE_PATH"
xcodebuild -project Throttle.xcodeproj -scheme Throttle \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS' \
    archive

EXPORT_DIR="$PROJECT_DIR/build/export"
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

EXPORT_PLIST="$PROJECT_DIR/build/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>TDV6D5L785</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

echo "→ Exporting signed app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST"

APP_PATH="$EXPORT_DIR/Throttle.app"

echo "→ Smoke-testing the build"
"$PROJECT_DIR/scripts/smoke-test.sh" "$APP_PATH"

echo "→ Building DMG"
DMG_PATH="$PROJECT_DIR/build/Throttle-1.0-alpha.dmg"
rm -f "$DMG_PATH"
create-dmg \
    --volname "Throttle" \
    --window-size 540 380 \
    --icon-size 96 \
    --icon "Throttle.app" 140 200 \
    --hide-extension "Throttle.app" \
    --app-drop-link 400 200 \
    "$DMG_PATH" \
    "$APP_PATH"

echo "→ Submitting for notarization"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile throttle-notary \
    --wait

echo "→ Stapling"
xcrun stapler staple "$DMG_PATH"

echo "→ Done: $DMG_PATH"

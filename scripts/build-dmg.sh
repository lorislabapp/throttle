#!/usr/bin/env bash
# Build and validate a signed DMG for Throttle.
# Notarization is fail-closed: pass --notarize only after explicit approval.
# Requires: xcodebuild, notarytool credentials in keychain under profile name
# "throttle-notary" (configured once via:
#   xcrun notarytool store-credentials throttle-notary --apple-id you@example --team-id TDV6D5L785)
#
# Manual Developer ID signing: the CloudKit entitlement forces embedded provisioning
# profiles. Mint/install them once (and after any cert rotation) via:
#   node scripts/provision-devid-profiles.mjs
# project.yml pins the profile names; this script's ExportOptions maps bundle→profile.

set -Eeuo pipefail
trap 'rc=$?; echo "✘ build-dmg.sh failed at line $LINENO (exit $rc)" >&2; exit $rc' ERR

NOTARIZE=false
case "${1:-}" in
    --notarize) NOTARIZE=true ;;
    --prepare-only|"") ;;
    *) echo "usage: $0 [--prepare-only|--notarize]" >&2; exit 64 ;;
esac

PROJECT_DIR="${PROJECT_DIR:-$HOME/GitHub/Throttle}"
cd "$PROJECT_DIR"
RELEASE_BUILD_DIR="${THROTTLE_RELEASE_BUILD_DIR:-$PROJECT_DIR/build}"
mkdir -p "$RELEASE_BUILD_DIR"

LOGIN_KEYCHAIN="${LOGIN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
SIGNING_IDENTITY="Developer ID Application: Christine Martin (TDV6D5L785)"
SIGNING_SHA1="8333AB7CD909731530AC62DD28CCA47C8D288225"
if ! security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" | grep -Fq "$SIGNING_SHA1"; then
    echo "✘ Required Developer ID identity is unavailable in $LOGIN_KEYCHAIN: $SIGNING_SHA1" >&2
    exit 78
fi

echo "→ Generating Xcode project"
xcodegen generate

echo "→ Archiving Release build"
ARCHIVE_PATH="$RELEASE_BUILD_DIR/Throttle.xcarchive"
rm -rf "$ARCHIVE_PATH"
xcodebuild -project Throttle.xcodeproj -scheme Throttle \
    -skipPackagePluginValidation -skipMacroValidation \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS' \
    archive

EXPORT_DIR="$RELEASE_BUILD_DIR/export"
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

EXPORT_PLIST="$RELEASE_BUILD_DIR/ExportOptions.plist"
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
    <string>manual</string>
    <key>signingCertificate</key>
    <string>$SIGNING_SHA1</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>com.lorislab.throttle</key>
        <string>Throttle DevID iCloud</string>
        <key>com.lorislab.throttle.widget</key>
        <string>Throttle Widget DevID</string>
    </dict>
</dict>
</plist>
PLIST

echo "→ Exporting signed app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST"

APP_PATH="$EXPORT_DIR/Throttle.app"

echo "→ Strictly verifying exported app and widget"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$APP_PATH/Contents/PlugIns/ThrottleWidget.appex"

echo "→ Smoke-testing the build"
"$PROJECT_DIR/scripts/smoke-test.sh" "$APP_PATH"

echo "→ Building DMG (diskutil — no create-dmg AppleScript, which needs Automation→Finder TCC and fails headless / on macOS betas)"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
DMG_PATH="$RELEASE_BUILD_DIR/Throttle-${VERSION}.dmg"
rm -f "$DMG_PATH"
STAGING=$(mktemp -d)
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag-to-install
diskutil image create from --volumeName "Throttle" --format UDZO "$STAGING" "$DMG_PATH"
rm -rf "$STAGING"

echo "→ Signing DMG itself (Gatekeeper trusts the container too)"
codesign --force --sign "$SIGNING_SHA1" --keychain "$LOGIN_KEYCHAIN" \
    --options runtime --timestamp "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"

if [ "$NOTARIZE" != true ]; then
    echo "→ Prepared locally: $DMG_PATH"
    echo "→ Notarization NOT RUN. Re-run with --notarize after explicit approval."
    exit 0
fi

echo "→ Submitting for notarization"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile throttle-notary \
    --wait

echo "→ Stapling"
xcrun stapler staple "$DMG_PATH"

echo "→ Generating Sparkle appcast entry"
# Prefer the EdDSA tool from Sparkle's compiled artifacts; the old DSA script
# in old_dsa_scripts/ can't sign modern updates, so explicitly exclude it.
SIGN_TOOL=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f \
    -path "*/artifacts/*" -not -path "*old_dsa*" 2>/dev/null | head -1)
if [ -z "$SIGN_TOOL" ]; then
    SIGN_TOOL=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f \
        -not -path "*old_dsa*" 2>/dev/null | head -1)
fi

if [ -z "$SIGN_TOOL" ] || [ ! -x "$SIGN_TOOL" ]; then
    echo "✘ Sparkle sign_update tool not found — appcast cannot be signed." >&2
    echo "  Run a build via Xcode at least once to populate DerivedData with Sparkle artifacts." >&2
    exit 1
fi

if true; then
    SIGN_OUTPUT=$("$SIGN_TOOL" "$DMG_PATH")
    DMG_SIZE=$(stat -f%z "$DMG_PATH")
    BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
    PUBDATE=$(LC_TIME=en_US date +"%a, %d %b %Y %H:%M:%S %z")

    # sign_update emits its own length="..." attribute; drop ours to avoid duplicates.
    APPCAST_ENTRY="$RELEASE_BUILD_DIR/appcast-entry-${VERSION}.xml"
    cat > "$APPCAST_ENTRY" <<XML
<item>
    <title>Version ${VERSION}</title>
    <pubDate>${PUBDATE}</pubDate>
    <sparkle:version>${BUILD_NUMBER}</sparkle:version>
    <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <enclosure url="https://lorislab.fr/throttle/Throttle-${VERSION}.dmg"
               type="application/octet-stream"
               ${SIGN_OUTPUT} />
</item>
XML
    echo "→ Appcast entry: $APPCAST_ENTRY"
    echo "→   Append the <item>...</item> contents to lorislab-website's appcast.xml"
fi

echo "→ Done: $DMG_PATH"

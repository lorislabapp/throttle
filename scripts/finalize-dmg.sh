#!/usr/bin/env bash
# Finalize a DMG from an ALREADY-exported, signed Throttle.app — skips the slow
# archive/export when create-dmg flaked at the unmount step. Reuses build/export.
# Notarization is fail-closed: pass --notarize only after explicit approval.
set -Eeuo pipefail
trap 'rc=$?; echo "✘ finalize-dmg.sh failed at line $LINENO (exit $rc)" >&2; exit $rc' ERR

NOTARIZE=false
case "${1:-}" in
    --notarize) NOTARIZE=true ;;
    --prepare-only|"") ;;
    *) echo "usage: $0 [--prepare-only|--notarize]" >&2; exit 64 ;;
esac

PROJECT_DIR="${PROJECT_DIR:-$HOME/GitHub/Throttle}"
cd "$PROJECT_DIR"
APP_PATH="$PROJECT_DIR/build/export/Throttle.app"
[ -d "$APP_PATH" ] || { echo "no export at $APP_PATH"; exit 1; }

LOGIN_KEYCHAIN="${LOGIN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
SIGNING_IDENTITY="Developer ID Application: Christine Martin (TDV6D5L785)"
SIGNING_SHA1="8333AB7CD909731530AC62DD28CCA47C8D288225"
if ! security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" | grep -Fq "$SIGNING_SHA1"; then
    echo "✘ Required Developer ID identity is unavailable in $LOGIN_KEYCHAIN: $SIGNING_SHA1" >&2
    exit 78
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$APP_PATH/Contents/PlugIns/ThrottleWidget.appex"

# Detach any stale create-dmg leftovers so the mount/unmount is clean.
for v in /Volumes/dmg.*; do [ -d "$v" ] && hdiutil detach "$v" -force 2>/dev/null || true; done
rm -f "$PROJECT_DIR"/build/rw.*.dmg 2>/dev/null || true

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
DMG_PATH="$PROJECT_DIR/build/Throttle-${VERSION}.dmg"
rm -f "$DMG_PATH"

echo "→ Building DMG ($VERSION)"
create-dmg \
    --volname "Throttle" \
    --window-size 540 380 --icon-size 96 \
    --icon "Throttle.app" 140 200 --hide-extension "Throttle.app" \
    --app-drop-link 400 200 \
    "$DMG_PATH" "$APP_PATH"

echo "→ Signing DMG"
codesign --force --sign "$SIGNING_SHA1" --keychain "$LOGIN_KEYCHAIN" \
    --options runtime --timestamp "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"

if [ "$NOTARIZE" != true ]; then
    echo "→ Prepared locally: $DMG_PATH"
    echo "→ Notarization NOT RUN. Re-run with --notarize after explicit approval."
    exit 0
fi

echo "→ Notarizing"
xcrun notarytool submit "$DMG_PATH" --keychain-profile throttle-notary --wait

echo "→ Stapling"
xcrun stapler staple "$DMG_PATH"

echo "→ Appcast entry"
SIGN_TOOL=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f -path "*/artifacts/*" -not -path "*old_dsa*" 2>/dev/null | head -1)
[ -n "$SIGN_TOOL" ] || SIGN_TOOL=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f -not -path "*old_dsa*" 2>/dev/null | head -1)
SIGN_OUTPUT=$("$SIGN_TOOL" "$DMG_PATH")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
PUBDATE=$(LC_TIME=en_US date +"%a, %d %b %Y %H:%M:%S %z")
cat > "$PROJECT_DIR/build/appcast-entry-${VERSION}.xml" <<XML
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
echo "→ Done: $DMG_PATH"

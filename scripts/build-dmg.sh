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

# Sparkle compares CFBundleVersion, NOT the marketing string. Shipping 3.2.91
# with CURRENT_PROJECT_VERSION left at 190 — the same build as 3.2.90 — produced
# a release that notarized, deployed and served correctly, and that no client
# ever offered: two builds numbered 190, nothing newer. Catch it here, before
# ten minutes of archiving, rather than after a full publish cycle.
PLANNED_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION:' project.yml | tr -dc '0-9')
PLANNED_VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')
if [ -n "$PLANNED_BUILD" ]; then
    # The published feed is the only authority on what has already shipped. A
    # network failure must NOT block a build, so this warns and continues; only a
    # feed we actually read can veto.
    FEED=$(curl -fsS --max-time 10 https://lorislab.fr/throttle/appcast.xml 2>/dev/null || true)
    if [ -z "$FEED" ]; then
        echo "⚠ Could not read the published appcast — build-number collision NOT checked."
    elif printf '%s' "$FEED" | grep -q "<sparkle:version>${PLANNED_BUILD}</sparkle:version>"; then
        SHIPPED=$(printf '%s' "$FEED" \
            | grep -B4 "<sparkle:version>${PLANNED_BUILD}</sparkle:version>" \
            | grep -m1 '<title>' | sed 's/.*<title>\(.*\)<\/title>.*/\1/')
        echo "✘ Build ${PLANNED_BUILD} is already published as \"${SHIPPED}\"." >&2
        echo "  Sparkle compares CFBundleVersion, so ${PLANNED_VERSION} would never be offered." >&2
        echo "  Raise CURRENT_PROJECT_VERSION in project.yml before building." >&2
        exit 65
    else
        echo "→ Build ${PLANNED_BUILD} (${PLANNED_VERSION}) is not yet published — OK"
    fi
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
# Apple's timestamp service is a network dependency, and it goes away sometimes.
# Twice on 2026-08-21 it failed with "The timestamp service is not available",
# after six minutes of universal archiving, leaving a zero-byte DMG behind — and
# both times an immediate manual retry succeeded. A signature without a trusted
# timestamp is not an option (notarization requires one), so retry rather than
# discard the build.
for attempt in 1 2 3 4 5; do
    if codesign --force --sign "$SIGNING_SHA1" --keychain "$LOGIN_KEYCHAIN" \
        --options runtime --timestamp "$DMG_PATH" 2>"$RELEASE_BUILD_DIR/codesign.err"; then
        break
    fi
    if ! grep -q "timestamp service is not available" "$RELEASE_BUILD_DIR/codesign.err"; then
        cat "$RELEASE_BUILD_DIR/codesign.err" >&2
        echo "✘ DMG signing failed for a reason other than the timestamp service." >&2
        exit 1
    fi
    if [ "$attempt" = 5 ]; then
        echo "✘ Apple's timestamp service stayed unavailable across 5 attempts." >&2
        echo "  The build is intact; re-run when it recovers." >&2
        exit 1
    fi
    echo "⚠ Timestamp service unavailable (attempt $attempt/5) — retrying in $((attempt * 10))s"
    sleep $((attempt * 10))
done
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

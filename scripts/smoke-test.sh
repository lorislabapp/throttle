#!/usr/bin/env bash
# Partial smoke-test automation for Throttle v1.0-alpha.
# Run after a release build. Prints PASS/FAIL per check.

set -u

PASS=0
FAIL=0

ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
ko() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

APP_PATH="${1:-$HOME/GitHub/Throttle/build/Build/Products/Debug/Throttle.app}"

[ -d "$APP_PATH" ] && ok "App bundle present at $APP_PATH" || ko "App bundle missing at $APP_PATH"

# LSUIElement
INFO="$APP_PATH/Contents/Info.plist"
if [ -f "$INFO" ]; then
    if /usr/libexec/PlistBuddy -c "Print :LSUIElement" "$INFO" 2>/dev/null | grep -q true; then
        ok "LSUIElement = true"
    else
        ko "LSUIElement not set to true (would show in Dock)"
    fi
else
    ko "Info.plist missing"
fi

# Bundle ID
if [ -f "$INFO" ]; then
    BID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO" 2>/dev/null)
    [ "$BID" = "com.lorislab.throttle" ] && ok "Bundle ID = com.lorislab.throttle" \
                                         || ko "Bundle ID is '$BID' (expected com.lorislab.throttle)"
fi

# Code signing
if codesign -dvv "$APP_PATH" 2>&1 | grep -q "Authority=Developer ID Application"; then
    ok "Signed with Developer ID Application"
else
    ko "Not signed with Developer ID Application (check signing config)"
fi

# Team ID
if codesign -dvv "$APP_PATH" 2>&1 | grep -q "TDV6D5L785"; then
    ok "Team ID = TDV6D5L785"
else
    ko "Team ID is not TDV6D5L785"
fi

echo
echo "=== Result: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

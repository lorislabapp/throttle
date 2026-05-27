#!/bin/bash
#
# Throttle Demo Mode Launcher
#
# Builds and launches Throttle with fake €207 savings data
# for screen recording perfect marketing videos.
#
# Usage:
#   chmod +x launch-demo.sh
#   ./launch-demo.sh
#
# The app will show:
# - €207 saved total (30M lifetime + 45M this week)
# - All 5 milestone badges unlocked
# - Session 6%, Weekly 80%, Sonnet 99%
# - Realistic sparkline showing growth
#
# Press Cmd+Q to quit when done recording.

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT="$SCRIPT_DIR/Throttle.xcodeproj"

echo "🎬 Throttle Demo Mode Launcher"
echo "==============================="
echo ""

# Check if Xcode is installed
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ Error: Xcode not found. Install Xcode from the App Store."
    exit 1
fi

echo "📦 Building Throttle (Debug)..."
xcodebuild -project "$PROJECT" \
    -scheme Throttle \
    -configuration Debug \
    -derivedDataPath "$SCRIPT_DIR/.build" \
    build \
    > /dev/null 2>&1

if [ $? -ne 0 ]; then
    echo "❌ Build failed. Check Xcode for errors."
    exit 1
fi

echo "✅ Build succeeded"
echo ""

# Find the built app
APP_PATH="$SCRIPT_DIR/.build/Build/Products/Debug/Throttle.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: App not found at $APP_PATH"
    exit 1
fi

echo "🎬 Launching Throttle in DEMO MODE..."
echo ""
echo "Demo data:"
echo "  • €207 saved total"
echo "  • Session: 6% (1.2M / 20M)"
echo "  • Weekly: 80% (640M / 800M)"
echo "  • Sonnet: 99% (792M / 800M)"
echo "  • All 5 milestone badges unlocked"
echo ""
echo "📹 Press Cmd+Shift+5 to start screen recording"
echo "⏹️  Press Cmd+Q to quit when done"
echo ""

# Launch with -demo flag
open "$APP_PATH" --args -demo

echo "✅ Demo mode launched!"
echo ""
echo "💡 TIP: For 30s video, record:"
echo "   1. Menu bar click → dropdown appears"
echo "   2. Hover over €207 banner (shows milestone badges)"
echo "   3. Scroll to show meter bars + sparkline"
echo "   4. Click Settings → show optimizer toggle"
echo "   5. Cmd+Q to quit"
echo ""

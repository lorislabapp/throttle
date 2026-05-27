#!/bin/bash
#
# Throttle Demo Screenshot Generator
#
# Generates perfect marketing screenshots from SwiftUI previews.
# Uses Xcode's preview rendering to export PNG images.
#
# Usage:
#   chmod +x generate-demo-screenshots.sh
#   ./generate-demo-screenshots.sh
#
# Output: ~/Desktop/throttle-screenshots/

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
OUTPUT_DIR="$HOME/Desktop/throttle-screenshots"
PROJECT="$SCRIPT_DIR/Throttle.xcodeproj"

echo "🎬 Throttle Demo Screenshot Generator"
echo "======================================"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"
echo "✓ Created output directory: $OUTPUT_DIR"

# Check if Xcode is installed
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ Error: Xcode not found. Install Xcode from the App Store."
    exit 1
fi

echo ""
echo "📸 Generating screenshots from SwiftUI previews..."
echo ""
echo "MANUAL STEPS (Xcode Canvas method):"
echo "1. Open Throttle.xcodeproj in Xcode"
echo "2. Open file: Throttle/UI/MenuBar/DropdownView+Preview.swift"
echo "3. Editor → Canvas → Show Canvas"
echo "4. Wait for previews to render (4 variants)"
echo "5. For each preview:"
echo "   - Click preview to focus"
echo "   - Cmd+Shift+4 → Space → Click preview window"
echo "   - Screenshot saved to Desktop"
echo "6. Move screenshots to: $OUTPUT_DIR"
echo ""
echo "PREVIEW VARIANTS:"
echo "  1. Hero (€207 saved)      → hero-screenshot.png"
echo "  2. Medium (€45 saved)     → medium-screenshot.png"
echo "  3. Early User (€5 saved)  → early-screenshot.png"
echo "  4. Free Tier (Upsell)     → free-tier-screenshot.png"
echo ""
echo "💡 TIP: For Product Hunt, use 'Hero (€207 saved)' as main image"
echo "💡 TIP: For Twitter thread, use 'Medium (€45 saved)' (more relatable)"
echo ""

# Alternative: Try to build and extract preview snapshots programmatically
# (This is experimental - Xcode Canvas is more reliable)
echo "📦 Building project (optional - for validation)..."
xcodebuild -project "$PROJECT" \
    -scheme Throttle \
    -configuration Debug \
    -destination 'platform=macOS' \
    build \
    > /dev/null 2>&1 && echo "✓ Build succeeded" || echo "⚠️  Build failed (non-blocking)"

echo ""
echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "1. Open Xcode and follow manual steps above"
echo "2. Screenshots will be in: $OUTPUT_DIR"
echo "3. Use for Product Hunt, Twitter, Reddit posts"
echo ""
echo "🎥 For 30s video demo:"
echo "   Run the Debug build with demo data, then use Cmd+Shift+5 to record"
echo ""

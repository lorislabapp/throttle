#!/bin/bash
# Diagnostic automatique pour Throttle v3.0 Deep Dive

echo "═══════════════════════════════════════════════════════════"
echo "  Throttle v3.0 — Diagnostic Automatique"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Test 1: App running
echo "✓ Test 1: App Running"
if pgrep -f "Throttle.app" > /dev/null; then
    echo "  ✅ Throttle is running (PID: $(pgrep -f Throttle.app))"
else
    echo "  ❌ Throttle is NOT running"
fi
echo ""

# Test 2: Build artifacts exist
echo "✓ Test 2: Build Artifacts"
if [ -f "build/Build/Products/Debug/Throttle.app/Contents/MacOS/Throttle" ]; then
    echo "  ✅ Throttle.app binary exists"
    BUILD_SIZE=$(du -sh build/Build/Products/Debug/Throttle.app | cut -f1)
    echo "     Size: $BUILD_SIZE"
else
    echo "  ❌ Binary not found"
fi
echo ""

# Test 3: New files in bundle
echo "✓ Test 3: New Files Included"
if [ -f "Throttle/UI/Settings/AssistantPane.swift" ]; then
    echo "  ✅ AssistantPane.swift exists on disk"
else
    echo "  ❌ AssistantPane.swift missing"
fi

if [ -f "Throttle/Services/CcusageImporter.swift" ]; then
    echo "  ✅ CcusageImporter.swift exists on disk"
else
    echo "  ❌ CcusageImporter.swift missing"
fi
echo ""

# Test 4: Git status
echo "✓ Test 4: Git Branch"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "  Current branch: $BRANCH"
COMMITS=$(git log deep-dive-v3 ^main --oneline | wc -l | xargs)
echo "  Commits ahead of main: $COMMITS"
echo ""

# Test 5: Console errors (last 30 seconds)
echo "✓ Test 5: Recent Console Errors"
if command -v log &> /dev/null; then
    ERRORS=$(log show --predicate 'process == "Throttle"' --last 30s --style compact 2>/dev/null | grep -i "error\|crash\|exception" | wc -l | xargs)
    if [ "$ERRORS" -eq 0 ]; then
        echo "  ✅ No errors in last 30 seconds"
    else
        echo "  ⚠️  Found $ERRORS error(s) in console"
        log show --predicate 'process == "Throttle"' --last 30s --style compact 2>/dev/null | grep -i "error\|crash\|exception" | head -3
    fi
else
    echo "  ⏭️  Skipped (log command not available)"
fi
echo ""

# Test 6: Claude Code detection
echo "✓ Test 6: Claude Code Detection"
if [ -d "$HOME/.claude/projects" ]; then
    PROJECTS=$(find "$HOME/.claude/projects" -name "*.jsonl" 2>/dev/null | wc -l | xargs)
    echo "  ✅ ~/.claude/projects exists"
    echo "     Found $PROJECTS session files"
else
    echo "  ⚠️  ~/.claude/projects not found (expected if Claude Code not installed)"
fi
echo ""

# Test 7: Database exists
echo "✓ Test 7: Database"
DB_PATH="$HOME/Library/Application Support/com.lorislab.throttle/throttle.db"
if [ -f "$DB_PATH" ]; then
    echo "  ✅ Database exists"
    DB_SIZE=$(du -h "$DB_PATH" | cut -f1)
    echo "     Size: $DB_SIZE"

    # Check if new tables exist (from ccusage import)
    if command -v sqlite3 &> /dev/null; then
        TABLES=$(sqlite3 "$DB_PATH" ".tables" 2>/dev/null | tr ' ' '\n' | wc -l | xargs)
        echo "     Tables: $TABLES"
    fi
else
    echo "  ℹ️  Database not yet created (app just launched)"
fi
echo ""

echo "═══════════════════════════════════════════════════════════"
echo "  Diagnostic Complete — Now run manual tests"
echo "  Guide: TEST-SESSION-LIVE.md"
echo "═══════════════════════════════════════════════════════════"

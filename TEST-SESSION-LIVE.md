# Test Session Live — Throttle v3.0 Deep Dive

**Date:** 2026-05-27  
**Build:** build/Build/Products/Debug/Throttle.app  
**Status:** Running locally

---

## 🎯 Tests Critiques (5-10 minutes)

### ✅ Test 1: Build & Launch
- [x] Build succeeded
- [x] App launched without crash
- [ ] Menu bar icon appears
- [ ] Dropdown opens when clicked

**Action:** Click the menu bar icon → dropdown should open

---

### Test 2: VoiceOver Labels (2 min)
**Ce qu'on teste:** Les 8 boutons icon-only ont des labels pour VoiceOver

**Steps:**
1. Enable VoiceOver: **Cmd+F5**
2. Click menu bar icon to open dropdown
3. **Tab** through all buttons
4. Listen: each button should announce its action (not just "Button")

**Expected:**
- Calibration buttons: "Decrease by 5 percent", "Decrease by 1 percent", "Increase by 1 percent", "Increase by 5 percent"
- (If you have ProjectAssistantTab visible): "Run local audit", "Export diagnostics", "Switch AI provider", "Clear conversation"

**Result:** PASS / FAIL / SKIP

**Disable VoiceOver:** Cmd+F5

---

### Test 3: Escape Key on Back Button (30 seconds)
**Ce qu'on teste:** First-run flow keyboard navigation

**Steps:**
1. If first-run already done: Delete settings to trigger it again:
   ```bash
   rm -rf ~/Library/Application\ Support/com.lorislab.throttle/
   killall Throttle
   open build/Build/Products/Debug/Throttle.app
   ```
2. First-run flow should appear
3. Click "Next" to go to step 2
4. **Press Escape**
5. Should go back to step 1

**Result:** PASS / FAIL / SKIP (if can't test easily)

---

### Test 4: Directory Deletion Recovery (1 min)
**Ce qu'on teste:** App ne crash pas si ~/.claude/projects/ est supprimé

**IMPORTANT:** Backup first!
```bash
# Backup
cp -r ~/.claude/projects ~/.claude/projects.backup

# Delete
rm -rf ~/.claude/projects/

# Wait 10 seconds
# Check dropdown → should show "Claude Code not detected" (no crash)

# Restore
mv ~/.claude/projects.backup ~/.claude/projects/
# Wait 10 seconds
# Check dropdown → should show meters again
```

**Result:** PASS / FAIL / SKIP

---

### Test 5: Exact Mode MainActor Isolation (30 seconds)
**Ce qu'on teste:** Pas de warnings MainActor dans la console

**Steps:**
1. Open Console.app
2. Filter: "Throttle"
3. In Throttle: Enable Exact mode (if you have claude.ai session)
4. Rapid-click between dropdown modes (meter → settings → stats → meter)
5. Check Console: should be NO warnings about "MainActor" or "isolation"

**Result:** PASS / FAIL / SKIP

---

### Test 6: Settings → Assistant Tab Exists (10 seconds)
**Ce qu'on teste:** Le nouveau tab AssistantPane apparaît

**Steps:**
1. Open dropdown
2. Click Settings (gear icon bottom-left)
3. Look for **"Assistant"** tab (should be 2nd tab, with brain icon)
4. Click it
5. Should show:
   - "Enable Caveman Mode" toggle
   - "Import from ccusage" button

**Result:** PASS / FAIL / SKIP

---

### Test 7: Calibration Empty State Guidance (20 seconds)
**Ce qu'on teste:** Le hint "Tap to set your cap" apparaît

**Steps:**
1. Settings → Calibration
2. Click "Reset all calibrations" (if button exists)
3. Go back to meter view
4. Each gauge should show:
   - "not calibrated"
   - "Tap to set your cap" (petit texte en dessous)

**Result:** PASS / FAIL / SKIP

---

### Test 8: Pro Banner Escape Key (30 seconds)
**Ce qu'on teste:** Banner dismiss avec Escape

**Prerequisites:** Free tier (no Pro license)

**Steps:**
1. If Pro banner visible in dropdown:
   - **Press Escape**
   - Banner should dismiss
2. If no banner: SKIP

**Result:** PASS / FAIL / SKIP

---

### Test 9: ccusage Import (2 min) — OPTIONAL
**Ce qu'on teste:** Import ccusage data to DB

**Prerequisites:**
```bash
npm install -g ccusage  # if not installed
ccusage  # run once to generate data
```

**Steps:**
1. Settings → Assistant tab
2. Click "Import from ccusage"
3. Should show "✓ Imported N days of usage data"
4. Go to Stats → should see imported events

**Result:** PASS / FAIL / SKIP (if ccusage not installed)

---

## 🐛 Bugs Found

[Note any bugs here]

---

## ✅ Decision

After tests:
- **ALL PASS** → Ship v3.0 immediately
- **1-2 FAIL (minor)** → Fix and re-test (1-2h)
- **3+ FAIL or 1 CRITICAL** → Review, deeper debugging needed

---

## 📊 Results Summary

Total tests: 9  
Passed: __  
Failed: __  
Skipped: __

**Ship-ready:** YES / NO / MAYBE

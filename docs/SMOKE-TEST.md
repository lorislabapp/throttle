# Throttle v1.0-alpha smoke test

Run these manually before tagging the build.

## A. Cold launch + first-run

1. Delete first-run flag: `defaults delete com.lorislab.throttle firstRunDone`
2. Delete database: `rm -rf ~/Library/Application\ Support/com.lorislab.throttle/`
3. Quit any running Throttle: `pkill Throttle || true`
4. Launch Throttle.app.
5. **Expect:** Menu bar icon appears. Click it → dropdown shows "Finish setup" CTA. Click "Finish setup" → first-run window appears with 3 steps. Navigate Back/Continue, choose plan, choose login items, "Get Started" closes window.

## B. With Claude Code data

1. Confirm `~/.claude/projects/` exists and has at least one `.jsonl` with usage events.
2. Click the menu bar icon.
3. **Expect:** Dropdown shows three rows (Session, Weekly all, Weekly Sonnet) with progress bars and reset countdowns. If you picked Pro/Max5x/Max20x in first-run, percentages are populated. If you skipped, "not calibrated" appears until auto-cal kicks in.

## C. No Claude Code

1. Quit Throttle.
2. Temporarily rename `~/.claude/projects/` → `~/.claude/projects-bak/`.
3. Launch Throttle.
4. **Expect:** Menu bar icon shows the empty gauge. Dropdown shows "Claude Code not detected."
5. Restore: `mv ~/.claude/projects-bak ~/.claude/projects`.

## D. Live update

1. With Throttle running and Claude Code idle, check the dropdown. Note the percent.
2. In another terminal, start a Claude Code session and ask it to do something simple (a few turns).
3. Quit Claude Code.
4. Open the dropdown again within ~30 seconds.
5. **Expect:** the percent has increased.

## E. Settings

1. Open Settings via the dropdown.
2. **Expect:** five tabs (General / Calibration / Hooks / Privacy / About) — all open without error.
3. Calibration tab shows current cap values; "Save" works on each row; "Reset all calibrations" zeros them.
4. Hooks tab shows status of `~/.claude/hooks/session-start-router.sh` and `pre-compact.sh`.
5. Privacy tab → "Show Logs…" opens the log viewer with content.
6. About tab shows correct version string.

## F. Singleton

1. With Throttle running, run `open -n /path/to/Throttle.app`.
2. **Expect:** the second instance launches briefly, then quits. Only one menu bar icon remains.

## G. Quit + relaunch persistence

1. Quit Throttle (dropdown → Quit).
2. Relaunch.
3. **Expect:** menu bar icon appears immediately. No first-run window. Caps from before are preserved (if you set them manually).

## H. Sleep / wake

1. Put Mac to sleep for 30 seconds, then wake.
2. **Expect:** Throttle still in menu bar; dropdown still works.

## I. Disk full backup (manual — optional)

Skip in v1.0-alpha; relevant when the optimizer (Plan 2) ships.

## Known v1.0-alpha limitations

- Pro features (paywall, optimizer, license, hooks management UI, backups UI) are not present. Plan 2 adds them.
- Sparkle auto-update is not wired. Plan 3 adds it.
- The Anthropic warning detector regex (WarningDetector.swift) is permissive and not yet validated against real warnings — it will likely need tuning when real warning JSONLs are inspected during beta.

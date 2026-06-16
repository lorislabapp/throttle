# Throttle — Cockpit work session, 2026-06-16

## Features shipped (committed to main)
- **Terminal theme presets**: 4 curated presets — Graphite, Midnight, Light, High Contrast — switchable from a top-bar palette menu; switching restyles every live session. Curated presets only, not a full colour/sound editor. The palette keeps ANSI 8 (dim — claude's tool/meta lines) recessive vs ANSI 15 (bright prose) so answers stand out from actions.
- **Drop-image menu**: on image drop, choose "Attach image (vision tokens estimate)" vs "OCR to text (local, saves tokens)". Instant menu (dimensions via ImageIO, OCR only on selection); Option = silent bypass. Token estimators: image w×h/750 with downscale clamp; text chars/4.
- **Attention detection + question feed**: watch each session's output for genuine interactive prompts only (numbered selection menu or yes/no) to avoid false positives on prose. Per-session "waiting" badges in the rail/tabs/overview + an expandable question history; a local notification fires when a hidden session is waiting on input; tapping it focuses that session.
- **Timeline navigation**: top-bar chevrons jump the active terminal to the previous/next conversation turn (claude responses or your prompts) plus a jump-to-live button.
- **Session hibernation**: free a session's RAM by terminating its process subtree while keeping the resume id; the tab stays in the rail and wakes back to full context. Moon button on hover. Serves the limited-RAM Mac constraint.

## Bug fixes
- **Session-context loss on cockpit restart**, three causes fixed: (1) the stats refresh no longer wipes a dormant tab's saved resume id; (2) on spawn we fall back to the newest transcript in the project dir if the id was lost; (3) the project-dir name now matches Claude Code's encoding (every non-alphanumeric becomes `-`), so paths with spaces or accents link correctly and no longer get lost.
- **Binding number divergence across surfaces**: the cockpit only labels a value EXACT when the exact snapshot is fresh; otherwise it degrades to the local estimate, matching the menu-bar dropdown.
- **Local estimate undercounting** badly vs the true server percentage: the exact reading now calibrates (anchors) the local cap on every snapshot (cap = local total / (percent/100)), respecting a user-set manual cap, so the local estimate tracks reality between exact refreshes.
- **"Open other folder" no-op under memory pressure**: the open panel/alert now activate the app and come to the front.

## Product decisions (scope)
- Curated theme presets, not a full theme/colour/sound editor.
- No NotebookLM integration inside the app (cloud + account would break the local-only positioning).
- "Xcode dev in general" is out of scope; only a narrow slice fits: a 1-click "send distilled Xcode build errors to claude" (token-saving, reads local DerivedData).

## Operational notes
- Building into the running app's DerivedData path can kill the live app (code page-in). The cockpit hosts its own working session, so a relaunch ends and resumes that session. macOS has no `setsid` binary — use a python `os.setsid()` for a detached relaunch. LaunchServices launches the registered bundle copy, so update the copy it actually launches, not an isolated build path.
- Sparkle release pipeline: `scripts/build-dmg.sh` (archive Release, Developer ID sign, notarize via the "throttle-notary" keychain profile, build DMG, generate the EdDSA appcast entry). Feed: `lorislab.fr/throttle/appcast.xml`. Current version 3.1.7 build 97. Release to all users still pending runtime verification.

## Commits (main)
- `36776a8` theme + drop menu + attention/feed + resume-context fixes
- `ce29bd9` hibernation + open-folder fix
- `a0ee4c8` binding honors exact freshness
- `6248059` anchor local cap to exact utilization (#2 estimate)
- `1387ca5` terminal presets + timeline navigation

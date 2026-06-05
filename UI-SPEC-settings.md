# UI-SPEC — Throttle Settings (Direction A · "Console Tabs")

Chosen via Claude Design (2026-06-05). Inherits the meter/Stats cockpit tokens.
Lives inline in the 440pt dropdown, edge-to-edge. **The standalone
`SettingsScene.swift` window is deleted — one code path, all inline.**

## Nav
Title row (Throttle · Settings · PRO/FREE/Trial + EXACT pills) → a **6-tab console
bar** (segmented, active tab = accent text + 2px accent underline) → one pane scrolls.
Tabs: **General · Pro · AI · Caps · Hooks · About**.

## Group content (re-tabbed from the old 5 panes)
- **General**: launch-at-login · notify 80/95 · weekly-reset reminder (Add to
  Calendar) · software updates (Check now + last-checked).
- **Pro** (NEW — extracted from old General): license block (Free → Buy €19 + Paste
  key · Trial → days-left banner + Buy · Activated → key •••• + renews + Deactivate) +
  Exact mode (locked for free; else toggle + numbered 3-step setup + status lamp
  Working/error/signed-out).
- **AI**: provider segmented (Apple/Claude/API) · API-key row (when API) · model
  quality segmented (Opus/Sonnet/Haiku) · caveman toggle · ccusage import.
- **Caps**: three cap windows (preset chips Pro/Max5×/Max20× — NOT TextField, macOS
  26.5) · "recalibrate I'm at __%" · reset all.
- **Hooks**: read-only status rows (✓ detected / dashed not-installed) + note.
- **About** (Privacy+About merged): reveal log · privacy policy · diagnostics export ·
  CSV export · telemetry note · app icon + version (mono; 10-tap dev unlock) + Check
  for updates + support/EULA/website links.

## Controls (cockpit)
- Rows: `.set-row` — min 44pt, hairline between, title 13 + sub 11(ink-2), trailing control.
- **Native** `Toggle(.switch)` tinted accent · native-style segmented (custom: bar-track
  bg, active = bg-elev + accent text) · chips (inset border; selected = accent tint +
  border) · buttons (inset border; `.primary` = accent fill white).
- Mono digits on caps/%/version/key/days. Accent only on interactive. No usage bars,
  no red. Hairlines + 16pt padding. No Canvas/numericText/shadow (macOS 26.5).

## States
Free vs Pro (license + exact locked) · Trial active · Exact working/error/signed-out ·
not-signed-in. All wired to the existing services (LicenseService, TrialService,
ExactModeService, CalibrationEngine, HookStatusService, AIProviderRegistry, …).

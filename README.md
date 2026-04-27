# Throttle Meter

> An open-source Claude Code usage meter for macOS. Watch your 5-hour and weekly limits live in your menu bar so you never get cut off mid-session without warning.

This repo is the **free, open-source meter** — the same code that ships inside the commercial [Throttle](https://lorislab.fr/throttle) app, minus the Pro features (optimizer wizard, license management, paid-tier UI).

## What it does

- Reads your Claude Code session files at `~/.claude/projects/<repo>/<session>.jsonl`
- Sums tokens consumed across rolling 5-hour and weekly windows
- Shows usage as a percentage in your menu bar, with progress bars in the dropdown
- Auto-calibrates from your observed peaks; manually adjustable in Settings
- Works fully offline — no telemetry, no network calls, no account

## What it does *not* do

- Modify any file in `~/.claude/`
- Connect to Anthropic, LorisLabs, or anyone else
- Track or log session content (only token counts and timestamps)

If you want optimization, hook installation, license-tier features, and Sparkle auto-update, get the commercial [Throttle](https://lorislab.fr/throttle) (€19, one-time).

## Privacy

Everything stays on your Mac. The privacy claim is **auditable in this repo** — see `Throttle/Services/`, `Throttle/Parser/`, `Throttle/DataLayer/`. The only filesystem reads are `~/.claude/projects/` (recursive) and writes are to `~/Library/Application Support/com.lorislab.throttle/` (local SQLite + logs).

## Free vs Commercial

| | Throttle Meter (this repo) | [Throttle](https://lorislab.fr/throttle) |
|---|:---:|:---:|
| Live menu-bar meter | ✅ | ✅ |
| 5-hour + weekly windows | ✅ | ✅ |
| Calibration (auto / manual) | ✅ | ✅ |
| Settings + log viewer | ✅ | ✅ |
| Optimizer wizard (cuts up to 70% off session-start context) | ❌ | ✅ |
| Hooks management UI | ❌ | ✅ |
| Backup + rollback for Claude Code config | ❌ | ✅ |
| Sparkle auto-update | ❌ | ✅ |
| Paid support | ❌ | ✅ |
| **License** | MIT | Commercial (€19 one-time) |

The commercial version is built on top of this exact codebase plus closed-source Pro modules.

## Build

Requirements:

- macOS 14 (Sonoma) or later
- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

```bash
git clone https://github.com/lorislabapp/throttle-meter.git
cd throttle-meter
xcodegen generate
open Throttle.xcodeproj
```

Or build from CLI:

```bash
xcodebuild -project Throttle.xcodeproj -scheme Throttle \
  -destination 'platform=macOS' build
```

The `.app` lands in `~/Library/Developer/Xcode/DerivedData/Throttle-*/Build/Products/Debug/Throttle.app`.

## Tests

```bash
xcodebuild test -project Throttle.xcodeproj -scheme Throttle \
  -destination 'platform=macOS'
```

21 unit tests covering JSONL parsing, calibration math, database queries, and the cold-start scanner.

## Architecture

Layered SwiftUI 6 + GRDB.swift app. One responsibility per file:

```
Throttle/
├── Models/         Codable + GRDB record types
├── Database/       Migrations, DatabaseManager, queries
├── Parser/         JSONL line parser, file parser, warning detector
├── DataLayer/      Cold-start scanner, FSEvents watcher, hourly sweeper, coordinator
├── Calibration/    Window math, calibration engine (auto/manual/anchor)
├── State/          @Observable AppState, UsageSnapshot
├── Services/       AppLogger, ClaudeCodePathProvider, login items, hook status
├── UI/MenuBar/     Menu bar label + dropdown
├── UI/FirstRun/    3-step welcome window
├── UI/Settings/    5 panes (General, Calibration, Hooks, Privacy, About)
└── UI/States/      Log viewer, empty states
```

## Identity

Built and signed by **Christine Martin** (LorisLabs).

- Apple Developer Team ID: `TDV6D5L785`
- Bundle ID: `com.lorislab.throttle`

## License

[MIT](LICENSE) — do whatever you want with it. Attribution appreciated, not required.

## Contributing

PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Be excellent to each other ([Code of Conduct](CODE_OF_CONDUCT.md)).

## Status

**v1.0-alpha.1** — first buildable version. Free tier complete. The commercial version's Pro features (optimizer, paywall, license) are in active development in a separate private repo.

If you'd like to be a beta tester, reach out at [support@lorislab.fr](mailto:support@lorislab.fr).

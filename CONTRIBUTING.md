# Contributing to Throttle Meter

Thanks for considering a contribution. This is the open-source meter that ships inside the commercial [Throttle](https://lorislab.fr/throttle) app — improvements here improve both.

## Quick start

```bash
git clone https://github.com/lorislabapp/throttle-meter.git
cd throttle-meter
brew install xcodegen
xcodegen generate
open Throttle.xcodeproj
```

Run the test suite:

```bash
xcodebuild test -project Throttle.xcodeproj -scheme Throttle \
  -destination 'platform=macOS'
```

All 21 tests should pass on a clean checkout. If they don't, that's a bug — please open an issue.

## What kinds of PRs are welcome

- Bug fixes (with a reproducer)
- Performance improvements
- More robust JSONL parsing for edge cases (real Claude Code session files we haven't seen yet)
- Tightening the WarningDetector regex against real Anthropic warning formats
- Better calibration heuristics
- Localization (FR, ES, DE, JA, etc.)
- Tests covering currently-untested paths (FSEvents, the DataLayerCoordinator)
- macOS HIG / accessibility improvements
- README / documentation

## What kinds of PRs are not a fit

- New features that change the product's scope (please open an issue first to discuss)
- Telemetry, analytics, crash reporting (deliberate design choice — Throttle Meter is local-only)
- Pro-tier features (paywall, optimizer wizard, license client) — those live in the private commercial repo
- Adding dependencies that pull in cloud services
- Bundle ID or signing changes

## Code style

- Swift 6, strict concurrency. `@Sendable`, `actor`, `@MainActor` — get them right.
- One responsibility per file. If a file grows beyond ~250 lines, split it.
- Tests live alongside source: `Throttle/Foo/Bar.swift` ↔ `ThrottleTests/FooTests/BarTests.swift`.
- Prefer `enum` namespaces with `static` functions over singletons or classes when there's no state.
- GRDB models conform to `Codable + FetchableRecord + (Mutable)PersistableRecord + Sendable`.

## Commit messages

Conventional-ish:

```
feat(parser): handle ISO8601 timestamps without Z suffix
fix(scanner): respect file_state on partial-line files
docs(readme): clarify privacy claim sourcing
test(calibration): cover anchor at extreme percent values
```

Scopes that exist: `app`, `db`, `parser`, `data`, `calibration`, `state`, `ui`, `services`, `tests`, `build`, `docs`.

## Issue reporting

A useful issue includes:

- macOS version + Xcode version
- What you did
- What you expected to see
- What actually happened
- A snippet of the relevant `~/.claude/projects/<repo>/<session>.jsonl` if it's a parser bug (redact any prompts you don't want public)

## Security

If you find a security issue (e.g. a way Throttle Meter exposes session content), email [support@lorislab.fr](mailto:support@lorislab.fr) directly rather than opening a public issue. We'll respond within a few days.

## Questions

Open an issue with the `question` label, or email [support@lorislab.fr](mailto:support@lorislab.fr).

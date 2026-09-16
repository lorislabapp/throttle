# Contributing to Throttle

Thanks for considering a contribution. This repository contains the current
Throttle product surfaces listed in the README. Check the root licence and any
path-specific notices before redistributing source or artifacts.

## Quick start

```bash
git clone https://github.com/lorislabapp/throttle.git
cd throttle
brew install xcodegen
xcodegen generate
open Throttle.xcodeproj
```

Run the test suite:

```bash
xcodebuild test -project Throttle.xcodeproj -scheme Throttle \
  -destination 'platform=macOS'
```

The test inventory evolves with the product. The command must finish with zero
unexpected failures; live-provider tests may skip only when they name their
explicit opt-in or missing fixture. Include the exact command, toolchain and
result bundle when reporting a failure.

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
- Undisclosed telemetry, analytics or data transfer
- Changes to licensing, paid-product boundaries or public distribution without prior maintainer review
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

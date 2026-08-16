# Throttle

Throttle is an Apple-first cockpit for Claude Code and Codex. It measures local coding-agent usage, helps diagnose context and prompt-cache cost, manages multiple terminal sessions, and supports reviewed handoffs between providers when one is unavailable or rate-limited.

Current status: active pre-release development. The repository contains macOS, iOS, widget, visionOS and self-hosted Edge surfaces. A local build is not proof of notarization, TestFlight approval or production readiness.

## What it does

- Parses local Claude Code session data and displays measured or clearly labelled estimated usage.
- Runs Claude Code and Codex sessions in a native macOS cockpit.
- Creates reviewed, one-writer handoff packets between providers; it does not silently copy provider transcripts.
- Offers explicit, reversible optimizers for supported Claude Code configuration and transcript workflows.
- Optionally mirrors encrypted state through the user's private CloudKit database and an authenticated LAN peer link.
- Optionally connects to a self-hosted Edge agent for remote sessions and repository transfer.
- Checks licenses and updates when those features are enabled.

Throttle is local-first, not offline-only. It has no third-party advertising or analytics SDK, but enabled product features can make network requests and can transfer user-selected data. See [PRIVACY.md](PRIVACY.md) for the current data-flow map and controls.

## Trust boundaries

- Local session files remain the source for local metrics. Unknown values stay unknown; Throttle does not invent provider usage or cost.
- Claude Code and Codex keep their own native session stores and authentication.
- Cross-provider handoff is reviewed before launch and keeps only one writer active in a checkout.
- Remote terminal input starts locked on iPhone, requires device-owner authentication, and relocks after inactivity or backgrounding.
- Edge is self-hosted and must use the secure transport requirements documented with the agent. Do not expose an insecure development endpoint to an untrusted network.
- Configuration-changing tools are opt-in, previewed, backed up and reversible.

## Platforms

| Surface | Purpose | Current proof boundary |
|---|---|---|
| macOS app + widget | usage, optimizer, cockpit, handoff and Edge setup | unit tests and local builds; fresh notarization still required |
| iOS app + widget | private mirror, alerts and authenticated LAN input to the user's Mac | simulator/build tests plus real-device gates |
| visionOS app | spatial read-only mirror | build/device validation required |
| Edge agent | macOS-managed self-hosted sessions and bounded repo transfer | local contract tests; live deployment is a separate gate |

## Build

Requirements:

- macOS 14 or later
- Xcode compatible with the SDKs in `project.yml`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
xcodegen generate
xcodebuild test -project Throttle.xcodeproj -scheme Throttle \
  -destination 'platform=macOS'
swift test --package-path ThrottleShared
(cd edge-agent && npm test)
```

The XcodeGen source of truth is [`project.yml`](project.yml). Do not hand-edit generated project settings.

## Repository map

```text
Throttle/             macOS app
ThrottleTests/        macOS unit tests
ThrottleiOS/          iOS companion
ThrottleiOSTests/     iOS security/behavior tests
ThrottleiOSWidget/    iOS widget and Live Activity
ThrottleVision/       visionOS companion
ThrottleShared/       shared models, peer transport and package tests
edge-agent/           self-hosted agent and contract tests
docs/                 designs and historical decisions (dated documents may be stale)
```

## Security and privacy reports

Security reports should use the repository's private disclosure channel or contact [support@lorislab.fr](mailto:support@lorislab.fr). Do not include access tokens, transcripts or personal session content in an issue.

See [PRIVACY.md](PRIVACY.md) for data handling. Historical launch and positioning documents are not current product or privacy policy.

## License

Copyright © 2026 LorisLabs. Check the applicable source headers and distribution agreement before redistributing commercial app components; the repository is not represented as an MIT-only meter.

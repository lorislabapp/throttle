# LAN protocol extraction — local evidence

Date: 2026-09-16. Mission: `8A91A20B-0E22-4C28-B2C7-3A767EF7FFDB`.
Worktree: `build/workflow-contracts-8a91a20b`, branch
`codex/workflow-contracts-8a91a20b`, base
`0f53c96882d8ad4caaf07c27efe0b052421999ef` plus uncommitted changes.
Toolchain: Xcode 27.0 (27A266a), Apple Swift 6.4.

## Change

`Packages/ThrottlePeerProtocol` owns the existing Foundation-only `PeerMessage`
framing. `ThrottleShared` adds a local package dependency; `ThrottlePeer` exposes
a public typealias for existing callers. The original implementation and its
provenance comment are preserved, with only two private local-variable renames
for lint. Existing product peer tests are unchanged.

Eleven independent conformance tests pin literal bytes, all eight wire kinds,
integer boundaries, truncation, multi-frame streams, nonzero slice indices,
unknown kinds and decoder size limits. The quality CI job now invokes this
suite separately, because dependency tests do not run with consumer tests.

Both native evidence profiles now include the new package's sources in their
hash inventories. A regression test verifies that changed or missing protocol
sources invalidate both macOS and iOS snapshots.

## Executed validation

| Check | Result | Local log |
|---|---|---|
| `swift test --package-path ThrottleShared --jobs 1` | PASS: 34 shared XCTest + 20 peer XCTest + 3 Swift Testing cases, no failures | `/private/tmp/throttle-peer-shared-20260916.log` |
| Standalone allowlisted copy, `swift test --package-path /private/tmp/throttle-peer-isolated-20260916-1us6yobz --jobs 1` | PASS: 11 cases, no failures | `/private/tmp/throttle-peer-isolated-20260916.log` |
| `swift build --package-path ThrottleShared --target ThrottlePeer --triple arm64-apple-ios17.0 --sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk --jobs 1` | PASS: protocol, shared module and transport; Debug-iphoneos objects produced | `/private/tmp/throttle-peer-ios-build-20260916.log` |
| `python3 -m unittest discover -s scripts/tests -p test_macos_evidence.py` | PASS: 32 tests | Terminal result; snapshot invalidation covers both schemes |
| SwiftLint 0.65.1 strict, no cache, five affected Swift files | PASS: 0 violations | `/private/tmp/throttle-peer-lint-20260916.log` |
| `git diff --check` | PASS | Local diff check |

The isolated copy contains exactly `Package.swift`, `README.md`, the canonical
`PeerMessage.swift`, and `PeerMessageConformanceTests.swift`. Copy hashes are in
`/private/tmp/throttle-peer-isolation-20260916.json`. It declares no package
dependencies and builds outside the source checkout. This demonstrates build
independence, not an OS-enforced filesystem isolation boundary.

The first sandboxed Swift invocation could not write the compiler cache; its
failure is preserved in `/private/tmp/throttle-peer-protocol-20260916.log`.
Authorized runs subsequently completed. Initial Python fixture and lint errors
were corrected before the final passing runs; no production checks were weakened.

## Limits and next step

These are local unit/conformance and compilation results. Full product Xcode
suites from September 15 are historical, not validation of this new dependency
graph. Exact CI (including pinned SwiftLint 0.63.2), app targets, real LAN/device
journeys and release artifact checks remain open. No release readiness is claimed.

The next component is the MCP declarative schema contract, separated from
handlers with one canonical source. Rights/provenance review, published-version
pinning and remote repository separation remain separate steps. No licence,
commit, push, signature, installation or publication was performed in this slice.

# Throttle release ledger — 3.2.81 (181)

Updated UTC: 2026-08-17T10:56:00Z
Repository: `/Users/kevinnadjarian/GitHub/Throttle`
Channel: Developer ID direct distribution through Sparkle
Authority: commit and public Sparkle/web release requested by the user. Fresh exact-artifact confirmations remain required before Apple notarization and public upload.

## Scope

- App: `com.lorislab.throttle`
- Version/build: 3.2.81 (181)
- Minimum macOS: 14.0
- Publisher/team: Christine Martin / TDV6D5L785
- Feed: `https://lorislab.fr/throttle/appcast.xml`
- Rollback owner: publisher; previous public artifact is 3.2.80 (180)
- Incident path: remove the 3.2.81 feed item first, then restore the 3.2.80 landing-page download
- User-visible release notes:
  - Provider-neutral Context Firewall and `throttle_read` for focused, recoverable large-file evidence.
  - Shared, explicit and reversible MCP installation for Claude Code and Codex.
  - Local Qwen summaries of archived context without Ollama or cloud fallback.
  - Ephemeral WebKit research with SSRF/redirect checks, prompt-injection boundaries, exact-source archival, caching and ranked safe links.
  - Large reviewed terminal pastes remain supported up to 1 MiB.
  - Existing-project detection, Claude/Codex selection and Dock reopen behavior remain enabled.

## Preflight

- Live Sparkle head verified as 3.2.80 (180); its DMG returns HTTP 200 with the feed-declared 26,177,492-byte length.
- Source version advanced to 3.2.81 (181).
- Existing user-owned `.codex/` and `.mcp.json` are excluded from release source changes.
- Developer ID Application SHA-1 `8333AB7CD909731530AC62DD28CCA47C8D288225` is available in the login keychain; the app and widget exported with their pinned Developer ID profiles.

## Build/archive

- Full XCTest after version bump: PASS (231 passed, 1 opt-in test skipped, 0 failed).
- Explicit embedded Qwen inference acceptance: PASS.
- Live WebKit bridge/cache acceptance against `https://example.com`: PASS.
- Fresh universal Developer ID archive/export: PASS.

## Assets

- Signed DMG: `/private/tmp/throttle-release-3.2.81/Throttle-3.2.81.dmg`.
- Pre-notary size: 26,247,448 bytes.
- Pre-notary SHA-256: `7e2b7de57f9e7aa586b7d674d7d3ec1872bbb4f7ed9ff2b1f386643e3b809223`.
- Architecture: universal `x86_64 arm64`.
- Apple notarization/staple: PENDING exact-artifact confirmation.
- Sparkle EdDSA enclosure signature and SHA-256: PENDING.

## Metadata

- Appcast item and landing-page download: PENDING.

## Assemble

- Project generation after version bump: PASS.
- Exported app/widget strict signature: PASS.
- DMG strict signature: PASS.
- Bundle smoke test: PASS (5/5, including Dock lifecycle metadata).

## Validate

- Final post-version-bump XCTest: PASS (231 passed, 1 opt-in test skipped, 0 failed).
- Pre-notary Gatekeeper state: expected `rejected`, source `Unnotarized Developer ID`, origin `Developer ID Application: Christine Martin (TDV6D5L785)`.
- Post-notary Gatekeeper and staple validation: PENDING.

## Submit

- Apple notarization upload: NOT STARTED.
- Public DMG/appcast/site upload: NOT STARTED.

## Post-release

- Live feed, DMG digest, signatures, Gatekeeper and landing page: PENDING.

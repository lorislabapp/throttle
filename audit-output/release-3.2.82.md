# Throttle release ledger — 3.2.82 (182)

Updated UTC: 2026-08-17T12:07:28Z
Repository: `/Users/kevinnadjarian/GitHub/Throttle`
Channel: Developer ID direct distribution through Sparkle
Authority: local changes, commit, push and release preparation requested by the user. Exact-artifact Apple notarization and public upload remain separate confirmation gates.

## Scope

- App: `com.lorislab.throttle`
- Version/build: 3.2.82 (182)
- Minimum macOS: 14.0
- Publisher/team: Christine Martin / TDV6D5L785
- Feed: `https://lorislab.fr/throttle/appcast.xml`
- Rollback owner: publisher; previous public artifact is 3.2.81 (181)
- Incident path: remove the 3.2.82 feed item first, then restore the 3.2.81 landing-page download
- User-visible release notes:
  - Provider-neutral local delegation from Claude Code or Codex to embedded Qwen 3 1.7B.
  - Bounded summarize, extract, classify, normalize and draft tasks using exact archived content pointers.
  - Exact quote validation, explicit `verified`, `review_required` and `escalate` outcomes.
  - No Qwen shell, network, file-write or credential access; planning, risky actions, patches and final verification remain with Claude/Codex.
  - Always-visible local-model install/remove/delegation controls and local task/context-savings counters.
  - Public positioning updated from a Claude usage meter to a local-first multi-provider token, context and cost optimizer.

## Preflight

- Source version advanced to 3.2.82 (182).
- Existing user-owned `.codex/` and `.mcp.json` remain excluded.
- Developer ID Application identity SHA-1 `8333AB7CD909731530AC62DD28CCA47C8D288225`: AVAILABLE and used for app, widget and DMG.
- Live feed, support/privacy URLs and previous public artifact: PENDING fresh verification before publication.

## Build/archive

- Full XCTest: PASS (239 total, 237 passed, 2 opt-in skipped, 0 failed).
- Explicit embedded Qwen inference + delegation acceptance: PASS (3/3, 0 skipped, 0 failed) using the installed model.
- Fresh universal Developer ID archive/export: PASS.

## Assets

- Signed pre-notary DMG: `/private/tmp/throttle-release-3.2.82/Throttle-3.2.82.dmg`.
- Pre-notary size: 26,265,368 bytes.
- Pre-notary SHA-256: `da6f22e29647049935f14328586386a2d7ec6149ae1dbe172befd948fd701240`.
- Architecture: universal `x86_64 arm64`.
- Apple notarization: ACCEPTED, submission `0968f19e-958b-4411-a987-2e54431a4e81`.
- Staple and staple validation: PASS.
- Final stapled size: 26,267,604 bytes.
- Final stapled SHA-256: `4e03bb19b40e930a9a2ffe51843e5118c21a7dcf51ce8644ce6f88e00628c342`.
- Sparkle EdDSA enclosure signature: `eotKPHaXCEjfRlYHTaTW3wpHWsS7F4nvjxqNrYVrZqWR74aAObHaoaiI42YbBFwrthkyOXr9ehzsbJZwUvRzBQ==`.

## Metadata

- Landing page: repositioning in progress.
- Appcast item, 3.2.82 landing-page link, home-page positioning and app metadata: LIVE.

## Assemble

- Project generation: PASS.
- Exported app/widget strict Developer ID signature: PASS.
- Bundle smoke test: PASS (5/5, including Dock lifecycle metadata).

## Validate

- HTML minification parse, JSON metadata, fragment anchors and diff whitespace: PASS.
- Pre-notary Gatekeeper state: expected `rejected`, source `Unnotarized Developer ID`, origin `Developer ID Application: Christine Martin (TDV6D5L785)`.
- Post-staple DMG and mounted-app Gatekeeper: PASS, source `Notarized Developer ID`, origin `Developer ID Application: Christine Martin (TDV6D5L785)`.
- Mounted app/widget strict signatures and universal `x86_64 arm64` architecture: PASS.
- Browser-based visual QA: BLOCKED because no browser backend is available in this session; post-upload HTTP/content verification remains required.

## Submit

- Apple notarization upload: COMPLETE and accepted after exact-artifact confirmation.
- Public DMG/appcast/site upload: COMPLETE after exact-destination confirmation.
- Targeted Hostinger upload sent exactly `throttle/Throttle-3.2.82.dmg`, `throttle/appcast.xml`, `throttle/index.html`, `index.html` and `apps/throttle.json`; unrelated dirty website files were excluded.

## Post-release

- Live feed XML: PASS; top item is 3.2.82 (182), enclosure length 26,267,604 and its EdDSA signature matches the locally generated value.
- Live landing page: PASS; the page links 3.2.82 and presents Throttle as a token, context and cost optimizer for Claude Code and Codex.
- Live home-page card and app metadata: PASS; both expose the new multi-provider/local-Qwen positioning.
- Live DMG download: PASS; 26,267,604 bytes.
- Live DMG SHA-256: `4e03bb19b40e930a9a2ffe51843e5118c21a7dcf51ce8644ce6f88e00628c342`, exact local match and byte-identical comparison PASS.
- Live downloaded DMG staple validation and strict signature: PASS.
- Live mounted app/widget strict signatures: PASS; universal `x86_64 arm64`, version/build 3.2.82 (182).
- Live downloaded DMG and mounted-app Gatekeeper: PASS, source `Notarized Developer ID`.
- Rollback remains available through the existing 3.2.81 feed item and DMG.

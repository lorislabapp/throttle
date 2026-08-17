# Throttle release ledger — 3.2.80 (180)

Updated UTC: 2026-08-17T08:46:39Z
Repository: `/Users/kevinnadjarian/GitHub/Throttle`
Channel: Developer ID direct distribution through Sparkle
Authority: release requested by the user. The publish-apple workflow still requires an exact-artifact confirmation before Apple notarization and another before public upload.

## Scope

- App: `com.lorislab.throttle`
- Version/build: 3.2.80 (180)
- Minimum macOS: 14.0
- Publisher/team: Christine Martin / TDV6D5L785
- Feed: `https://lorislab.fr/throttle/appcast.xml`
- Rollback owner: publisher; previous public artifact is 3.2.79 (179)
- Incident path: remove the 3.2.80 item from the feed first, then restore the prior download link
- User-visible release notes:
  - Embedded Qwen 3 1.7B through MLX, with no Ollama daemon or account required.
  - Local-model UI covers explicit install progress, local-only selection and removal.
  - Selecting Local never silently sends project context to a cloud provider.
  - Reviewed terminal pastes now accept logs up to 1 MiB and show an estimated token count.
  - Opening a project detects an existing tab and offers to focus it or open another intentionally.
  - Every new project tab asks explicitly whether to start with Claude Code or Codex.

## Preflight

- Live Sparkle head verified as 3.2.79 (179) on 2026-08-17.
- Developer ID Application identity SHA-1 `8333AB7CD909731530AC62DD28CCA47C8D288225` is available in the login keychain.
- Source version advanced to 3.2.80 (180).
- Qwen model card declares Apache-2.0 and a 968 MB 4-bit MLX download.
- Existing user-owned `.codex/` and `.mcp.json` remain excluded from release source changes.

## Build/archive

- Final XCTest after version bump and project-open flow: 221 passed, 1 intentionally skipped, 0 failed on macOS 27 beta.
- Explicit embedded-model acceptance: 1 passed, 0 skipped; 937 MB installed and a real MLX response streamed.
- Release arm64 compilation before version bump: PASS.
- Fresh Developer ID archive/export: BLOCKED — the first universal MLX archive was
  interrupted before system disk exhaustion (390 MB free at the stop point). Its
  isolated DerivedData and release temp directory were removed; no artifact was
  produced and nothing was uploaded.

## Assets

- Signed DMG: PENDING.
- Apple notarization/staple: PENDING explicit confirmation.
- Sparkle enclosure signature and SHA-256: PENDING.

## Metadata

- Appcast item and landing page: PENDING second explicit confirmation.

## Assemble

- Project generation: PASS after version bump and dependency pinning.
- Deep/strict app signature, widget signature and smoke test: PENDING.

## Validate

- Full XCTest after version bump: PASS (221 passed, 1 opt-in acceptance test skipped, 0 failed).
- Embedded Qwen download and live inference: PASS in the separate explicitly enabled acceptance run.
- `git diff --check`: PASS before archive preparation.
- Gatekeeper and notarization: PENDING.

## Submit

- Apple notarization upload: NOT STARTED.
- Public DMG/appcast/site upload: NOT STARTED.

## Post-release

- Live feed, DMG digest, staple, Gatekeeper and landing page: PENDING.

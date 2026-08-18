# Throttle release ledger — 3.2.83 (183)

Updated UTC: 2026-08-18T18:50:00Z
Repository: `/Users/kevinnadjarian/GitHub/Throttle`
Channel: Developer ID direct distribution through Sparkle
Authority: build, notarization, Sparkle publication and website update explicitly requested by the user on 2026-08-18.

## Scope

- App: `com.lorislab.throttle`
- Version/build: 3.2.83 (183)
- Minimum macOS: 14.0
- Publisher/team: Christine Martin / TDV6D5L785
- Feed: `https://lorislab.fr/throttle/appcast.xml`
- Rollback owner: publisher; previous public artifact is 3.2.82 (182)
- Incident path: remove the 3.2.83 feed item first, then restore the 3.2.82 landing-page download
- User-visible release notes:
  - LOCAL MIX dashboard panel: retro-attribution of local-safe sessions, shadow replay on the embedded model (zero API tokens, real sessions untouched), golden-set ledger with a rule-of-three bound on hard failures only, on-machine benchmark.
  - Router advisory at the mission-handoff boundary: Local-safe / Frontier / Uncertain from deterministic rules plus the user's replay history (demote-only).
  - Deterministic log fold (ANSI strip + exact-repeat collapse) as a pre-pass to local-model prompts; validation still quotes the original source.
  - Adaptive keep-alive: the embedded model unloads on critical memory pressure.
  - Evidence mode: `Throttle --sota-selftest` proves the whole stack end-to-end with zero frontier tokens and writes a timestamped report.
  - 4-runtime session selector completed (Claude / Codex / Local / Terminal).

## Preflight

- Source version advanced to 3.2.83 (183).
- User-owned `.codex/` and `.mcp.json` remain excluded from version control.
- Full XCTest: PASS (all suites, 2026-08-18 19:58 UTC).
- SOTA self-test on debug binary: PASS 6/6 + 1 honest skip (bench skipped under live memory pressure), 0 frontier tokens, 3.7 s.

## Build/archive

- Fresh universal Developer ID archive/export: PASS (scripts/build-dmg.sh --notarize; first attempt failed on a full disk, retried after reclaiming space).
- Exported app/widget strict Developer ID signature: PASS.
- Bundle smoke test: PASS (5/5).

## Assets

- Final stapled DMG: `build/Throttle-3.2.83.dmg` (copied to lorislab-website/throttle/).
- Size: 26,431,956 bytes.
- SHA-256 (stapled): `e9d261ae92d661803d3999f933ff9d0fdafdc6ebb4d4721215af8b0b9c89460e`.
- Apple notarization: ACCEPTED, submission `49ee9884-55f7-48b2-8ff8-2076641bedc6`.
- Staple and staple validation: PASS.
- Sparkle EdDSA enclosure signature: `drQQ7fwZkXW2jHMcciLhpPBFNvM/8TLvtLW96EJq3AuF0PJ1c00FrHtKoOhfWtPNXA4na0VqFQ7z3MNDlddRCw==`.

## Metadata

- Landing page `throttle/index.html`: three New rows (Local Mix measured, Router advisory, Deterministic log fold), 3.2.82 badges retired, download meta v3.2.83 / 26.4 MB.
- Appcast item 3.2.83 with release-notes description: committed in lorislab-website (fc96356).
- Publication to lorislab.fr: LIVE 2026-08-18 ~18:53 UTC (deploy stamps 20260818185225 + 20260818185308 with DEPLOY_DMG=1).
- Independent post-deploy verification: live appcast shortVersionString 3.2.83; landing v3.2.83; served DMG SHA-256 matches the notarized artifact byte-for-byte.
- User's unrelated in-progress website work (arcyra.html, kernel files, downloads/, arcyra images) was stashed/held during the deploy at the user's request and fully restored after.

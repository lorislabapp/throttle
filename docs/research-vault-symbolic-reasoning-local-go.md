# Research Vault symbolic reasoning — local GO evidence

- Date: 2026-08-30 (Europe/Paris)
- Repository HEAD: `83a259a8b37d2ae26915022c581e094d1bd9fedf`
- Authority: local source, tests, build and evidence only
- Outcome: **GO LOCAL — symbolic reasoning implementation**
- Excluded: commit, push, install, notarization, site upload, Sparkle/appcast
  mutation and public release

## Gate ledger

| Gate | Result | Evidence |
|---|---|---|
| Native semantics and oracle | PASS | 100,000 Lemmalog differential programs; versioned golden cases |
| Provenance and projection | PASS | approved verified/supported claims only; exact receipt/source propagation |
| SQLCipher durability | PASS | schema, atomic generation/cache, migration, crash and corruption coverage |
| Owner boundary | PASS | promotion/retraction owner-XPC only; hostile DTO tests; MCP read-only |
| Explainability and retraction | PASS | alternative proofs, bounded why/impact/delta, selective asserted-relation removal |
| Workbench | PASS automated | asserted/derived/hypothesis separation, confirmation, source identifiers, projection tests |
| Performance | PASS | Release p95 117.47 ms/1k, 1.09 s/10k, 12.87 s/100k; 100k RSS 319,913,984 bytes |
| Package verification | PASS | 40 XCTest + 85 Swift Testing, Debug/Release, oracle, XPC/MCP/process/recovery/supply chain |
| Full app tests | PASS | 353 total, 350 passed, 3 explicit skips, 0 failed |
| Release build | PASS local | `/private/tmp/throttle-reasoning-ui-derived/Build/Products/Release/Throttle.app` |
| Source hygiene | PASS scoped | new reasoning scope SwiftLint strict 0; diff check clean; current-change Gitleaks clean |
| Localization | PASS automated | EN/FR string catalog JSON and compiler validation |

## Deliberate stop decisions

- Full rebuild remains the production strategy. All pre-registered budgets pass,
  so incremental truth maintenance would add risk without measured necessity.
- The gateway operational cap remains 10,000 base facts. The 100,000-fact run
  proves headroom but does not expand the product contract.
- Lemmalog remains a pinned development oracle only and is absent from the app
  runtime graph.

## Separate delivery gates

The local bundle identifies as `com.lorislab.throttle` with Team ID
`TDV6D5L785`, but the host certificate chain currently returns
`CSSMERR_TP_NOT_TRUSTED`. Human keyboard/VoiceOver acceptance and installed
helper/runtime validation are also not run. These facts do not invalidate the
local implementation GO; they prevent using this packet as a distribution GO.

## Post-crash continuation — 2026-08-30

- The two opt-in embedded-model acceptances now pass against the installed
  937 MB `mlx-community/Qwen3-1.7B-4bit` snapshot: bounded JSON delegation and
  in-process streamed inference. Evidence:
  `/private/tmp/throttle-embedded-model-live-r4.xcresult` (3 tests, 0 failures,
  0 skips).
- The inference acceptance previously allowed a configured Ollama endpoint to
  satisfy a test named as embedded MLX. The test now temporarily removes and
  exactly restores that live preference, asserts the server route is disabled,
  and therefore cannot pass without exercising the in-process model.
- The explicit private-worker acceptance also passes against the configured
  Tailscale Ollama service using only the synthetic prompt
  `Reply exactly LOCAL_ROUTE_OK`. Evidence:
  `/private/tmp/throttle-private-worker-live.xcresult` (1 test, 0 failures,
  0 skips; HTTP 200; 7.08 seconds).
- Temporary opt-in/configuration files were removed after validation. No app
  install, publication, commit or push was performed in this continuation.
- These are post-publication source and runtime proofs. They do not alter or
  retroactively redefine the exact Throttle 3.4.0 (209) published artifact.

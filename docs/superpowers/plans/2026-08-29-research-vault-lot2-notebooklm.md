# Research Vault Lot 2 — NotebookLM import plan

**Goal:** Build a resumable, source-indexed NotebookLM export pipeline that
stages local files with complete provenance and feeds the existing quarantine.
No live notebook is accessed by tests or by this implementation pass.

**Authority boundary:** Local code, fixtures, tests and build only. A live
`nlm_list_notebooks`, `nlm_list_sources` or `nlm_export_source` call requires a
fresh exact notebook/account/classification authorization. No upload, chat,
generation, deletion or notebook mutation is in scope.

## Task 1 — narrow gateway transport

- Add an actor-based `NotebookLMGatewayClient` using the configured stdio MCP
  server through `/bin/zsh -lc`.
- Allow exactly three tool names: list notebooks, list sources, export source.
- Serialize calls, bound startup/call/output sizes, discard stderr content and
  reject malformed or mismatched JSON-RPC responses.
- Inject a protocol-backed fake in tests; never invoke the real gateway there.

## Task 2 — resumable staging job

- Model notebook/source descriptors independently of gateway response details.
- Persist an atomic checkpoint after every exported zero-based source index.
- Name staged exports by index, write a provenance sidecar containing notebook
  URL, source index, title, export time and SHA-256, and never overwrite a
  conflicting payload.
- Support pause/cancellation and idempotent restart from the checkpoint.

## Task 3 — provenance-aware ingestion

- Teach `NotebookLMMigrationImporter` to validate sidecars, bind each sidecar
  hash to its payload and carry notebook URL/index/title into the sealed receipt.
- Keep duplicate titles distinct through source index and deterministic receipt
  identity. Imported receipts remain `open` findings in quarantine.

## Task 4 — Workbench state/UI

- Add notebook listing/selection and visible n/N job progress behind an explicit
  user action.
- Keep the local-folder migration fallback and all fail-closed status messages.
- Pause/resume without promoting any source.

## Gate

- Fake-gateway tests prove rerun without duplicate, interruption/restart without
  loss, source-index disambiguation, output bounds and forbidden-tool rejection.
- Package/app tests, scoped SwiftLint and build pass.
- Stop before the first live gateway call and request the exact external GO.

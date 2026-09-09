# SOTA integration — implementation ledger

Updated: 2026-09-08. Target: the current context-testing integration checkout.
Existing CI, CloudKit and release-staging changes belong to concurrent work and
are preserved. No install, release, account setup or cross-app mutation is authorized
by this ledger. Research is not runtime evidence.

## Product contract

- Personal validation first, then mandatory product qualification per retained module.
- Local core; explicit optional connectors; bounded task autonomy with human acceptance.
- macOS 14 compatibility retained; newer Apple APIs are optional adapters.
- No private corpus, credentials, paths, histories or portfolio fixtures in public assets.
- Diagnostics/exports/sync are data boundaries, not exemptions to privacy policy.
- Every module needs synthetic examples, EN/FR onboarding, disablement, migration,
  accessibility, a clean-user acceptance and an explicit distribution gate.

## Delivery and gates

| Lot | Implementation | Personal acceptance | Product qualification |
|---|---|---|---|
| L0 baseline/reconciliation | Active integration checkout reconciled; concurrent deltas preserved | 121-case subset passes; full macOS build and 670 cases pass with 5 allowed skips, but source snapshot changed | Strict snapshot qualification still open |
| L1 isolation/privacy | Preview-first support summary wired at both entry points; no raw attachments | Three report-model and four real archive tests pass; hosted preview/export acceptance pending | Full outbound/project isolation and clean install still open |
| L2 evidence/durability | Project-serialized mutations, command receipts and opt-in MCP retry/sequence metadata wired | Concurrency, corruption, router/retry, process-lock and changed-input tests pass | Crash recovery, complete input coverage and caller authority still open |
| L3 cockpit workflow | Pending | Ten consecutive measured tasks required | Pending |
| L4 evals/review | Pending; extend ShadowReplay | Frozen cases, repetitions and human adjudication | Pending |
| L5 context/research | Pending; retain Vault ownership | Retrieval/abstention/isolation comparison | Pending |
| L6 Apple/visual QA | Existing macOS evidence validator under concurrent development | New snapshot must be tested | Device/AX/platform matrix pending |
| L7 product signals | Pending; read-only imports before connectors | Deduplication/freshness/coverage | Per-user credentials; no implicit collection |
| L8 opt-in app kits | Pending; extract only demonstrated shared contracts | Throttle, then explicitly authorized app pilots | Synthetic fixtures; no mandatory runtime dependency |

Dependencies: L0 → L1 → L2 → L3; L4/L5/L6 use those foundations;
L7 uses evidence/privacy contracts; L8 follows proven shared needs.

## Implementation scope of this checkpoint

Do not call L1 or L2 complete from a helper or unit suite. This increment wires
the privacy change into the actual exporter, transactionally prepares cockpit
claims, and serializes MCP claim/event/review mutations. Original events remain
readable. Appends reject invalid or partial logs rather than replacing history.

Implemented source paths:

- `DiagnosticsExporter` now builds `DiagnosticReport` from typed counts, numeric
  version fields and categorical status. The archive allowlist is `summary.txt`;
  no logger, raw error, MetricKit or savings attachments are copied. Unknown
  counts stay unknown. Temporary storage is unique and private. Support preview
  is now implemented; other export and sync paths are not covered by this change.
- `PlanStore.mutate` holds a project filesystem lock across cooperating writers'
  read/check/append operations. It has a bounded acquisition timeout, no-follow
  file opens and durable file synchronization. New event UUIDs support native
  idempotent retries and an optional expected sequence. Generic MCP events can no
  longer impersonate dedicated review, claim, check or integration operations.
- `TaskLauncher` prepares and claims inside the same transaction; runtime launch
  stays outside it. This path still needs hosted integration and responsiveness
  testing: synchronous lock waiting and Git preparation are not a UX qualification.
- `WorkflowEvidenceReceipt` separates a command result from complete test
  coverage. The actual verification service records it and refuses a positive
  result when tracked inputs are dirty afterward or either revision changed.
  Projection and cockpit show the evidence scope; legacy events decode without
  fabricating a receipt. The new visible scope/support strings have EN/FR entries.
- The lightweight verifier now includes these exact production model/service
  sources and real disposable-Git integration tests, with complete XCTest and
  Swift Testing reports, inventories and source hashes. An optional task-owned
  scratch path avoids rebuilding an independent cache per run.

Important boundaries: the lock is cooperative coordination, not authentication.
The hash chain is not a signature and cannot detect an entirely rewritten chain
or an edited final event. Retry identity and expected sequence are now exposed
through the MCP schemas but remain optional for legacy callers. Command receipts do not snapshot
untracked files, dependencies or environment, and structural test-inventory
validation is not a trusted xcresult importer. Directory durability, injected
crashes, full filesystem race hardening, authenticated callers and end-to-end
outbound policy remain open. No broad security or SOTA verdict follows from this slice.

Validation constraint at start: about 1.4 GiB free. No cache deletion; no full
Xcode build until adequate headroom exists. Lightweight tests must retain exact
source hashes and complete results. A subset pass is not a hosted macOS pass.

## Verification checkpoint

- First exact-source run: **108 cases passed**, 97 XCTest plus 11 Swift Testing,
  zero reported errors; both processes exited 0. Duration: 68.454 seconds.
  All 37 source/test hashes and the runner hash were rechecked against live files.
  Durable sanitized summary: [2026-09-08-sota-core-evidence.json](2026-09-08-sota-core-evidence.json).
- Six Python evidence-validator regression tests pass (missing suite/case,
  malformed or skipped reports, duplicate cases and hidden failures).
- Scoped strict SwiftLint 0.65.1 passes. This is not the pinned 0.63.2 CI result.
- Five modified host/UI files pass Swift syntax parsing only; this is not type
  checking. New source/test membership is present in the generated Xcode project.
  Localization JSON parses. No app was launched or diagnostic archive exported.
- Raw local receipt, log and XML are in
  `/private/tmp/throttle-sota-core/throttle-core-evidence-rdzphm54/`.
  They are temporary; recheck existence after reboot. The sanitized summary
  retains relative source hashes and artifact digests, not private absolute paths.
- Initial sandbox-only compilation failed on the global Clang cache; the
  explicitly escalated retry passed. The failed attempt was not counted as a pass.
- First checkpoint free-space observation: **414 MiB**. The macOS evidence verifier requires
  **10 GiB** before building. Full host compilation/tests, macOS 14 runtime,
  accessibility, physical acceptance and clean-user qualification were not run.

## Continuation: preview-first diagnostics

Implemented on the same branch/base after a fresh dirty-worktree reconciliation.
At restart, 4.9 GiB were free; the latest observation is about 1.0 GiB. Concurrent
release/iOS/CloudKit changes remain separate and untouched.

- Both the About pane and Assistant button open a standalone retained AppKit
  window. This follows the existing popover constraint: interactive sheets can
  disappear when their first click dismisses the menu-bar popover.
- The preview freezes a typed `DiagnosticReport`. Explicit save exports that
  exact value without rereading the database. Cancel does not initiate an export.
  Reopening a closed window uses a fresh preview; a visible or exporting window
  is not replaced by another request. The controls include EN/FR strings.
- Archive construction runs off the main actor. `DiagnosticArchive` has no
  database/log/provider dependency. It stages `report/summary.txt` privately,
  excludes resource-fork metadata, and copies the completed ZIP to a unique path
  without replacing an earlier export. The resulting ZIP is mode 0600. Staging
  cleanup targets only the directory created by that invocation.
- Export feedback stays in the preview. The Assistant no longer inserts a local
  export path into the conversation, and Finder reveal is a separate explicit
  action. Adjacent CSV and MetricKit comments now accurately distinguish their
  more sensitive/local payloads from the support summary.

Fresh evidence:

- **112 cases pass**, 101 XCTest plus 11 Swift Testing, in 74.196 seconds. The four
  added cases use real `ditto`/`unzip` on synthetic temporary fixtures: exact ZIP
  inventory/preview equality, rejected private canaries, distinct/private repeated
  exports, and preservation of an invalid destination. No user's Desktop export
  was invoked. All 39 source/test hashes were rechecked against live files.
- [Sanitized receipt](2026-09-08-sota-diagnostics-evidence.json); raw log/XML/receipt
  under `/private/tmp/throttle-sota-core/throttle-core-evidence-3cxg7slz/`.
  The sandbox-only attempt `throttle-core-evidence-vfbs3ho0` failed before any
  cases on the Clang cache restriction; the authorized retry is the pass above.
- Six validator regression tests pass. Scoped strict SwiftLint 0.65.1 passes;
  pinned 0.63.2 remains a separate CI gate. Only two existing baseline records
  were adjusted downward after removing the old chat-export method: assistant
  struct 809 → 800 effective lines, file 1032 → 1018. No lint rule was disabled
  and no new suppression was introduced.
- The exact `DiagnosticReport`, `DiagnosticsPreviewView`, window controller and
  `RetainedWindowPolicy` sources pass `swiftc -typecheck -swift-version 6 -target
  arm64-apple-macosx14.0`. This does not type-check the GRDB data collection bridge
  or the complete host. Generated Xcode membership includes the new files.

Still open: actual app/GRDB integration, keyboard/VoiceOver and French layout,
cancel/retry/close interaction, complete macOS 14 runtime acceptance, and the
global export/sync policy. `ditto` remains an external local process; an injected
hang/timeout and I/O failure matrix is not qualified by the successful ZIP tests.
This increment does not close L1 or the full integration plan.

## Continuation: MCP retries and stale-state refusal

After the user freed disk space, a fresh check showed 7.9 GiB. The full macOS
verifier was actually attempted: it stopped before compilation at 8,151,040,000
free bytes, below its 10 GiB requirement. It ran **zero hosted cases**. The
additional `sources_changed_or_not_recorded` error reflects that the preflight
stopped before the initial snapshot, not a demonstrated source change mid-build.
Receipt: `/private/tmp/throttle-sota-macos/throttle-macos-akn7sws5/evidence/receipt.json`,
SHA-256 `6ed633ed7cdbdbf59f87f95cb223d9871970fe7af956daca790a8a1add498945`.
Free space later rose to 9.3 GiB; this is still below the build gate.

The in-scope implementation continued without lowering that gate:

- All three mutation schemas expose paired `event_id`/`expected_seq`. The task
  readout exposes `seq=N`. Metadata is strictly validated before mutation;
  booleans, strings, fractions, unsafe-size integers, partial pairs and invalid
  UUIDs cannot silently become an unprotected legacy request.
- Claim, event and verdict retries compare intent inside the existing project
  transaction. A changed UUID payload/author/original sequence is refused.
  A fresh intent with a stale sequence is refused, including when the same author
  released and reclaimed the task. A legitimate replay acknowledges only the old
  persistence; it cannot reacquire ownership or count a rejection twice.
- The actual task argument router was extracted from the intake/transport file,
  allowing the production implementation to run in the isolated test target
  without stubbing `ThrottleMCPServer`. The live adapter uses this same router.
- [Client contract and synthetic example](sota-mcp-retry-contract.md). Existing
  clients without metadata keep legacy behavior, not new generation protection.
  Client-supplied `by` is still not authenticated; this is not an authority token.

Verification: **121 cases pass** (110 XCTest, 11 Swift Testing), 80.312 seconds,
43 exact source/test hashes and runner hash match the live checkout. Six new
retry cases and three router cases cover concurrent duplicate claims, lost
release replies, reassignment, conflicting payloads, stale generations,
duplicate verdicts and malformed JSON metadata. Six Python validator tests and
scoped strict SwiftLint 0.65.1 pass. The remaining schema/intake adapter files
pass syntax parsing; the full app and live stdio MCP session are still untested.
New source/test membership is present in the regenerated Xcode project.

[Sanitized evidence](2026-09-08-sota-mcp-retry-evidence.json); raw artifacts:
`/private/tmp/throttle-sota-core/throttle-core-evidence-cuh5m75u/`. The earlier
118-case run is retained at `throttle-core-evidence-1ej1y6mw` and superseded by
the router-inclusive run, not added to its count. No installed app, account,
service, other project or release artifact was changed by this checkpoint.

## Full macOS build and hosted suite: executed, snapshot gate still open

Space subsequently reached 12 GiB, so the complete macOS verifier ran in an
isolated Debug ad hoc host. **The build succeeded. The native inventory contains
675 cases: 670 passed and exactly the five declared opt-in cases were skipped.**
Both XCTest (672 cases including skips) and Swift Testing (3 cases) completed.
Native summary/tree/inventory reconciliation reports no missing case, unexpected
skip, test failure or count mismatch. Eleven runner commands exited zero.
Total verifier duration: 634.794 seconds.

This closes the earlier uncertainty about whether the combined app and its tests
compile, including the new diagnostics UI/bridge and MCP schemas. It does not
qualify real preview interaction, private iCloud services, signed XPC, macOS 14
runtime, physical acceptance, the separate complete Vault package suite or release.

**Do not mark the strict receipt PASS.** Of 667 snapshotted files, one changed
during the run: `Packages/ResearchVaultKit/Scripts/verify-ipc-boundary.sh`, part of
concurrent work. No path was added or removed. The native test results pass, but
the source stability gate correctly returns `sources_changed_or_not_recorded`.
The original receipt is preserved unchanged at
`/private/tmp/throttle-sota-macos/throttle-macos-g3m_prz3/evidence/receipt.json`.
SHA-256: `c7b6a20c8b43dad0f4033a4c53d38b9e4106967ba8b26d75178196a50ae0b189`.
[Durable sanitized summary](2026-09-08-sota-full-macos-evidence.json).

Thread Performance Checker emitted priority-inversion warnings, including around
synchronous Git operations. No functional test failed because of them; they remain
a responsiveness investigation, not a clean UX verdict.

A narrowly scoped `--derived-data-path` option was added to the verifier so a
replay can use this task's already compiled Xcode cache while keeping fresh
reports, inventory and source snapshots. The disk thresholds, test requirements,
skip allowlist and source-change refusal were not relaxed. Fourteen verifier
regression tests pass; the new CLI option parses. Concurrent evolution of the
verifier's other Apple-host support is preserved, not attributed to this work.

The replay was attempted with the existing cache, but stopped before build at
7,581,011,968 free bytes (final subsequent observation about 6.4 GiB). Its zero-case
receipt is preserved at
`/private/tmp/throttle-sota-macos/throttle-macos-8nu3jd7x/evidence/receipt.json`.
No prior evidence or build cache was deleted. Exact continuation after restoring
10 GiB free and reconciling concurrent edits:

```sh
python3 -B scripts/verify-macos-evidence.py \
  --output-parent /private/tmp/throttle-sota-macos \
  --derived-data-path /private/tmp/throttle-sota-macos/throttle-macos-g3m_prz3/DerivedData
```

Recheck that cache's existence after reboot. An output of 670 passed tests does
not override a changed-source receipt; only a fresh stable run closes this gate.

## Increment of 2026-09-09 (Claude Code, integration branch)

Reference for the caller-authentication question, verified against the MCP
specification revision 2026-07-28 (Authorization, "Protocol Requirements"):
*implementations using an STDIO transport SHOULD NOT follow the authorization
specification and instead retrieve credentials from the environment.* For a
stdio server launched by the host, the caller's identity is the operating
system's: whoever can spawn the process under this user already holds every
right the process has. "Authenticated capability-bound callers" for
Throttle's stdio MCP therefore means OS identity plus a capability descriptor
carried by the environment or a 0600 file the launcher owns — not OAuth. A
design is recorded, not implemented; nothing here widens what a caller may do.

Implemented in this increment (hosted verification pending on the
integration CI):

- **L2 durability.** `PlanStore` appends now request `F_FULLFSYNC` (with
  `fsync` fallback) and flush the log directory when a task's first event
  creates its file; a failed flush is `writeNotDurable`, never a silent
  success. A torn trailing write reads as an invalid chain, stops further
  appends and is never trimmed: `testTornTrailingWriteIsRefusedNotRepaired`,
  `testFirstEventIsVisibleToAFreshStoreAndSurvivesADroppedCache`.
- **L2 receipts.** `WorkflowEvidenceReceipt` records two inputs a revision
  stamp cannot see: a digest of untracked paths (`git ls-files --others
  --exclude-standard`) and a digest of the allowlisted environment
  (`DEVELOPER_DIR`, `PATH`, `SDKROOT`, `TOOLCHAINS`) plus the toolchain
  version. They name the environment a receipt was true for; they never widen
  or narrow what it proves, and receipts written before them still decode.
  Credentials and `HOME` never shape the digest (tested).
- **L1 outbound policy.** `OutboundPolicy.scrub` is the one rule every export
  shares: credential-shaped strings (Anthropic, GitHub, Apple auth keys, AWS,
  Slack, bearer tokens, private-key blocks) are masked by kind at the boundary.
  Applied to the usage CSV; diagnostics already export typed values only.
- **Defect found and fixed while wiring it.** `CSVExporter` selected a
  `project_path` column that `usage_events` never had, so the About pane's CSV
  export failed on every database and reported nothing. The export now
  attributes each event through `file_state.encoded_project` by session, exports
  a blank project for an unattributed session, and leaves no header-only file
  behind on failure. `CSVExporterTests` reproduce both.

- **L2 capability-bound callers (implemented after the design above).**
  `PlanMCPAuthority` is a private 0600 descriptor the launcher writes in the
  user's Application Support — never inside a repository — naming the plan's
  repository and the task's worktree, the author the runtime speaks as and the
  operations it may perform (`read`, `event`, `verdict`; never another
  `claim`). `TaskLauncher.prepare` writes it in the same transaction as the
  claim; the Cockpit passes its path to that tab's runtime only through
  `THROTTLE_PLAN_AUTHORITY`, and the MCP router measures every task call
  against it. No descriptor: legacy caller, unchanged. Present: narrowed.
  Unreadable, world-readable, foreign-owned, symlinked, malformed or expired:
  every call refused, because a launcher that meant to narrow rights must
  not silently widen them. A restored tab restarts as a legacy caller.
  Tests: descriptor loading and refusals, symlinked project resolution,
  router refusals, launcher writes 0600 outside the repo with the right grant.
- **L3 instrument.** `scripts/pilot-metrics.py` aggregates the ten-task
  registry without inventing a number (4 tests; committed registry: 0/10).
- **L4 foundations.** ShadowReplay's bound arithmetic is pinned by tests and
  the frozen certification set has a stable digest.

Not done: hosted UI acceptance of the diagnostics preview, outbound canaries
on the CloudKit/LAN mirror payloads (iOS privacy tests exist on the SOTA
branch), crash testing with a real killed writer, native xcresult import,
the ten measured tasks themselves.

## Exact next gate and continuation

1. Obtain adequate free space without deleting unrelated or rollback material.
   Reconcile the dirty checkout again before running the host verifier; concurrent
   CloudKit, iOS privacy and release work are separate, not credited to this slice.
2. Run the complete macOS evidence lane, resolve any host type-check/test failures,
   then exercise the actual support archive, cockpit claim/review/check path,
   corrupted-log recovery UX and legacy-event migration. Report source snapshot
   and expected/completed inventory, not only a process exit code.
3. Finish L1: hosted support-preview acceptance, centrally enforced outbound/project policies and
   privacy canaries on every retained export/sync path. Finish L2: authenticated
   capability-bound callers, end-to-end retry/generation checks, crash testing,
   complete input receipts and native result import. Requalify each increment.
4. Personal pilot, then mandatory product packaging/EN-FR onboarding/AX/clean-user
   acceptance for each retained module. Only then promote it; implement L3-L8 in
   dependency order using the gates above. No other app is modified without its
   explicit scope approval, and no external connector is activated implicitly.

This is an implementation checkpoint, not completion of the integration plan.

## Deferred integrations (not forgotten)

Native: task orchestration, receipt UI, evaluations, review triage, governed
memory and product-signal projection. Reuse: Git, installed runtimes, Apple test
tools, scanners and existing Vault. Optional adapters: Promptfoo/OTEL, versioned
documentation, XcodeBuildMCP, web/UI testing, design references, public-page
research and read-only analytics/crash/subscription APIs. Do not rebuild a SaaS
backend, model, compiler, payment system or design editor.

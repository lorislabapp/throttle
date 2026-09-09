# Throttle — what is not done (opened 2026-09-09, after 3.6.0 shipped)

3.6.0 build 220 is published, byte-verified live, and `main` points at it.
This file is the single place a later session reads to know what is still
open; it exists so nothing below is rediscovered or silently dropped.

## Research Vault — Lot 5 (the only Vault lot left)

Spec: `docs/superpowers/specs/2026-08-29-research-vault-full-sota-design.md`.
Lots 1-4 shipped in 3.6.0: quarantine review state, parsers in the package,
resumable NotebookLM import with sidecar provenance, MCP read/write with the
dual protocol, and a retrieval benchmark bound to a frozen private corpus.

- [x] **Claims view** — `ResearchClaimsProjector` + the Workbench pane: proof,
      hypothesis, contradiction, unresolved and moved-source lanes, each claim
      one click from the exact source. A promoted contradiction outranks
      confidence; a source re-observed under a different hash demotes the claim
      out of proof; dangling evidence is named, not dropped.
- [x] **Sources panel** — hash and sensitivity were already shown; the row now
      reads its origin in words (NotebookLM notebook and one-based index),
      says how many claims rest on it, and flags content that changed since.
- [x] **Versions and drift** — the Revisions pane already lists a source's
      versions with the claims each one touched, beside a taxonomy audit.
- [x] **Saved views** — a view now carries project, evidence status, source kind
      and a freshness window, captures what is on screen when saved, and
      narrows every pane when selected. Views written before these filters
      decode with them unset, so they keep showing what they always showed.
- [x] **Opt-in NotebookLM sync** — a switch per notebook, each remembering the
      staging folder it syncs into; "Sync now" re-runs the Lot 2 job for those
      only. New material lands in quarantine, unchanged sources count as
      already present, and turning a notebook off forgets its folder.
- [x] **Accessibility audit** of the Workbench — recorded in
      `docs/testing/2026-09-09-vault-workbench-accessibility.md`. Reduce Motion
      needs no branch (the window animates nothing); Command-1..6 switch panes;
      spoken counts, progress, status region and decorative icons fixed. A real
      VoiceOver pass on the running app is still owed.

## Evidence gates that only Kevin can close

- [ ] Review the frozen corpus manifest (65 documents) at
      `~/Library/Application Support/Throttle/research-vault/golden-set.manifest.json`.
- [ ] Write ≥20 human questions with their relevant documents
      (template: `docs/testing/golden-set.human-queries.example.json`). Below
      twenty they are reported but never gate; from twenty the benchmark's
      quality claim moves from `derived_titles_only` to `human_queries`.
- [ ] Ten measured real tasks in `docs/testing/pilot-10-tasks.csv`
      (aggregate with `python3 scripts/pilot-metrics.py`). 0/10 today, so no
      productivity claim can be made.
- [ ] Device and session journeys: iCloud account switch, widget without the
      app, Live Activity, notifications, Face ID, terminal, VoiceOver;
      Codex↔Claude resume, real Quit, Mac→Linux→Mac conversation.

## Acted on from the 2026-09-09 research

The four reports in `docs/research/` are the evidence behind these.

- [x] **Router is cache-aware.** Caches are model-scoped, so a mid-session
      detour strands a write proportional to the whole conversation. The
      advisor now takes the live session's cache position, refuses to advise
      local inside a warm session, and states what the detour would cost.
- [ ] **Re-entry after absence.** The human-factors evidence says the feature
      is not the live view: rebuilding situation awareness costs about a third
      of capacity even in a management-by-exception system, and resuming an
      interrupted task took 25 min 26 s in Mark et al. 2005. Nothing in
      Throttle addresses the moment attention comes back.
- [ ] **Alarm discipline.** A tool call or a token tick is a status, not an
      alarm; the industrial standard is at most one alarm per ten minutes and
      three priorities. Below 0.70 reliability a detector is worse than none.
- [ ] **visionOS**: keep `ThrottleVision` frozen as the small windowed slice it
      is, with an explicit kill condition. The market read is negative as a
      product and the transport needs no entitlement, so there is nothing to
      hurry.

## SOTA ledger items still open

From `docs/testing/sota-integration-ledger.md` (increment of 2026-09-09):

- [ ] L1: hosted acceptance of the diagnostics preview; outbound canaries on
      the CloudKit and LAN mirror payloads.
- [ ] L2: crash testing with a real killed writer; native xcresult import.
- [ ] L3: the cockpit workflow itself (PlanStore is hardened, the surface and
      the full journey are not).
- [ ] L4: frozen evaluation cases, repetitions, human adjudication.
- [ ] L5: retrieval/abstention/isolation comparison — the dense challenger is
      measured `measured_not_promoted`; BM25 stays production until a
      significant, product-relevant gain is measured.
- [ ] L6: device/accessibility/platform matrix.
- [ ] L7: read-only product signals beyond the MetricKit summary.
- [ ] L8: shared app kits — only after a contract is demonstrated twice.

## Known limits recorded on purpose

- The task-log hash chain cannot detect an edited final line or a fully
  rewritten chain; that needs a signature, not a hash.
- The plan-store lock is cooperative coordination, not authentication.
- `PlanMCPAuthority` narrows a launched runtime; it is not a sandbox.
- Sparkle compares `CFBundleVersion`: any release must bump the build number.

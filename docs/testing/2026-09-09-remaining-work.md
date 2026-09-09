# Throttle — what is not done (opened 2026-09-09, after 3.6.0 shipped)

3.6.0 build 220 is published, byte-verified live, and `main` points at it.
This file is the single place a later session reads to know what is still
open; it exists so nothing below is rediscovered or silently dropped.

## Research Vault — Lot 5 (the only Vault lot left)

Spec: `docs/superpowers/specs/2026-08-29-research-vault-full-sota-design.md`.
Lots 1-4 shipped in 3.6.0: quarantine review state, parsers in the package,
resumable NotebookLM import with sidecar provenance, MCP read/write with the
dual protocol, and a retrieval benchmark bound to a frozen private corpus.

- [ ] **Claims view** — findings across receipts grouped as proof, hypothesis,
      contradiction and open question; every claim navigates to the exact
      source it rests on. The model already carries it
      (`ResearchFinding.status`, `evidenceIDs`, `ResearchReceipt.openQuestions`,
      `ResearchRelationCandidate`); the projection and the surface do not exist.
- [ ] **Sources panel** — per source: hash, origin (including the NotebookLM
      notebook and index), freshness, sensitivity.
- [ ] **Versions and drift** — a revised source marks the claims that rested on
      it; taxonomy drift audit.
- [ ] **Saved views** are query-only today; the spec asks for project, source,
      theme and date filters.
- [ ] **Opt-in NotebookLM sync** — per-notebook toggle, re-running the Lot 2
      job (idempotent by hash), new material landing in quarantine. Never
      silent.
- [ ] **Accessibility audit** of the Workbench: VoiceOver, keyboard, Reduce
      Motion.

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

# Cockpit prompt refiner + prompt library — design

Date: 2026-08-26 · Status: design approved, implementation not started
Repo state at authoring: HEAD `0de8b5a` (3.2.106 / build 205)

## 1. What this is

An in-cockpit assistant that turns a rough draft into a prompt worth sending to
the agent running in the active tab, shows why it changed, and makes previously
good prompts findable again. It never sends anything on its own.

Three targets share one composer:

| Mode | Refines | Applied to |
|---|---|---|
| Session | the next instruction for the live agent | the active tab's PTY, pasted without Enter |
| Mission | a `MissionHandoff.objective` | the objective field of `MissionHandoffSheet` |
| /loop | the argument the user types after `/loop` | pasted as text; Throttle does not model `/loop` |

## 2. Decisions locked by the user

| Decision | Choice |
|---|---|
| Where it lives | a unified right sidebar, segments **Audit** and **Refiner** |
| Side shell | **stays** in the terminal's `HSplitView` — it does not move into the sidebar |
| Output of a refinement | user setting: insert (default) · copy · send directly |
| Model used | existing `AIProviderRegistry` preferences, plus a local-first toggle |
| "Why it changed" visibility | user setting |
| Loop target | both `MissionHandoff.objective` and the `/loop` argument |
| Prompt library | in scope, second Design pass for its visuals |
| Visual direction | **1c "Takeover"** from the Claude Design project |

Two of these were chosen against a stated recommendation, and stay as chosen:
the user picked "both moments equally" for usage rhythm (resolved by the mode
selector giving Session a fast path and Mission a review path), and "everything
in one spec" over decomposition (resolved by the milestones in §8).

## 3. Visual lock — direction 1c "Takeover"

Source: Claude Design project `fb232897-bbe6-4b35-8410-79ae90ca1aef`,
file `Cockpit Sidebar.dc.html`, artboard `1c`.

The Refiner is **a stack of full-column focus screens**, not panels sharing the
column. Only one screen occupies the 280pt column at a time.

```
Home ──New draft──▶ Compose ──⌘⏎──▶ Loading ──▶ Result ──Insert──▶ Applied
  ▲                    │                │           │
  └────── ‹ Back ──────┴──── Error ─────┴─ ‹ Draft ─┘
```

**Home** — `TARGET` segmented control (Session · Mission · /loop), a 44pt dashed
"New draft" button, then the `HISTORY` list: one row per past refinement, title
plus a tabular-nums meta line, 44pt minimum height, hairline separated.

**Compose** — "‹ Back" plus a `<mode> · DRAFT` caption, then a monospaced text
editor taking all remaining height (~30 lines visible at 640pt, so a 15-line
draft never scrolls — the reason this direction was chosen), then draft metrics
and a 44pt `Refine ⌘⏎` button.

**Loading** — centred shimmer bars, `<model> · <elapsed>`, and a Cancel button.

**Error** — centred, amber `△ No AI provider available.`, the reassurance that
the draft is kept, a link to the provider settings, and "Back to draft".

**Result** — "‹ Draft" plus the model name, the proposal in a scrolling
monospaced box, then:
- the signature move: a **press-and-hold** button that swaps the proposal for the
  original draft in the same spot and swaps back on release. Comparison is
  temporal, not spatial, so nothing shrinks in a 280pt column.
- an `LN · B · TOK` delta strip in tabular numerals — the cost evidence shown
  before applying.
- the rationale bullets, each with an accent `·` marker.
- three re-refine chips: `shorter` · `precise` · `+ constraints`.
- a 44pt `Insert — you fire` primary with a 72pt `Copy` secondary.

**Applied** — `✓ In the terminal — you press ⏎.` plus "Done".

### Tokens

Ported from the artboard and reconciled with the existing
`CockpitAuditInspector`:

| Token | Value |
|---|---|
| Column width | 280pt |
| Panel background | `.regularMaterial` (artboard: `rgba(36,36,40,0.86)` + 24px blur) |
| Hairline | `Color.primary.opacity(0.10)`, 1px |
| Section header | 8.5pt, semibold, tracking 0.8, `.tertiary`, uppercase |
| Row label | 11pt `.secondary` · value 11pt monospacedDigit `.primary` |
| Recessive value | drops to `.tertiary`, never shrinks |
| Filled primary accent | `#0071E3` |
| Accent text and icons | `#0A84FF` |
| Warning | `#FF9F0A` |
| Interactive row / button height | ≥ 44pt |
| Monospaced body | 11pt, line height 1.55-1.6 |
| Header padding | 14 horizontal, 12 vertical |

The two blues are deliberate, not an inconsistency: `#0071E3` lacks contrast as
thin text on the dark cockpit background, so accent *text* uses `#0A84FF` while
filled primaries keep `#0071E3`. Both ship as named tokens.

### Deviations from the brief, accepted

- The brief allowed the column to widen while drafting. All three directions
  declined; 1c instead takes over the column with focus screens. Accepted — no
  widening is implemented.
- No direction included the prompt library. It is deferred to a second Design
  pass (§8, M2); 1c's `HISTORY` list is the seam it will extend.

## 4. Architecture

### New files

| File | Role |
|---|---|
| `Throttle/UI/Cockpit/CockpitSidebar.swift` | segment host (Audit · Refiner), renders exactly one segment |
| `Throttle/UI/Cockpit/PromptRefinerPane.swift` | the 1c focus-screen stack |
| `Throttle/Services/PromptRefinerModel.swift` | `@Observable` state: draft, proposal, mode, screen, history |
| `Throttle/Services/PromptRefinerService.swift` | pure `enum`, builds prompts, walks providers, returns a proposal |
| `ThrottleTests/ServiceTests/PromptRefinerServiceTests.swift` | service tests |

### Modified files

| File | Change |
|---|---|
| `MultiCockpitRoot.swift` | `CockpitAuditInspector()` at line 62-65 becomes `CockpitSidebar(...)`; `showInspector` becomes `showSidebar` + `sidebarTab`; the toolbar toggle at line 134-136 keeps its `sidebar.trailing` icon |
| `MultiCockpitModel.swift` | add `insertDraft(_:)` — paste text into the active tab's terminal |

### Why state lives outside the views

`CockpitViewModel` (used by the Audit segment) owns a polling `Task`
(`CockpitData.swift:115`). Keeping it mounted off-screen would run that loop for
nothing on a 16 GB machine, so the sidebar renders **one segment at a time** —
exactly the lifecycle that already works when the inspector is hidden.

That makes view state unsafe to hold in `@State`. `PromptRefinerModel` therefore
lives outside the view tree, so switching segments or closing the sidebar never
loses a typed draft.

The NSView-stability rule quoted at `MultiCockpitRoot.swift:581` does **not**
apply here: it governs AppKit-hosted PTYs, and the side shell is not moving.

### Insertion path

Insertion uses SwiftTerm's `paste(_:)` (bracketed paste), **not** `send(txt:)`.
A refined prompt is almost always multi-line, and raw newlines through
`send(txt:)` are read by the TUI as repeated Enter presses, submitting the draft
line by line.

`ReviewedPasteService`'s confirmation alert is **not** reused here. It fires at
≥4 lines (`ReviewedPasteService.swift:28`), which a refined prompt nearly always
exceeds, and the Result screen already shows the entire text plus
`LN · B · TOK` — strictly more review than the alert's truncated preview. The
hard invariants are kept: reject NUL/ESC, cap at 1 MiB.

### Provider chain

`PromptRefinerService` mirrors `AIOptimizerService`: unique delimiters (not
code fences, since prompts contain them), then `resolveActive()` followed by
`firstAvailable(excluding:)` for up to three attempts. It returns
`{ proposed, why: [String], provider }` and never writes anything itself. The
provider name is surfaced in the UI — this app does not hide authorship.

The system prompt varies on two axes: the **mode** (§1) and the **runtime of the
active tab** (`CockpitTab.runtime`), because Claude Code and Codex do not share
prompt idioms.

## 5. Settings

| Key | Values | Default |
|---|---|---|
| `throttleRefinerOutput` | `insert` · `copy` · `send` | `insert` |
| `throttleRefinerForceLocal` | Bool — constrain the chain to Apple Intelligence / embedded | `true` |
| `throttleRefinerRationale` | `always` · `collapsed` · `missionOnly` · `never` | `missionOnly` |

`send` shows a one-time warning: it is the only mode that spends without review.
`throttleRefinerForceLocal` defaults on because paying Claude tokens to save
Claude tokens is the trap the repo's doctrine already refuses elsewhere.

Model choice and quality reuse the existing `AIProviderRegistry.preferredKind`
and `qualityPreference` (surfaced today in `DropdownView.swift:2906` and
`ProjectAssistantTab.swift:185`). No duplicate setting is introduced.

## 6. Prompt library (M2)

Storage and search reuse what already exists — no new dependency:

- `EmbeddingProvider` / `NLEmbeddingProvider` — Apple's `NLEmbedding`, local,
  no download.
- `BruteForceVectorStore` — cosine search, `upsert` / `search` / JSON
  persistence.
- The `SemanticCorpusStore` pattern — one corpus directory per key. The library
  is one more corpus.

Brute force is correct at library scale (hundreds of prompts). The ANN/vector
backend listed as deferred in `docs/TODO.md` only becomes necessary at a much
larger corpus.

Scope: save a proposal under a name, list and manage saved prompts, semantic
search over them, and a typed trigger (e.g. `;;bug`) that expands a saved prompt
at the cursor in the Compose screen. Visuals pending the second Design pass.

## 7. Doctrine

Consistent with `docs/TODO.md`:

- Nothing is sent without an explicit user action (default output never presses
  Enter).
- No live prompt compression, no silent rewriting of what the user typed. The
  refiner only ever proposes; the user applies.
- No data-path proxy. The refiner reads the active tab's runtime and cwd, not
  its traffic.
- Authorship and cost are always shown, never hidden.

## 8. Milestones

**M1 — sidebar + refiner (unblocked).** `CockpitSidebar`, `PromptRefinerModel`,
`PromptRefinerService`, `PromptRefinerPane` with all six 1c screens, the three
settings, and the service tests. Ships useful on its own.

**M2 — prompt library (blocked on the second Design pass).** Saving, library
screen, semantic search, expander, and the Home navigation that reconciles
History with Library.

## 9. Tests

`PromptRefinerServiceTests`, against the pure `enum`, no UI:

- delimiter parsing, including a proposal that itself contains code fences
- provider fallback: first provider fails, second answers
- `noProvider` and `empty` error paths
- NUL / ESC rejection and the 1 MiB cap
- each mode produces the expected target and a runtime-appropriate system prompt

M2 adds: round-trip save/load of the library corpus, a semantic hit whose query
shares no words with the stored prompt, and trigger expansion at a cursor offset.

## 10. Open

- Second Design pass for M2 (brief issued 2026-08-26).
- Whether History persists across app launches or is session-scoped — decide
  when M2's Home navigation is designed, since the two lists are shown together.

# UI-SPEC — Research Vault workbench

Direction **1c · Checklist**, chosen from three Claude Design directions
(`Research Vault Directions.dc.html`, project `9c55c986`). Window is 1100×700 at
its ideal size, 940×620 floor.

## The problem this replaces

The window carried 32 controls on one flat surface. Roughly 25 of them are
curator plumbing the everyday searcher never touches. The control that adds a
folder lived in the sidebar header under an unlabelled icon, while the section
titled "Add sources, folders and migrations" had no way to add a folder. French
labels truncated. Disabled controls greyed out without saying why, and on the
Portfolio roll-up the folder button did nothing at all, silently.

## The core move

The vault's lifecycle is a **three-step checklist** — turn on → approve in Login
Items → add a folder — that occupies the results area until it is complete, then
folds into the trust line. Facets move into the sidebar under the selected space
and carry counts. All eight ways in sit behind a single **Add to vault…** button
that opens a sheet.

Everyday view: 5 controls on screen. Curators pay one extra step; every intake
goes through the sheet.

## Layout

Two columns: a 240pt sidebar and a main column.

**Sidebar** (`#F4F4F6` light / `#232326` dark, 1px hairline on the trailing edge,
10pt horizontal padding, 2pt row gap):
- `SPACES` — 10.5pt semibold, 0.8pt tracking, uppercase, tertiary.
- One row per space, 44pt minimum height: a 6pt dot, the name, and a trailing
  count when a query has run ("2 hits") or documents wait ("3 waiting"). The
  selected row takes a 7pt-radius fill and its dot takes the accent.
- Under the selected space only: each watched folder's path in 11.5pt monospace,
  then an accent **+ Add folder to <space>…** row. This is the folder control,
  in the one place a folder belongs.
- `FACETS · <scope>` then the six facets — Evidence, Sources, Claims, Timeline,
  Revisions, Reasoning — each 36pt with a trailing tabular count. Before a
  search the counts read "—" and the labels are tertiary.

**Main column**:
- 52pt title bar: back chevron, "Research Vault", spacer, **Add to vault…**.
- Search block, 28/40pt padding: a 44pt field carrying the scope as an inline
  chip ("throttle ⌄"), and, after a search, a trailing "N excerpts · 0.08 s".
  Below it the two secondary actions as plain accent text, each followed by its
  own reason when unavailable ("— needs at least one excerpt").
- Content area, 640pt measure for prose and 760pt for the review list.
- 44pt trust line: "Encrypted vault on · 128 documents · 41 receipts ·
  SQLCipher 4.18.0", tabular, engine name in monospace.

## States

| State | Content area |
|---|---|
| Never enabled | The checklist, step 1 live: a 24pt/700 title, three numbered rows with 28pt discs, the live step's disc filled with the accent and carrying its own primary button. Search field is inert and says "Search turns on at step 3." |
| Enabled, empty | Steps 1 and 2 collapse to checked one-liners; step 3 is live with **Watch a folder…** primary and **Other ways in…** secondary. |
| Quarantine pending | "N documents waiting for review", each row a monospaced file name over its metadata line, Approve / Reject trailing, and an "Approve all N" footer. Search says "Nothing is searchable until you approve the documents below." |
| Results | Optional local synthesis first, tagged `SYNTHESIS · LOCAL` in a bordered pill, each sentence carrying a citation link. Then numbered excerpts: the text, then one monospaced metadata line — path, location, hash, freshness — and the evidence status as a bordered uppercase pill. |
| No results | "Nothing in <space> matches "<query>"." plus how many documents were searched and whether Portfolio has hits elsewhere, then **Show the N Portfolio excerpts** and **Try fewer words**. |

Every disabled control states its reason in place. Nothing greys out mutely.

## Add to vault sheet

560pt wide, title "Add to <space>", subtitle "Everything is hashed, encrypted and
held in quarantine until you approve it."

**Everyday** — 15pt semibold label over a 12.5pt hint, accent filled button:
- Watch a folder — "Throttle keeps it in sync. Best for a research folder you
  already keep." → Choose folder…
- Add files — "Drop in individual notes, PDFs or exports." → Choose files…

**Occasional** — 44pt rows, label + 11.5pt hint, accent text action:
- Import sealed receipts · Signed .receipt files from another Mac.
- Inbox folder and sync · A drop folder Throttle empties on demand.
- Import a NotebookLM export · Local file, no Google connection.
- Import a Markdown export · One .md or a folder of them.
- Import one URL · HTTPS, single page, quarantined.
- List NotebookLM notebooks · Explicit read/export only; resumes where it
  stopped. Gated behind the export toggle; the action reads "Allow first" until
  it is on.

## Tokens

- Accent `#0071E3` light / `#0A84FF` dark — interactive only, never data.
- Hairlines `rgba(0,0,0,.09)` light / `rgba(255,255,255,.10)` dark.
- Radii: 10pt fields and primary buttons, 9pt secondary, 7pt sidebar rows and
  chips, 4pt status pills.
- Type: 24/700 display · 17/600 step title · 15/600 sheet row · 14 body ·
  13 UI · 12.5 hint · 11.5 metadata · 10.5/600 uppercase section.
- Every number tabular; paths, hashes and the engine name monospaced.
- Minimum 44pt hit targets throughout, and labels sized for French at +30%.

## Accessibility

The checklist is a single VoiceOver group per step, announcing the step number
and its state. Facet counts are read with their label. The scope chip announces
"Search scope: <space>". Disabled controls expose their reason as their
accessibility hint, not just as adjacent text.

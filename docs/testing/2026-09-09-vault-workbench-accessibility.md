# Research Vault Workbench — accessibility audit (2026-09-09)

Scope: the Workbench window only (`Throttle/UI/ResearchVault`). This is a code
audit against the Lot 5 gate, not a screen-reader session: a VoiceOver pass on
the running app is still owed and is listed as open below.

## Reduce Motion

The window animates nothing: no `withAnimation`, no `.animation(...)`, no
`.contentTransition`, and the macOS 26.5 guard already bans Canvas and
`.shadow` here. There is nothing to reduce, so Reduce Motion needs no branch —
asserted rather than assumed, and worth re-checking if an animation is ever
added.

## Keyboard

- Command-1 to Command-6 switch panes in the order the sidebar lists them, so
  the whole window is reachable without a pointer.
- Lists carry a selection binding, so arrow keys move through sources,
  timeline, revisions and reasoning rows.
- Every action is a real `Button` or `Toggle`; nothing is a tap gesture on a
  shape, so Full Keyboard Access reaches all of them.

## VoiceOver

Fixed in this pass:

- Facet rows announced their title and count as two unrelated fragments
  ("Claims, 12"). The count is now a value with its noun.
- The busy indicator and the NotebookLM import progress were silent; they now
  say what is working and how far it is.
- The search glass and the reasoning selection checkmark were spoken as
  images; both are decorative and are now hidden from VoiceOver, with the
  selected row carrying the `.isSelected` trait instead.
- The status line — where every outcome in this window is reported — is now a
  labelled region marked as updating, so a reader can return to the result of
  what they just did.

Already correct before this pass: every icon-only button carries a label
(back, remove folder, add folder), claim cards combine into one element with
the claim as label, evidence buttons say which source they open and warn when
it has changed, and the two view filters are labelled.

## Still open

- A real VoiceOver pass on the running app, including rotor navigation and
  focus order after switching panes.
- The quarantine and setup panes were not part of this audit.

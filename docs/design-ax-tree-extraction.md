# Design — AX-tree UI extraction (notebook finding #4)

**Idea:** instead of feeding Claude an expensive raw screenshot (~thousands of
vision tokens), serialize the focused app's macOS Accessibility (AX) tree into a
compact markdown "DOM" — claimed 80–90% fewer tokens for UI-driving tasks.

## The hard constraint
Throttle does NOT control how Claude Code takes screenshots. Claude's vision
input comes from its own tools / pasted images. Throttle can't intercept and
swap a screenshot for an AX dump in-flight (no hook rewrites image input).

## The only viable shape: a Throttle MCP tool
Throttle already runs an MCP server (`Throttle --mcp-server`). Add a tool, e.g.
`ui_snapshot(bundleId?)`, that:
- reads the focused (or named) app's AX tree via `AXUIElement` APIs,
- serializes it to compact markdown (role, title, value, frame; prune chrome),
- returns text — no image, no network, on-device (Apple-Silicon friendly).

The user (or a CLAUDE.md rule) then tells Claude: "to inspect a Mac UI, call
`ui_snapshot` instead of taking a screenshot." Adoption is opt-in by instruction.

## Feasibility / effort
- AX extraction: real but well-trodden AppKit work (`AXUIElementCopyAttributeValue`,
  recurse children, depth/size caps). **M effort.**
- Requires the **Accessibility** TCC permission (user grants once) — same class
  of permission Throttle already uses for Exact mode AppleScript.
- Risk: AX trees can be huge/noisy → must prune aggressively (visible-only,
  depth cap, drop decorative nodes) or it's not actually smaller than a screenshot.

## Where it fits the wedge
✅ cuts tokens (vision → text) · ✅ on-device · ✅ Throttle owns the MCP tool.
But it ONLY helps UI-automation workflows — a narrow slice of Claude Code users.
Most Throttle users aren't driving Mac UIs with Claude. So high effort, narrow
audience.

## Verdict
**Buildable, but defer.** It's a legit MCP-tool feature (not a hook hack), but
the audience is narrow and the pruning work is fiddly. Lower priority than the
token wins that hit every user (TOON, cache hygiene). Revisit if UI-automation
becomes a real user request. If built: ship as a `ui_snapshot` MCP tool, opt-in
by CLAUDE.md instruction, with strict tree pruning + a measured size check.

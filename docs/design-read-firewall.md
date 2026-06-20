# Design — Read-Firewall / local-RAG auto-config (NotebookLM 2026-06-20)

**Idea:** detect when a session is burning tokens by brute-force reading files
(recursive directory dumps, re-reading large files), attribute it as high-waste,
and offer a 1-click optimization: wire a LOCAL retrieval MCP (`mcp-local-rag`)
into the project so claude gets precise semantic snippets instead of whole-file
dumps. Squarely the `detect → cost-attribute → optimize 1-click` loop; nothing
Anthropic's own tooling does.

## Detect
Watch the session's tool stream (the cockpit already sniffs PTY output) for a
read-heavy signature, e.g.:
- ≥ N sequential `Read`/`read_file` calls in one turn, or
- a single turn loading > ~150 KB / a large fraction of the context in file bytes,
- repeated re-reads of the same large file.
Attribute the wasted weighted tokens to that project (we already cost-attribute
per project) so the nudge shows real money, not a vibe.

## Optimize (1-click, opt-in, PREVIEW first)
Offer: "This project re-reads big files a lot (~€X/wk). Add local semantic search?"
→ on accept, inject `mcp-local-rag` into the project's `.mcp.json`:
- runs entirely locally via `npx` + an embedded LanceDB vector DB — no docker,
  no API key, no cloud (passes the no-cloud non-goal).
- **Never silent:** show the exact `.mcp.json` diff and let the user confirm;
  back up the file first; offer one-click revert. Editing someone's project
  config is high-trust — preview + undo are mandatory.

## Risks / golden-rule watch
- **Recall is lossy.** Semantic snippets can MISS context that a full read would
  have given claude → we'd be silently changing what the model sees and could
  degrade correctness. This is the subtle golden-rule-adjacent risk: it's not a
  faked number, but it IS an undisclosed change to claude's inputs. Mitigation:
  frame it as an explicit user choice, keep it per-project + revertible, and never
  force it; measure before/after task success if we can.
- **Compatibility.** `mcp-local-rag` must actually be present/installable; detect
  failure and fall back to doing nothing rather than writing a broken `.mcp.json`.

## Throttle scope check
✅ detect→attribute→optimize · ✅ local-only · ✅ opt-in + preview + revert.
Verdict: promising, MEDIUM-HIGH leverage. Build behind explicit consent with a
config diff preview; gate the headline savings on real measurement.

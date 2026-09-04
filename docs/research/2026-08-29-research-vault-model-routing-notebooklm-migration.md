# Research Vault, local model routing, and NotebookLM migration

Date: 2026-08-29 (Europe/Paris)

## Decision

Research Vault is the default knowledge system for Throttle. NotebookLM is an
optional, user-initiated source of export data, never a runtime dependency and
never a reason to require a persistent Chrome/Computer Use connection.

The older `inventory_incomplete_reconciliation_blocked` result is a correct
fail-closed outcome from the separate NotebookLM gateway. It does not mean the
Research Vault service is unavailable. Throttle must not answer it by silently
opening a browser or sending another question.

## Migration contract implemented locally

- User selects an already-exported folder.
- Supported inputs: Markdown, text, CSV, JSON/JSONL, HTML, RTF, DOCX, and PDF.
- No sign-in, browser automation, network upload, move, or deletion.
- Symbolic links, path escapes, unreadable documents, oversized files, invalid
  project keys, and empty exports fail closed.
- Raw bytes receive a SHA-256; receipt identifiers are deterministic from
  project key, relative path, and content hash.
- Imported text is classified `OPEN`, not `VERIFIED` or `SUPPORTED` merely
  because it was copied.
- A user-saveable JSON manifest records each path, format, byte count,
  extracted character count, raw SHA-256, and aggregate SHA-256.

This is a migration/import mechanism, not a Google-side exporter. Google still
owns the acquisition step. NotebookLM documents note export to Google Docs or
Sheets; Google Takeout can export account data, but the exact set available is
account/product dependent. Throttle therefore validates the bytes it receives
instead of promising a complete proprietary notebook archive.

Primary references:

- Google NotebookLM notes: https://support.google.com/notebooklm/answer/16262519?hl=en
- Google Takeout: https://support.google.com/accounts/answer/3024190?hl=en
- NotebookLM sources: https://support.google.com/notebooklm/answer/16215270?co=GENIE.Platform%3DDesktop&hl=en-GB

## Model routing contract implemented locally

The Project Assistant's `Local` provider now has an executable route:

1. Probe the explicitly configured private/loopback Ollama endpoint.
2. Use the exact model returned by `/api/tags` and selected by the user.
3. If the server fails, fall back only to the installed same-device MLX model.
4. If neither is available, fail closed. Never fall back to Claude, Codex, or
   another cloud provider while `Local` is selected.

Selection never pulls or starts a model. The catalog is advisory and links to
model cards. Current entries cover the supported embedded Qwen model and
self-hosted Qwen 3 4B, Qwen3-Coder 30B A3B, and gpt-oss 20B. Suitability still
requires a benchmark on the exact host; a model-card claim is not runtime proof.

Primary references:

- Ollama model listing API: https://docs.ollama.com/api/tags
- Ollama tool calling: https://docs.ollama.com/capabilities/tool-calling
- Ollama structured outputs: https://docs.ollama.com/capabilities/structured-outputs
- OpenAI gpt-oss 20B: https://developers.openai.com/api/docs/models/gpt-oss-20b
- Hugging Face model cards: https://huggingface.co/docs/hub/model-cards

## Portfolio contract

Portfolio remains a read-only scan of `~/GitHub`. It now exposes search,
selection, backlinks, exact local source paths, and a direct Research Vault
query. The graph does not read the encrypted database directly and does not
invent Vault coverage. Research Vault remains the policy and provenance owner.

Primary references:

- Obsidian graph view: https://help.obsidian.md/plugins/graph
- Obsidian backlinks: https://help.obsidian.md/plugins/backlinks
- Obsidian Canvas: https://help.obsidian.md/plugins/canvas

## Evidence versus remaining hypotheses

Verified locally in this cycle: code compilation, app test suite, migration
unit tests, ResearchVaultKit debug/release matrices, SQLCipher behavior,
fail-closed IPC/MCP policies, crash recovery, and the provider truth panel's
rendered accessibility tree.

Not yet verified in this cycle: a real user NotebookLM export end-to-end, a
live Ollama Project Assistant answer on the selected host/model, complete visual
and accessibility QA of every new screen, and a fresh trusted Release signature.


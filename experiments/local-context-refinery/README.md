# Throttle Local Context Refinery

Experimental, read-only MCP sidecar for reducing developer logs before they reach Codex or Claude Code. It does not alter Throttle's notarized app, install a model, or modify either agent's configuration.

## Safety contract

- Deterministic extraction runs first and owns `status` plus `evidence`.
- Every result requires supervisor review; it is never a release or security approval.
- Inputs must be regular files inside `THROTTLE_REFINERY_ROOTS` (the current directory by default). Symlink escapes are rejected.
- Only `.log`, `.txt`, `.json`, `.jsonl`, `.out` and `.err` inputs are accepted; sensitive-looking filenames such as `.env`, credentials, tokens, cookies, keys and PKCS#12 files are refused.
- Inputs over 5 MiB are rejected instead of silently truncated.
- Common bearer tokens, API keys, passwords and signed URL parameters are redacted.
- Optional Ollama inference receives only reduced, redacted evidence.
- The Ollama endpoint is restricted to loopback HTTP. No cloud endpoint is accepted.
- No shell command, build, write tool, model download or configuration mutation is exposed.

## Validate without a model

```sh
cd experiments/local-context-refinery
npm test
npm run eval
```

## Run the stdio server

```sh
cd /absolute/path/to/Throttle
THROTTLE_REFINERY_ROOTS="/absolute/project:/private/tmp" \
  node experiments/local-context-refinery/mcp-server.mjs
```

The server exposes:

- `refine_log`: deterministic reduction for Xcode, tests, signing, notarization and MCP traces;
- `refinery_health`: configuration inspection without a model or network call.

`refine_log` returns both MCP `structuredContent` and the same serialized JSON in a text block for older clients. Its evidence includes source line numbers and SHA-256 hashes.

## Optional local model

No model name is assumed and nothing is downloaded automatically. Pin a model revision/tag only after the evaluation corpus passes:

```sh
THROTTLE_REFINERY_MODEL="<pinned-qwen-model>" \
THROTTLE_REFINERY_OLLAMA_URL="http://127.0.0.1:11434" \
THROTTLE_REFINERY_ROOTS="/absolute/project:/private/tmp" \
  node experiments/local-context-refinery/mcp-server.mjs
```

Call `refine_log` with `use_local_model: true`. If Ollama or the configured model is unavailable, deterministic evidence is still returned and `model_assist.status` is `unavailable`. Model output is advisory and cannot replace the reducer's status or evidence.

## Agent configuration previews

Do not apply these snippets silently. Both clients need a fresh session after an explicitly approved configuration change.

Claude Code project `.mcp.json` preview:

```json
{
  "mcpServers": {
    "throttle-refinery": {
      "type": "stdio",
      "command": "node",
      "args": ["/absolute/path/to/Throttle/experiments/local-context-refinery/mcp-server.mjs"],
      "env": {
        "THROTTLE_REFINERY_ROOTS": "/absolute/project:/private/tmp"
      }
    }
  }
}
```

Codex trusted-project `.codex/config.toml` preview:

```toml
[mcp_servers.throttle-refinery]
command = "node"
args = ["/absolute/path/to/Throttle/experiments/local-context-refinery/mcp-server.mjs"]
env = { THROTTLE_REFINERY_ROOTS = "/absolute/project:/private/tmp" }
```

## Promotion gates

Before integration into Throttle's signed bundle or any automatic routing:

1. Build a versioned corpus of real Xcode, XCTest, codesign, notarytool, ASC and MCP logs with secrets removed.
2. Require 100% recall for signing, security and release-critical diagnostics.
3. Measure relevant-line recall, false omission, unsupported claims, compression ratio, latency, peak RAM and secret leakage.
4. Pin the runtime and model revision; do not train on mutable documentation.
5. Run model-off and model-on outputs against the same gold set.
6. Keep the model advisory until an independent counter-audit passes.

The repository currently includes a small synthetic regression corpus only. Run `npm run eval` for the deterministic baseline and `npm run eval -- --model` after configuring a pinned local model. This is an engineering smoke set, not the 200–500-case production certification corpus.

Current local checkpoint (2026-08-16): official Ollama `qwen3.5:4b`, model ID `2a654d98e6fb`, blob SHA-256 `81fb60c7daa80fc1123380b98970b320ae233409f0f71a72ed7b9b0d62f40490`. The model is forced into non-thinking structured output, can only select supplied evidence hashes, cannot generate causes or actions, and remains advisory. See `eval/RESULTS-2026-08-16.md` for the bounded evidence and limitations.

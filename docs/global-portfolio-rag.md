# Global portfolio RAG

Throttle can expose one local, provider-neutral portfolio index to every Claude Code and Codex session through the existing `throttle-memory` MCP server.

The index discovers repositories from configured roots and records evidence-backed projects, reusable source components, declared dependencies, tools, workflows, research catalogs, and configured handoffs. Retrieval also fuses matching durable local memory and prior-session evidence. Agents retrieve it with `throttle_global_context`; they can explicitly rebuild its derived snapshot with `throttle_refresh_global_context`.

Retrieval is advisory. A result is a candidate to inspect, not proof that a checkout, SDK, account, signing identity, provider state, or release is currently valid. It never grants permission to upload, publish, submit, message, or modify another project.

## Portable post-install profile

Settings → General → **Global portfolio RAG profile** imports and exports JSON or YAML. The public app contains no customer project names or personal configuration.

Choose **Setup…** for the five-step onboarding assistant:

1. confirm the local-only privacy boundary and whether to use AI suggestions;
2. choose discovery folders;
3. review and include/exclude detected repositories;
4. edit every capability, tool, workflow and handoff, with optional local suggestions;
5. save the portable profile and explicitly opt into the shared MCP installation.

After a user enables **Throttle as an MCP source** for the first time, Throttle opens this assistant automatically. It never blocks manual JSON/YAML configuration.

### Local model policy

The assistant prefers Apple Foundation Models when it is available on the Mac, then a user-configured private Ollama worker, then Throttle's embedded MLX model. There is no cloud fallback. If no local model is ready, or if generated JSON fails the bounded schema, the deterministic scan remains intact.

The model sees only derived labels and evidence file names, not source bodies or credentials. Suggestions remain visibly labelled and editable; saving them is the user's confirmation, not proof that a capability, release, provider, signing identity, or website is current. Apple explicitly recommends a useful non-AI fallback, transparency, user control, and confirmation before consequential actions in its [Generative AI HIG](https://developer.apple.com/design/human-interface-guidelines/generative-ai). Apple documents Foundation Models as an on-device model whose availability must be checked at runtime in [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel).

JSON example:

```json
{
  "version": 1,
  "roots": ["/Users/example/Projects"],
  "exclusions": ["Archive"],
    "max_results": 6,
  "projects": [
    {
      "match": "DocumentApp",
      "display_name": "Document Studio",
      "aliases": ["Docs"],
      "capabilities": ["Document conversion pipeline"],
      "tools": ["Portable rendering SDK"],
      "workflows": ["Validated release build"],
      "handoffs": ["After release, hand off website metadata"]
    }
  ]
}
```

The YAML representation uses quoted scalars and JSON-compatible flow arrays so import stays small and deterministic:

```yaml
version: 1
roots: ["/Users/example/Projects"]
exclusions: ["Archive"]
max_results: 6
projects:
  - match: "DocumentApp"
    display_name: "Document Studio"
    aliases: ["Docs"]
    capabilities: ["Document conversion pipeline"]
    tools: ["Portable rendering SDK"]
    workflows: ["Validated release build"]
    handoffs: ["After release, hand off website metadata"]
```

`match` accepts either the repository directory name or its absolute path. Roots must be absolute. Profiles are versioned and bounded; unknown keys, malformed values, and secret-looking fields such as tokens, passwords, credentials, or private keys are rejected. Export includes configuration only—never indexed source text, transcript contents, or credentials.

After enabling **Throttle as an MCP source**, restart Claude Code and Codex so they reload the tool schemas. Importing a profile invalidates the old snapshot; the next retrieval rebuilds it automatically.

## Session awareness and rollback

Enabling the shared MCP source also installs a bounded session reminder: a Claude Code `SessionStart` hook and a managed block in Codex's active global instruction file. The reminder explicitly says not to call `throttle_global_context` on every session. It requests a six-result lookup only when cross-project reuse, prior portfolio decisions, a substantial new feature, a release, a website, or a handoff could materially change the work.

The global lookup is deliberately a routing step: it does not automatically open semantic indexes from several repositories. Follow a promising result with `throttle_semantic_search` for that one repository. Derived snapshots are reused for up to 24 hours; profile changes invalidate them immediately, and `throttle_refresh_global_context` remains available for an explicit fresh scan. This avoids repeatedly scanning a large portfolio during session startup while keeping every result labelled as a lead to verify.

Throttle follows Codex's documented global precedence: a non-empty `~/.codex/AGENTS.override.md` is used before `~/.codex/AGENTS.md`. Existing instructions and unrelated Claude hooks are preserved. Configuration files are backed up, managed additions are idempotent and removable, symbolic links are refused, and an unrelated file occupying Throttle's hook path is never overwritten. See the official [Codex AGENTS.md documentation](https://learn.chatgpt.com/docs/agent-configuration/agents-md).

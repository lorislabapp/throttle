# Plan orientation and local/frontier routing — SOTA decision packet

Date: 2026-09-04 (Europe/Paris)
Status: product decision and implementation input, not release evidence

## Decision

Throttle must separate four concepts that the current UI blends together:

1. **Project** — the repository whose plan and files are visible.
2. **Session** — one continuing conversation/work unit with its own state.
3. **Runtime** — Claude Code or Codex, which owns tools, terminal and native resume.
4. **Model route** — local or frontier inference for the Project Assistant and bounded delegation.

The Plan view should always show the active project, path, session and runtime,
select the most relevant task, and state the next action in plain language. AI
routing belongs in a dedicated, resizable window. An embedded Qwen model must
not be presented as a full coding runtime until Throttle can prove equivalent
tool, workspace, resume and handoff contracts.

## Evidence ledger

- `VERIFIED` — The current Plan binds to `cockpit.active.cwd`, but its header
  shows only the plan title. Session/runtime identity is absent from the Plan
  surface (`CockpitPlanView`, `PlanTreeView`).
- `VERIFIED` — The current tree relies on colour dots and raw dependency IDs;
  the inspector can open with no selected task and no next-action guidance.
- `VERIFIED` — `AgentRuntime.local` has no executable and currently opens a bare
  shell. The new-session chooser exposes only Claude Code and Codex. Calling it
  a local coding session would be false.
- `VERIFIED` — Embedded Qwen runs in-process through MLX and the optional Ollama
  worker is preferred only when explicitly configured. Local selection is a
  privacy boundary and fails closed rather than silently sending project
  context to a cloud provider.
- `VERIFIED` — Apple recommends persistent selection in split views so the
  relationship between hierarchy and detail stays clear, useful window titles,
  and adaptable Mac windows rather than unnecessary modal nesting.
- `VERIFIED` — VS Code's current agent UI treats a session as the unit of work,
  scopes it to a workspace, and exposes session target, agent, permission and
  language model as distinct controls. Its session list shows status and type.
- `VERIFIED` — Zed groups threads by project and shows which agent is running
  each thread. Model choice is attached to the thread/editor rather than hidden
  in a global settings page.
- `VERIFIED` — Claude Code sessions are tied to a project directory and can be
  named, resumed or branched. Model choice is an initial per-session selection;
  provider fallback does not create a provider-neutral continuation contract.
- `VERIFIED` — Ollama `/api/tags` returns exact installed model names. UI
  selection must use those exact tags; aliases such as `throttle-worker` versus
  `throttle-worker:latest` need explicit normalization.

## SOTA capability matrix

| Need | SOTA behaviour | Throttle decision |
|---|---|---|
| Stay oriented | Project, workspace/path, session, runtime and state visible together | Add a persistent context band to Plan |
| Know what to do | One primary next action, with the blocker and prerequisite named | Add a next-step card and dependency navigation |
| Resume safely | Preserve provider-native session identity; hand off explicitly | Keep reviewed handoffs; never silently swap an active CLI session |
| Choose local/frontier | Route visible near the work, advanced providers in a dedicated manager | Add an AI Routing window |
| Rate-limit recovery | Explain the boundary and offer valid targets | Offer Codex handoff; local remains Assistant/bounded work until tool parity exists |
| Privacy | Local-only choice never falls through to cloud | Preserve current fail-closed local boundary |
| Model discovery | Exact server-reported tags and observable backend | Keep `/api/tags`; normalize display/selection |

## Smallest defensible implementation

1. Add a Plan context band with project name, repository path, active session,
   runtime and state.
2. Automatically select the task owned by the active mission, otherwise the
   first actionable leaf, otherwise the first leaf.
3. Add a plain-language next-step card. For a blocked task, link directly to
   the first unmet dependency.
4. Add a dedicated AI Routing window opened from the Cockpit route control and
   the AI settings surface. It exposes new-session routing, Assistant provider,
   embedded/worker truth and the bounded-delegation switch.
5. State the rate-limit policy explicitly: reviewed Codex handoff for coding;
   no claim that embedded Qwen can resume a Claude/Codex terminal session.

## Rejected assumptions

- A provider toggle is not a session handoff.
- An installed local model is not automatically a tool-capable coding agent.
- A coloured status dot is not sufficient orientation.
- A configured Ollama endpoint is not required for local inference.
- Rate-limit detection is not authorization to move or mutate a live session.

## Privacy, security and accessibility

- No background transfer of transcript or repository content is added.
- Local remains fail-closed; a route change is explicit and visible.
- Status is communicated with text and symbols, never colour alone.
- The routing window is resizable and keyboard accessible.
- Active selection remains persistent across the Plan hierarchy and inspector.

## Validation gates

- Unit-test task selection and unmet-dependency logic.
- Compile the complete macOS target with warnings as errors.
- Run Plan, routing and local-model service tests.
- Visually inspect Plan at wide and minimum window widths.
- Verify VoiceOver labels and keyboard traversal on a running build.
- A signed build, install and public release remain separate gates.

## Primary sources

- Apple HIG, Split views: https://developer.apple.com/design/human-interface-guidelines/split-views
- Apple HIG, Toolbars: https://developer.apple.com/design/human-interface-guidelines/toolbars
- Apple HIG, Designing for macOS: https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/
- VS Code, Manage agent sessions: https://code.visualstudio.com/docs/agents/run/sessions/manage-sessions
- VS Code, AI language models: https://code.visualstudio.com/docs/agent-customization/language-models
- Zed, Agent Panel: https://zed.dev/docs/ai/agent-panel
- Zed, Parallel Agents: https://zed.dev/docs/ai/parallel-agents
- Claude Code, Manage sessions: https://code.claude.com/docs/en/sessions
- Claude Code, Model configuration: https://code.claude.com/docs/en/model-config
- Ollama, List models: https://docs.ollama.com/api/tags
- Ollama, Structured outputs: https://docs.ollama.com/capabilities/structured-outputs

## Local research reused

- `Research Vault, local model routing, and NotebookLM migration`, DeepSearsh
  document `dr-e1d95900c1c85b48`, SHA-256
  `e1d95900c1c85b483f51d643958c69c14bc1f08e1cdacdd7d65bcc82609f2812`.
- `Throttle Workspaces — marché, produit et architecture SOTA`, DeepSearsh
  document `dr-30cafe32eb40894c`, SHA-256
  `30cafe32eb40894cd436e973f5591b733f0937ef738dafa1a985c5915318386c`.

## Open items

- A true local coding session needs a separately designed tool/permission,
  transcript, worktree and resume contract.
- A local continuation offered after a rate limit needs a reviewed summary
  handoff and measured task-class acceptance before it can be automatic.

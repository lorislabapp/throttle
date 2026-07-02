# Offloading Claude Code to Proxmox on a 16 GB Mac — deep-research guide

Deep research 2026-07-02 (105 agents, 24/25 claims confirmed, 1 refuted). Goal: cut the Mac's RAM/swap pressure by moving auxiliary services (and optionally the whole dev env) to the Proxmox homelab (10.9.8.8).

## The core mechanic (verified)
- **Local stdio MCP servers = child processes on the Mac** → they hold the Mac's RAM/CPU. (`code.claude.com/docs/en/mcp`, MCP spec)
- **Remote HTTP MCP servers run elsewhere**; `claude` connects over the network → **zero local child process**. Moving them off = the relief.
- Transport: **Streamable HTTP is the official remote transport** (single `/mcp` endpoint, POST/GET/DELETE). **SSE is deprecated** (removal dates enforced through 2026). Build new connections on Streamable HTTP.
- ❌ **Refuted myth:** "remote MCP must be public HTTPS." FALSE. A **private LAN / Tailscale endpoint is fine** — no public exposure needed.

## What CAN vs CANNOT move (hard constraint)
| Workload | Offload to Proxmox? |
|---|---|
| Heavy node/python MCP servers | ✅ biggest, easiest win |
| Vector/RAG backend, batch/benchmark jobs | ✅ |
| NLEmbedding embeddings (Throttle) | ❌ Apple-only (CoreML), stays Mac |
| `claude` process + git + terminal + editing | ❌ stays local — **unless** you commit to full remote-dev |

→ The `claude` node process (the dominant RAM cost, and the one that OOM'd the build) only leaves the Mac if you do **full remote-dev** (§Phase 2) OR you hibernate idle sessions (Throttle H01, already shipped).

## Phase 1 — move MCP servers to Proxmox (do this week)
Biggest bang; you have **15 user-scope MCP servers** loading into every session.

1. **LXC, not VM** (verified: LXC ~30–100 MB base vs VM ~180 MB–1 GB; 1–2% CPU overhead). Debian LXC, ~2 GB RAM, on 10.9.8.8.
2. Host the servers behind a **gateway** so the Mac connects **once**:
   - **Supergateway** — wraps a stdio MCP server → Streamable HTTP with one command. Simplest per-server. (`github.com/supercorp-ai/supergateway`)
   - **MetaMCP** or **hwdsl2/docker-mcp-gateway** — aggregate MANY servers behind one authenticated endpoint (`/mcp`), Bearer-token. (`github.com/metatool-ai/metamcp`, `github.com/hwdsl2/docker-mcp-gateway`)
3. **Reach it privately** — Tailscale on the Proxmox host (zero port-forward, WireGuard mesh) or plain LAN `10.9.8.x`. No public HTTPS required. (`tailscale.com/kb/1133/proxmox`)
   - Unprivileged LXC + Tailscale needs `/dev/net/tun`: add `lxc.cgroup2.devices.allow: c 10:200 rwm` + `lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file`.
4. Rewire Claude Code:
   ```
   claude mcp add --transport http <name> http://<lxc-host>:<port>/mcp   # + Authorization: Bearer <token>
   ```
   Then **remove the local stdio copies** from `~/.claude.json` — use Throttle's new **MCP manager** (disable/delete), no hand-editing.
5. Vendor-hosted shortcut where it exists (zero self-hosting): GitHub → `claude mcp add --transport http github https://api.githubcopilot.com/mcp` (Bearer PAT).

## Phase 2 — full remote-dev (deeper relief, optional)
Moves source, extensions, terminals, AND `claude`/node compute onto the server; only a thin UI stays on the Mac.
- **VS Code Remote-SSH** — strongest single relief. Installs VS Code Server on the host; terminals + extensions + `claude` run remotely. (`code.visualstudio.com/docs/remote/ssh`)
- **SSH + tmux/mosh** — run `claude` in a durable tmux session on the box; mosh survives roaming. (duanestorey.com walkthrough)
- **Mutagen hybrid** — keep editor + git local, code + build on server via real-time sync. Pre-1.0 (v0.18.x), scaling issue at huge file counts — validate on repo size. (`github.com/mutagen-io/mutagen`)

## Node / Claude Code memory tuning (complements offload)
- `export NODE_OPTIONS="--max-old-space-size=1536"` (test 1024 for many light sessions).
- `claude --max-agents 3`, `claude --bare` (skip auto-discovery), `--resume` over new sessions.
- On the LXC: Node 20+ is **cgroup-aware** — heap defaults to 50% of container RAM up to 4 Gi (2 GB cap beyond). So sizing the LXC's RAM auto-bounds the MCP node heaps.
- Known: Claude Code node has had memory-leak/OOM reports on long sessions + subagents (anthropics/claude-code #4953) — another reason to hibernate idle sessions.

## Measure the relief (no source gave numbers — benchmark locally)
Before/after moving N servers:
- `vm_stat 1` → watch `pageouts` drop
- Activity Monitor → Memory → "Swap Used"
- `memory_pressure`, `footprint <pid>` for per-process RSS

## Throttle tie-ins
- **MCP manager** (shipped 3.2.27) already lists/moves/disables servers — the control surface for Phase 1.
- Throttle's **Pattern-A MCP proxy** (verified) is conceptually Supergateway — a future "Run on Proxmox" button could deploy a server to the LXC + rewrite the config to the remote URL.
- **Auto-hibernate** (shipped, this branch) is the ONLY thing that frees the local `claude` node RAM without full remote-dev.

## Open questions (need local benchmarking)
- Actual swap/RSS reduction from moving N servers (measure).
- Added latency of MCP calls over Tailscale to LAN Proxmox for interactive sessions.
- LXC vs VM final call for the gateway (LXC recommended: lower overhead).

## Key sources
code.claude.com/docs/en/mcp · modelcontextprotocol.io spec · github.com/supercorp-ai/supergateway · github.com/metatool-ai/metamcp · code.visualstudio.com/docs/remote/ssh · tailscale.com/kb/1133/proxmox · developers.redhat.com/articles/2025/10/10/nodejs-20-memory-management-containers

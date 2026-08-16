# Throttle Edge Agent

Runs on a Proxmox LXC (or any Linux/macOS host with `tmux` + `ttyd` + `node ≥18`) to
**offload Claude Code sessions off a RAM-constrained Mac**. It spawns and measures
sessions, and — on explicit attach — streams keystrokes into one. The agent listens
on loopback only; Throttle reaches it through tailnet-only HTTPS.

**Doctrine:** `claude` on this host talks to Anthropic **directly** — the agent is
**not** on the data path and never sees request/response bodies. Lifecycle
(start/stop/pause/resume) is always coarse. Keystroke streaming exists **only** while
a client is attached (`/sessions/:id/attach`) — Kevin's 2026-07-11 full-control pivot
deliberately overrides the earlier measure-only-forever stance for this one path, in
exchange for the client-side write-unlock gate documented below. Node built-ins only
for the base agent (keep the LXC light); `ttyd` is the one external binary dependency.

**Installing `ttyd`:** Debian and Ubuntu do **not** package it (`apt-cache policy ttyd`
returns no candidate — verified against a real Debian 12 LXC) — the deploy script Kevin's
Mac generates (`EdgeAgentService.deployScript`) downloads the pinned, checksummed
[tsl0922/ttyd](https://github.com/tsl0922/ttyd) v1.7.7 release binary for `uname -m`
straight to `/usr/local/bin/ttyd` instead. If you're setting this up by hand, do the
same rather than reaching for `apt-get install ttyd` — it won't find anything.

## Run
```bash
umask 077
openssl rand -hex 24 > /opt/throttle-agent/agent-token  # share once with the Mac
export THROTTLE_AGENT_TOKEN_FILE=/opt/throttle-agent/agent-token
node throttle-agent.mjs
```

Env: `THROTTLE_AGENT_TOKEN_FILE` (production; systemd credential in one-click deploy),
`THROTTLE_AGENT_TOKEN` (development fallback only), `THROTTLE_AGENT_HOST` (loopback only,
default `127.0.0.1`),
`THROTTLE_AGENT_PORT` (default `8787`), `THROTTLE_AGENT_TTYD_PORT` (default `8788`),
`THROTTLE_AGENT_CLAUDE_CMD` (default `claude`; tests use `sleep 3600`),
`CLAUDE_PROJECTS_DIR` (default `~/.claude/projects`), and bounded mission roots
`THROTTLE_AGENT_MISSION_ROOT` / `THROTTLE_AGENT_INCOMING_ROOT` (defaults under
`/opt/throttle-agent`).

Kalystr missions additionally require `git` and `systemd-run`. Each mission runs
in a detached Git worktree under `/opt/throttle-agent/missions`, inside a transient
systemd service capped at 6 GiB RAM, 2 GiB swap, 250% CPU and 256 tasks. Claude runs
non-interactively with a USD budget and deadline, safe mode, no Bash or web tools.

## Security
- **Transport**: the process refuses non-loopback binds. One-click deploy requires
  the node's full `*.ts.net` name and configures Tailscale Serve as a persistent,
  tailnet-only HTTPS reverse proxy. A separately managed private HTTPS proxy is an
  acceptable manual alternative. Never use Tailscale Funnel.
- **App-layer gate**: every control request requires `Authorization: Bearer <token>`
  (constant-time compared). ttyd binds only to `127.0.0.1`; the agent authenticates
  and proxies its WebSocket, injecting an internal header. No secret is placed in
  ttyd's argv or handshake.
- **Client-side write-unlock**: the iOS/Mac terminal client opens read-only and
  requires a local Face ID/Touch ID unlock before forwarding keystrokes, auto-relocking
  after 5 min idle. This is a UX safety net enforced by the client, not by ttyd or the
  agent — a compromised/jailbroken device could bypass it, same trust level as the
  token stored in the platform Keychain.
- The explicit Deploy button makes Throttle SSH to the selected host (and, when
  configured, pipes each step through `pct exec <id> -- bash -s`). It verifies the
  bearer-gated MCP endpoint before backing up and changing local Claude routing.
- **Exposure**: only the HTTPS proxy port is exposed. `THROTTLE_AGENT_TTYD_PORT` is
  an internal loopback hop and must never be forwarded.
- **Claude OAuth**: setup-token output is written atomically to a mode-0600,
  purpose-scoped file and injected only into spawned Claude processes. It is never
  appended to `~/.profile` or passed as a command argument.

## API
| Method | Path | Auth | Body / Result |
|---|---|---|---|
| GET | `/health` | no | `{ok, version, tmux, ttyd, sessions, attached}` |
| POST | `/mcp` | yes | MCP Streamable HTTP control plane (`list`, `start`, `pause/resume/stop`) |
| GET | `/sessions` | yes | `{sessions: [{id, project, cwd, state, model, tokens, startedAt}]}` |
| POST | `/sessions` | yes | `{project?, cwd, resume?}` → `{id, name}` (spawns `claude` in tmux) |
| POST | `/sessions/:id/stop` | yes | kill the tmux session (and any attached ttyd) |
| POST | `/sessions/:id/pause` | yes | SIGSTOP the session's process (freeze tokens) |
| POST | `/sessions/:id/resume` | yes | SIGCONT |
| POST | `/sessions/:id/attach` | yes | `{ok, id, port, path}` — (re)spawns a loopback ttyd and returns the authenticated WS proxy path on the API port; retargeting kills any previous attach |
| PUT | `/transcripts?cwd=<abs>&session=<id>` | yes | raw JSONL body → `{ok, sessionId, bytes}` — context transfer: writes the FULL session transcript to `~/.claude/projects/<encoded cwd>/<id>.jsonl` so a follow-up `POST /sessions {cwd, resume: id}` resumes with the Mac session's context (verified live 2026-07-12: `claude --resume` accepts a transcript copied from another machine/cwd). 512 MB cap, streamed to disk |
| POST | `/missions` | yes | bounded `{missionId,cwd,baseCommit,task,maxSeconds,maxBudgetUsd}` → accepted mission in an isolated Git worktree |
| GET | `/missions/:id` | yes | bounded state/output tail plus base commit, patch SHA-256 and HMAC result authentication |
| GET | `/missions/:id/patch` | yes | binary Git patch, maximum 32 MiB, with contract/base/hash/HMAC headers |
| POST | `/missions/:id/stop` | yes | stops the transient systemd mission unit |
| DELETE | `/missions/:id` | yes | deletes a terminal mission worktree/result and its exact `/opt/throttle-agent/incoming/:id` clone |

Mission requests and exit status are persisted with mode `0600`. If the Edge Agent
restarts while a transient mission unit continues, version 1.0.0 reattaches a bounded
watcher and finalizes the authenticated result. Deletion is refused while a mission
is running or when its persisted source path does not exactly match the mission ID.

Sessions are hosted in `tmux` (name prefix `throttle-`) so a crashed agent doesn't kill
them; on restart the agent re-discovers live sessions by that prefix. Only one ttyd
attach is live at a time (personal/homelab scale, not multi-tenant) — attaching to a
different session id kills and respawns ttyd retargeted at the new tmux session.

# Throttle Edge Agent

Runs on a Proxmox LXC (or any Linux/macOS host with `tmux` + `ttyd` + `node ≥18`) to
**offload Claude Code sessions off a RAM-constrained Mac**. It spawns and measures
sessions, and — on explicit attach — streams keystrokes into one, over a token-gated
HTTP API the Throttle Mac cockpit and iOS companion talk to.

**Doctrine:** `claude` on this host talks to Anthropic **directly** — the agent is
**not** on the data path and never sees request/response bodies. Lifecycle
(start/stop/pause/resume) is always coarse. Keystroke streaming exists **only** while
a client is attached (`/sessions/:id/attach`) — Kevin's 2026-07-11 full-control pivot
deliberately overrides the earlier measure-only-forever stance for this one path, in
exchange for the client-side write-unlock gate documented below. Node built-ins only
for the base agent (keep the LXC light); `ttyd` is the one external binary dependency.

## Run
```bash
export THROTTLE_AGENT_TOKEN="$(openssl rand -hex 24)"   # share this with the Mac
node throttle-agent.mjs
```

Env: `THROTTLE_AGENT_TOKEN` (required), `THROTTLE_AGENT_HOST` (default `0.0.0.0`),
`THROTTLE_AGENT_PORT` (default `8787`), `THROTTLE_AGENT_TTYD_PORT` (default `8788`),
`THROTTLE_AGENT_CLAUDE_CMD` (default `claude`; tests use `sleep 3600`),
`CLAUDE_PROJECTS_DIR` (default `~/.claude/projects`).

## Security
- **Transport**: bind to a Tailscale/LAN address and keep the host behind Tailscale —
  WireGuard is the encryption boundary for both the HTTP API and the ttyd WebSocket.
  No separate TLS/Caddy layer for either; mTLS remains a possible future hardening.
- **App-layer gate**: every HTTP request except `/health` requires `Authorization:
  Bearer <token>` (constant-time compared). The ttyd instance spawned on attach reuses
  the *same* shared token as its HTTP Basic credential (`-c throttle:<token>`) — one
  secret to rotate, not two.
- **Client-side write-unlock**: the iOS/Mac terminal client opens read-only and
  requires a local Face ID/Touch ID unlock before forwarding keystrokes, auto-relocking
  after 5 min idle. This is a UX safety net enforced by the client, not by ttyd or the
  agent — a compromised/jailbroken device could bypass it, same trust level as the
  token already sitting in UserDefaults today.
- The Throttle Mac generates the systemd deploy + verifies the endpoint before use; it
  never SSHes for you.

## API
| Method | Path | Auth | Body / Result |
|---|---|---|---|
| GET | `/health` | no | `{ok, version, tmux, ttyd, sessions, attached}` |
| GET | `/sessions` | yes | `{sessions: [{id, project, cwd, state, model, tokens, startedAt}]}` |
| POST | `/sessions` | yes | `{project?, cwd, resume?}` → `{id, name}` (spawns `claude` in tmux) |
| POST | `/sessions/:id/stop` | yes | kill the tmux session (and any attached ttyd) |
| POST | `/sessions/:id/pause` | yes | SIGSTOP the session's process (freeze tokens) |
| POST | `/sessions/:id/resume` | yes | SIGCONT |
| POST | `/sessions/:id/attach` | yes | `{ok, id, port, path}` — (re)spawns ttyd on `THROTTLE_AGENT_TTYD_PORT` attached to this session's tmux pane; retargeting kills any previous attach |

Sessions are hosted in `tmux` (name prefix `throttle-`) so a crashed agent doesn't kill
them; on restart the agent re-discovers live sessions by that prefix. Only one ttyd
attach is live at a time (personal/homelab scale, not multi-tenant) — attaching to a
different session id kills and respawns ttyd retargeted at the new tmux session.

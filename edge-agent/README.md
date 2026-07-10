# Throttle Edge Agent

Runs on a Proxmox LXC (or any Linux/macOS host with `tmux` + `node ≥18`) to **offload
Claude Code sessions off a RAM-constrained Mac**. It spawns and *measures* sessions and
exposes a token-gated HTTP API the Throttle Mac cockpit talks to.

**Doctrine (matches Throttle):** measure-only, coarse lifecycle. `claude` on this host
talks to Anthropic **directly** — the agent is **not** on the data path and never sees
request/response bodies. It offers start / stop / pause / resume only; **no keystroke
streaming**. Node built-ins only (keep the LXC light).

## Run
```bash
export THROTTLE_AGENT_TOKEN="$(openssl rand -hex 24)"   # share this with the Mac
node throttle-agent.mjs
```

Env: `THROTTLE_AGENT_TOKEN` (required), `THROTTLE_AGENT_HOST` (default `0.0.0.0`),
`THROTTLE_AGENT_PORT` (default `8787`), `THROTTLE_AGENT_CLAUDE_CMD` (default `claude`;
tests use `sleep 3600`), `CLAUDE_PROJECTS_DIR` (default `~/.claude/projects`).

## Security
Bind to a **Tailscale/LAN** address and keep the host behind Tailscale for an encrypted
path; every request except `/health` requires `Authorization: Bearer <token>`
(constant-time compared). mTLS is a planned hardening. The Throttle Mac generates the
systemd deploy + verifies the endpoint before use; it never SSHes for you.

## API
| Method | Path | Auth | Body / Result |
|---|---|---|---|
| GET | `/health` | no | `{ok, version, tmux, sessions}` |
| GET | `/sessions` | yes | `{sessions: [{id, project, cwd, state, model, tokens, startedAt}]}` |
| POST | `/sessions` | yes | `{project?, cwd, resume?}` → `{id, name}` (spawns `claude` in tmux) |
| POST | `/sessions/:id/stop` | yes | kill the tmux session |
| POST | `/sessions/:id/pause` | yes | SIGSTOP the session's process (freeze tokens) |
| POST | `/sessions/:id/resume` | yes | SIGCONT |

Sessions are hosted in `tmux` (name prefix `throttle-`) so a crashed agent doesn't kill
them; on restart the agent re-discovers live sessions by that prefix.

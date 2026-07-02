# MCP offload — provisioning plan (a) + "Run MCP on your server" design (b)

## (a) Provision Kevin's Proxmox — BLOCKED on reachability
Proxmox MCP returned `fetch failed` (host 10.9.8.8 unreachable from this session — host down or not on the tailnet). Resume when reachable.

### Candidate analysis (15 user-scope MCP servers)
**Offload (pure API/LAN, no local files — only need env on the LXC):**
- `tavily` (TAVILY_API_KEY) · `hostinger-mcp` (API_TOKEN) — trivial, 1 key each, npx-spawned
- `proxmox` (runs naturally on the Proxmox host)
- `mailpilot` (5 env: MCP_API_KEY/MAILCOW_URL/MAILCOW_API_KEY/NODE_TLS_REJECT_UNAUTHORIZED/MAILPILOT_URL; `npx tsx` = RAM-heavy)
- `opnsense-mcp` (talks to OPNsense LAN) · `community-mcp` (web/API — confirm)

**Do NOT offload (read local files/repos/keys):**
- `audit-mcp` (local repos) · `lorislab-web` (~/GitHub/lorislab-website) · `lorislab-sync` + `app-store-connect` (local ASC key) · `mcp-local-rag` (BASE_DIR)
→ Instead: **disable if unused** (per the on-device advisor), don't relocate.

**Leave (Mac-bound / already remote):**
- `throttle-memory` (Throttle.app + local usage.db) · `notebooklm-native` (Companion.app) · `shotkit` (screenshots)
- `lorislab-comms` — already `ssh root@10.9.8.167`; local footprint is just an ssh client (negligible)

### Provisioning steps (once Proxmox is reachable)
1. LXC: Debian, ~2 GB RAM, next free VMID on 10.9.8.8. Tailscale in the LXC (`/dev/net/tun` allow lines for unprivileged) OR plain LAN.
2. Node LTS + a gateway (MetaMCP to aggregate, or Supergateway per server) exposing Streamable HTTP at `/mcp` with a Bearer token.
3. Install the offload set's packages (npx cache / global installs).
4. Secrets: **placeholders in the gateway env; Kevin injects the real values** (decision (ii)) — Throttle/Claude never writes Bitwarden secrets to the box.
5. Start small: prove with `tavily` + `proxmox` first, then add `hostinger`, `mailpilot`, `opnsense`, `community`.
6. Rewire Claude Code (Kevin, or Throttle MCP manager): `claude mcp add --transport http <name> http://<lxc>:<port>/mcp` (+ Bearer) and remove the local stdio copies from `~/.claude.json`.
7. Measure: `vm_stat 1` / Activity Monitor Swap before/after.

---

## (b) "Run MCP on your server" — Throttle feature design (BYO-server, no hosting)

**Principle:** Throttle **orchestrates**; the user **owns the box**. Throttle never hosts infra (local-first / no-data-path doctrine). Works with any SSH-reachable host: Proxmox LXC, VPS, NAS, spare Mac.

### UX (in the MCP manager)
- Per stdio server flagged `OFFLOAD` by the advisor → action **"Run on your server…"**.
- Sheet: pick/enter an **SSH target** (host, user, key — reuse existing SSH config; never store the key), and a **port**.
- Throttle shows a **preflight**: is the server offloadable? (no local-file deps — reuse the candidate heuristic), which env vars it needs (names only, never values).

### What Throttle generates / does
1. **Preflight check** — SSH in, verify Node present (offer to install), verify reachability back from the Mac.
2. **Deploy** — copy/generate a Supergateway (or gateway) unit that wraps the server's `command`+`args` and exposes Streamable HTTP + Bearer. Write a systemd unit (or a container) on the host.
3. **Secrets** — generate an `.env` template with the **names** of the required vars; Kevin fills the values on the host (or points at the host's own secret store). Throttle never transmits Bitwarden values.
4. **Rewire** — write the `claude mcp add --transport http …` config and (via the MCP manager) move the server's scope to remote + park the stdio copy (reversible; backed up — same machinery already shipped).
5. **Verify** — a `list_tools` handshake to the new URL (reuse `MCPHealthService`); on success, mark it remote in the tracker; on failure, roll back to the stdio copy.

### Reuses what's already shipped
- **MCP manager** (3.2.27) — the control surface + config read/write + backups.
- **MCP advisor** (3.2.28) — flags which servers to offload.
- **MCPHealthService** — the `list_tools` verify.
- **Pattern-A proxy** — conceptually identical to Supergateway; the code understanding transfers.

### Scope / non-goals
- ✅ BYO-server deploy + rewire + verify + rollback.
- ❌ Throttle-hosted infra (never).
- ❌ Auto-installing arbitrary MCP servers with unknown local-file deps — preflight refuses non-offloadable servers (points the user to `DISABLE` instead).
- ⚠️ Secrets: names-only; user injects values. No plaintext secret transit through Throttle.

### Build order (when greenlit)
1. Preflight/offloadability check (extends advisor) + SSH-target model.
2. Gateway unit generator (Supergateway systemd template).
3. Deploy over SSH + verify handshake + rollback.
4. UI in MCP manager ("Run on your server…" + status).
Estimate: multi-session feature; ship behind a "Advanced / homelab" section, Pro-gated.

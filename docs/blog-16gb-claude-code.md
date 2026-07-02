# Running many Claude Code sessions on a 16 GB Mac without swap hell

Draft — for review, then publish via comms (blog + Bluesky + Mastodon). Engineer-to-engineer, no hype.

---

I run a lot of Claude Code at once. On a 16 GB Apple Silicon Mac that means swap — sometimes 25+ GB of it — and the occasional OOM that takes a build down with it. Here's the playbook I actually use, and what I built into Throttle to make it automatic.

## 1. Your MCP servers are eating your RAM

A local (stdio) MCP server isn't magic — Claude Code **spawns it as a child process on your machine** and talks to it over stdin/stdout. Ten stdio MCP servers = ten node/python processes, each with its own heap, living in your Mac's memory for the whole session. Multiply by every concurrent session.

The fix is architectural: run the heavy ones **somewhere else** and connect over the network. Claude Code's recommended remote transport is **Streamable HTTP** (the old HTTP+SSE transport is deprecated):

```
claude mcp add --transport http <name> http://<host>:<port>/mcp
```

Now `claude` connects by URL and spawns **zero** local process for that server.

Where's "somewhere else"? A homelab box works great — a small Proxmox LXC (Debian, ~2 GB, ~30–100 MB base overhead vs a full VM). Consolidate many servers behind one endpoint with a gateway like **Supergateway** or **MetaMCP**, and reach it **privately over Tailscale or your LAN** — no public exposure, no port forwarding, no HTTPS certificate dance. (A common myth says remote MCP must be public HTTPS. It doesn't.)

## 2. Which servers to move? Let the tool tell you

The hard part isn't moving servers — it's knowing *which*. So Throttle ships an **on-device MCP advisor**: for every configured server it looks at your **real last-30-day tool-call usage** (from your own transcripts), an estimate of the server's resident memory, and its transport, then recommends **keep / disable / offload / review** with a plain reason. A server you haven't called in a month but that spawns a process every session? `DISABLE`. A heavy one you use daily? `OFFLOAD`. All computed locally — no cloud, no telemetry.

## 3. Reclaim RAM from idle sessions automatically

Pausing a session (SIGSTOP) stops it burning tokens but **keeps its resident pages** — no RAM relief. The thing that actually frees memory is **hibernation**: kill the process subtree, keep the `--resume` id. Throttle now does this **automatically under memory pressure** — when the Mac hits critical pressure it hibernates sessions that have been idle 15+ minutes (never the one you're working in), frees ~300 MB–1 GB each, and you reopen the tab to resume with full context. Reversible, default-on, one quiet notification.

## 4. The leak nobody warns you about

Claude Code's node process can grow unbounded on long sessions and heavy sub-agent use — a known issue where it balloons into tens of GB and gets OOM-killed. When Throttle sees a session's RSS blow past the leak threshold, it offers a one-tap **restart-in-place**: it reclaims the leaked heap and resumes the *same conversation* via `--resume`. You lose the leaked memory, not your context.

## 5. Cap the heap, limit the agents, measure the relief

Two opt-in knobs for when you run many light sessions:

```
export NODE_OPTIONS="--max-old-space-size=1536"   # cap the V8 heap per session
claude --max-agents 3                              # fewer parallel sub-agents
```

(Throttle can inject both per Cockpit session for you.) Careful: too low a cap crashes claude on a big context — 4096+ is safe for most; drop toward 1536 only with many small sessions.

Then **measure**, don't guess:

```
vm_stat 1          # watch "pageouts" — should stop climbing
memory_pressure    # kernel pressure level
```

Activity Monitor → Memory → "Swap Used" is the honest scoreboard.

---

**TL;DR** — offload heavy MCP servers to a homelab box over remote HTTP; let an on-device advisor tell you which; auto-hibernate idle sessions; restart the leaky ones in place; cap Node heap for the small ones; measure with `vm_stat`. Most of this is one download away in [Throttle](https://lorislab.fr/throttle/) — a local-first, 100%-on-device usage meter and optimizer for Claude Code.

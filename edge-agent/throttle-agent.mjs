#!/usr/bin/env node
// Throttle Edge Agent — runs on a Proxmox LXC (or any Linux/macOS host) to offload
// Claude Code sessions off a RAM-constrained Mac. It SPAWNS + MEASURES sessions and
// exposes a token-gated HTTP API the Mac cockpit talks to. It is NOT a data-path
// proxy: `claude` on this host reaches Anthropic directly; the agent never sees the
// request/response bodies. Lifecycle (start/stop/pause/resume) plus, on explicit
// attach, a keystroke-streaming PTY bridge (ttyd wrapping tmux) — Kevin's 2026-07-11
// full-control pivot deliberately overrides the earlier measure-only doctrine for
// this path. The octet stream only exists while a client is attached; `claude`
// itself is still never proxied.
//
// Deps: Node built-ins only (keep the LXC light) + the `ttyd` binary on PATH.
// Transport security: bind to a Tailscale/LAN address and gate every request on a
// bearer token; put the host behind Tailscale for an encrypted path (mTLS is a
// future hardening). ttyd reuses the same shared token as HTTP Basic credentials —
// no separate secret to manage.
//
// Config via env:
//   THROTTLE_AGENT_TOKEN   required — shared bearer token (Mac sends it)
//   THROTTLE_AGENT_HOST    bind address (default 0.0.0.0)
//   THROTTLE_AGENT_PORT    default 8787
//   THROTTLE_AGENT_TTYD_PORT   default 8788 — port for the on-demand ttyd attach
//   THROTTLE_AGENT_CLAUDE_CMD  the launch command (default "claude"); tests set
//                              this to e.g. "sleep 3600" to exercise plumbing.
//   CLAUDE_PROJECTS_DIR    default ~/.claude/projects (for usage readout)

import http from 'node:http';
import net from 'node:net';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

const execFileP = promisify(execFile);

const TOKEN = process.env.THROTTLE_AGENT_TOKEN;
const HOST = process.env.THROTTLE_AGENT_HOST || '0.0.0.0';
const PORT = parseInt(process.env.THROTTLE_AGENT_PORT || '8787', 10);
const TTYD_PORT = parseInt(process.env.THROTTLE_AGENT_TTYD_PORT || '8788', 10);
const CLAUDE_CMD = process.env.THROTTLE_AGENT_CLAUDE_CMD || 'claude';
const PROJECTS_DIR = process.env.CLAUDE_PROJECTS_DIR || path.join(os.homedir(), '.claude', 'projects');
const VERSION = '0.2.0';

if (!TOKEN) { console.error('FATAL: set THROTTLE_AGENT_TOKEN'); process.exit(1); }

// In-memory registry of sessions this agent spawned. tmux is the process host so a
// crashed agent doesn't kill sessions; on restart we re-discover by tmux name prefix.
const PREFIX = 'throttle-';
const sessions = new Map(); // id -> { id, project, cwd, startedAt }

async function sh(cmd, args) {
  try { const { stdout } = await execFileP(cmd, args); return stdout.trim(); }
  catch (e) { return null; }
}
const hasTmux = async () => (await sh('which', ['tmux'])) !== null;
const hasTtyd = async () => (await sh('which', ['ttyd'])) !== null;

// ---- ttyd attach (single active client — personal/homelab scale, not multi-tenant) ----
// Only one interactive attach at a time: attaching to a different session id kills
// and respawns ttyd retargeted at the new tmux session. Lifecycle (start/stop/pause/
// resume) above is untouched and works independently of any attach.
let ttydProc = null;
let ttydSessionId = null;

async function portOpen(port, host = '127.0.0.1') {
  return new Promise((resolve) => {
    const sock = net.createConnection({ port, host });
    sock.once('connect', () => { sock.destroy(); resolve(true); });
    sock.once('error', () => resolve(false));
  });
}

function killTtyd() {
  if (ttydProc) { try { ttydProc.kill('SIGTERM'); } catch {} }
  ttydProc = null;
  ttydSessionId = null;
}

async function attachTtyd(id) {
  if (ttydSessionId === id && ttydProc && !ttydProc.killed) return; // already attached
  killTtyd();
  ttydProc = spawn('ttyd', ['-p', String(TTYD_PORT), '-W', '-c', `throttle:${TOKEN}`,
    'tmux', 'attach-session', '-t', PREFIX + id], { stdio: 'ignore' });
  ttydSessionId = id;
  ttydProc.once('exit', () => { if (ttydSessionId === id) { ttydProc = null; ttydSessionId = null; } });
  for (let i = 0; i < 50; i++) { // ~5s max
    if (await portOpen(TTYD_PORT)) return;
    await new Promise(r => setTimeout(r, 100));
  }
  throw new Error('ttyd did not come up in time');
}

async function tmuxList() {
  // Use a literal '|' separator, not '\t': some tmux builds don't emit a real tab
  // for the format escape, which collapsed the fields into one and produced a
  // composite id ("hex_created_activity") that the stop route then rejected.
  const out = await sh('tmux', ['list-sessions', '-F', '#{session_name}|#{session_created}|#{session_activity}']);
  if (!out) return [];
  return out.split('\n').filter(l => l.startsWith(PREFIX)).map(l => {
    const [name, created, activity] = l.split('|');
    return { name, id: name.slice(PREFIX.length), created: Number(created), activity: Number(activity) };
  });
}

// Best-effort usage readout from the newest transcript for a cwd (mirrors the Mac's
// cwd -> ~/.claude/projects/<encoded> mapping; encoding = path with / and . -> -).
function encodedProjectDir(cwd) { return cwd.replace(/[/.]/g, '-'); }
function newestTranscript(cwd) {
  const dir = path.join(PROJECTS_DIR, encodedProjectDir(cwd));
  try {
    const files = fs.readdirSync(dir).filter(f => f.endsWith('.jsonl'))
      .map(f => ({ f, m: fs.statSync(path.join(dir, f)).mtimeMs })).sort((a, b) => b.m - a.m);
    return files.length ? path.join(dir, files[0].f) : null;
  } catch { return null; }
}
function usageFor(cwd) {
  const t = newestTranscript(cwd);
  if (!t) return { tokens: null, model: null };
  try {
    const lines = fs.readFileSync(t, 'utf8').trim().split('\n');
    let tokens = 0, model = null;
    for (const ln of lines) {
      try {
        const o = JSON.parse(ln);
        const u = o?.message?.usage;
        if (u) tokens += (u.input_tokens || 0) + (u.output_tokens || 0);
        if (o?.message?.model) model = o.message.model;
      } catch {}
    }
    return { tokens: tokens || null, model };
  } catch { return { tokens: null, model: null }; }
}

async function listSessions() {
  const live = await tmuxList();
  return live.map(s => {
    const meta = sessions.get(s.id) || {};
    const idleSec = Math.max(0, Math.floor(Date.now() / 1000) - s.activity);
    const u = meta.cwd ? usageFor(meta.cwd) : { tokens: null, model: null };
    return {
      id: s.id,
      project: meta.project || s.id,
      cwd: meta.cwd || null,
      state: idleSec > 300 ? 'idle' : 'working',
      model: u.model,
      tokens: u.tokens,
      startedAt: s.created,
    };
  });
}

async function startSession({ project, cwd, resume }) {
  if (!cwd) throw new Error('cwd required');
  const id = crypto.randomBytes(4).toString('hex');
  const name = PREFIX + id;
  const launch = resume ? `${CLAUDE_CMD} --resume ${JSON.stringify(resume)}` : CLAUDE_CMD;
  const inner = `cd ${JSON.stringify(cwd)} && ${launch}`;
  await execFileP('tmux', ['new-session', '-d', '-s', name, 'bash', '-lc', inner]);
  sessions.set(id, { id, project: project || path.basename(cwd), cwd, startedAt: Date.now() });
  return { id, name };
}
async function stopSession(id) { await sh('tmux', ['kill-session', '-t', PREFIX + id]); sessions.delete(id); }
async function paneSignal(id, sig) {
  const pid = await sh('tmux', ['list-panes', '-t', PREFIX + id, '-F', '#{pane_pid}']);
  if (pid) await sh('bash', ['-lc', `pkill -${sig} -P ${pid.split('\n')[0]} || kill -${sig} ${pid.split('\n')[0]}`]);
}

// ---- HTTP ----
function send(res, code, obj) { const b = JSON.stringify(obj); res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(b); }
function authed(req) {
  const h = req.headers['authorization'] || '';
  const t = h.startsWith('Bearer ') ? h.slice(7) : '';
  // constant-time compare
  const a = Buffer.from(t), b = Buffer.from(TOKEN);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
function body(req) {
  return new Promise((resolve) => { let d = ''; req.on('data', c => d += c); req.on('end', () => { try { resolve(d ? JSON.parse(d) : {}); } catch { resolve({}); } }); });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  // health is unauthenticated (liveness only, no data)
  if (p === '/health' && req.method === 'GET') {
    return send(res, 200, {
      ok: true, version: VERSION, tmux: await hasTmux(), ttyd: await hasTtyd(),
      sessions: (await tmuxList()).length, attached: ttydSessionId,
    });
  }
  if (!authed(req)) return send(res, 401, { error: 'unauthorized' });
  try {
    if (p === '/sessions' && req.method === 'GET') return send(res, 200, { sessions: await listSessions() });
    if (p === '/sessions' && req.method === 'POST') { const r = await startSession(await body(req)); return send(res, 201, r); }
    const m = p.match(/^\/sessions\/([A-Za-z0-9_-]+)\/(stop|pause|resume|attach)$/);
    if (m && req.method === 'POST') {
      const [, id, action] = m;
      if (action === 'stop') { if (ttydSessionId === id) killTtyd(); await stopSession(id); }
      if (action === 'pause') await paneSignal(id, 'STOP');
      if (action === 'resume') await paneSignal(id, 'CONT');
      if (action === 'attach') {
        if (!(await hasTtyd())) return send(res, 500, { error: 'ttyd not installed' });
        await attachTtyd(id);
        return send(res, 200, { ok: true, id, port: TTYD_PORT, path: '/ws' });
      }
      return send(res, 200, { ok: true, id, action });
    }
    return send(res, 404, { error: 'not found' });
  } catch (e) { return send(res, 500, { error: String(e.message || e) }); }
});

server.listen(PORT, HOST, () => console.error(`[throttle-agent] ${VERSION} listening on ${HOST}:${PORT} (tmux sessions prefix "${PREFIX}")`));

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => { killTtyd(); process.exit(0); });
}

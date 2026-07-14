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
const VERSION = '0.5.0';

if (!TOKEN) { console.error('FATAL: set THROTTLE_AGENT_TOKEN'); process.exit(1); }

// Registry of sessions this agent spawned. tmux is the process host so a crashed
// agent doesn't kill sessions; on restart we re-discover by tmux name prefix.
// Metadata (project/cwd) is PERSISTED next to the agent: without it a restart
// forgot every session's cwd, which broke usage readout and the bring-back
// transcript route for sessions that were still alive in tmux.
const PREFIX = 'throttle-';
const META_PATH = '/opt/throttle-agent/sessions.json';
const sessions = new Map(); // id -> { id, project, cwd, startedAt }
try {
  for (const [k, v] of Object.entries(JSON.parse(fs.readFileSync(META_PATH, 'utf8')))) sessions.set(k, v);
} catch {}
function persistSessions() {
  try { fs.writeFileSync(META_PATH, JSON.stringify(Object.fromEntries(sessions)), { mode: 0o600 }); } catch {}
}

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
    'tmux', '-u', 'attach-session', '-t', PREFIX + id],
    { stdio: 'ignore', env: { ...process.env, LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8' } });
  ttydSessionId = id;
  ttydProc.once('exit', () => { if (ttydSessionId === id) { ttydProc = null; ttydSessionId = null; } });
  for (let i = 0; i < 50; i++) { // ~5s max
    if (await portOpen(TTYD_PORT)) return;
    await new Promise(r => setTimeout(r, 100));
  }
  throw new Error('ttyd did not come up in time');
}

// ---- In-app Claude OAuth (`claude setup-token` driven through tmux) ----
// `setup-token` insists on a TTY, which used to force a manual `ssh -tt` step.
// Instead we run it inside a throwaway tmux session and screen-scrape: the Mac
// app fetches the login URL from /auth/peek, the user authorizes in their
// browser, pastes the code into Throttle, /auth/submit types it back in, and
// the agent persists the minted token to ~/.profile itself. Zero terminal.
const AUTH_SESSION = 'throttle-auth';
const HOME_DIR = process.env.HOME || os.homedir();

function claudeAuthReady() {
  try {
    if (fs.readFileSync(path.join(HOME_DIR, '.profile'), 'utf8').includes('CLAUDE_CODE_OAUTH_TOKEN')) return true;
  } catch {}
  try { fs.accessSync(path.join(HOME_DIR, '.claude', '.credentials.json')); return true; } catch {}
  return false;
}

async function authStart() {
  await sh('tmux', ['kill-session', '-t', AUTH_SESSION]); // stale run, if any
  const spawnEnv = { ...process.env, HOME: HOME_DIR };
  await execFileP('tmux', ['new-session', '-d', '-s', AUTH_SESSION, '-x', '220', '-y', '50',
    'bash', '-lc', `${CLAUDE_CMD} setup-token`], { env: spawnEnv });
  return { ok: true };
}

async function authPeek() {
  const pane = await sh('tmux', ['capture-pane', '-t', AUTH_SESSION, '-p', '-J', '-S', '-200']);
  if (pane === null) return { running: false, url: null, done: claudeAuthReady() };
  const url = (pane.match(/https:\/\/\S+/g) || []).pop() || null;
  // setup-token prints the minted token on success — persist it and clean up.
  const tok = (pane.match(/sk-ant-oat[0-9A-Za-z_-]+/g) || []).pop() || null;
  if (tok) {
    persistOAuthToken(tok);
    await sh('tmux', ['kill-session', '-t', AUTH_SESSION]);
    return { running: false, url: null, done: true };
  }
  return { running: true, url, done: false };
}

async function authSubmit(code) {
  if (!code || !/^[0-9A-Za-z#_%|.-]{4,600}$/.test(code)) throw new Error('bad code');
  await execFileP('tmux', ['send-keys', '-t', AUTH_SESSION, code, 'Enter']);
  return { ok: true };
}

function persistOAuthToken(tok) {
  const profile = path.join(HOME_DIR, '.profile');
  let cur = '';
  try { cur = fs.readFileSync(profile, 'utf8'); } catch {}
  const line = `export CLAUDE_CODE_OAUTH_TOKEN=${tok}`;
  const next = cur.includes('CLAUDE_CODE_OAUTH_TOKEN')
    ? cur.replace(/export CLAUDE_CODE_OAUTH_TOKEN=\S+/, line)
    : cur + (cur.endsWith('\n') || cur === '' ? '' : '\n') + line + '\n';
  fs.writeFileSync(profile, next, { mode: 0o600 });
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

// Make ~/.claude.json non-interactive for a headless offload session, so a freshly
// deployed box doesn't hang a spawned session on claude's first-run gates:
//   - theme picker + onboarding: a brand-new box has never run claude interactively,
//     so without these flags the session sits at "choose a theme" and dies.
//   - per-folder trust: an offloaded cwd is new to the box → "Is this a project you
//     trust?" gate. Pre-accepting it is the user answering yes for a folder THEY
//     chose to offload to — NOT a permissions bypass.
// Best-effort; a failure here never blocks start.
function seedClaudeConfig(cwd) {
  try {
    const p = path.join(os.homedir(), '.claude.json');
    const d = fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : {};
    if (!d.theme) d.theme = 'dark';
    d.hasCompletedOnboarding = true;
    if (!d.lastOnboardingVersion) d.lastOnboardingVersion = '2.1.0';
    d.hasUsedBackslashReturn = true;
    d.projects = d.projects || {};
    d.projects[cwd] = Object.assign({}, d.projects[cwd], { hasTrustDialogAccepted: true });
    fs.writeFileSync(p, JSON.stringify(d, null, 2));
  } catch {}
}

async function startSession({ project, cwd, resume }) {
  if (!cwd) throw new Error('cwd required');
  seedClaudeConfig(cwd);
  const id = crypto.randomBytes(4).toString('hex');
  const name = PREFIX + id;
  const launch = resume ? `${CLAUDE_CMD} --resume ${JSON.stringify(resume)}` : CLAUDE_CMD;
  // mkdir -p the cwd first: an offloaded session names a project dir that may not
  // exist yet on this box (the Mac had it, we don't). Without this `cd` fails and
  // the tmux session dies on launch — the transcript was uploaded but claude never
  // starts. Creating it is the sane "run a session here" behaviour.
  const inner = `mkdir -p ${JSON.stringify(cwd)} && cd ${JSON.stringify(cwd)} && ${launch}`;
  // Spawn the tmux server in its OWN transient systemd scope, NOT in this agent's
  // service cgroup. Under systemd, a tmux server forked directly by the agent lives
  // in throttle-agent.service's control group and gets reaped almost immediately
  // (verified: identical spawn dies <2.5s under the service but survives from a
  // plain shell). `systemd-run --scope` moves it to an independent scope so the
  // session outlives the request — and a later `systemctl restart` of the agent no
  // longer kills running sessions either. Falls back to a bare tmux spawn where
  // systemd-run isn't available (non-systemd hosts / macOS dev).
  // Spawn with HOME explicitly set. Under systemd the service env has NO HOME
  // (verified live: the agent process environ lacked HOME entirely), so the
  // session's `bash -lc` couldn't source ~/.profile — no CLAUDE_CODE_OAUTH_TOKEN,
  // no ~/.local/bin PATH — and claude exited within ~2s. os.homedir() resolves the
  // home from /etc/passwd even when $HOME is unset, so this is correct for root and
  // any other service user without hardcoding a path. (The unit also sets
  // KillMode=process so `systemctl restart` no longer reaps live sessions.)
  // LANG/LC_ALL: a minimal Debian LXC defaults to the C locale, and tmux then
  // renders every non-ASCII glyph as "_" — the Mac cockpit's attached view showed
  // accented French (and claude's box-drawing UI) as underscores. C.UTF-8 always
  // exists on glibc ≥2.13, no locale-gen needed. `-u` forces tmux UTF-8 too.
  const spawnEnv = { ...process.env, HOME: process.env.HOME || os.homedir(),
                     LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8' };
  await execFileP('tmux', ['-u', 'new-session', '-d', '-s', name, 'bash', '-lc', inner],
    { env: spawnEnv });
  sessions.set(id, { id, project: project || path.basename(cwd), cwd, startedAt: Date.now() });
  persistSessions();
  return { id, name };
}
async function stopSession(id) { await sh('tmux', ['kill-session', '-t', PREFIX + id]); sessions.delete(id); persistSessions(); }
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
// Raw octet-stream body for transcript upload. Session JSONLs run to tens of MB;
// cap at 512 MB as a runaway guard, stream straight to disk (no buffering the
// whole file in memory on a small LXC).
const MAX_TRANSCRIPT_BYTES = 512 * 1024 * 1024;
function streamToFile(req, dest) {
  return new Promise((resolve, reject) => {
    let n = 0;
    const out = fs.createWriteStream(dest, { mode: 0o600 });
    req.on('data', (c) => {
      n += c.length;
      if (n > MAX_TRANSCRIPT_BYTES) { out.destroy(); fs.rmSync(dest, { force: true }); req.destroy(); reject(new Error('transcript too large')); }
    });
    req.pipe(out);
    out.on('finish', () => resolve(n));
    out.on('error', (e) => { fs.rmSync(dest, { force: true }); reject(e); });
  });
}

// Context transfer (Mac -> this box): receive a FULL session JSONL and place it at
// ~/.claude/projects/<encoded cwd>/<sessionId>.jsonl so a follow-up
// POST /sessions {cwd, resume: sessionId} resumes with the Mac session's context
// instead of burning 10-20 turns rebuilding it. Full copy only — the Mac side never
// truncates (truncation corrupts the session chain).
async function receiveTranscript(req, url) {
  const cwd = url.searchParams.get('cwd');
  const sessionId = url.searchParams.get('session');
  if (!cwd || !cwd.startsWith('/')) throw new Error('cwd (absolute) required');
  if (!sessionId || !/^[A-Za-z0-9-]{8,64}$/.test(sessionId)) throw new Error('bad session id');
  const dir = path.join(PROJECTS_DIR, encodedProjectDir(cwd));
  fs.mkdirSync(dir, { recursive: true });
  const dest = path.join(dir, `${sessionId}.jsonl`);
  const bytes = await streamToFile(req, dest);
  if (bytes === 0) { fs.rmSync(dest, { force: true }); throw new Error('empty transcript'); }
  return { ok: true, sessionId, bytes, dest };
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  // health is unauthenticated (liveness only, no data)
  if (p === '/health' && req.method === 'GET') {
    return send(res, 200, {
      ok: true, version: VERSION, tmux: await hasTmux(), ttyd: await hasTtyd(),
      sessions: (await tmuxList()).length, attached: ttydSessionId,
      claudeAuth: claudeAuthReady(),
    });
  }
  if (!authed(req)) return send(res, 401, { error: 'unauthorized' });
  try {
    if (p === '/auth/start' && req.method === 'POST') return send(res, 200, await authStart());
    if (p === '/auth/peek' && req.method === 'GET') return send(res, 200, await authPeek());
    if (p === '/auth/submit' && req.method === 'POST') { const { code } = await body(req); return send(res, 200, await authSubmit(code)); }
    if (p === '/sessions' && req.method === 'GET') return send(res, 200, { sessions: await listSessions() });
    if (p === '/sessions' && req.method === 'POST') { const r = await startSession(await body(req)); return send(res, 201, r); }
    if (p === '/transcripts' && req.method === 'PUT') { const r = await receiveTranscript(req, url); return send(res, 201, r); }
    // Bring-back: stream the NEWEST transcript for a session's cwd so the Mac can
    // resume it locally. `claude --resume` writes a NEW jsonl (new session id) on
    // the box, so "newest for the cwd" — not the original id — is the right file.
    const tm = p.match(/^\/sessions\/([A-Za-z0-9_-]+)\/transcript$/);
    if (tm && req.method === 'GET') {
      const meta = sessions.get(tm[1]);
      if (!meta?.cwd) return send(res, 404, { error: 'unknown session cwd (agent restarted?)' });
      const t = newestTranscript(meta.cwd);
      if (!t) return send(res, 404, { error: 'no transcript on the box yet' });
      res.writeHead(200, {
        'Content-Type': 'application/octet-stream',
        'X-Session-Id': path.basename(t, '.jsonl'),
        'Content-Length': fs.statSync(t).size,
      });
      fs.createReadStream(t).pipe(res);
      return;
    }
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

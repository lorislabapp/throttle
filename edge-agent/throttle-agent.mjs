#!/usr/bin/env node
// Throttle Edge Agent — runs on a Proxmox LXC (or any Linux/macOS host) to offload
// Claude Code sessions off a RAM-constrained Mac. It SPAWNS + MEASURES sessions and
// exposes a token-gated loopback HTTP API behind an authenticated HTTPS reverse
// proxy. It is NOT a data-path
// proxy: `claude` on this host reaches Anthropic directly; the agent never sees the
// request/response bodies. Lifecycle (start/stop/pause/resume) plus, on explicit
// attach, a keystroke-streaming PTY bridge (ttyd wrapping tmux) — Kevin's 2026-07-11
// full-control pivot deliberately overrides the earlier measure-only doctrine for
// this path. The octet stream only exists while a client is attached; `claude`
// itself is still never proxied.
//
// Deps: Node built-ins only (keep the LXC light) + the `ttyd` binary on PATH.
// Transport security: non-loopback binds are refused. Tailscale Serve (default)
// or an equivalent trusted HTTPS reverse proxy terminates TLS. ttyd also stays on
// loopback and is reachable only through the authenticated WebSocket proxy below,
// so no credential appears in ttyd's argv.
//
// Config via env:
//   THROTTLE_AGENT_TOKEN_FILE production bearer-token file (systemd credential)
//   THROTTLE_AGENT_TOKEN   development-only fallback
//   THROTTLE_AGENT_HOST    loopback bind address (default 127.0.0.1)
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
import assert from 'node:assert/strict';

const execFileP = promisify(execFile);

function readAgentToken() {
  const explicit = process.env.THROTTLE_AGENT_TOKEN_FILE;
  const credentialDir = process.env.CREDENTIALS_DIRECTORY;
  const file = explicit || (credentialDir ? path.join(credentialDir, 'agent-token') : null);
  if (file) {
    try { return fs.readFileSync(file, 'utf8').trim(); } catch {}
  }
  return process.env.THROTTLE_AGENT_TOKEN;
}

const TOKEN = readAgentToken();
const HOST = process.env.THROTTLE_AGENT_HOST || '127.0.0.1';
const PORT = parseInt(process.env.THROTTLE_AGENT_PORT || '8787', 10);
const TTYD_PORT = parseInt(process.env.THROTTLE_AGENT_TTYD_PORT || '8788', 10);
const CLAUDE_CMD = process.env.THROTTLE_AGENT_CLAUDE_CMD || 'claude';
const CODEX_CMD = process.env.THROTTLE_AGENT_CODEX_CMD || 'codex';
const PROJECTS_DIR = process.env.CLAUDE_PROJECTS_DIR || path.join(os.homedir(), '.claude', 'projects');
const VERSION = '1.0.0';
const MISSION_ROOT = process.env.THROTTLE_AGENT_MISSION_ROOT || '/opt/throttle-agent/missions';
const INCOMING_ROOT = process.env.THROTTLE_AGENT_INCOMING_ROOT || '/opt/throttle-agent/incoming';
const MAX_MISSION_TASK_BYTES = 32 * 1024;
const MAX_MISSION_PATCH_BYTES = 32 * 1024 * 1024;

function missionRequest(value) {
  const invalid = message => { throw Object.assign(new Error(message), { code: 400 }); };
  if (!value || typeof value !== 'object') invalid('mission body required');
  const missionId = String(value.missionId || '');
  const cwd = String(value.cwd || '');
  const baseCommit = String(value.baseCommit || '');
  const task = String(value.task || '');
  const maxSeconds = Number(value.maxSeconds ?? 900);
  const maxBudgetUsd = Number(value.maxBudgetUsd ?? 3);
  if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(missionId)) {
    invalid('missionId must be a lowercase UUID');
  }
  if (cwd !== path.join(INCOMING_ROOT, missionId)) invalid('cwd must match the mission incoming directory');
  if (!/^[a-f0-9]{40,64}$/.test(baseCommit)) invalid('baseCommit must be an exact git object id');
  if (!task.trim() || Buffer.byteLength(task) > MAX_MISSION_TASK_BYTES || task.includes('\0')) invalid('task must contain 1-32768 UTF-8 bytes');
  if (!Number.isInteger(maxSeconds) || maxSeconds < 30 || maxSeconds > 3600) invalid('maxSeconds must be 30-3600');
  if (!Number.isFinite(maxBudgetUsd) || maxBudgetUsd <= 0 || maxBudgetUsd > 20) invalid('maxBudgetUsd must be >0 and <=20');
  return { missionId, cwd, baseCommit, task, maxSeconds, maxBudgetUsd };
}

function missionManifestHmac(token, manifest) {
  const canonical = [
    'kalystr-edge-result-v1', manifest.missionId, manifest.baseCommit,
    manifest.patchSha256, String(manifest.patchBytes), String(manifest.exitCode),
  ].join('\0');
  return crypto.createHmac('sha256', token).update(canonical).digest('hex');
}

if (process.argv.includes('--self-test')) {
  const request = missionRequest({
    missionId: '12345678-1234-1234-1234-123456789abc',
    cwd: '/opt/throttle-agent/incoming/12345678-1234-1234-1234-123456789abc',
    baseCommit: 'a'.repeat(40), task: 'Fix the bounded fixture.', maxSeconds: 60, maxBudgetUsd: 1,
  });
  assert.equal(request.maxSeconds, 60);
  assert.throws(() => missionRequest({ ...request, cwd: 'relative' }));
  const manifest = { missionId: request.missionId, baseCommit: request.baseCommit,
    patchSha256: 'b'.repeat(64), patchBytes: 42, exitCode: 0 };
  assert.equal(missionManifestHmac('secret', manifest), '7f6ae1e531647ec4ee00372443eace7ea35fd7d73e0e1c8214aa3e3ad6b64c2f');
  assert.notEqual(missionManifestHmac('secret', manifest), missionManifestHmac('other', manifest));
  assert.equal(isLoopbackHost('127.0.0.1'), true);
  assert.equal(isLoopbackHost('0.0.0.0'), false);
  console.log('throttle edge mission contract: ok');
  process.exit(0);
}

if (!TOKEN) { console.error('FATAL: provide the bearer token through a protected credential file'); process.exit(1); }

// Registry of sessions this agent spawned. tmux is the process host so a crashed
// agent doesn't kill sessions; on restart we re-discover by tmux name prefix.
// Metadata (project/cwd) is PERSISTED next to the agent: without it a restart
// forgot every session's cwd, which broke usage readout and the bring-back
// transcript route for sessions that were still alive in tmux.
const PREFIX = 'throttle-';
const META_PATH = '/opt/throttle-agent/sessions.json';
const sessions = new Map(); // id -> { id, project, cwd, startedAt }
const missionProcesses = new Map();
const missionFinalizing = new Set();
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
  ttydProc = spawn('ttyd', ['-i', '127.0.0.1', '-p', String(TTYD_PORT), '-W',
    '-H', 'X-Throttle-Authorized', 'tmux', '-u', 'attach-session', '-t', PREFIX + id],
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
// the agent persists the minted token to a private purpose-scoped file. Zero terminal.
const AUTH_SESSION = 'throttle-auth';
const HOME_DIR = process.env.HOME || os.homedir();
const OAUTH_TOKEN_PATH = process.env.THROTTLE_AGENT_OAUTH_TOKEN_FILE
  || '/opt/throttle-agent/claude-oauth-token';

function isLoopbackHost(host) {
  return ['127.0.0.1', '::1', 'localhost'].includes(host);
}

if (!isLoopbackHost(HOST)) {
  console.error('FATAL: THROTTLE_AGENT_HOST must be loopback; expose it only through an authenticated HTTPS reverse proxy');
  process.exit(1);
}

function claudeAuthReady() {
  try { if (fs.statSync(OAUTH_TOKEN_PATH).size > 20) return true; } catch {}
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

/// Rebuild the sign-in URL from a tmux pane.
///
/// A single regex over the capture returns the first third of it. Claude Code
/// prints the URL across several pane rows, and `capture-pane -J` does not join
/// them — it only rejoins lines TMUX wrapped, not lines the application emitted.
/// The result looked like a URL, was returned as a URL, and led nowhere; the
/// only way to authenticate the box was to reassemble it by hand.
///
/// A URL continues onto the next row when that row has no spaces and is not
/// blank — wrapped continuations never do, and the prose around them always
/// does.
function extractAuthURL(pane) {
  const lines = pane.split('\n').map(l => l.replace(/\s+$/, ''));
  for (let i = 0; i < lines.length; i++) {
    const start = lines[i].match(/https:\/\/\S+$/);
    if (!start) continue;
    let url = start[0];
    for (let j = i + 1; j < lines.length; j++) {
      const next = lines[j].trim();
      if (!next || /\s/.test(next)) break;
      url += next;
    }
    return url;
  }
  return null;
}

async function authPeek() {
  const pane = await sh('tmux', ['capture-pane', '-t', AUTH_SESSION, '-p', '-J', '-S', '-200']);
  if (pane === null) return { running: false, url: null, done: claudeAuthReady() };
  const url = extractAuthURL(pane);
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
  fs.mkdirSync(path.dirname(OAUTH_TOKEN_PATH), { recursive: true, mode: 0o700 });
  const tmp = `${OAUTH_TOKEN_PATH}.tmp`;
  fs.writeFileSync(tmp, `${tok}\n`, { mode: 0o600 });
  fs.renameSync(tmp, OAUTH_TOKEN_PATH);
  fs.chmodSync(OAUTH_TOKEN_PATH, 0o600);
}

function oauthShellPrefix() {
  const file = `'${OAUTH_TOKEN_PATH.replaceAll("'", "'\\''")}'`;
  return `if [ -r ${file} ]; then CLAUDE_CODE_OAUTH_TOKEN="$(cat ${file})"; export CLAUDE_CODE_OAUTH_TOKEN; fi;`;
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
// Must reproduce Claude Code's own encoding EXACTLY, or a transcript lands in a
// directory `claude --resume` never looks in — and the failure is silent: the
// session starts and immediately dies with "No conversation found with session
// ID". Claude replaces every code unit outside [A-Za-z0-9-], so an accent becomes
// a dash while the letter under it survives (decomposed "Éclair" -> "E-clair").
// Replacing only / and . kept the accent bytes and produced a different directory.
/// `claude` or `codex`; anything unknown falls back to claude, which is what
/// every caller predating the runtime parameter meant.
function normalizeRuntime(value) {
  return String(value || '').toLowerCase() === 'codex' ? 'codex' : 'claude';
}

function encodedProjectDir(cwd) { return cwd.replace(/[^A-Za-z0-9-]/g, '-'); }
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

async function startSession({ project, cwd, resume, runtime }) {
  if (!cwd) throw new Error('cwd required');
  const kind = normalizeRuntime(runtime);
  if (kind === 'claude') seedClaudeConfig(cwd);
  const id = crypto.randomBytes(4).toString('hex');
  const name = PREFIX + id;
  // The two CLIs disagree on how to name the thing and how to reopen it, so the
  // runtime has to travel with the request. Offloading a Codex tab used to launch
  // `claude --resume <codex uuid>`: claude has never heard of that id, the session
  // died on the spot, and the offload still reported success.
  const bin = kind === 'codex' ? CODEX_CMD : CLAUDE_CMD;
  const launch = resume
    ? (kind === 'codex'
        ? `${bin} resume ${JSON.stringify(resume)}`
        : `${bin} --resume ${JSON.stringify(resume)}`)
    : bin;
  // mkdir -p the cwd first: an offloaded session names a project dir that may not
  // exist yet on this box (the Mac had it, we don't). Without this `cd` fails and
  // the tmux session dies on launch — the transcript was uploaded but claude never
  // starts. Creating it is the sane "run a session here" behaviour.
  const inner = `mkdir -p ${JSON.stringify(cwd)} && cd ${JSON.stringify(cwd)} && ${oauthShellPrefix()} exec ${launch}`;
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

function missionPaths(id) {
  const root = path.join(MISSION_ROOT, id);
  return { root, worktree: path.join(root, 'worktree'), state: path.join(root, 'state.json'),
    request: path.join(root, 'request.json'), exitCode: path.join(root, 'exit-code'),
    output: path.join(root, 'output.log'), patch: path.join(root, 'result.patch') };
}

function readMissionState(id) {
  try { return JSON.parse(fs.readFileSync(missionPaths(id).state, 'utf8')); } catch { return null; }
}

function writeMissionState(id, value) {
  const p = missionPaths(id);
  fs.mkdirSync(p.root, { recursive: true, mode: 0o700 });
  const tmp = `${p.state}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value), { mode: 0o600 });
  fs.renameSync(tmp, p.state);
}

function writeMissionRequest(request) {
  const p = missionPaths(request.missionId);
  fs.mkdirSync(p.root, { recursive: true, mode: 0o700 });
  const tmp = `${p.request}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(request), { mode: 0o600 });
  fs.renameSync(tmp, p.request);
}

function readMissionRequest(id) {
  try { return missionRequest(JSON.parse(fs.readFileSync(missionPaths(id).request, 'utf8'))); }
  catch { return null; }
}

function readMissionExitCode(id) {
  try {
    const value = Number(fs.readFileSync(missionPaths(id).exitCode, 'utf8').trim());
    return Number.isInteger(value) ? value : null;
  } catch { return null; }
}

function outputTail(file, maxBytes = 16 * 1024) {
  try {
    const size = fs.statSync(file).size;
    const length = Math.min(size, maxBytes);
    const fd = fs.openSync(file, 'r');
    const data = Buffer.alloc(length);
    fs.readSync(fd, data, 0, length, size - length); fs.closeSync(fd);
    return data.toString('utf8');
  } catch { return ''; }
}

async function finalizeMission(request, exitCode, terminationReason = null) {
  if (missionFinalizing.has(request.missionId)) return;
  missionFinalizing.add(request.missionId);
  const p = missionPaths(request.missionId);
  let patch = Buffer.alloc(0), failure = null;
  try {
    await execFileP('git', ['-C', p.worktree, 'add', '-N', '.']);
    const result = await execFileP('git', ['-C', p.worktree, 'diff', '--binary', '--full-index', request.baseCommit, '--'],
      { encoding: 'buffer', maxBuffer: MAX_MISSION_PATCH_BYTES + 1 });
    patch = Buffer.from(result.stdout);
    if (patch.length > MAX_MISSION_PATCH_BYTES) throw new Error('patch exceeds 32 MiB');
    if (patch.length === 0) throw new Error('mission produced no patch');
    fs.writeFileSync(p.patch, patch, { mode: 0o600 });
  } catch (error) { failure = String(error.message || error); }
  const manifest = {
    contractVersion: 'kalystr-edge-result-v1', missionId: request.missionId,
    baseCommit: request.baseCommit, patchSha256: crypto.createHash('sha256').update(patch).digest('hex'),
    patchBytes: patch.length, exitCode: Number.isInteger(exitCode) ? exitCode : -1,
  };
  const state = {
    ...manifest, hmacSha256: missionManifestHmac(TOKEN, manifest),
    state: failure || manifest.exitCode !== 0 ? 'failed' : 'completed',
    terminationReason, failure, outputTail: outputTail(p.output), finishedAt: Date.now(),
  };
  writeMissionState(request.missionId, state);
  missionProcesses.delete(request.missionId);
}

async function startMission(raw) {
  const request = missionRequest(raw);
  const p = missionPaths(request.missionId);
  if (fs.existsSync(p.root)) throw Object.assign(new Error('mission id already exists'), { code: 409 });
  if ((await sh('which', ['systemd-run'])) === null) {
    throw Object.assign(new Error('systemd-run is required for kernel CPU/RAM limits'), { code: 503 });
  }
  await execFileP('git', ['-C', request.cwd, 'cat-file', '-e', `${request.baseCommit}^{commit}`]);
  fs.mkdirSync(p.root, { recursive: true, mode: 0o700 });
  writeMissionRequest(request);
  try {
    await execFileP('git', ['-C', request.cwd, 'worktree', 'add', '--detach', p.worktree, request.baseCommit]);
  } catch (error) {
    fs.rmSync(p.root, { recursive: true, force: true });
    throw error;
  }
  const task = [
    'You are executing a bounded Kalystr remote editing mission.',
    'Work only inside the current Git worktree. Do not access secrets, the network, or paths outside it.',
    'Bash and web tools are unavailable. Make only the requested source edits; Kalystr will validate and test locally.',
    '', request.task,
  ].join('\n');
  const args = ['-p', '--safe-mode', '--no-session-persistence', '--permission-mode', 'acceptEdits',
    '--tools', 'Read', 'Edit', 'Write', 'Glob', 'Grep', '--output-format', 'json',
    '--max-budget-usd', String(request.maxBudgetUsd)];
  const output = fs.openSync(p.output, 'a', 0o600);
  const unit = `kalystr-mission-${request.missionId}`;
  const quotedExit = `'${p.exitCode.replaceAll("'", "'\\''")}'`;
  const command = [
    `${oauthShellPrefix()} ${CLAUDE_CMD} ${args.map(value => `'${value.replaceAll("'", "'\\''")}'`).join(' ')}`,
    'status=$?',
    `printf '%s\\n' "$status" > ${quotedExit}.tmp`,
    `mv ${quotedExit}.tmp ${quotedExit}`,
    'exit "$status"',
  ].join('; ');
  const child = spawn('systemd-run', [
    '--quiet', '--pipe', '--wait', '--collect', `--unit=${unit}`,
    '--service-type=exec', '--property=MemoryMax=6G', '--property=MemorySwapMax=2G',
    '--property=CPUQuota=250%', '--property=TasksMax=256', `--working-directory=${p.worktree}`,
    `--setenv=HOME=${HOME_DIR}`, '--setenv=LANG=C.UTF-8', '--setenv=LC_ALL=C.UTF-8',
    '/bin/bash', '-lc', command,
  ], {
    cwd: p.worktree, env: { ...process.env, HOME: HOME_DIR, LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8' },
    stdio: ['pipe', output, output], detached: true,
  });
  fs.closeSync(output);
  child.stdin.end(task);
  const started = { contractVersion: 'kalystr-edge-mission-v1', missionId: request.missionId,
    baseCommit: request.baseCommit, state: 'running', startedAt: Date.now(), maxSeconds: request.maxSeconds,
    resourceIsolation: { memoryMaxBytes: 6 * 1024 ** 3, memorySwapMaxBytes: 2 * 1024 ** 3,
      cpuQuotaPercent: 250, tasksMax: 256 } };
  writeMissionState(request.missionId, started);
  const timeout = setTimeout(() => {
    void execFileP('systemctl', ['stop', unit]);
  }, request.maxSeconds * 1000);
  timeout.unref();
  missionProcesses.set(request.missionId, { child, timeout, request, unit });
  child.once('error', async error => {
    clearTimeout(timeout);
    fs.appendFileSync(p.output, `\nspawn failed: ${error.message}\n`);
    await finalizeMission(request, -1, 'spawn_failed');
  });
  child.once('exit', async (code, signal) => {
    clearTimeout(timeout);
    await finalizeMission(request, code ?? -1, signal ? `signal:${signal}` : null);
  });
  return started;
}

async function stopMission(id) {
  const running = missionProcesses.get(id);
  if (!running) throw Object.assign(new Error('mission is not running'), { code: 409 });
  await execFileP('systemctl', ['stop', running.unit]);
  return { ok: true, missionId: id, action: 'stop' };
}

async function recoverMission(id, state) {
  const request = readMissionRequest(id);
  if (!request) {
    const failed = { ...state, state: 'failed', finishedAt: Date.now(),
      failure: 'persisted mission request is unavailable after agent restart',
      terminationReason: 'agent_restart_request_missing' };
    writeMissionState(id, failed); return;
  }
  const unit = `kalystr-mission-${id}`;
  const finish = async (exitCode, reason) => {
    const running = missionProcesses.get(id);
    if (running?.timeout) clearTimeout(running.timeout);
    if (running?.interval) clearInterval(running.interval);
    await finalizeMission(request, exitCode, reason);
  };
  const completedCode = readMissionExitCode(id);
  if (completedCode !== null) return finish(completedCode, 'agent_restart_recovered');
  const active = await sh('systemctl', ['is-active', unit]);
  if (!['active', 'activating'].includes(active)) return finish(-1, 'agent_restart_unit_inactive');

  const elapsed = Math.max(0, Date.now() - Number(state.startedAt || Date.now()));
  const remaining = Math.max(0, Number(state.maxSeconds || request.maxSeconds) * 1000 - elapsed);
  const timeout = setTimeout(() => { void execFileP('systemctl', ['stop', unit]); }, remaining);
  timeout.unref();
  let polling = false;
  const interval = setInterval(async () => {
    if (polling) return;
    polling = true;
    try {
      const exitCode = readMissionExitCode(id);
      if (exitCode !== null) return await finish(exitCode, 'agent_restart_recovered');
      const status = await sh('systemctl', ['is-active', unit]);
      if (!['active', 'activating'].includes(status)) await finish(-1, 'agent_restart_unit_inactive');
    } finally { polling = false; }
  }, 1000);
  interval.unref();
  missionProcesses.set(id, { child: null, timeout, interval, request, unit });
}

async function recoverMissions() {
  let entries = [];
  try { entries = fs.readdirSync(MISSION_ROOT, { withFileTypes: true }); } catch { return; }
  for (const entry of entries) {
    if (!entry.isDirectory() || !/^[a-f0-9-]{36}$/.test(entry.name)) continue;
    const state = readMissionState(entry.name);
    if (state?.state === 'running') await recoverMission(entry.name, state);
  }
}

async function cleanupMission(id) {
  const state = readMissionState(id);
  if (!state) throw Object.assign(new Error('mission not found'), { code: 404 });
  if (!['completed', 'failed'].includes(state.state) || missionProcesses.has(id)) {
    throw Object.assign(new Error('mission is still running'), { code: 409 });
  }
  const request = readMissionRequest(id);
  const expectedCwd = path.join(INCOMING_ROOT, id);
  if (!request || request.cwd !== expectedCwd) {
    throw Object.assign(new Error('mission cleanup path contract mismatch'), { code: 409 });
  }
  const p = missionPaths(id);
  try { await execFileP('git', ['-C', request.cwd, 'worktree', 'remove', '--force', p.worktree]); }
  catch { fs.rmSync(p.worktree, { recursive: true, force: true }); }
  await sh('git', ['-C', request.cwd, 'worktree', 'prune']);
  fs.rmSync(request.cwd, { recursive: true, force: true });
  fs.rmSync(p.root, { recursive: true, force: true });
  return { ok: true, missionId: id, action: 'deleted' };
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
function body(req, maxBytes = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let d = '', n = 0;
    req.on('data', c => {
      n += c.length;
      if (n > maxBytes) { reject(Object.assign(new Error('request body too large'), { code: 413 })); req.destroy(); return; }
      d += c;
    });
    req.on('end', () => { try { resolve(d ? JSON.parse(d) : {}); } catch { reject(Object.assign(new Error('invalid JSON'), { code: 400 })); } });
  });
}

// ---- Streamable-HTTP MCP surface ------------------------------------------------
// Claude Code can route its edge-session operations through the same bearer-gated
// endpoint as the Mac app. This is deliberately a control plane: prompts and model
// responses still flow directly between `claude` on the user's LXC and Anthropic.
const MCP_TOOLS = [
  {
    name: 'throttle_edge_list_sessions',
    description: 'List Claude Code sessions running on the user-owned Throttle edge server.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'throttle_edge_start_session',
    description: 'Start a Claude Code session on the user-owned edge server in an absolute remote working directory.',
    inputSchema: {
      type: 'object',
      properties: {
        cwd: { type: 'string', description: 'Absolute working directory on the edge server.' },
        project: { type: 'string', description: 'Optional display name.' },
        resume: { type: 'string', description: 'Optional uploaded Claude session ID to resume.' },
      },
      required: ['cwd'],
    },
  },
  {
    name: 'throttle_edge_session_action',
    description: 'Pause, resume, or stop a Claude Code session running on the edge server.',
    inputSchema: {
      type: 'object',
      properties: {
        id: { type: 'string' },
        action: { type: 'string', enum: ['pause', 'resume', 'stop'] },
      },
      required: ['id', 'action'],
    },
  },
];

function mcpText(value) {
  return { content: [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value, null, 2) }] };
}

async function handleMCP(req, res) {
  const message = await body(req);
  const id = message.id;
  const ok = (result) => send(res, 200, { jsonrpc: '2.0', id, result });
  const fail = (code, text) => send(res, 200, { jsonrpc: '2.0', id, error: { code, message: text } });

  if (message.method === 'initialize') {
    res.setHeader('Mcp-Session-Id', crypto.randomUUID());
    return ok({
      protocolVersion: '2024-11-05',
      capabilities: { tools: {} },
      serverInfo: { name: 'throttle-edge', version: VERSION },
    });
  }
  if (message.method === 'notifications/initialized') {
    res.writeHead(202); return res.end();
  }
  if (message.method === 'tools/list') return ok({ tools: MCP_TOOLS });
  if (message.method !== 'tools/call') return fail(-32601, `Method not found: ${message.method || ''}`);

  const name = message.params?.name;
  const args = message.params?.arguments || {};
  if (name === 'throttle_edge_list_sessions') return ok(mcpText(await listSessions()));
  if (name === 'throttle_edge_start_session') {
    if (typeof args.cwd !== 'string' || !args.cwd.startsWith('/')) return fail(-32602, 'cwd must be absolute');
    return ok(mcpText(await startSession(args)));
  }
  if (name === 'throttle_edge_session_action') {
    if (!/^[A-Za-z0-9_-]+$/.test(args.id || '') ||
        !['pause', 'resume', 'stop'].includes(args.action)) return fail(-32602, 'bad id or action');
    if (args.action === 'stop') await stopSession(args.id);
    if (args.action === 'pause') await paneSignal(args.id, 'STOP');
    if (args.action === 'resume') await paneSignal(args.id, 'CONT');
    return ok(mcpText({ ok: true, id: args.id, action: args.action }));
  }
  return fail(-32602, `Unknown tool: ${name || ''}`);
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
  const kind = normalizeRuntime(url.searchParams.get('runtime'));
  if (!cwd || !cwd.startsWith('/')) throw new Error('cwd (absolute) required');
  if (!sessionId || !/^[A-Za-z0-9-]{8,64}$/.test(sessionId)) throw new Error('bad session id');
  if (kind === 'codex') return receiveCodexRollout(req, url, sessionId);
  const dir = path.join(PROJECTS_DIR, encodedProjectDir(cwd));
  fs.mkdirSync(dir, { recursive: true });
  const dest = path.join(dir, `${sessionId}.jsonl`);
  const bytes = await streamToFile(req, dest);
  if (bytes === 0) { fs.rmSync(dest, { force: true }); throw new Error('empty transcript'); }
  return { ok: true, sessionId, bytes, dest };
}

// Codex files its rollouts by DATE, not by working directory:
// ~/.codex/sessions/YYYY/MM/DD/rollout-<iso>-<uuid>.jsonl. The date is carried in
// the filename itself, so the original name has to travel with the upload — invent
// one and `codex resume` will not find the session it just received.
async function receiveCodexRollout(req, url, sessionId) {
  const file = url.searchParams.get('file') || '';
  const m = /^rollout-(\d{4})-(\d{2})-(\d{2})T[0-9-]+-[A-Za-z0-9-]+\.jsonl$/.exec(file);
  if (!m) throw new Error('codex rollout filename required (rollout-<iso>-<uuid>.jsonl)');
  if (!file.includes(sessionId)) throw new Error('rollout filename does not carry the session id');
  const dir = path.join(os.homedir(), '.codex', 'sessions', m[1], m[2], m[3]);
  fs.mkdirSync(dir, { recursive: true });
  const dest = path.join(dir, file);
  const bytes = await streamToFile(req, dest);
  if (bytes === 0) { fs.rmSync(dest, { force: true }); throw new Error('empty transcript'); }
  return { ok: true, sessionId, bytes, dest };
}

// Repo transfer (Mac -> box): receive a `git bundle` (full history, single file)
// and clone it at `cwd`, so an offloaded session lands next to the actual CODE —
// not an empty directory. Bundle > tarball: it carries .git history compactly and
// `git clone <bundle>` is atomic. Only into an ABSENT or EMPTY cwd (409 otherwise:
// never clobber a directory that already has content).
async function receiveRepo(req, url) {
  const cwd = url.searchParams.get('cwd');
  const branch = url.searchParams.get('branch') || 'HEAD';
  if (!cwd || !cwd.startsWith('/')) throw new Error('cwd (absolute) required');
  if (!/^[A-Za-z0-9._\/-]{4,300}$/.test(branch)) throw new Error('bad branch');
  if (fs.existsSync(cwd) && fs.readdirSync(cwd).length > 0) {
    const err = new Error('cwd not empty — refusing to clobber'); err.code = 409; throw err;
  }
  const tmp = path.join(os.tmpdir(), `throttle-repo-${crypto.randomBytes(4).toString('hex')}.bundle`);
  await streamToFile(req, tmp);
  try {
    const args = branch === 'HEAD' ? ['clone', tmp, cwd] : ['clone', '-b', branch, tmp, cwd];
    await execFileP('git', args);
    // A clone takes branches and tags; it ignores refs/throttle/wip, which is
    // where the Mac's uncommitted work travels. Fetch it explicitly and apply it
    // to the fresh worktree, so a session handed over mid-edit continues from
    // what was on screen rather than from the last commit.
    let wipApplied = false;
    try {
      await execFileP('git', ['-C', cwd, 'fetch', '--quiet', tmp,
                              '+refs/throttle/wip:refs/throttle/wip']);
      // The ref is a plain snapshot commit, not a stash, so `stash apply` does
      // not apply. Checking its tree out over a freshly cloned worktree cannot
      // conflict with anything, then unstaging leaves the files modified exactly
      // as they were on the other machine.
      await execFileP('git', ['-C', cwd, 'checkout', 'refs/throttle/wip', '--', '.']);
      await execFileP('git', ['-C', cwd, 'reset', '--quiet']);
      wipApplied = true;
    } catch { /* nothing was in flight, or it did not apply — the commits are there */ }
    return { ok: true, cwd, branch, wipApplied };
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}

// A commit holding everything not yet committed — modified tracked files AND new
// untracked ones — without disturbing the repository.
//
// `git stash create` was the obvious tool and is the wrong one: it silently drops
// untracked files, and ignores `-u` when asked to include them. A handoff that
// loses every newly created file is worse than no handoff, because the loss is
// invisible until someone goes looking for the file.
//
// Writing through a TEMPORARY index is what makes this safe: `git add -A` stages
// into a throwaway file, so the real index and working tree are untouched and the
// session keeps running exactly as it was. Ignored paths stay ignored.
async function snapshotWorkInProgress(cwd) {
  const idx = path.join(os.tmpdir(), `throttle-index-${crypto.randomBytes(6).toString('hex')}`);
  const env = { ...process.env, GIT_INDEX_FILE: idx };
  try {
    await execFileP('git', ['-C', cwd, 'read-tree', 'HEAD'], { env });
    await execFileP('git', ['-C', cwd, 'add', '-A', '.'], { env });
    const { stdout: tree } = await execFileP('git', ['-C', cwd, 'write-tree'], { env });
    const t = tree.trim();
    const { stdout: head } = await execFileP('git', ['-C', cwd, 'rev-parse', 'HEAD^{tree}']);
    if (!t || t === head.trim()) return null;   // nothing in flight
    const { stdout: c } = await execFileP('git', ['-C', cwd, 'commit-tree', t, '-p', 'HEAD',
                                                  '-m', 'Throttle handoff: work in progress']);
    return c.trim() || null;
  } catch {
    return null;
  } finally {
    fs.rmSync(idx, { force: true });
  }
}

// Bring-back for CODE, symmetric to `receiveRepo`. The offload ships the repo
// out as a bundle; without this the reverse trip carried only the conversation,
// so a session could report work that existed nowhere the user could reach.
//
// A bundle rather than a diff or a tarball: it is one file, it carries real
// commits with their history, and `git fetch <bundle>` on the other side is an
// ordinary fetch — no patch application, no conflict resolution, nothing that
// can damage the Mac's working tree.
//
// Uncommitted work on the box is included as its own ref. `git stash create`
// builds a commit object from the index and worktree WITHOUT touching either,
// so the box keeps working exactly as it was while the Mac still receives what
// was in flight. Losing that is the failure this whole feature exists to
// prevent.
async function sendRepoBundle(req, res, url) {
  const cwd = url.searchParams.get('cwd');
  if (!cwd || !cwd.startsWith('/')) throw new Error('cwd (absolute) required');
  if (!fs.existsSync(path.join(cwd, '.git'))) {
    const err = new Error('not a git repository'); err.code = 404; throw err;
  }

  // Capture in-flight work as a ref the bundle can carry.
  let wip = null;
  try {
    wip = await snapshotWorkInProgress(cwd);
    if (wip) await execFileP('git', ['-C', cwd, 'update-ref', 'refs/throttle/wip', wip]);
    else await execFileP('git', ['-C', cwd, 'update-ref', '-d', 'refs/throttle/wip']).catch(() => {});
  } catch { /* nothing in flight — the commits still go */ }

  const tmp = path.join(os.tmpdir(), `throttle-out-${crypto.randomBytes(4).toString('hex')}.bundle`);
  try {
    await execFileP('git', ['-C', cwd, 'bundle', 'create', tmp, '--all']);
    const stat = fs.statSync(tmp);
    res.writeHead(200, {
      'content-type': 'application/octet-stream',
      'content-length': String(stat.size),
      // The Mac needs to know whether in-flight work is inside, and which commit
      // it is, without parsing the bundle.
      'x-throttle-wip': wip || '',
    });
    await new Promise((resolve, reject) => {
      const rs = fs.createReadStream(tmp);
      rs.on('error', reject); res.on('error', reject); res.on('finish', resolve);
      rs.pipe(res);
    });
  } finally {
    fs.rmSync(tmp, { force: true });
  }
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
      missionContract: 'kalystr-edge-mission-v1', git: (await sh('which', ['git'])) !== null,
      resourceIsolation: (await sh('which', ['systemd-run'])) !== null ? 'systemd-v1' : null,
    });
  }
  if (!authed(req)) return send(res, 401, { error: 'unauthorized' });
  try {
    if (p === '/mcp' && req.method === 'POST') return await handleMCP(req, res);
    if (p === '/auth/start' && req.method === 'POST') return send(res, 200, await authStart());
    if (p === '/auth/peek' && req.method === 'GET') return send(res, 200, await authPeek());
    if (p === '/auth/submit' && req.method === 'POST') { const { code } = await body(req); return send(res, 200, await authSubmit(code)); }
    if (p === '/sessions' && req.method === 'GET') return send(res, 200, { sessions: await listSessions() });
    if (p === '/sessions' && req.method === 'POST') { const r = await startSession(await body(req)); return send(res, 201, r); }
    if (p === '/missions' && req.method === 'POST') {
      try { return send(res, 202, await startMission(await body(req))); }
      catch (e) { return send(res, [400, 409, 413, 503].includes(e.code) ? e.code : 500, { error: String(e.message || e) }); }
    }
    const mission = p.match(/^\/missions\/([a-f0-9-]{36})$/);
    if (mission && req.method === 'GET') {
      const state = readMissionState(mission[1]);
      return state ? send(res, 200, state) : send(res, 404, { error: 'mission not found' });
    }
    if (mission && req.method === 'DELETE') {
      try { return send(res, 200, await cleanupMission(mission[1])); }
      catch (e) { return send(res, [404, 409].includes(e.code) ? e.code : 500, { error: String(e.message || e) }); }
    }
    const missionPatch = p.match(/^\/missions\/([a-f0-9-]{36})\/patch$/);
    if (missionPatch && req.method === 'GET') {
      const state = readMissionState(missionPatch[1]);
      const file = missionPaths(missionPatch[1]).patch;
      if (!state || !['completed', 'failed'].includes(state.state) || !fs.existsSync(file)) {
        return send(res, 409, { error: 'mission result not ready' });
      }
      res.writeHead(200, {
        'Content-Type': 'application/octet-stream', 'Content-Length': state.patchBytes,
        'X-Kalystr-Contract': state.contractVersion, 'X-Kalystr-Mission-Id': state.missionId,
        'X-Kalystr-Base-Commit': state.baseCommit, 'X-Kalystr-Patch-Sha256': state.patchSha256,
        'X-Kalystr-Hmac-Sha256': state.hmacSha256,
      });
      fs.createReadStream(file).pipe(res); return;
    }
    const missionStop = p.match(/^\/missions\/([a-f0-9-]{36})\/stop$/);
    if (missionStop && req.method === 'POST') {
      try { return send(res, 202, await stopMission(missionStop[1])); }
      catch (e) { return send(res, e.code === 409 ? 409 : 500, { error: String(e.message || e) }); }
    }
    if (p === '/transcripts' && req.method === 'PUT') { const r = await receiveTranscript(req, url); return send(res, 201, r); }
    if (p === '/repos' && req.method === 'GET') {
      try { return await sendRepoBundle(req, res, url); }
      catch (e) { return send(res, e.code === 404 ? 404 : 500, { error: String(e.message || e) }); }
    }
    if (p === '/repos' && req.method === 'PUT') {
      try { const r = await receiveRepo(req, url); return send(res, 201, r); }
      catch (e) { return send(res, e.code === 409 ? 409 : 500, { error: String(e.message || e) }); }
    }
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
        return send(res, 200, { ok: true, id, port: PORT, path: `/terminal/${id}/ws` });
      }
      return send(res, 200, { ok: true, id, action });
    }
    return send(res, 404, { error: 'not found' });
  } catch (e) { return send(res, 500, { error: String(e.message || e) }); }
});

// Authenticated WS reverse proxy. The public connection reaches this server only
// after TLS termination; ttyd remains loopback-only and trusts the header injected
// here after the bearer token and active session have both been verified.
server.on('upgrade', (req, client, head) => {
  const match = new URL(req.url, 'http://loopback').pathname
    .match(/^\/terminal\/([A-Za-z0-9_-]+)\/ws$/);
  if (!match || !authed(req) || match[1] !== ttydSessionId || !ttydProc || ttydProc.killed) {
    client.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
    return;
  }
  const upstream = net.createConnection({ host: '127.0.0.1', port: TTYD_PORT });
  upstream.once('connect', () => {
    const headers = Object.entries(req.headers)
      .filter(([name]) => !['authorization', 'host', 'x-throttle-authorized'].includes(name.toLowerCase()))
      .map(([name, value]) => `${name}: ${Array.isArray(value) ? value.join(', ') : value}`);
    upstream.write([
      'GET /ws HTTP/1.1',
      `Host: 127.0.0.1:${TTYD_PORT}`,
      ...headers,
      'X-Throttle-Authorized: 1',
      '',
      '',
    ].join('\r\n'));
    if (head.length) upstream.write(head);
    client.pipe(upstream);
    upstream.pipe(client);
  });
  upstream.once('error', () => client.destroy());
  client.once('error', () => upstream.destroy());
});

server.listen(PORT, HOST, () => {
  console.error(`[throttle-agent] ${VERSION} listening on ${HOST}:${PORT} (tmux sessions prefix "${PREFIX}")`);
  void recoverMissions().catch(error => console.error(`[throttle-agent] mission recovery failed: ${error.message}`));
});

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => { killTtyd(); process.exit(0); });
}

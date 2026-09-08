// New server conversations use their own process scope and private tmux socket.
// They do not claim to be a returned local conversation or reuse a transfer UUID.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { TransferStore, TransferCoordinator, SystemdTransferBackend, requireUnmanagedWorkspace } from './transfer-runtime.mjs';

const exec = promisify(execFile);
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const fail = message => { throw Object.assign(new Error(message), { code: 409 }); };
const quote = value => "'" + String(value).replaceAll("'", "'\\''") + "'";
export const isFreshID = id => typeof id === 'string' && id.startsWith('fresh-') && UUID.test(id.slice(6));
export const freshID = id => { if (!isFreshID(id)) fail('invalid fresh session identity'); return id.slice(6); };

export class FreshSessionStore extends TransferStore {
  constructor(root, environment = process.env) {
    super(root, path.join(root, 'protected-workspaces'));
    this.environment = environment;
  }
  read(id) {
    let stat;
    const file = this.file(id, 'record.json');
    try { stat = fs.lstatSync(file); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
    if (!stat.isFile() || stat.size > 32768) fail('fresh session journal is invalid');
    const record = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (record.contractVersion !== 1 || record.id !== id || record.serverID !== this.identity()
        || !Number.isFinite(record.createdAt) || record.createdAt <= 0
        || !['prepared', 'starting', 'remote', 'stopped'].includes(record.phase)) fail('fresh session journal is invalid');
    if (record.input !== null) {
      const input = record.input;
      if (!input || !['claude', 'codex'].includes(input.runtime) || !path.isAbsolute(input.cwd || '')
          || input.cwd.includes('\0') || input.cwd.length > 4096 || typeof input.project !== 'string'
          || input.project.length > 256 || !UUID.test(input.nativeSessionID || '')) fail('fresh session binding is invalid');
          validateLaunch(record.launch);
    } else if (record.phase !== 'stopped') fail('fresh session binding is missing');
    if (record.phase === 'stopped') {
      const receipt = record.stopReceipt;
      if (!this.tombstoned(id) || !receipt || !UUID.test(receipt.bootID || '')
          || receipt.unit !== 'throttle-session-' + id + '.service'
          || receipt.controlGroup !== '/system.slice/' + receipt.unit || receipt.populated !== 0
          || !['inactive', 'failed'].includes(receipt.activeState) || !Number.isFinite(receipt.observedAt)
          || receipt.observedAt <= 0 || (receipt.invocationID !== null && !/^[a-f0-9]{32}$/.test(receipt.invocationID || ''))) {
        fail('fresh session stop is not confirmed');
      }
    } else if (record.stopReceipt) fail('unexpected fresh session stop receipt');
    return record;
  }
  prepareFresh(raw, transferStore) {
    const id = raw?.requestID;
    if (!UUID.test(id || '')) fail('a stable lowercase requestID is required');
    if (raw?.serverID !== this.identity()) fail('fresh server identity changed or missing');
    this.directory(id);
    const runtime = raw?.runtime || 'claude';
    if (!['claude', 'codex'].includes(runtime) || raw?.resume) fail('fresh sessions cannot resume an existing identity');
    const cwd = raw?.cwd;
    if (typeof cwd !== 'string' || cwd.length > 4096) fail('fresh session directory is invalid');
    requireUnmanagedWorkspace(transferStore, cwd);
    requireUnmanagedWorkspace(this, cwd);
    const project = String(raw?.project || path.basename(cwd)).slice(0, 256);
    if (this.tombstoned(id)) fail('fresh session has been stopped');
    const previous = this.read(id);
    if (previous) {
      if (previous.input?.cwd !== cwd || previous.input?.runtime !== runtime || previous.input?.project !== project) {
        fail('fresh request identity was reused with different input');
      }
      return previous;
    }
    if (fs.existsSync(this.directory(id))) fail('fresh session state needs recovery');
    if (this.all().filter(record => record.phase !== 'stopped').length >= 32) fail('too many unresolved fresh sessions');
    const record = { contractVersion: 1, serverID: this.identity(), id, phase: 'prepared', createdAt: Date.now(),
      input: { cwd, runtime, project, nativeSessionID: crypto.randomUUID() },
      launch: configuredLaunch(runtime, this.environment) };
    this.save(record);
    return record;
  }
}

export class FreshSessionBackend extends SystemdTransferBackend {
  constructor(store, options = {}) { super(store, { ...options, purpose: 'transfer' }); }
  unit(id) { this.store.directory(id); return 'throttle-session-' + id + '.service'; }
  definition(id) { return super.definition(id).replace('--transfer-launch', '--fresh-launch'); }
}

export class FreshSessions extends TransferCoordinator {
  async create(raw, transferStore) {
    const record = this.store.prepareFresh(raw, transferStore);
    return this.exclusive(record.id, async () => {
      const current = this.store.read(record.id);
      if (this.store.tombstoned(record.id)) fail('fresh session has been stopped');
      if (current.phase !== 'prepared') {
        // A lost reply or restarted coordinator may only observe the original unit.
        // Never issue another StartUnit for an uncertain launch.
        await this.backend.confirmRunning(record.id);
        current.phase = 'remote'; this.store.save(current);
        return this.description(current);
      }
      if (!(await this.backend.ready())) fail('systemd with cgroup v2 and tmux is required');
      current.phase = 'starting'; this.store.save(current);
      await this.backend.install(record.id);
      await this.backend.start(record.id);
      if (this.store.tombstoned(record.id)) fail('fresh session stopped while starting');
      await this.backend.confirmRunning(record.id);
      current.phase = 'remote'; this.store.save(current);
      return this.description(current);
    });
  }
  description(record, state = record.phase) {
    return { id: 'fresh-' + record.id, serverID: record.serverID, project: record.input?.project || 'Recovery needed',
      cwd: record.input?.cwd || null, runtime: record.input?.runtime || null,
      // Codex chooses its identity after launch. No newest-cwd association is made.
      nativeSessionID: record.input?.runtime === 'claude' && record.launch?.command === 'claude' ? record.input.nativeSessionID : null,
      state, model: null, tokens: null, transcriptBytes: null, startedAt: Math.floor(record.createdAt / 1000) };
  }
  async list() {
    const result = [];
    for (const record of this.store.all().filter(record => record.phase !== 'stopped')) {
      let state = record.phase === 'prepared' ? 'pending' : 'unverified';
      if (record.phase !== 'prepared') {
        try { state = (await this.backend.state(record.id)).ActiveState === 'active' ? 'remote' : 'ended'; } catch {}
      }
      result.push(this.description(record, state));
    }
    return result;
  }
  async stop(externalID) {
    const id = freshID(externalID);
    this.store.tombstone(id);
    return this.exclusive(id, async () => {
      let record, metadataError;
      try { record = this.store.read(id); } catch (error) { metadataError = error; }
      if (record?.stopReceipt) return publicStopRecord(record);
      const receipt = await this.backend.stop(id);
      if (metadataError) throw metadataError;
      record ||= { contractVersion: 1, serverID: this.store.identity(), id, input: null, createdAt: Date.now() };
      record.phase = 'stopped'; record.stopReceipt = receipt;
      this.store.save(record);
      return publicStopRecord(record);
    });
  }
  async terminal(externalID) {
    const id = freshID(externalID);
    if (!this.store.read(id) || this.store.tombstoned(id)) fail('fresh session is stopped or missing');
    await this.backend.confirmRunning(id);
    return { socket: this.backend.socket(id), name: 'throttle-' + id };
  }
  async signal(externalID, signal) {
    const id = freshID(externalID);
    if (!this.store.read(id) || this.store.tombstoned(id)) fail('fresh session is stopped or missing');
    await this.backend.signal(id, signal);
  }
}

function requireFreshUnit(id) {
  if (!UUID.test(id) || fs.readFileSync('/proc/self/cgroup', 'utf8').trim()
      !== '0::/system.slice/throttle-session-' + id + '.service') fail('fresh helper is outside its process scope');
}

export async function launchFresh(root, unusedWorkspaceRoot, id) {
  requireFreshUnit(id);
  const store = new FreshSessionStore(root), record = store.read(id);
  if (!record || store.tombstoned(id)) fail('fresh session launch refused');
  fs.mkdirSync(record.input.cwd, { recursive: true });
  const socket = new FreshSessionBackend(store).socket(id);
  if (fs.existsSync(socket)) fail('fresh terminal socket already exists');
  const command = [process.execPath, process.argv[1], '--fresh-native', root, unusedWorkspaceRoot, id].map(quote).join(' ');
  if (store.tombstoned(id)) fail('fresh session stopped before terminal launch');
  await exec('tmux', ['-S', socket, '-f', '/dev/null', '-u', 'new-session', '-d', '-s', 'throttle-' + id, command],
    { timeout: 10000, env: { ...process.env, HOME: os.homedir(), LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8' } });
}

export async function runFreshNative(root, unusedWorkspaceRoot, id) {
  requireFreshUnit(id);
  const store = new FreshSessionStore(root), record = store.read(id);
  if (!record || store.tombstoned(id)) fail('fresh native writer refused');
  return spawnFreshCommand(record);
}

function publicStopRecord(record) {
  const { launch, ...result } = record;
  return result;
}

function validateLaunch(launch) {
  if (!launch || typeof launch.command !== 'string' || !launch.command.trim()
      || Buffer.byteLength(launch.command) > 8192 || /[\0\r\n]/.test(launch.command)
      || typeof launch.oauthFile !== 'string' || !path.isAbsolute(launch.oauthFile)
      || launch.oauthFile.length > 4096 || /[\0\r\n]/.test(launch.oauthFile)) fail('invalid configured fresh command');
}

function configuredLaunch(runtime, environment) {
  const key = runtime === 'claude' ? 'THROTTLE_AGENT_CLAUDE_CMD' : 'THROTTLE_AGENT_CODEX_CMD';
  const launch = { command: environment[key] ?? runtime,
    oauthFile: environment.THROTTLE_AGENT_OAUTH_TOKEN_FILE || '/opt/throttle-agent/claude-oauth-token' };
  validateLaunch(launch);
  return launch;
}

// Uses only the trusted descriptor captured in the private journal, never HTTP input
// or the helper's (different) systemd environment. Custom commands receive no CLI flags.
export async function spawnFreshCommand(record, options = {}) {
  validateLaunch(record.launch);
  const input = record.input;
  const launch = record.launch.command + (input.runtime === 'claude' && record.launch.command === 'claude'
    ? ' --session-id ' + quote(input.nativeSessionID) : '');
  const oauthFile = record.launch.oauthFile;
  const oauth = 'if [ -r ' + quote(oauthFile) + ' ]; then CLAUDE_CODE_OAUTH_TOKEN="$(cat '
    + quote(oauthFile) + ')"; export CLAUDE_CODE_OAUTH_TOKEN; fi;';
  const command = 'cd ' + quote(input.cwd) + ' || exit 1; ' + oauth + ' exec ' + launch;
  return await new Promise((resolve, reject) => {
    const child = spawn('bash', ['-lc', command], { stdio: options.stdio || 'inherit',
      env: { ...process.env, HOME: os.homedir(), LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8' } });
    child.once('error', reject);
    child.once('exit', (code, signal) => resolve(code ?? (signal ? 128 : 1)));
  });
}

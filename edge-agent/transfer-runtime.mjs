// The v2 transfer journal owns session continuity. tmux is only the PTY transport;
// its isolated server and the native writer are children of one systemd unit.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { pipeline } from 'node:stream/promises';
import { Transform } from 'node:stream';

const exec = promisify(execFile);
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const SHA = /^[a-f0-9]{64}$/;
const MAX_BYTES = 128 * 1024 * 1024;
const fail = (message, code = 409) => { throw Object.assign(new Error(message), { code }); };
const shellQuote = value => `'${String(value).replaceAll("'", "'\\''")}'`;
const unitQuote = value => '"' + String(value).replaceAll('\\', '\\\\').replaceAll('"', '\\"')
  .replaceAll('%', '%%').replaceAll('$', () => '$$') + '"';

function durableDirectory(directory) {
  try {
    if (!fs.statSync(directory).isDirectory()) fail('journal path is not a directory');
    return;
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const parent = path.dirname(directory);
  durableDirectory(parent);
  fs.mkdirSync(directory, { mode: 0o700 });
  const fd = fs.openSync(parent, 'r');
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}

export function durableWrite(file, data) {
  durableDirectory(path.dirname(file));
  const tmp = `${file}.${crypto.randomUUID()}.tmp`;
  let fd;
  try {
    fd = fs.openSync(tmp, 'wx', 0o600);
    fs.writeFileSync(fd, data);
    fs.fsyncSync(fd);
    fs.closeSync(fd); fd = undefined;
    fs.renameSync(tmp, file);
    const dir = fs.openSync(path.dirname(file), 'r');
    try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
    fs.rmSync(tmp, { force: true });
  }
}

// Immutable metadata is linked into place only after its contents are durable.
// A retry may observe the same bytes, but can never replace the accepted binding.
function durablePublish(file, data) {
  durableDirectory(path.dirname(file));
  const temporary = `${file}.${crypto.randomUUID()}.pending`;
  try {
    const descriptor = fs.openSync(temporary, 'wx', 0o600);
    try { fs.writeFileSync(descriptor, data); fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
    try { fs.linkSync(temporary, file); } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      const stat = fs.lstatSync(file);
      if (!stat.isFile() || stat.size > 32768 || fs.readFileSync(file, 'utf8') !== data) {
        fail('immutable transfer binding changed');
      }
    }
    const directory = fs.openSync(path.dirname(file), 'r');
    try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
  } finally { fs.rmSync(temporary, { force: true }); }
}

export async function fileHash(file) {
  const hash = crypto.createHash('sha256');
  for await (const bytes of fs.createReadStream(file)) hash.update(bytes);
  return hash.digest('hex');
}

export class TransferStore {
  constructor(root, workspaceRoot) { this.root = root; this.workspaceRoot = workspaceRoot; }
  identity() {
    const file = path.join(this.root, 'identity.json');
    if (!fs.existsSync(file)) {
      if (fs.existsSync(this.root) && fs.readdirSync(this.root).some(name => UUID.test(name))) {
        fail('server identity missing from existing journal');
      }
      durableWrite(file, JSON.stringify({ serverID: crypto.randomUUID() }));
    }
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!UUID.test(value.serverID || '')) fail('invalid server identity');
    return value.serverID;
  }
  directory(id) { if (!UUID.test(id)) fail('transfer id must be a lowercase UUID', 400); return path.join(this.root, id); }
  file(id, name) { return path.join(this.directory(id), name); }
  read(id) {
    const file = this.file(id, 'record.json');
    try {
      const stat = fs.lstatSync(file);
      if (!stat.isFile() || stat.size > 32768) fail('invalid transfer journal');
      const record = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (record.contractVersion !== 2 || record.id !== id || record.serverID !== this.identity()
          || !['prepared', 'starting', 'remote', 'stopped', 'frozen', 'returned'].includes(record.phase)) fail('invalid transfer journal');
      if (record.stopReceipt) {
        const proof = record.stopReceipt;
        if (!['stopped', 'frozen', 'returned'].includes(record.phase) || !this.tombstoned(id)
            || !UUID.test(proof.bootID || '') || proof.unit !== `throttle-transfer-${id}.service`
            || proof.controlGroup !== `/system.slice/${proof.unit}` || proof.populated !== 0
            || !['inactive', 'failed'].includes(proof.activeState) || !Number.isFinite(proof.observedAt)
            || (proof.invocationID !== null && !/^[a-f0-9]{32}$/.test(proof.invocationID || ''))) {
          fail('invalid stop receipt');
        }
      } else if (['stopped', 'frozen', 'returned'].includes(record.phase)) fail('stopped state has no receipt');
      if (['frozen', 'returned'].includes(record.phase)) {
        validateFrozenShape(record, record.frozen);
        if (!this.returnSealed(id)) fail('return worker is not sealed');
        if (record.phase === 'returned' && (!record.acknowledgement
            || record.acknowledgement.transcript !== record.frozen.transcript.sha256
            || record.acknowledgement.repo !== record.frozen.repo.sha256
            || !Number.isFinite(record.acknowledgement.observedAt) || record.acknowledgement.observedAt <= 0)) {
          fail('invalid return acknowledgement');
        }
      } else if (record.frozen || record.acknowledgement) fail('invalid return phase');
      if (record.input === null) {
        if (!record.stopReceipt) fail('missing transfer input');
      } else {
        const input = record.input;
        if (!input || input.id !== id || !UUID.test(input.nativeSessionID || '')
            || !['claude', 'codex'].includes(input.runtime) || !SHA.test(input.baselineSHA256 || '')
            || input.remoteCwd !== path.join(this.workspaceRoot, id)
            || !path.isAbsolute(input.sourceCwd || '') || path.basename(input.filename || '') !== input.filename) {
          fail('invalid transfer binding');
        }
      }
      const binding = this.binding(id);
      if (binding && JSON.stringify(record.input) !== JSON.stringify(binding.input)) {
        fail('mutable transfer record contradicts immutable binding');
      }
      return record;
    } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  }
  all(excludingID = null) {
    if (!fs.existsSync(this.root)) return [];
    const entries = fs.readdirSync(this.root, { withFileTypes: true });
    if (entries.length > 4096) fail('transfer journal is full');
    return entries.filter(entry => UUID.test(entry.name) && entry.name !== excludingID).map(entry => {
      if (!entry.isDirectory()) fail('invalid transfer journal entry');
      const record = this.read(entry.name);
      if (!record) fail('incomplete transfer journal');
      return record;
    }).filter(Boolean);
  }
  save(record) { durableWrite(this.file(record.id, 'record.json'), JSON.stringify(record)); }
  tombstoned(id) { return fs.existsSync(this.file(id, 'stopped')); }
  returnSealed(id) { return fs.existsSync(this.file(id, 'return-sealed')); }
  sealReturn(id) { if (!this.returnSealed(id)) durableWrite(this.file(id, 'return-sealed'), 'no more capture starts\n'); }
  tombstone(id) {
    // This file is monotone and never removed. Mutable status cannot undo it.
    this.identity();
    if (!this.tombstoned(id)) durableWrite(this.file(id, 'stopped'), 'no further writer starts\n');
  }
  validateInput(raw) {
    const id = String(raw?.id || '');
    const runtime = raw?.runtime;
    const nativeSessionID = String(raw?.nativeSessionID || '').toLowerCase();
    if (!UUID.test(id) || !UUID.test(nativeSessionID) || !['claude', 'codex'].includes(runtime)) {
      fail('exact transfer and native identities required', 400);
    }
    if (!SHA.test(raw.baselineSHA256 || '') || !path.isAbsolute(raw.sourceCwd || '')
        || String(raw.sourceCwd).length > 4096 || String(raw.sourceCwd).includes('\0')) fail('invalid source binding', 400);
    const remoteCwd = path.join(this.workspaceRoot, id);
    if (raw.remoteCwd !== remoteCwd) fail('workspace must match this transfer', 400);
    const filename = String(raw.filename || '');
    if (Buffer.byteLength(filename) > 255 || /[\x00-\x1f\x7f]/.test(filename)) fail('invalid transcript filename', 400);
    const codexName = new RegExp(`^rollout-(\\d{4})-(\\d{2})-(\\d{2})T[^/\\\\]+-${nativeSessionID}\\.jsonl$`);
    if (runtime === 'claude' ? filename.toLowerCase() !== `${nativeSessionID}.jsonl` : !codexName.test(filename)) {
      fail('transcript filename does not match native identity', 400);
    }
    const input = { id, runtime, nativeSessionID, sourceCwd: raw.sourceCwd, remoteCwd, filename,
      baselineSHA256: raw.baselineSHA256, project: String(raw.project || '').slice(0, 256) };
    return input;
  }
  binding(id) {
    const file = this.file(id, 'binding.json');
    let stat;
    try { stat = fs.lstatSync(file); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
    if (!stat.isFile() || stat.size > 32768) fail('invalid immutable transfer binding');
    const binding = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (binding.contractVersion !== 2 || binding.id !== id || binding.input?.id !== id || binding.serverID !== this.identity()
        || !Number.isFinite(binding.createdAt) || binding.createdAt <= 0
        || JSON.stringify(this.validateInput(binding.input)) !== JSON.stringify(binding.input)) {
      fail('invalid immutable transfer binding');
    }
    return binding;
  }
  preserveBinding(record) {
    const binding = { contractVersion: 2, serverID: record.serverID, id: record.id,
      input: record.input, createdAt: record.createdAt };
    durablePublish(this.file(record.id, 'binding.json'), JSON.stringify(binding));
  }
  prepare(raw) {
    const input = this.validateInput(raw);
    const { id, runtime, nativeSessionID } = input;
    if (this.tombstoned(id)) fail('transfer has a durable stop tombstone');
    const existing = this.read(id);
    if (existing) {
      if (JSON.stringify(existing.input) !== JSON.stringify(input)) fail('transfer id reused with different input');
      return existing;
    }
    const records = this.all();
    if (records.filter(record => !record.stopReceipt).length >= 32) fail('too many unresolved transfers');
    if (records.some(record => record.input?.runtime === runtime && record.input?.nativeSessionID === nativeSessionID
        && record.phase !== 'returned')) fail('native session already claimed by another transfer');
    const record = { contractVersion: 2, serverID: this.identity(), id, input, phase: 'prepared', createdAt: Date.now() };
    this.preserveBinding(record);
    this.save(record);
    return record;
  }
}

/// Legacy repository/session endpoints cannot write inside a managed transfer.
export function requireUnmanagedWorkspace(store, cwd) {
  if (typeof cwd !== 'string' || !path.isAbsolute(cwd) || cwd.includes('\0')) fail('absolute cwd required', 400);
  const canonical = location => {
    const tail = [];
    let current = path.resolve(location);
    while (!fs.existsSync(current)) { tail.unshift(path.basename(current)); current = path.dirname(current); }
    return path.join(fs.realpathSync(current), ...tail);
  };
  const target = canonical(cwd);
  for (const root of [store.root, store.workspaceRoot].map(canonical)) {
    if (target === root || target.startsWith(root + path.sep)) fail('use the v2 transfer endpoint for this workspace', 426);
  }
}

export class SystemdTransferBackend {
  constructor(store, options = {}) {
    this.store = store;
    this.unitRoot = options.unitRoot || '/run/systemd/system';
    this.script = options.script || process.argv[1];
    this.home = options.home || os.homedir();
    this.purpose = options.purpose || 'transfer';
    if (!['transfer', 'return'].includes(this.purpose)) fail('invalid unit purpose');
  }
  unit(id) { this.store.directory(id); return `throttle-${this.purpose}-${id}.service`; }
  runtimeDirectory(id) { return this.unit(id).slice(0, -'.service'.length); }
  // Linux sockaddr_un has a short fixed path limit. Journal roots may be long;
  // the unit-owned runtime directory gives every caller the same bounded socket.
  socket(id) { return path.join('/run', this.runtimeDirectory(id), 'terminal.sock'); }
  bootID() { return fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim(); }
  async ready() {
    if (process.platform !== 'linux' || !fs.existsSync('/sys/fs/cgroup/cgroup.controllers')) return false;
    try {
      await exec('systemctl', ['show', '--property=Version'], { timeout: 5000 });
      await exec('tmux', ['-V'], { timeout: 5000 });
      return fs.existsSync(this.unitRoot);
    } catch { return false; }
  }
  definition(id) {
    // No external launcher: even a delayed StartUnit creates the helper inside
    // the same cgroup. A tombstoned helper exits nonzero before spawning tmux.
    return `[Unit]\nDescription=Throttle transfer ${id}\n[Service]\nType=oneshot\nRemainAfterExit=yes\n`
      + `KillMode=control-group\nSendSIGKILL=yes\nTimeoutStartSec=120\nTimeoutStopSec=5\nRestart=no\n`
      + `RuntimeDirectory=${this.runtimeDirectory(id)}\nRuntimeDirectoryMode=0700\n`
      + `Slice=system.slice\nDelegate=no\nUMask=0077\nEnvironment=${unitQuote('HOME=' + this.home).replaceAll('$$', () => '$')}\n`
      + `ExecStart=${unitQuote(process.execPath)} ${unitQuote(this.script)} --${this.purpose === 'return' ? 'transfer-freeze' : 'transfer-launch'} `
      + `${unitQuote(this.store.root)} ${unitQuote(this.store.workspaceRoot)} ${id}\n`;
  }
  async install(id) {
    durableWrite(path.join(this.unitRoot, this.unit(id)), this.definition(id));
    await exec('systemctl', ['daemon-reload'], { timeout: 15000 });
  }
  async start(id) { await exec('systemctl', ['start', this.unit(id)], { timeout: 125000 }); }
  async state(id) {
    let stdout;
    try {
      ({ stdout } = await exec('systemctl', ['show', this.unit(id),
        '--property=LoadState,ActiveState,SubState,InvocationID,ControlGroup,MainPID'], { timeout: 5000 }));
    } catch (error) {
      // show may return a nonzero status with an explicit not-found state.
      // Transport/permission failures and partial replies remain unresolved.
      if (typeof error.stdout !== 'string' || !/^LoadState=not-found$/m.test(error.stdout)) throw error;
      stdout = error.stdout;
    }
    const fields = Object.fromEntries(stdout.trim().split('\n').map(line => {
      const at = line.indexOf('='); return [line.slice(0, at), line.slice(at + 1)];
    }));
    if (!['loaded', 'not-found'].includes(fields.LoadState) || !fields.ActiveState) fail('unit state unavailable');
    return { bootID: this.bootID(), ...fields };
  }
  async stop(id) {
    const before = await this.state(id);
    if (before.LoadState !== 'not-found') await exec('systemctl', ['stop', this.unit(id)], { timeout: 15000 });
    const after = await this.state(id);
    if (!['inactive', 'failed'].includes(after.ActiveState)) fail('unit stop remains unresolved');
    const expected = `/system.slice/${this.unit(id)}`;
    for (const group of new Set([expected, before.ControlGroup, after.ControlGroup].filter(Boolean))) {
      if (group !== expected) fail('unit cgroup identity changed');
      const events = path.join('/sys/fs/cgroup', group, 'cgroup.events');
      try {
        if (!/^populated 0$/m.test(fs.readFileSync(events, 'utf8'))) fail('unit cgroup is still populated');
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    return { bootID: after.bootID, invocationID: before.InvocationID || null, unit: this.unit(id),
      controlGroup: expected, activeState: after.ActiveState, populated: 0, observedAt: Date.now() };
  }
  async confirmRunning(id) {
    const state = await this.state(id);
    const expected = `/system.slice/${this.unit(id)}`;
    if (state.ActiveState !== 'active' || state.ControlGroup !== expected
        || !/^[a-f0-9]{32}$/.test(state.InvocationID || '')) fail('unit start remains unresolved');
    const { stdout } = await exec('tmux', ['-S', this.socket(id), 'display-message', '-p',
      '-t', `throttle-${id}`, '#{pid}|#{pane_pid}'], { timeout: 5000 });
    const pids = stdout.trim().split('|');
    if (pids.length !== 2 || pids.some(pid => !/^[1-9][0-9]+$/.test(pid))) fail('tmux process identity unavailable');
    for (const pid of pids) {
      const before = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
      const group = fs.readFileSync(`/proc/${pid}/cgroup`, 'utf8').trim();
      const after = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
      const started = stat => stat.slice(stat.lastIndexOf(')') + 2).split(' ')[19];
      if (group !== `0::${expected}` || started(before) !== started(after)) fail('tmux process is outside the unit');
    }
    return state;
  }
  async freeze(id) {
    const worker = new SystemdTransferBackend(this.store, {
      unitRoot: this.unitRoot, script: this.script, home: this.home, purpose: 'return'
    });
    // Reconcile a possibly interrupted previous worker before starting another.
    await worker.stop(id);
    const draft = this.store.file(id, 'return-draft.json');
    if (!fs.existsSync(draft)) {
      if (this.store.returnSealed(id)) fail('sealed return has no draft; recovery required');
      await worker.install(id);
      try { await worker.start(id); } finally {
        if (fs.existsSync(draft)) this.store.sealReturn(id);
        await worker.stop(id);
      }
    } else {
      this.store.sealReturn(id);
      await worker.stop(id);
    }
    const stat = fs.lstatSync(draft);
    if (!stat.isFile() || stat.size > 32768) fail('invalid return draft');
    return JSON.parse(fs.readFileSync(draft, 'utf8'));
  }
  async signal(id, signal) {
    if (!['SIGSTOP', 'SIGCONT'].includes(signal)) fail('unsupported signal', 400);
    await exec('systemctl', ['kill', '--kill-who=all', `--signal=${signal}`, this.unit(id)], { timeout: 5000 });
  }
}

export function nativeTranscriptPath(input, home) {
  if (input.runtime === 'claude') return path.join(home, '.claude', 'projects',
    input.remoteCwd.replace(/[^A-Za-z0-9-]/g, '-'), input.filename);
  const date = /^rollout-(\d{4})-(\d{2})-(\d{2})T/.exec(input.filename);
  if (!date) fail('invalid Codex rollout filename');
  return path.join(home, '.codex', 'sessions', ...date.slice(1), input.filename);
}

export function requireTranscriptIdentity(file, input) {
  const fd = fs.openSync(file, 'r');
  try {
    const bytes = Buffer.alloc(64 * 1024);
    const length = fs.readSync(fd, bytes, 0, bytes.length, 0);
    for (const line of bytes.subarray(0, length).toString('utf8').split('\n').slice(0, 12)) {
      let object;
      try { object = JSON.parse(line); } catch { continue; }
      const metadata = input.runtime === 'codex' ? (object.type === 'session_meta' ? object.payload : null) : object;
      const id = input.runtime === 'codex' ? metadata?.id : metadata?.sessionId;
      if (typeof id === 'string' && id.toLowerCase() === input.nativeSessionID
          && [input.sourceCwd, input.remoteCwd].includes(metadata?.cwd)) return;
    }
    fail('transcript metadata does not bind the requested runtime, native identity and cwd');
  } finally { fs.closeSync(fd); }
}

export async function publishNativeTranscript(source, destination, input) {
  requireTranscriptIdentity(source, input);
  if (await fileHash(source) !== input.baselineSHA256) fail('staged transcript hash changed');
  durableDirectory(path.dirname(destination));
  const temporary = `${destination}.${crypto.randomUUID()}.incoming`;
  try {
    fs.copyFileSync(source, temporary, fs.constants.COPYFILE_EXCL);
    fs.chmodSync(temporary, 0o600);
    const fd = fs.openSync(temporary, 'r');
    try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    if (await fileHash(temporary) !== input.baselineSHA256) fail('native transcript staging hash mismatch');
    try { fs.linkSync(temporary, destination); } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      if (!fs.lstatSync(destination).isFile() || await fileHash(destination) !== input.baselineSHA256) {
        fail('native transcript already differs');
      }
    }
    const dir = fs.openSync(path.dirname(destination), 'r');
    try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
  } finally { fs.rmSync(temporary, { force: true }); }
}

function requireUnit(id, purpose = 'transfer') {
  const expected = `0::/system.slice/throttle-${purpose}-${id}.service`;
  if (fs.readFileSync('/proc/self/cgroup', 'utf8').trim() !== expected) fail('writer is outside its transfer unit');
}

export async function launchTransfer(root, workspaceRoot, id) {
  const store = new TransferStore(root, workspaceRoot);
  const record = store.read(id);
  if (!record || store.tombstoned(id)) fail('transfer launch refused');
  requireUnit(id);
  // Preparation belongs to this unit too: git, filters and their descendants
  // must be gone before the unit's stop receipt can freeze the working tree.
  const incoming = store.file(id, 'incoming.bundle');
  if (await fileHash(incoming) !== record.repoSHA256) fail('staged repository hash changed');
  await publishNativeTranscript(store.file(id, 'incoming.jsonl'),
    nativeTranscriptPath(record.input, os.homedir()), record.input);
  if (fs.existsSync(record.input.remoteCwd)) fail('transfer workspace already exists');
  await exec('git', ['clone', incoming, record.input.remoteCwd], { timeout: 100000 });
  const remoteRef = `refs/throttle/transfers/${id}/outbound`;
  await exec('git', ['-C', record.input.remoteCwd, 'fetch', '--no-tags', incoming, `${remoteRef}:${remoteRef}`], { timeout: 15000 });
  await exec('git', ['-C', record.input.remoteCwd, 'checkout', '--detach', remoteRef], { timeout: 15000 });
  if (store.tombstoned(id)) fail('transfer stopped during preparation');
  const socket = new SystemdTransferBackend(store).socket(id);
  if (fs.existsSync(socket)) fail('transfer tmux socket already exists');
  const command = [process.execPath, process.argv[1], '--transfer-native', root, workspaceRoot, id]
    .map(shellQuote).join(' ');
  await exec('tmux', ['-S', socket, '-f', '/dev/null', '-u', 'new-session', '-d',
    '-s', `throttle-${id}`, command], {
    timeout: 10000, env: { ...process.env, HOME: os.homedir(), LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8' }
  });
}

export async function runTransferNative(root, workspaceRoot, id) {
  const store = new TransferStore(root, workspaceRoot);
  const record = store.read(id);
  if (!record || store.tombstoned(id)) fail('transfer writer refused');
  requireUnit(id); // An existing foreign tmux server must never launch this writer.
  const input = record.input;
  const binary = input.runtime === 'codex' ? 'codex' : 'claude';
  const args = input.runtime === 'codex' ? `resume ${shellQuote(input.nativeSessionID)}` : `--resume ${shellQuote(input.nativeSessionID)}`;
  const oauthFile = process.env.THROTTLE_AGENT_OAUTH_TOKEN_FILE || '/opt/throttle-agent/claude-oauth-token';
  const oauth = `if [ -r ${shellQuote(oauthFile)} ]; then CLAUDE_CODE_OAUTH_TOKEN="$(cat ${shellQuote(oauthFile)})"; export CLAUDE_CODE_OAUTH_TOKEN; fi;`;
  const command = `cd ${shellQuote(input.remoteCwd)} || exit 1; ${oauth} exec ${binary} ${args}`;
  return await new Promise((resolve, reject) => {
    const child = spawn('bash', ['-lc', command], { stdio: 'inherit',
      env: { ...process.env, HOME: os.homedir(), LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8' } });
    child.once('error', reject);
    child.once('exit', (code, signal) => resolve(code ?? (signal ? 128 : 1)));
  });
}

// Called only after the native writer's stop receipt, inside a separate bounded
// unit. Its output is not downloadable until that unit and its children stop.
export async function freezeTransfer(root, workspaceRoot, id) {
  requireUnit(id, 'return');
  const store = new TransferStore(root, workspaceRoot);
  const record = store.read(id);
  if (!record?.input || record.phase !== 'stopped' || !record.stopReceipt || !store.tombstoned(id)
      || store.returnSealed(id) || fs.existsSync(store.file(id, 'return-draft.json'))) fail('return capture is closed or not stopped');
  const result = await snapshotTransfer(store, record, os.homedir());
  store.sealReturn(id);
  return result;
}

export async function snapshotTransfer(store, record, home) {
  const input = record.input;
  const attempts = fs.readdirSync(store.directory(record.id)).filter(name => name.startsWith('return-') && UUID.test(name.slice(7)));
  if (attempts.length >= 8) fail('interrupted returns need recovery before another attempt');
  const attempt = 'return-' + crypto.randomUUID();
  const directory = store.file(record.id, attempt);
  durableDirectory(directory);
  const source = nativeTranscriptPath(input, home);
  const stat = fs.lstatSync(source);
  if (!stat.isFile() || stat.size < 1 || stat.size > MAX_BYTES) fail('native transcript unavailable or too large');
  requireTranscriptIdentity(source, input);
  const transcript = path.join(directory, 'transcript.jsonl');
  fs.copyFileSync(source, transcript, fs.constants.COPYFILE_EXCL);
  const env = { ...process.env, GIT_INDEX_FILE: path.join(directory, 'index'),
    GIT_AUTHOR_NAME: 'Throttle', GIT_AUTHOR_EMAIL: 'transfer@localhost',
    GIT_COMMITTER_NAME: 'Throttle', GIT_COMMITTER_EMAIL: 'transfer@localhost' };
  const git = async args => (await exec('git', ['-C', input.remoteCwd, ...args], {
    env, timeout: 100000, maxBuffer: 65536
  })).stdout.trim();
  if (fs.realpathSync(await git(['rev-parse', '--show-toplevel'])) !== fs.realpathSync(input.remoteCwd)) {
    fail('return repository root changed');
  }
  await git(['read-tree', 'HEAD']);
  await git(['add', '-A', '.']);
  const include = path.join(input.remoteCwd, '.throttleinclude');
  if (fs.existsSync(include)) {
    const info = fs.lstatSync(include);
    if (!info.isFile() || info.size > 65536) fail('invalid .throttleinclude');
    for (const line of fs.readFileSync(include, 'utf8').split('\n').map(line => line.trim())) {
      if (line && !line.startsWith('#')) await git(['add', '-f', '--', line]);
    }
  }
  const tree = await git(['write-tree']);
  const head = await git(['rev-parse', 'HEAD']);
  const commit = await git(['commit-tree', tree, '-p', head, '-m', 'Throttle return snapshot']);
  const ref = `refs/throttle/transfers/${record.id}/return`;
  await git(['update-ref', ref, commit]);
  const repo = path.join(directory, 'repo.bundle');
  await git(['bundle', 'create', repo, ref]);
  const artifact = async file => {
    const size = fs.lstatSync(file).size;
    if (size < 1 || size > MAX_BYTES) fail('return file exceeds 128 MiB');
    fs.chmodSync(file, 0o400);
    const fd = fs.openSync(file, 'r');
    try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    return { bytes: size, sha256: await fileHash(file) };
  };
  const manifest = { attempt, transcript: await artifact(transcript), repo: await artifact(repo), tree, commit, ref };
  const descriptor = fs.openSync(directory, 'r');
  try { fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
  // Draft publication synchronizes the directory chain after both file fsyncs.
  durableWrite(store.file(record.id, 'return-draft.json'), JSON.stringify(manifest));
  return manifest;
}

function validateFrozenShape(record, frozen) {
  if (!frozen || !/^return-[a-f0-9-]{36}$/.test(frozen.attempt)
      || !UUID.test(frozen.attempt.slice(7)) || !/^[a-f0-9]{40,64}$/.test(frozen.tree || '')
      || !/^[a-f0-9]{40,64}$/.test(frozen.commit || '')
      || frozen.ref !== `refs/throttle/transfers/${record.id}/return`) fail('invalid return manifest');
  for (const kind of ['transcript', 'repo']) {
    const expected = frozen[kind];
    if (!expected || !SHA.test(expected.sha256 || '') || !Number.isSafeInteger(expected.bytes)
        || expected.bytes < 1 || expected.bytes > MAX_BYTES) fail('invalid return artifact');
  }
}

async function validateFrozen(store, record, frozen) {
  validateFrozenShape(record, frozen);
  for (const [kind, name] of [['transcript', 'transcript.jsonl'], ['repo', 'repo.bundle']]) {
    const expected = frozen[kind];
    const file = store.file(record.id, path.join(frozen.attempt, name));
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.size !== expected.bytes || await fileHash(file) !== expected.sha256) {
      fail('frozen return artifact changed');
    }
  }
  requireTranscriptIdentity(store.file(record.id, path.join(frozen.attempt, 'transcript.jsonl')), record.input);
}

export class TransferCoordinator {
  constructor(store, backend) { this.store = store; this.backend = backend; this.locks = new Map(); }
  async exclusive(id, operation) {
    const previous = this.locks.get(id) || Promise.resolve();
    const current = previous.catch(() => {}).then(operation);
    this.locks.set(id, current);
    try { return await current; } finally { if (this.locks.get(id) === current) this.locks.delete(id); }
  }
  prepare(raw) { return this.store.prepare(raw); }
  async upload(id, stream, kind) {
    return this.exclusive(id, async () => {
      const record = this.store.read(id);
      if (!record || record.phase !== 'prepared' || this.store.tombstoned(id)) fail('transfer is not accepting uploads');
      const target = this.store.file(id, kind === 'transcript' ? 'incoming.jsonl' : 'incoming.bundle');
      const tmp = `${target}.${crypto.randomUUID()}.tmp`;
      let count = 0;
      const hash = crypto.createHash('sha256');
      const limit = new Transform({ transform(chunk, _, done) {
        count += chunk.length;
        if (count > MAX_BYTES) return done(Object.assign(new Error('transfer exceeds 128 MiB'), { code: 413 }));
        hash.update(chunk); done(null, chunk);
      } });
      try {
        await pipeline(stream, limit, fs.createWriteStream(tmp, { flags: 'wx', mode: 0o600 }));
        if (!count) fail('empty transfer file', 400);
        const digest = hash.digest('hex');
        if (kind === 'transcript' && digest !== record.input.baselineSHA256) fail('transcript hash mismatch');
        if (fs.existsSync(target)) {
          if (await fileHash(target) !== digest) fail('conflicting repeated upload');
        } else {
          const fd = fs.openSync(tmp, 'r');
          try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
          fs.renameSync(tmp, target);
        }
        record[kind === 'transcript' ? 'transcriptSHA256' : 'repoSHA256'] = digest;
        this.store.save(record);
        return { bytes: count, sha256: digest };
      } finally { fs.rmSync(tmp, { force: true }); }
    });
  }
  transcriptPath(input) { return nativeTranscriptPath(input, this.backend.home); }
  async start(id) {
    return this.exclusive(id, async () => {
      let record = this.store.read(id);
      if (!record || this.store.tombstoned(id)) fail('transfer has been stopped');
      if (record.phase !== 'prepared') return record; // Never retry a possibly submitted start.
      if (!record.transcriptSHA256 || !record.repoSHA256) fail('transcript and repository must both be staged');
      if (!(await this.backend.ready())) fail('systemd with cgroup v2 and tmux required', 503);
      record.phase = 'starting'; record.bootID = this.backend.bootID();
      this.store.save(record); // Uncertainty survives a crash at every following await.
      await this.backend.install(id);
      await this.backend.start(id);
      record = this.store.read(id);
      if (this.store.tombstoned(id)) fail('transfer stopped while starting');
      const state = await this.backend.confirmRunning(id);
      record.phase = 'remote'; record.unitState = state;
      this.store.save(record);
      return record;
    });
  }
  async freeze(id) {
    await this.stop(id);
    return this.exclusive(id, async () => {
      const record = this.store.read(id);
      if (!record?.input || !record.stopReceipt) fail('return metadata is missing; keep both copies');
      if (!record.frozen) {
        const frozen = await this.backend.freeze(id);
        this.store.sealReturn(id);
        await validateFrozen(this.store, record, frozen);
        record.frozen = frozen; record.phase = 'frozen';
        this.store.save(record);
      } else { await validateFrozen(this.store, record, record.frozen); }
      return record;
    });
  }
  async download(id, kind) {
    const record = this.store.read(id);
    if (!record?.frozen || !['frozen', 'returned'].includes(record.phase) || !['transcript', 'repo'].includes(kind)) {
      fail('return is not frozen');
    }
    await validateFrozen(this.store, record, record.frozen);
    return { file: this.store.file(id, path.join(record.frozen.attempt, kind === 'transcript' ? 'transcript.jsonl' : 'repo.bundle')),
      ...record.frozen[kind] };
  }
  async acknowledge(id, hashes) {
    return this.exclusive(id, async () => {
      const record = this.store.read(id);
      if (!record?.frozen || !record.stopReceipt || hashes?.transcript !== record.frozen.transcript.sha256
          || hashes?.repo !== record.frozen.repo.sha256) fail('verified return hashes required');
      await validateFrozen(this.store, record, record.frozen);
      record.acknowledgement = { transcript: hashes.transcript, repo: hashes.repo, observedAt: Date.now() };
      record.phase = 'returned';
      this.store.save(record);
      return record;
    });
  }
  async list() {
    const records = this.store.all().filter(record => record.input && !record.stopReceipt);
    const result = [];
    // Bound subprocess fan-out on a small host. A failed observation is shown
    // explicitly, never treated as a stop receipt or permission for local resume.
    for (let offset = 0; offset < records.length; offset += 4) {
      const batch = await Promise.all(records.slice(offset, offset + 4).map(async record => {
        let state = record.phase === 'prepared' ? 'pending' : 'unverified';
        if (record.phase !== 'prepared') {
          try {
            const observed = await this.backend.state(record.id);
            state = observed.ActiveState === 'active' ? 'remote' : 'ended';
          } catch { /* keep unknown rather than inferring termination */ }
        }
        let transcriptBytes = null;
        try { transcriptBytes = fs.statSync(this.transcriptPath(record.input)).size; } catch {}
        return { id: record.id, project: record.input.project, cwd: record.input.remoteCwd,
          runtime: record.input.runtime, nativeSessionID: record.input.nativeSessionID,
          state, model: null, tokens: null, startedAt: Math.floor(record.createdAt / 1000), transcriptBytes };
      }));
      result.push(...batch);
    }
    return result;
  }
  async stop(id) {
    // Monotone file is written synchronously before waiting for the start queue.
    this.store.tombstone(id);
    return this.exclusive(id, async () => {
      let record, metadataError;
      try { record = this.store.read(id); } catch (error) { metadataError = error; }
      if (record?.stopReceipt) return record;
      const receipt = await this.backend.stop(id);
      // Corrupt metadata cannot keep the process scope alive. Preserve the bad
      // file for recovery and retain local ownership instead of fabricating state.
      if (metadataError) throw metadataError;
      if (!record) {
        // Losing mutable status must not lose the native identity. Recover only
        // after the unit is empty; the immutable record never authorizes start.
        const binding = this.store.binding(id);
        if (binding && this.store.all(id).some(other => other.phase !== 'returned'
            && other.input?.runtime === binding.input.runtime
            && other.input?.nativeSessionID === binding.input.nativeSessionID)) {
          fail('native session is claimed by another transfer; preserve both journals');
        }
        record = binding ? { ...binding, phase: 'stopped' }
          : { contractVersion: 2, serverID: this.store.identity(), id, phase: 'stopped', input: null, createdAt: Date.now() };
      }
      record.phase = 'stopped'; record.stopReceipt = receipt;
      this.store.save(record);
      return record;
    });
  }
}

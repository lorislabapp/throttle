// Explicit Linux-only qualification. No HTTP service or native AI CLI is started.
// --plan is read-only. --execute creates its own journals, workspaces and units.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { Readable } from 'node:stream';
import { FreshSessionStore, FreshSessionBackend, FreshSessions } from './fresh-runtime.mjs';
import { TransferStore, TransferCoordinator, SystemdTransferBackend,
  launchTransfer, freezeTransfer, nativeTranscriptPath } from './transfer-runtime.mjs';

const exec = promisify(execFile), self = fileURLToPath(import.meta.url), source = path.dirname(self);
const quote = value => "'" + String(value).replaceAll("'", "'\\''") + "'";
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const scopes = [], observations = [];
const unitQuote = value => '"' + String(value).replaceAll('\\', '\\\\').replaceAll('"', '\\"')
  .replaceAll('%', '%%').replaceAll('$', () => '$$') + '"';
function save(file, value) {
  const temporary = file + '.pending-' + crypto.randomUUID();
  const fd = fs.openSync(temporary, 'wx', 0o600);
  try { fs.writeFileSync(fd, JSON.stringify(value, null, 2)); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(temporary, file);
  const directory = fs.openSync(path.dirname(file), 'r');
  try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
}
function gitEnvironment(root) {
  return { PATH: '/usr/bin:/bin', HOME: path.join(root, 'home'), LANG: 'C.UTF-8',
    XDG_CONFIG_HOME: path.join(root, 'home', '.config'), GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_TEMPLATE_DIR: path.join(root, 'empty-template') };
}
async function gitRun(root, args, timeout = 15000) {
  return exec('git', ['-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false',
    '-c', 'core.fsmonitor=false', ...args], { timeout, env: gitEnvironment(root) });
}
function watchdogName(root) { return 'throttle-qualification-' + path.basename(root).slice(4); }
async function armWatchdog(root) {
  const name = watchdogName(root), directory = '/run/systemd/system/';
  for (const suffix of ['.service', '.timer']) assert.equal(fs.existsSync(directory + name + suffix), false);
  fs.writeFileSync(directory + name + '.service', '[Unit]\nDescription=Throttle isolated qualification cleanup\n'
    + '[Service]\nType=oneshot\nTimeoutStartSec=90\nKillMode=control-group\nUMask=0077\n'
    + 'ExecStart=' + unitQuote(process.execPath) + ' ' + unitQuote(self) + ' --cleanup ' + unitQuote(root) + '\n',
    { flag: 'wx', mode: 0o600 });
  fs.writeFileSync(directory + name + '.timer', '[Unit]\nDescription=Throttle qualification deadline\n'
    + '[Timer]\nOnActiveSec=180s\nAccuracySec=1s\nUnit=' + name + '.service\n', { flag: 'wx', mode: 0o600 });
  await exec('systemctl', ['daemon-reload'], { timeout: 15000 });
  await exec('systemctl', ['start', name + '.timer'], { timeout: 10000 });
  const { stdout } = await exec('systemctl', ['is-active', name + '.timer'], { timeout: 5000 });
  assert.equal(stdout.trim(), 'active');
}
async function cleanup(root) {
  assertRoot(root);
  // Cancellation precedes the registry snapshot so concurrent registration
  // either appears in this snapshot or observes the marker and stops itself.
  save(path.join(root, 'cancelled.json'), { at: Date.now() });
  const registryFile = path.join(root, 'scopes.json');
  assert.ok(fs.lstatSync(registryFile).isFile() && fs.statSync(registryFile).size <= 32768);
  const registry = JSON.parse(fs.readFileSync(registryFile, 'utf8'));
  assert.ok(Array.isArray(registry) && registry.length <= 4);
  const results = [];
  for (const scope of registry) {
    try {
      assert.match(scope.id, /^[a-f0-9-]{36}$/);
      assert.ok(['fresh-claude-journal', 'fresh-codex-journal', 'transfers'].includes(scope.directory));
      assert.ok(['fresh', 'transfer', 'return'].includes(scope.kind));
      const store = scope.kind === 'fresh' ? new FreshSessionStore(path.join(root, scope.directory), {})
        : new TransferStore(path.join(root, scope.directory), path.join(root, 'workspaces'));
      const backend = scope.kind === 'fresh' ? new FreshSessionBackend(store)
        : new SystemdTransferBackend(store, { purpose: scope.kind });
      // Markers precede StopUnit even if the normal flow failed before it could stop.
      store.tombstone(scope.id);
      if (scope.kind !== 'fresh') store.sealReturn(scope.id);
      const receipt = await backend.stop(scope.id);
      const file = '/run/systemd/system/' + backend.unit(scope.id);
      if (fs.existsSync(file)) fs.unlinkSync(file);
      results.push({ unit: backend.unit(scope.id), receipt });
    } catch (error) { results.push({ id: scope.id, error: error.message }); }
  }
  save(path.join(root, 'cleanup-report.json'), results);
  try { await exec('systemctl', ['daemon-reload'], { timeout: 15000 }); }
  catch (error) { results.push({ error: 'daemon-reload: ' + error.message }); save(path.join(root, 'cleanup-report.json'), results); }
  return results;
}
async function disarmWatchdog(root) {
  const name = watchdogName(root);
  await exec('systemctl', ['stop', name + '.timer', name + '.service'], { timeout: 95000 });
  for (const suffix of ['.timer', '.service']) {
    const file = '/run/systemd/system/' + name + suffix;
    if (fs.existsSync(file)) fs.unlinkSync(file);
  }
  await exec('systemctl', ['daemon-reload'], { timeout: 15000 });
}
function identity(pid) {
  const stat = fs.readFileSync('/proc/' + pid + '/stat', 'utf8');
  return { pid, start: stat.slice(stat.lastIndexOf(')') + 2).split(' ')[19],
    cgroup: fs.readFileSync('/proc/' + pid + '/cgroup', 'utf8').trim() };
}
function assertRoot(root) {
  assert.match(root, /^\/opt\/throttle-qualification\/run-[a-f0-9-]{36}$/);
  assert.equal(process.platform, 'linux');
  assert.equal(process.getuid(), 0);
}
function helperGuard(root, id, purpose) {
  const base = path.dirname(root);
  assertRoot(base);
  assert.equal(os.homedir(), path.join(base, 'home'));
  assert.match(id, /^[a-f0-9-]{36}$/);
  assert.equal(identity(process.pid).cgroup, '0::/system.slice/throttle-' + purpose + '-' + id + '.service');
  // Unit helpers may inherit manager-level Git overrides independently of the driver.
  for (const key of Object.keys(process.env)) { if (key.startsWith('GIT_')) delete process.env[key]; }
  // Fixture helpers also isolate system/global Git configuration, not only HOME.
  Object.assign(process.env, gitEnvironment(base));
}
async function inertWriter(root, id, cwd, child = false) {
  assertRoot(root);
  assert.match(id, /^[a-f0-9-]{36}$/);
  assert.ok(cwd.startsWith(root + '/'));
  assert.match(identity(process.pid).cgroup, new RegExp('^0::/system.slice/throttle-(session|transfer)-' + id + '\\.service$'));
  process.on('SIGTERM', () => {});
  if (!child) {
    fs.writeFileSync(path.join(cwd, 'fixture-work.txt'), 'work produced by the isolated fixture\n');
    const descendant = spawn(process.execPath, [self, '--fixture-child', root, id, cwd], {
      detached: true, stdio: 'ignore', env: { ...process.env, HOME: path.join(root, 'home') }
    });
    descendant.unref();
  }
  fs.writeFileSync(path.join(root, id + (child ? '-child' : '-parent') + '.json'), JSON.stringify(identity(process.pid)));
  const timer = setInterval(() => {}, 1000);
  // Convenience exit only. The external systemd timer handles suspended writers.
  setTimeout(() => { clearInterval(timer); process.exit(0); }, 240000);
}
async function awaitWriters(root, id, unit) {
  const deadline = Date.now() + 15000;
  const files = ['parent', 'child'].map(kind => path.join(root, id + '-' + kind + '.json'));
  while (!files.every(file => fs.existsSync(file)) && Date.now() < deadline) await sleep(100);
  const writers = files.map(file => JSON.parse(fs.readFileSync(file, 'utf8')));
  for (const writer of writers) {
    assert.deepEqual(identity(writer.pid), writer);
    assert.equal(writer.cgroup, '0::/system.slice/' + unit);
  }
  return writers;
}
function assertGone(writers) {
  for (const writer of writers) {
    try { assert.notEqual(identity(writer.pid).start, writer.start, 'original descendant is still present'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}
async function register(backend, id) {
  const root = path.dirname(backend.store.root);
  assert.equal(fs.existsSync(path.join(root, 'cancelled.json')), false);
  const unit = backend.unit(id);
  assert.equal(fs.existsSync('/run/systemd/system/' + unit), false);
  let stdout;
  try { ({ stdout } = await exec('systemctl', ['show', unit, '--property=LoadState', '--value'], { timeout: 5000 })); }
  catch (error) { if (error.stdout?.trim() !== 'not-found') throw error; stdout = error.stdout; }
  assert.equal(stdout.trim(), 'not-found');
  scopes.push({ backend, id, unit });
  save(path.join(root, 'scopes.json'), scopes.map(scope => ({ id: scope.id,
    directory: path.basename(scope.backend.store.root),
    kind: scope.backend instanceof FreshSessionBackend ? 'fresh' : scope.backend.purpose })));
  // A concurrent deadline may have snapshotted the previous registry. Permanently
  // stop this newly registered scope before any caller can install/start it.
  if (fs.existsSync(path.join(root, 'cancelled.json'))) { await cleanup(root); throw new Error('qualification expired'); }
}
async function freshCase(root, runtime) {
  const command = [process.execPath, self, '--fixture-writer', root];
  const id = crypto.randomUUID(), cwd = path.join(root, 'fresh-' + runtime);
  const store = new FreshSessionStore(path.join(root, 'fresh-' + runtime + '-journal'), {
    ['THROTTLE_AGENT_' + runtime.toUpperCase() + '_CMD']: [...command, id, cwd].map(quote).join(' '),
    THROTTLE_AGENT_OAUTH_TOKEN_FILE: path.join(root, 'no-oauth-token')
  });
  const backend = new FreshSessionBackend(store, { script: path.join(source, 'throttle-agent.mjs'),
    home: path.join(root, 'home') });
  assert.equal(await backend.ready(), true);
  await register(backend, id);
  const request = { requestID: id, serverID: store.identity(), runtime, cwd, project: 'Qualification ' + runtime };
  const sessions = new FreshSessions(store, backend);
  const first = await sessions.create(request, new TransferStore(path.join(root, 'unused-transfers'), path.join(root, 'unused-work')));
  assert.equal(first.nativeSessionID, null, 'a configured fixture must not claim a native CLI identity');
  const writers = await awaitWriters(root, id, backend.unit(id));
  const before = await backend.state(id);
  const retry = await new FreshSessions(new FreshSessionStore(store.root, {}), backend)
    .create(request, new TransferStore(path.join(root, 'unused-transfers'), path.join(root, 'unused-work')));
  assert.equal(retry.id, first.id);
  assert.equal((await backend.state(id)).InvocationID, before.InvocationID);
  await sessions.signal(first.id, 'SIGSTOP');
  const pauseDeadline = Date.now() + 5000;
  const paused = () => writers.every(writer => /^[Tt]$/.test(
    fs.readFileSync('/proc/' + writer.pid + '/stat', 'utf8').split(') ')[1].split(' ')[0]));
  while (!paused() && Date.now() < pauseDeadline) await sleep(50);
  assert.equal(paused(), true, 'kernel must confirm both fixture writers are stopped');
  const stopped = await sessions.stop(first.id);
  assert.equal(stopped.stopReceipt.populated, 0);
  assertGone(writers);
  await assert.rejects(sessions.create(request, new TransferStore(path.join(root, 'unused-transfers'), path.join(root, 'unused-work'))));
  observations.push({ case: 'fresh-' + runtime, id, writers, invocationID: before.InvocationID,
    receipt: stopped.stopReceipt, retrySameInvocation: true, stoppedWhilePaused: true });
}
async function transferCase(root) {
  const id = crypto.randomUUID(), nativeSessionID = crypto.randomUUID();
  const store = new TransferStore(path.join(root, 'transfers'), path.join(root, 'workspaces'));
  const backend = new SystemdTransferBackend(store, { script: self, home: path.join(root, 'home') });
  await register(backend, id);
  await register(new SystemdTransferBackend(store, { script: self, home: path.join(root, 'home'), purpose: 'return' }), id);
  const repository = path.join(root, 'source'); fs.mkdirSync(repository);
  const git = async args => (await gitRun(root, ['-C', repository, ...args])).stdout.trim();
  await git(['init']); await git(['config', 'user.name', 'Throttle Qualification']);
  await git(['config', 'user.email', 'qualification@example.invalid']);
  fs.writeFileSync(path.join(repository, 'baseline.txt'), 'original work\n');
  await git(['add', '.']); await git(['commit', '-m', 'synthetic baseline']);
  const ref = 'refs/throttle/transfers/' + id + '/outbound';
  await git(['update-ref', ref, 'HEAD']);
  const bundle = path.join(root, 'source.bundle'); await git(['bundle', 'create', bundle, ref]);
  const transcript = Buffer.from(JSON.stringify({ sessionId: nativeSessionID, cwd: repository, type: 'user' }) + '\n');
  const input = { id, nativeSessionID, runtime: 'claude', sourceCwd: repository,
    remoteCwd: path.join(store.workspaceRoot, id), filename: nativeSessionID + '.jsonl',
    baselineSHA256: hash(transcript), project: 'Synthetic transfer' };
  const transfers = new TransferCoordinator(store, backend);
  transfers.prepare(input);
  await transfers.upload(id, Readable.from([transcript]), 'transcript');
  await transfers.upload(id, fs.createReadStream(bundle), 'repo');
  await transfers.start(id);
  const writers = await awaitWriters(root, id, backend.unit(id));
  // Lose only this fixture's mutable metadata: the product must stop its cgroup
  // and recover the exact immutable binding, never start another writer.
  fs.unlinkSync(store.file(id, 'record.json'));
  const stopped = await transfers.stop(id);
  assert.deepEqual(stopped.input, store.validateInput(input)); assertGone(writers);
  const frozen = await transfers.freeze(id), again = await transfers.freeze(id);
  assert.deepEqual(again.frozen, frozen.frozen);
  const returned = await transfers.download(id, 'repo');
  const inspection = path.join(root, 'returned');
  await gitRun(root, ['clone', returned.file, inspection]);
  await gitRun(root, ['-C', inspection, 'fetch', '--no-tags', returned.file, frozen.frozen.ref + ':' + frozen.frozen.ref]);
  const { stdout } = await gitRun(root, ['-C', inspection, 'show', frozen.frozen.commit + ':fixture-work.txt'], 5000);
  assert.equal(stdout, 'work produced by the isolated fixture\n');
  await transfers.acknowledge(id, { transcript: frozen.frozen.transcript.sha256, repo: returned.sha256 });
  observations.push({ case: 'transfer-stop-metadata-loss-freeze-return', id, writers,
    receipt: stopped.stopReceipt, manifest: frozen.frozen, nativeCLI: 'replaced by synthetic helper' });
}
async function execute(root) {
  assertRoot(root);
  assert.equal(process.versions.node, '24.20.0', 'use the exact prepared qualification runtime');
  assert.equal(fs.existsSync(root), false, 'never reuse a previous qualification root');
  const base = path.dirname(root);
  if (fs.existsSync(base)) assert.equal(fs.realpathSync(base), base, 'qualification parent must not be a symlink');
  const report = { startedAt: new Date().toISOString(), node: process.version, root,
    verdict: 'FAIL', observations, cleanup: [], productionServiceUnchanged: false };
  const serviceState = async () => (await exec('systemctl', ['show', 'throttle-agent.service',
    '--property=ActiveState,SubState,MainPID,InvocationID'], { timeout: 5000 })).stdout;
  const before = await serviceState();
  fs.mkdirSync(root, { recursive: true, mode: 0o700 });
  fs.mkdirSync(path.join(root, 'home'), { mode: 0o700 });
  fs.mkdirSync(path.join(root, 'empty-template'), { mode: 0o700 });
  save(path.join(root, 'scopes.json'), []);
  try {
    await armWatchdog(root);
    await freshCase(root, 'claude');
    await freshCase(root, 'codex');
    await transferCase(root);
    report.verdict = 'PASS';
  } catch (error) { report.error = error.stack; }
  finally {
    try {
      report.cleanup = await cleanup(root);
      if (report.cleanup.some(result => result.error)) report.verdict = 'FAIL';
      else await disarmWatchdog(root);
    } catch (error) { report.cleanup.push({ error: error.message }); report.verdict = 'FAIL'; }
    try {
      report.productionServiceUnchanged = await serviceState() === before;
      if (!report.productionServiceUnchanged) report.verdict = 'FAIL';
    } catch (error) { report.observationError = error.message; report.verdict = 'FAIL'; }
    report.endedAt = new Date().toISOString();
    fs.writeFileSync(path.join(root, 'qualification-report.json'), JSON.stringify(report, null, 2), { mode: 0o600 });
    console.log(JSON.stringify(report, null, 2));
  }
  process.exitCode = report.verdict === 'PASS' ? 0 : 1;
}

const [mode, ...args] = process.argv.slice(2);
if (mode === '--plan') {
  console.log(JSON.stringify({ contractVersion: 1, node: '24.20.0', platform: 'Linux x86_64 cgroup v2 systemd',
    scenarios: ['fresh Claude fixture retry and paused stop', 'fresh Codex fixture retry and paused stop',
      'transfer synthetic writer, missing mutable journal, confirmed stop, frozen Git return'],
    limits: { cases: 3, scopeUnits: 4, watchdogUnits: 2, externalCleanupAfterSeconds: 180 },
    mutations: ['/opt/throttle-qualification/run-UUID only', '/run/systemd/system/unique throttle unit files', 'systemctl daemon-reload'],
    excluded: ['HTTP service restart', 'native Claude/Codex CLI', 'user repositories', 'user CLI configuration', 'publication'] }, null, 2));
} else if (mode === '--cleanup' && args.length === 1) {
  const result = await cleanup(args[0]);
  console.log(JSON.stringify(result));
  process.exitCode = result.some(item => item.error) ? 1 : 0;
} else if (['--fixture-writer', '--fixture-child'].includes(mode)) {
  await inertWriter(...args, mode === '--fixture-child');
} else if (['--transfer-launch', '--transfer-native', '--transfer-freeze'].includes(mode)) {
  const [root, workspaceRoot, id] = args;
  helperGuard(root, id, mode === '--transfer-freeze' ? 'return' : 'transfer');
  if (mode === '--transfer-launch') await launchTransfer(root, workspaceRoot, id);
  else if (mode === '--transfer-freeze') await freezeTransfer(root, workspaceRoot, id);
  else {
    const store = new TransferStore(root, workspaceRoot), record = store.read(id);
    assert.ok(record?.input && !store.tombstoned(id));
    fs.appendFileSync(nativeTranscriptPath(record.input, os.homedir()), JSON.stringify({ type: 'fixture-result' }) + '\n');
    await inertWriter(path.dirname(root), id, record.input.remoteCwd);
  }
} else if (mode === '--execute' && args.length === 1) {
  await execute(args[0]);
} else { throw new Error('Use --plan, or explicitly approved --execute /opt/throttle-qualification/run-UUID'); }

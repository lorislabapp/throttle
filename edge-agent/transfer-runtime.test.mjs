import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { Readable } from 'node:stream';
import { TransferStore, TransferCoordinator, SystemdTransferBackend, publishNativeTranscript, snapshotTransfer, nativeTranscriptPath, requireUnmanagedWorkspace } from './transfer-runtime.mjs';

function receipt(id) {
  return { bootID: '12345678-1234-1234-1234-123456789abc', invocationID: null,
    unit: `throttle-transfer-${id}.service`, controlGroup: `/system.slice/throttle-transfer-${id}.service`,
    activeState: 'inactive', populated: 0, observedAt: Date.now() };
}
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'throttle-transfer-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const store = new TransferStore(path.join(root, 'journal'), path.join(root, 'workspaces'));
  const id = crypto.randomUUID(), nativeSessionID = crypto.randomUUID();
  const input = { id, nativeSessionID, runtime: 'claude', sourceCwd: '/source',
    remoteCwd: path.join(store.workspaceRoot, id), filename: `${nativeSessionID}.jsonl`,
    baselineSHA256: crypto.createHash('sha256').update('transcript').digest('hex'), project: 'Fixture' };
  return { root, store, input };
}

test('prepare is idempotent, exact, and reserves a native identity across projects', t => {
  const { store, input } = fixture(t);
  assert.deepEqual(store.prepare(input), store.prepare(input));
  assert.throws(() => store.prepare({ ...input, sourceCwd: '/different' }), /different input/);
  const id = crypto.randomUUID();
  assert.throws(() => store.prepare({ ...input, id, remoteCwd: path.join(store.workspaceRoot, id) }), /already claimed/);
  assert.throws(() => store.prepare({ ...input, filename: '../wrong.jsonl' }), /filename/);
});

test('stop-before-prepare survives restart and cannot be overwritten by a delayed start', async t => {
  const { store, input } = fixture(t);
  const backend = { stop: async id => receipt(id) };
  const coordinator = new TransferCoordinator(store, backend);
  await coordinator.stop(input.id);
  const restarted = new TransferStore(store.root, store.workspaceRoot);
  assert.throws(() => restarted.prepare(input), /tombstone/);
  await assert.rejects(new TransferCoordinator(restarted, backend).start(input.id), /stopped/);
  const another = { ...input, id: crypto.randomUUID(), nativeSessionID: crypto.randomUUID() };
  another.remoteCwd = path.join(store.workspaceRoot, another.id);
  another.filename = `${another.nativeSessionID}.jsonl`;
  assert.equal(restarted.prepare(another).phase, 'prepared');
});

test('upload validates the full hash and never clobbers a staged transcript', async t => {
  const { store, input } = fixture(t);
  store.prepare(input);
  const coordinator = new TransferCoordinator(store, {});
  await assert.rejects(coordinator.upload(input.id, Readable.from(['wrong']), 'transcript'), /hash mismatch/);
  assert.equal(fs.existsSync(store.file(input.id, 'incoming.jsonl')), false);
  const result = await coordinator.upload(input.id, Readable.from(['tran', 'script']), 'transcript');
  assert.equal(result.sha256, input.baselineSHA256);
  await coordinator.upload(input.id, Readable.from(['transcript']), 'transcript');
  assert.equal(fs.readFileSync(store.file(input.id, 'incoming.jsonl'), 'utf8'), 'transcript');
});

test('a stop tombstone is visible while waiting for an earlier operation', async t => {
  const { store, input } = fixture(t);
  store.prepare(input);
  const coordinator = new TransferCoordinator(store, { stop: async id => receipt(id) });
  let finish, entered;
  const barrier = new Promise(resolve => { entered = resolve; });
  const pending = coordinator.exclusive(input.id, () => new Promise(resolve => { finish = resolve; entered(); }));
  await barrier;
  const stop = coordinator.stop(input.id);
  assert.equal(store.tombstoned(input.id), true);
  finish(); await pending; await stop;
  assert.equal(store.read(input.id).phase, 'stopped');
  assert.throws(() => store.prepare(input), /tombstone/);
});

test('unconfirmed stop retains the tombstone and never produces a receipt', async t => {
  const { store, input } = fixture(t);
  store.prepare(input);
  const coordinator = new TransferCoordinator(store, { stop: async () => { throw new Error('still populated'); } });
  await assert.rejects(coordinator.stop(input.id), /still populated/);
  assert.equal(store.tombstoned(input.id), true);
  assert.equal(store.read(input.id).stopReceipt, undefined);
});

test('corrupt journals fail closed and unit generation bounds startup and stop', t => {
  const { store, input, root } = fixture(t);
  store.prepare(input);
  fs.writeFileSync(store.file(input.id, 'record.json'), '{truncated');
  assert.throws(() => store.all());
  const backend = new SystemdTransferBackend(store, { script: `${root}/a %b$.mjs`, home: root });
  const unit = backend.definition(input.id);
  assert.match(unit, /TimeoutStartSec=120/);
  assert.match(unit, /KillMode=control-group/);
  assert.match(unit, /a %%b\$\$\.mjs/);
  assert.doesNotMatch(unit, /WantedBy|Restart=always/);
});

test('a truthy fake stop receipt or missing record cannot release a native claim', async t => {
  const { store, input } = fixture(t);
  const record = store.prepare(input);
  store.save({ ...record, stopReceipt: true });
  assert.throws(() => store.all(), /invalid stop receipt/);
  fs.rmSync(store.file(input.id, 'record.json'));
  assert.throws(() => store.all(), /incomplete transfer journal/);
});

test('lost mutable state retains its native claim after backend reconciliation', async t => {
  const { store, input } = fixture(t);
  store.prepare(input);
  fs.rmSync(store.file(input.id, 'record.json'));
  store.tombstone(input.id);
  const id = crypto.randomUUID();
  assert.throws(() => store.prepare({ ...input, id, remoteCwd: path.join(store.workspaceRoot, id) }), /incomplete/);
  const coordinator = new TransferCoordinator(store, { stop: async id => receipt(id) });
  await coordinator.stop(input.id);
  assert.deepEqual(store.read(input.id).input, store.validateInput(input));
  assert.throws(() => store.prepare({ ...input, id, remoteCwd: path.join(store.workspaceRoot, id) }), /already claimed/);
});

test('native publication is exact, idempotent, and preserves a differing destination', async t => {
  const { store, input, root } = fixture(t);
  const source = path.join(root, 'source.jsonl'), destination = path.join(root, 'native', input.filename);
  const bytes = JSON.stringify({ sessionId: input.nativeSessionID, cwd: input.sourceCwd }) + '\n';
  input.baselineSHA256 = crypto.createHash('sha256').update(bytes).digest('hex');
  fs.writeFileSync(source, bytes);
  await publishNativeTranscript(source, destination, input);
  await publishNativeTranscript(source, destination, input);
  assert.equal(fs.readFileSync(destination, 'utf8'), bytes);
  fs.writeFileSync(destination, 'different local writer');
  await assert.rejects(publishNativeTranscript(source, destination, input), /already differs/);
  assert.equal(fs.readFileSync(destination, 'utf8'), 'different local writer');
  assert.deepEqual(fs.readdirSync(path.dirname(destination)), [input.filename]);
});

test('wrong native metadata never creates a published transcript', async t => {
  const { input, root } = fixture(t);
  const source = path.join(root, 'source.jsonl'), destination = path.join(root, 'native.jsonl');
  const bytes = JSON.stringify({ sessionId: crypto.randomUUID(), cwd: input.sourceCwd }) + '\n';
  input.baselineSHA256 = crypto.createHash('sha256').update(bytes).digest('hex');
  fs.writeFileSync(source, bytes);
  await assert.rejects(publishNativeTranscript(source, destination, input), /metadata/);
  assert.equal(fs.existsSync(destination), false);
});

for (const barrier of ['ready', 'install', 'start', 'confirmRunning']) {
  test(`stop racing ${barrier} cannot leave a writer or permit a replacement`, async t => {
    const { store, input } = fixture(t);
    const record = store.prepare(input);
    record.transcriptSHA256 = input.baselineSHA256;
    record.repoSHA256 = 'b'.repeat(64);
    store.save(record);
    let reached, release, writer = false, starts = 0;
    const entered = new Promise(resolve => { reached = resolve; });
    const held = new Promise(resolve => { release = resolve; });
    const pauseAt = async name => { if (name === barrier) { reached(); await held; } };
    const backend = {
      ready: async () => { await pauseAt('ready'); return true; },
      bootID: () => receipt(input.id).bootID,
      install: async () => pauseAt('install'),
      start: async id => {
        await pauseAt('start');
        if (store.tombstoned(id)) throw new Error('helper refused tombstone');
        writer = true; starts++;
      },
      confirmRunning: async () => {
        await pauseAt('confirmRunning');
        if (!writer) throw new Error('no writer');
        return { ActiveState: 'active', InvocationID: 'a'.repeat(32) };
      },
      stop: async id => { writer = false; return receipt(id); }
    };
    const coordinator = new TransferCoordinator(store, backend);
    const starting = coordinator.start(input.id).catch(error => error);
    await entered;
    const stopping = coordinator.stop(input.id);
    assert.equal(store.tombstoned(input.id), true);
    assert.equal(store.read(input.id).stopReceipt, undefined);
    const nextID = crypto.randomUUID();
    assert.throws(() => store.prepare({ ...input, id: nextID, remoteCwd: path.join(store.workspaceRoot, nextID) }), /claimed/);
    release();
    await starting; await stopping;
    assert.equal(writer, false);
    assert.ok(starts <= 1);
    assert.equal(store.read(input.id).phase, 'stopped');
    await assert.rejects(coordinator.start(input.id), /stopped/);
  });
}


for (const loseStatus of [false, true]) {
test(`return freezes exact files after stop and hash acknowledgement (lost mutable status: ${loseStatus})`, async t => {
  const { store, input, root } = fixture(t);
  store.prepare(input);
  fs.mkdirSync(input.remoteCwd, { recursive: true });
  const git = args => execFileSync('git', ['-C', input.remoteCwd, ...args], { encoding: 'utf8',
    env: { ...process.env, GIT_AUTHOR_NAME: 'Fixture', GIT_AUTHOR_EMAIL: 'test@localhost',
      GIT_COMMITTER_NAME: 'Fixture', GIT_COMMITTER_EMAIL: 'test@localhost' } }).trim();
  git(['init', '--quiet']);
  for (const [key, value] of [['core.hooksPath', '/dev/null'], ['commit.gpgsign', 'false'], ['core.fsmonitor', 'false']]) {
    git(['config', key, value]);
  }
  fs.writeFileSync(path.join(input.remoteCwd, 'work.txt'), 'baseline');
  fs.writeFileSync(path.join(input.remoteCwd, 'deleted.txt'), 'baseline');
  git(['add', '-A']); git(['commit', '--quiet', '-m', 'baseline']);
  fs.writeFileSync(path.join(input.remoteCwd, 'work.txt'), 'remote work');
  fs.writeFileSync(path.join(input.remoteCwd, 'new.txt'), 'untracked');
  fs.rmSync(path.join(input.remoteCwd, 'deleted.txt'));
  const indexBefore = fs.readFileSync(path.join(input.remoteCwd, '.git/index'));
  const headBefore = git(['rev-parse', 'HEAD']);
  const home = path.join(root, 'home'), transcript = nativeTranscriptPath(input, home);
  fs.mkdirSync(path.dirname(transcript), { recursive: true });
  const bytes = JSON.stringify({ sessionId: input.nativeSessionID, cwd: input.sourceCwd }) + '\n';
  fs.writeFileSync(transcript, bytes);
  let stopped = false, freezes = 0;
  const backend = { stop: async id => { stopped = true; return receipt(id); },
    freeze: async id => { assert.equal(stopped, true); freezes++; return snapshotTransfer(store, store.read(id), home); } };
  const coordinator = new TransferCoordinator(store, backend);
  await assert.rejects(coordinator.download(input.id, 'transcript'), /not frozen/);
  if (loseStatus) fs.rmSync(store.file(input.id, 'record.json'));
  const frozen = await coordinator.freeze(input.id);
  assert.equal(frozen.phase, 'frozen');
  assert.deepEqual(fs.readFileSync(path.join(input.remoteCwd, '.git/index')), indexBefore);
  assert.equal(git(['rev-parse', 'HEAD']), headBefore);
  const returned = await coordinator.download(input.id, 'transcript');
  assert.equal(fs.readFileSync(returned.file, 'utf8'), bytes);
  const bundle = await coordinator.download(input.id, 'repo');
  const clone = path.join(root, 'returned-code');
  execFileSync('git', ['clone', '--quiet', bundle.file, clone]);
  execFileSync('git', ['-C', clone, 'fetch', '--quiet', bundle.file, `${frozen.frozen.ref}:${frozen.frozen.ref}`]);
  execFileSync('git', ['-C', clone, 'checkout', '--quiet', '--detach', frozen.frozen.ref]);
  assert.equal(fs.readFileSync(path.join(clone, 'work.txt'), 'utf8'), 'remote work');
  assert.equal(fs.readFileSync(path.join(clone, 'new.txt'), 'utf8'), 'untracked');
  assert.equal(fs.existsSync(path.join(clone, 'deleted.txt')), false);
  fs.appendFileSync(transcript, 'changed after freeze');
  assert.deepEqual((await coordinator.freeze(input.id)).frozen, frozen.frozen);
  assert.equal(freezes, 1);
  const nextID = crypto.randomUUID();
  const next = { ...input, id: nextID, remoteCwd: path.join(store.workspaceRoot, nextID) };
  assert.throws(() => store.prepare(next), /already claimed/);
  await assert.rejects(coordinator.acknowledge(input.id, { transcript: '0'.repeat(64), repo: bundle.sha256 }), /hashes/);
  const acknowledged = await coordinator.acknowledge(input.id, { transcript: returned.sha256, repo: bundle.sha256 });
  assert.equal(store.prepare(next).phase, 'prepared');
  // An older returned record may disappear after a newer transfer claims the
  // same native session. Its immutable backup must not reclaim that live writer.
  fs.rmSync(store.file(input.id, 'record.json'));
  await assert.rejects(coordinator.freeze(input.id), /claimed by another/);
  assert.equal(store.read(input.id), null);
  assert.equal(freezes, 1);
  store.save(acknowledged);
  fs.chmodSync(returned.file, 0o600); fs.appendFileSync(returned.file, 'corrupt');
  await assert.rejects(coordinator.download(input.id, 'transcript'), /changed/);
});
}

test('return cannot bypass a failed native stop or a missing binding', async t => {
  const { store, input } = fixture(t);
  store.prepare(input);
  let freezes = 0;
  const coordinator = new TransferCoordinator(store, { stop: async () => { throw new Error('still populated'); },
    freeze: async () => { freezes++; } });
  await assert.rejects(coordinator.freeze(input.id), /still populated/);
  assert.equal(freezes, 0);
  const unknown = crypto.randomUUID();
  const reconciled = new TransferCoordinator(store, { stop: async id => receipt(id), freeze: async () => { freezes++; } });
  await assert.rejects(reconciled.freeze(unknown), /metadata is missing/);
  assert.equal(freezes, 0);
  const backend = new SystemdTransferBackend(store, { purpose: 'return' });
  assert.equal(backend.unit(input.id), `throttle-return-${input.id}.service`);
  assert.match(backend.definition(input.id), /--transfer-freeze/);
  assert.match(backend.definition(input.id), /KillMode=control-group/);
});


test('legacy writers cannot enter transfer workspaces directly or through symlinks', t => {
  const { store, input, root } = fixture(t);
  fs.mkdirSync(store.workspaceRoot, { recursive: true });
  const alias = path.join(root, 'alias');
  fs.symlinkSync(store.workspaceRoot, alias);
  for (const cwd of [input.remoteCwd, path.join(alias, input.id, 'nested'), store.root]) {
    assert.throws(() => requireUnmanagedWorkspace(store, cwd), /v2 transfer/);
  }
  assert.doesNotThrow(() => requireUnmanagedWorkspace(store, path.join(root, 'ordinary-project')));
});


test('returned phase cannot release a native claim without sealed artifacts and matching acknowledgement', async t => {
  const { store, input } = fixture(t);
  store.prepare(input);
  const coordinator = new TransferCoordinator(store, { stop: async id => receipt(id) });
  await coordinator.stop(input.id);
  const stopped = store.read(input.id);
  const nextID = crypto.randomUUID();
  const next = { ...input, id: nextID, remoteCwd: path.join(store.workspaceRoot, nextID) };
  const artifact = { bytes: 1, sha256: 'a'.repeat(64) };
  const frozen = { attempt: 'return-' + crypto.randomUUID(), transcript: artifact, repo: artifact,
    tree: 'b'.repeat(40), commit: 'c'.repeat(40), ref: `refs/throttle/transfers/${input.id}/return` };
  for (const invalid of [
    { phase: 'returned' },
    { phase: 'returned', frozen },
    { phase: 'returned', frozen, acknowledgement: { transcript: 'wrong', repo: artifact.sha256, observedAt: Date.now() } }
  ]) {
    store.save({ ...stopped, ...invalid });
    assert.throws(() => store.prepare(next), /invalid return|not sealed/);
  }
  store.sealReturn(input.id);
  store.save({ ...stopped, phase: 'returned', frozen, acknowledgement: { transcript: 'wrong', repo: artifact.sha256, observedAt: Date.now() } });
  assert.throws(() => store.prepare(next), /acknowledgement/);
});


test('immutable binding survives missing mutable state and only recovers after confirmed stop', async t => {
  const { store, input } = fixture(t);
  const accepted = store.prepare(input);
  const original = fs.readFileSync(store.file(input.id, 'binding.json'));
  fs.rmSync(store.file(input.id, 'record.json'));
  const restarted = new TransferStore(store.root, store.workspaceRoot);
  let starts = 0, stops = 0;
  const backend = { start: async () => { starts++; }, stop: async id => { stops++; return receipt(id); } };
  const coordinator = new TransferCoordinator(restarted, backend);
  await assert.rejects(coordinator.start(input.id), /stopped/);
  const stopped = await coordinator.stop(input.id);
  assert.equal(starts, 0); assert.equal(stops, 1);
  assert.deepEqual(stopped.input, accepted.input);
  assert.equal(stopped.createdAt, accepted.createdAt);
  assert.equal(stopped.phase, 'stopped');
  assert.deepEqual(fs.readFileSync(store.file(input.id, 'binding.json')), original);
  await assert.rejects(coordinator.start(input.id), /stopped/);
  assert.throws(() => restarted.prepare(input), /tombstone/);
});

test('crash after immutable publication cannot start a writer or replace its accepted identity', async t => {
  const { store, input } = fixture(t);
  store.save = () => { throw new Error('simulated power loss before mutable status'); };
  assert.throws(() => store.prepare(input), /power loss/);
  const restarted = new TransferStore(store.root, store.workspaceRoot);
  const binding = restarted.binding(input.id);
  assert.equal(binding.input.nativeSessionID, input.nativeSessionID);
  let stopped = false;
  const coordinator = new TransferCoordinator(restarted, { stop: async id => { stopped = true; return receipt(id); } });
  await assert.rejects(coordinator.start(input.id), /stopped/);
  const recovered = await coordinator.stop(input.id);
  assert.equal(stopped, true);
  assert.deepEqual(recovered.input, binding.input);
  const modified = { ...recovered, input: { ...binding.input, sourceCwd: '/wrong' } };
  assert.throws(() => restarted.preserveBinding(modified), /binding changed/);
  assert.deepEqual(restarted.binding(input.id), binding);
});

test('contradictory or corrupt metadata cannot be substituted during recovery', async t => {
  const { store, input } = fixture(t);
  const accepted = store.prepare(input);
  store.save({ ...accepted, input: { ...accepted.input, sourceCwd: '/wrong' } });
  assert.throws(() => store.read(input.id), /contradicts/);
  const corrupt = fs.readFileSync(store.file(input.id, 'record.json'));
  let corruptScopeStopped = false;
  const corruptCoordinator = new TransferCoordinator(store, {
    stop: async id => { corruptScopeStopped = true; return receipt(id); }
  });
  await assert.rejects(corruptCoordinator.stop(input.id), /contradicts/);
  assert.equal(corruptScopeStopped, true);
  assert.deepEqual(fs.readFileSync(store.file(input.id, 'record.json')), corrupt);
  fs.rmSync(store.file(input.id, 'record.json'));
  fs.writeFileSync(store.file(input.id, 'binding.json'), '{partial');
  let stopped = false;
  const coordinator = new TransferCoordinator(store, { stop: async id => { stopped = true; return receipt(id); } });
  await assert.rejects(coordinator.stop(input.id), SyntaxError);
  assert.equal(stopped, true);
  assert.equal(store.tombstoned(input.id), true);
  assert.equal(store.read(input.id), null);
  assert.equal(fs.readFileSync(store.file(input.id, 'binding.json'), 'utf8'), '{partial');
});


test('oversized native filenames are rejected before publishing any journal binding', t => {
  const { store, input } = fixture(t);
  const filename = `rollout-2026-09-08T${'x'.repeat(32768)}-${input.nativeSessionID}.jsonl`;
  assert.throws(() => store.prepare({ ...input, runtime: 'codex', filename }), /filename/);
  assert.equal(fs.existsSync(store.file(input.id, 'binding.json')), false);
  assert.equal(fs.existsSync(store.file(input.id, 'record.json')), false);
});


test('terminal sockets stay inside a short unit-owned runtime directory even for long journal roots', t => {
  const { root, input } = fixture(t);
  const store = new TransferStore(path.join(root, 'long-journal-'.repeat(20)), path.join(root, 'work'));
  const backend = new SystemdTransferBackend(store);
  const socket = backend.socket(input.id);
  assert.ok(Buffer.byteLength(store.file(input.id, 'terminal.sock')) > 108);
  assert.ok(Buffer.byteLength(socket) < 108);
  assert.equal(socket, '/run/throttle-transfer-' + input.id + '/terminal.sock');
  assert.match(backend.definition(input.id), new RegExp('RuntimeDirectory=throttle-transfer-' + input.id));
  assert.match(backend.definition(input.id), /RuntimeDirectoryMode=0700/);
});

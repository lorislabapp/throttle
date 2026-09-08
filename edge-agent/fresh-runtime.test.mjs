import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { FreshSessionStore, FreshSessionBackend, FreshSessions, freshID, spawnFreshCommand } from './fresh-runtime.mjs';
import { TransferStore } from './transfer-runtime.mjs';

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'throttle-fresh-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const store = new FreshSessionStore(path.join(root, 'fresh'), {});
  const transfers = new TransferStore(path.join(root, 'transfers'), path.join(root, 'workspaces'));
  const request = { requestID: crypto.randomUUID(), serverID: store.identity(), cwd: path.join(root, 'repo'), runtime: 'claude' };
  let starts = 0, stops = 0;
  const backend = { ready: async () => true, install: async () => {}, start: async () => { starts++; },
    confirmRunning: async () => {}, state: async () => ({ ActiveState: 'active' }),
    socket: id => store.file(id, 'terminal.sock'),
    stop: async id => { stops++; return { bootID: crypto.randomUUID(), invocationID: null,
      unit: 'throttle-session-' + id + '.service', controlGroup: '/system.slice/throttle-session-' + id + '.service',
      activeState: 'inactive', populated: 0, observedAt: Date.now() }; } };
  return { root, store, transfers, request, backend, starts: () => starts, stops: () => stops };
}

test('same fresh request starts once and never aliases a transfer workspace', async t => {
  const fixtureValue = fixture(t), { store, transfers, request, backend } = fixtureValue;
  const sessions = new FreshSessions(store, backend);
  const [first, repeated] = await Promise.all([sessions.create(request, transfers), sessions.create(request, transfers)]);
  assert.equal(first.id, repeated.id); assert.equal(fixtureValue.starts(), 1);
  assert.notEqual(first.nativeSessionID, request.requestID);
  assert.equal(freshID(first.id), request.requestID);
  await assert.rejects(sessions.create({ ...request, cwd: path.join(fixtureValue.root, 'other') }, transfers), /different input/);
  await assert.rejects(sessions.create({ ...request, requestID: crypto.randomUUID(), serverID: store.identity(), cwd: transfers.workspaceRoot }, transfers), /v2 transfer/);
  const terminal = await sessions.terminal(first.id);
  assert.equal(terminal.name, 'throttle-' + request.requestID);
  assert.equal(terminal.socket, store.file(request.requestID, 'terminal.sock'));
});

test('stopping during fresh startup leaves a permanent tombstone and a scoped receipt', async t => {
  const value = fixture(t), { store, transfers, request, backend } = value;
  let entered, release;
  const began = new Promise(resolve => { entered = resolve; });
  backend.start = async () => { entered(); await new Promise(resolve => { release = resolve; }); };
  const sessions = new FreshSessions(store, backend);
  const starting = sessions.create(request, transfers);
  await began;
  const stopping = sessions.stop('fresh-' + request.requestID);
  assert.equal(store.tombstoned(request.requestID), true);
  release();
  await assert.rejects(starting, /stopped while starting/);
  const stopped = await stopping;
  assert.equal(stopped.phase, 'stopped'); assert.equal(value.stops(), 1);
  assert.equal(stopped.stopReceipt.unit, 'throttle-session-' + request.requestID + '.service');
  await assert.rejects(sessions.create(request, transfers), /stopped/);
  await assert.rejects(sessions.terminal('fresh-' + request.requestID), /stopped/);
  await assert.rejects(sessions.signal('fresh-' + request.requestID, 'SIGCONT'), /stopped/);
});

test('failed fresh stop retains the writer state and retry cannot become an unconfirmed success', async t => {
  const { store, transfers, request, backend } = fixture(t);
  const sessions = new FreshSessions(store, backend);
  const started = await sessions.create(request, transfers);
  backend.stop = async () => { throw new Error('still populated'); };
  await assert.rejects(sessions.stop(started.id), /still populated/);
  assert.equal(store.read(request.requestID).phase, 'remote');
  assert.equal(store.tombstoned(request.requestID), true);
  await assert.rejects(sessions.create(request, transfers), /stopped/);
});

test('Codex fresh conversations report no invented native identity or usage', async t => {
  const { store, transfers, request, backend } = fixture(t);
  const sessions = new FreshSessions(store, backend);
  const result = await sessions.create({ ...request, runtime: 'codex' }, transfers);
  assert.equal(result.nativeSessionID, null); assert.equal(result.tokens, null);
  await assert.rejects(sessions.create({ ...request, requestID: crypto.randomUUID(), resume: crypto.randomUUID() }, transfers), /cannot resume/);
});

test('fresh units share the verified backend but have their own helper, namespace and socket', t => {
  const { store, request } = fixture(t);
  const backend = new FreshSessionBackend(store, { script: '/fixture/agent.mjs', home: '/fixture/home' });
  const definition = backend.definition(request.requestID);
  assert.equal(backend.unit(request.requestID), 'throttle-session-' + request.requestID + '.service');
  assert.match(definition, /KillMode=control-group/);
  assert.match(definition, /--fresh-launch/);
  assert.doesNotMatch(definition, /--transfer-launch|Restart=always/);
  assert.equal(backend.socket(request.requestID), '/run/throttle-session-' + request.requestID + '/terminal.sock');
  assert.match(definition, new RegExp('RuntimeDirectory=throttle-session-' + request.requestID));
  assert.match(definition, /RuntimeDirectoryMode=0700/);
});


test('fresh retries retain their identity across coordinator restart and a lost start reply', async t => {
  const value = fixture(t), { store, transfers, request, backend } = value;
  const start = backend.start;
  backend.start = async id => { await start(id); throw new Error('reply lost'); };
  await assert.rejects(new FreshSessions(store, backend).create(request, transfers), /reply lost/);
  const reopened = new FreshSessionStore(store.root, {});
  const retried = await new FreshSessions(reopened, backend).create(request, transfers);
  assert.equal(value.starts(), 1); assert.equal(retried.id, 'fresh-' + request.requestID);
  assert.equal(retried.state, 'remote');
  for (const delta of [{ requestID: undefined }, { serverID: crypto.randomUUID() }, { runtime: 'codex' }]) {
    await assert.rejects(new FreshSessions(reopened, backend).create({ ...request, ...delta }, transfers));
  }
  assert.equal(value.starts(), 1);
});

test('configured inert commands survive helper environment changes and receive no native flags', async t => {
  const value = fixture(t), { root, transfers, request, backend } = value;
  fs.mkdirSync(request.cwd, { recursive: true });
  const output = path.join(root, 'inert-result.json'), script = path.join(root, 'inert.mjs');
  fs.writeFileSync(script, `import fs from 'node:fs'; fs.writeFileSync(process.argv[2], JSON.stringify(process.argv.slice(3)));`);
  for (const runtime of ['claude', 'codex']) {
    const command = [process.execPath, script, output, runtime, 'with space', '%$literal'].map(JSON.stringify).join(' ')
      .replace('"%$literal"', "'%$literal'");
    const store = new FreshSessionStore(path.join(root, runtime), {
      ['THROTTLE_AGENT_' + runtime.toUpperCase() + '_CMD']: command,
      THROTTLE_AGENT_OAUTH_TOKEN_FILE: path.join(root, 'missing-token')
    });
    const sessions = new FreshSessions(store, backend);
    const result = await sessions.create({ ...request, serverID: store.identity(), runtime }, transfers);
    assert.equal(result.nativeSessionID, null);
    const helperStore = new FreshSessionStore(store.root, {});
    const record = helperStore.read(request.requestID);
    assert.equal(await spawnFreshCommand(record, { stdio: 'ignore' }), 0);
    assert.deepEqual(JSON.parse(fs.readFileSync(output, 'utf8')), [runtime, 'with space', '%$literal']);
    const stopped = await sessions.stop(result.id);
    assert.equal(stopped.launch, undefined);
  }
});

test('invalid configured commands fail before backend start without falling back to a native CLI', async t => {
  const value = fixture(t), { store, transfers, request, backend } = value;
  store.environment = { THROTTLE_AGENT_CLAUDE_CMD: '' };
  await assert.rejects(new FreshSessions(store, backend).create(request, transfers), /invalid configured/);
  assert.equal(value.starts(), 0); assert.equal(store.read(request.requestID), null);
});

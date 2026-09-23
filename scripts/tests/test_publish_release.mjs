import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { validateStage, checkedOffset, uploadChunks, uploadCredentials, packageStage, publish } from '../publish-release.mjs';

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'throttle-publish-fixture-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(`${root}/throttle`);
  for (const name of ['appcast.xml', 'index.html', 'Throttle-3.8.0.dmg']) writeFileSync(`${root}/throttle/${name}`, 'fixture');
  return root;
}
const reply = (status, offset) => ({ status, ok: status >= 200 && status < 300,
  headers: { get: () => offset } });

test('stage permits exactly the expected regular artifacts', t => {
  const root = fixture(t);
  assert.equal(validateStage(root), root);
  writeFileSync(`${root}/private.txt`, 'fixture');
  assert.throws(() => validateStage(root), /Unexpected file/);
});
test('stage refuses extra nested files and symlinked artifacts', t => {
  const root = fixture(t);
  writeFileSync(`${root}/throttle/extra.txt`, 'fixture');
  assert.throws(() => validateStage(root), /exactly/);
  rmSync(`${root}/throttle/extra.txt`);
  rmSync(`${root}/throttle/index.html`);
  symlinkSync(`${root}/throttle/appcast.xml`, `${root}/throttle/index.html`);
  assert.throws(() => validateStage(root), /exactly/);
});
test('zip receives path arguments without invoking a shell', () => {
  const calls = [];
  const stage = '/tmp/synthetic $(touch forbidden)';
  packageStage(stage, '/tmp/archive.zip', (...args) => calls.push(args));
  assert.deepEqual(calls, [['/usr/bin/zip', ['-r', '/tmp/archive.zip', '.', '-x', '.DS_Store'],
    { cwd: stage, stdio: 'ignore' }]]);
});
test('credential validation never includes response content in errors', () => {
  const privateFixture = 'synthetic-sensitive-marker';
  for (const value of [{ auth_key: privateFixture }, { url: 'http://bad', auth_key: privateFixture },
    { url: 'https://host/?token=private', auth_key: privateFixture, rest_auth_key: privateFixture }]) {
    assert.throws(() => uploadCredentials(value), error => {
      assert.equal(error.message, 'Upload credentials unavailable.');
      assert.equal(error.message.includes(privateFixture), false);
      return true;
    });
  }
});
test('offsets are exact safe decimal values in the accepted range', () => {
  assert.equal(checkedOffset('4', 4, 4), 4);
  for (const value of [null, '', 'NaN', '4junk', '-1', '9007199254740992', '3', '5']) {
    assert.throws(() => checkedOffset(value, 4, 4), /offset/);
  }
});
test('successful PATCH requires explicit exact offset, never fabricated progress', async () => {
  for (const offset of [null, '0', '5']) {
    let calls = 0;
    await assert.rejects(uploadChunks('https://fixture.invalid', Buffer.from('abcd'), {}, {
      fetcher: async () => { calls++; return reply(204, offset); }, sleep: async () => {}
    }), /offset/);
    assert.equal(calls, 1);
  }
});
test('lost PATCH reconciles committed chunk without empty resend', async () => {
  const methods = [];
  await uploadChunks('https://fixture.invalid', Buffer.from('abcd'), {}, {
    fetcher: async (_url, options) => {
      methods.push(options.method);
      assert.ok(options.signal);
      if (options.method === 'PATCH') throw new Error('synthetic network failure');
      return reply(200, '4');
    }, sleep: async () => {}
  });
  assert.deepEqual(methods, ['PATCH', 'HEAD']);
});
test('partial reconciliation resends only remaining bytes', async () => {
  const bodies = [];
  await uploadChunks('https://fixture.invalid', Buffer.from('abcd'), {}, {
    fetcher: async (_url, options) => {
      if (options.method === 'HEAD') return reply(200, '2');
      bodies.push(options.body.toString());
      if (bodies.length === 1) throw new Error('synthetic network failure');
      return reply(204, '4');
    }, sleep: async () => {}
  });
  assert.deepEqual(bodies, ['abcd', 'cd']);
});
test('retry count is bounded and a bad HEAD never authorizes progress', async () => {
  let patches = 0;
  await assert.rejects(uploadChunks('https://fixture.invalid', Buffer.from('abcd'), {}, {
    fetcher: async (_url, options) => {
      if (options.method === 'HEAD') return reply(200, '0');
      patches++; throw new Error('synthetic network failure');
    }, sleep: async () => {}
  }), /four attempts/);
  assert.equal(patches, 4);
  await assert.rejects(uploadChunks('https://fixture.invalid', Buffer.from('abcd'), {}, {
    fetcher: async (_url, options) => {
      if (options.method === 'HEAD') return reply(200, '5');
      throw new Error('synthetic network failure');
    }, sleep: async () => {}
  }), /out-of-range/);
});

test('offline publication exercises bounded requests and never reads raw error bodies', async t => {
  const root = fixture(t);
  const calls = [];
  const logs = [];
  let clock = 1_000;
  await publish(root, 'synthetic-token', {
    execute: (_tool, args) => writeFileSync(args[1], 'synthetic-zip'),
    sleep: async ms => { clock += ms; }, now: () => clock, log: line => logs.push(line),
    fetcher: async (url, options) => {
      calls.push(options.method || 'GET');
      assert.ok(options.signal);
      if (url.endsWith('/upload-urls')) return { ok: true, json: async () => ({
        url: 'https://upload.fixture.invalid', auth_key: 'synthetic-auth', rest_auth_key: 'synthetic-rest'
      }) };
      if (options.method === 'PATCH') return reply(204, String(options.body.length));
      if (url.endsWith('/deploy')) return { status: 500, text: () => { throw new Error('must not read'); } };
      if (options.method === 'POST') return reply(201, '0');
      return { ok: true, text: async () => readFileSync(`${root}/deploy-stamp.txt`, 'utf8') };
    }
  });
  assert.deepEqual(calls, ['POST', 'POST', 'PATCH', 'POST', 'GET']);
  assert.equal(logs.join('\n').includes('synthetic-token'), false);
  assert.equal(logs.join('\n').includes('synthetic-auth'), false);
  assert.ok(logs.some(line => line.includes('Verified live stamp')));
});

#!/usr/bin/env node
// Publish a staged Throttle release to lorislab.fr — ONLY the files under <stage>.
//
// Same Hostinger archive→deploy path as lorislab-website/deploy.mjs, but from an isolated
// directory (throttle/appcast.xml, throttle/index.html, throttle/Throttle-X.dmg). The deploy
// extracts OVER public_html (merge), so nothing else on the site moves — in particular the
// website checkout's in-flight work never ships by accident, and no stale DMG re-uploads.
//
// Usage: HOSTINGER_API_TOKEN=… node scripts/publish-release.mjs <stage-dir>
// Then:  scripts/verify-public-release.sh <stage-dir>
import { readFileSync, statSync, unlinkSync, writeFileSync, existsSync } from 'fs';
import { execSync } from 'child_process';

const STAGE_DIR = process.argv[2];
if (!STAGE_DIR || !existsSync(`${STAGE_DIR}/throttle/appcast.xml`)) {
  console.error('usage: publish-release.mjs <stage-dir>   (from scripts/stage-release.py)');
  process.exit(64);
}
const TOKEN = process.env.HOSTINGER_API_TOKEN;
if (!TOKEN) { console.error('HOSTINGER_API_TOKEN missing'); process.exit(1); }

const BASE = 'https://developers.hostinger.com';
const USERNAME = 'u376697750';
const DOMAIN = 'lorislab.fr';
const TIMESTAMP = new Date().toISOString().replace(/[-:T]/g, '').substring(0, 14);
const FILENAME = `throttle-release-${TIMESTAMP}.zip`;
const ARCHIVE = `${STAGE_DIR}/../${FILENAME}`;
const STAMP = `${TIMESTAMP}-${Math.random().toString(36).slice(2, 10)}`;
writeFileSync(`${STAGE_DIR}/deploy-stamp.txt`, `${STAMP}\n`);

execSync(`cd "${STAGE_DIR}" && zip -r "${ARCHIVE}" . -x ".DS_Store" 2>/dev/null`);
const FILESIZE = statSync(ARCHIVE).size;
console.log(`Archive: ${FILENAME} (${(FILESIZE / 1024 / 1024).toFixed(1)} MB)`);
console.log(execSync(`unzip -l "${ARCHIVE}"`).toString());

const credsResp = await fetch(`${BASE}/api/hosting/v1/files/upload-urls`, {
  method: 'POST',
  headers: { 'Authorization': `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ file_paths: [`public_html/${FILENAME}`], username: USERNAME, domain: DOMAIN })
});
const creds = await credsResp.json();
if (!creds.url) { console.error('Failed to get creds:', creds); process.exit(1); }
const uploadUrl = creds.url.replace(/\/$/, '');
const fileUrl = `${uploadUrl}/public_html/${FILENAME}?override=true`;
const headers = { 'X-Auth': creds.auth_key, 'X-Auth-Rest': creds.rest_auth_key, 'upload-length': FILESIZE.toString(), 'upload-offset': '0' };
const preResp = await fetch(fileUrl, { method: 'POST', headers, body: '' });
if (preResp.status !== 201) { console.error('Pre-upload failed:', preResp.status, await preResp.text()); process.exit(1); }

const fileData = readFileSync(ARCHIVE);
const CHUNK = 8 * 1024 * 1024;
const tusAuth = { 'X-Auth': creds.auth_key, 'X-Auth-Rest': creds.rest_auth_key, 'Tus-Resumable': '1.0.0' };
let offset = 0;
while (offset < FILESIZE) {
  const end = Math.min(offset + CHUNK, FILESIZE);
  let done = false;
  for (let attempt = 1; attempt <= 4 && !done; attempt++) {
    try {
      const resp = await fetch(fileUrl, {
        method: 'PATCH',
        headers: { ...tusAuth, 'Content-Type': 'application/offset+octet-stream', 'upload-offset': String(offset) },
        body: fileData.subarray(offset, end),
        signal: AbortSignal.timeout(180000)
      });
      if (resp.status !== 204) throw new Error(`${resp.status} ${await resp.text()}`);
      offset = parseInt(resp.headers.get('upload-offset') || String(end), 10);
      done = true;
    } catch (e) {
      if (attempt === 4) { console.error(`\nChunk @${offset} failed: ${e.message || e}`); process.exit(1); }
      await new Promise(r => setTimeout(r, 2000 * attempt));
      try {
        const head = await fetch(fileUrl, { method: 'HEAD', headers: tusAuth, signal: AbortSignal.timeout(30000) });
        const srv = parseInt(head.headers.get('upload-offset') || '', 10);
        if (!Number.isNaN(srv)) offset = srv;
      } catch {}
    }
  }
  process.stdout.write(`\r  ${(offset / 1048576).toFixed(0)}/${(FILESIZE / 1048576).toFixed(0)} MB`);
}
console.log('\nUploaded.');

const deployResp = await fetch(`${BASE}/api/hosting/v1/accounts/${USERNAME}/websites/${DOMAIN}/deploy`, {
  method: 'POST',
  headers: { 'Authorization': `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ archive_path: `public_html/${FILENAME}` })
});
console.log(`Deploy trigger: ${deployResp.status} — ${(await deployResp.text()).slice(0, 200)}`);
try { unlinkSync(ARCHIVE); } catch {}

// The trigger's status code is not evidence (it has returned 500 on deploys that landed).
// The stamp proves the bytes reached the origin.
console.log('Verifying stamp...');
const DEADLINE = Date.now() + 240_000;
let live = null;
while (Date.now() < DEADLINE) {
  await new Promise(r => setTimeout(r, 5_000));
  try {
    const r = await fetch(`https://${DOMAIN}/deploy-stamp.txt?cb=${Date.now()}`, { cache: 'no-store' });
    if (r.ok) { live = (await r.text()).trim(); if (live === STAMP) break; }
  } catch {}
  process.stdout.write('.');
}
if (live !== STAMP) { console.error(`\n❌ NOT verified: site serves ${live ?? '(none)'}, expected ${STAMP}`); process.exit(1); }
console.log(`\n✅ Verified live (stamp ${STAMP}). Now run scripts/verify-public-release.sh ${STAGE_DIR}`);

#!/usr/bin/env node
// Publish only a previously verified, isolated Throttle stage to lorislab.fr.
// Usage: inject HOSTINGER_API_TOKEN in the process environment (never CLI/logs).
import { readFileSync, statSync, lstatSync, readdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { resolve, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const BASE = 'https://developers.hostinger.com';
const USERNAME = 'u376697750';
const DOMAIN = 'lorislab.fr';
const CHUNK = 8 * 1024 * 1024;

export class ReleaseFailure extends Error {}

export function validateStage(directory) {
  const stage = resolve(directory);
  const regular = path => lstatSync(path).isFile() && !lstatSync(path).isSymbolicLink();
  if (!lstatSync(stage).isDirectory() || lstatSync(stage).isSymbolicLink()) {
    throw new ReleaseFailure('Stage must be a real directory.');
  }
  const rootFiles = readdirSync(stage);
  if (rootFiles.some(name => !['throttle', 'deploy-stamp.txt'].includes(name))
      || (rootFiles.includes('deploy-stamp.txt') && !regular(`${stage}/deploy-stamp.txt`))) {
    throw new ReleaseFailure('Unexpected file in stage root.');
  }
  const content = `${stage}/throttle`;
  if (!lstatSync(content).isDirectory() || lstatSync(content).isSymbolicLink()) {
    throw new ReleaseFailure('Throttle stage must be a real directory.');
  }
  const names = readdirSync(content);
  const dmgs = names.filter(name => /^Throttle-[0-9]+(?:\.[0-9]+){0,2}\.dmg$/.test(name));
  if (names.length !== 3 || dmgs.length !== 1 || !names.includes('appcast.xml')
      || !names.includes('index.html') || names.some(name => !regular(`${content}/${name}`))) {
    throw new ReleaseFailure('Stage must contain exactly appcast.xml, index.html and one versioned DMG.');
  }
  return stage;
}

export function checkedOffset(value, minimum, maximum) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new ReleaseFailure('Upload returned a missing or invalid offset.');
  }
  const offset = Number(value);
  if (!Number.isSafeInteger(offset) || offset < minimum || offset > maximum) {
    throw new ReleaseFailure('Upload returned an out-of-range offset.');
  }
  return offset;
}

export async function uploadChunks(fileUrl, bytes, auth, {
  fetcher = fetch, sleep = ms => new Promise(resolveSleep => setTimeout(resolveSleep, ms)),
  progress = () => {}, chunkSize = CHUNK
} = {}) {
  if (!Number.isSafeInteger(chunkSize) || chunkSize <= 0) throw new ReleaseFailure('Invalid chunk size.');
  let offset = 0;
  while (offset < bytes.length) {
    const end = Math.min(offset + chunkSize, bytes.length);
    let done = false;
    for (let attempt = 1; attempt <= 4 && !done; attempt++) {
      try {
        const response = await fetcher(fileUrl, {
          method: 'PATCH',
          headers: { ...auth, 'Content-Type': 'application/offset+octet-stream', 'upload-offset': String(offset) },
          body: bytes.subarray(offset, end), signal: AbortSignal.timeout(180_000)
        });
        if (response.status !== 204) throw new ReleaseFailure('Upload chunk rejected.');
        offset = checkedOffset(response.headers.get('upload-offset'), end, end);
        done = true;
      } catch (error) {
        // Protocol violations must never be converted into fabricated progress.
        if (error instanceof ReleaseFailure && error.message !== 'Upload chunk rejected.') throw error;
        if (attempt === 4) throw new ReleaseFailure('Upload chunk failed after four attempts.');
        await sleep(2_000 * attempt);
        let head;
        try {
          head = await fetcher(fileUrl, {
            method: 'HEAD', headers: auth, signal: AbortSignal.timeout(30_000)
          });
        } catch { throw new ReleaseFailure('Upload state could not be reconciled.'); }
        if (!head.ok) throw new ReleaseFailure('Upload state could not be reconciled.');
        offset = checkedOffset(head.headers.get('upload-offset'), offset, end);
        // A lost PATCH response may already have committed this entire chunk.
        done = offset === end;
      }
    }
    progress(offset, bytes.length);
  }
}

export function uploadCredentials(value) {
  let url;
  try { url = new URL(value?.url); } catch { throw new ReleaseFailure('Upload credentials unavailable.'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash
      || typeof value.auth_key !== 'string' || !value.auth_key
      || typeof value.rest_auth_key !== 'string' || !value.rest_auth_key) {
    throw new ReleaseFailure('Upload credentials unavailable.');
  }
  return { url: url.href.replace(/\/$/, ''), auth: value.auth_key, restAuth: value.rest_auth_key };
}

export function packageStage(stage, archive, execute = execFileSync) {
  execute('/usr/bin/zip', ['-r', archive, '.', '-x', '.DS_Store'], { cwd: stage, stdio: 'ignore' });
}

export async function publish(directory, token, {
  fetcher = fetch, execute = execFileSync,
  sleep = ms => new Promise(resolveSleep => setTimeout(resolveSleep, ms)),
  now = Date.now, log = console.log
} = {}) {
  if (!directory || !token) throw new ReleaseFailure('Stage path and HOSTINGER_API_TOKEN are required.');
  const stage = validateStage(directory);
  const timestamp = new Date(now()).toISOString().replace(/[-:T]/g, '').substring(0, 14);
  const filename = `throttle-release-${timestamp}.zip`;
  const archive = `${dirname(stage)}/${filename}`;
  // Never merge into a previous ZIP from another attempt in the same second.
  try { lstatSync(archive); throw new ReleaseFailure('Release ZIP already exists; use a fresh attempt.'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  const stamp = `${timestamp}-${Math.random().toString(36).slice(2, 10)}`;
  writeFileSync(`${stage}/deploy-stamp.txt`, `${stamp}\n`);
  packageStage(stage, archive, execute);
  const size = statSync(archive).size;
  log(`Archive: ${basename(archive)} (${(size / 1048576).toFixed(1)} MB)`);

  const credentialsResponse = await fetcher(`${BASE}/api/hosting/v1/files/upload-urls`, {
    method: 'POST', signal: AbortSignal.timeout(30_000),
    headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ file_paths: [`public_html/${filename}`], username: USERNAME, domain: DOMAIN })
  });
  if (!credentialsResponse.ok) throw new ReleaseFailure('Upload credential request rejected.');
  let payload;
  try { payload = await credentialsResponse.json(); }
  catch { throw new ReleaseFailure('Upload credential response is invalid.'); }
  const credentials = uploadCredentials(payload);
  const fileUrl = `${credentials.url}/public_html/${filename}?override=true`;
  const auth = { 'X-Auth': credentials.auth, 'X-Auth-Rest': credentials.restAuth, 'Tus-Resumable': '1.0.0' };
  const pre = await fetcher(fileUrl, {
    method: 'POST', signal: AbortSignal.timeout(30_000),
    headers: { ...auth, 'upload-length': String(size), 'upload-offset': '0' }, body: ''
  });
  if (pre.status !== 201) throw new ReleaseFailure('Upload creation rejected.');
  await uploadChunks(fileUrl, readFileSync(archive), auth, { fetcher, sleep });
  log('Uploaded.');
  // Do not retry deployment blindly: an unknown HTTP result may have applied it.
  const deployed = await fetcher(`${BASE}/api/hosting/v1/accounts/${USERNAME}/websites/${DOMAIN}/deploy`, {
    method: 'POST', signal: AbortSignal.timeout(30_000),
    headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ archive_path: `public_html/${filename}` })
  });
  log(`Deploy trigger HTTP ${deployed.status}; awaiting public stamp.`);
  const deadline = now() + 240_000;
  let verified = false;
  while (now() < deadline) {
    await sleep(5_000);
    try {
      const response = await fetcher(`https://${DOMAIN}/deploy-stamp.txt?cb=${now()}`, {
        cache: 'no-store', signal: AbortSignal.timeout(15_000)
      });
      if (response.ok && (await response.text()).trim() === stamp) { verified = true; break; }
    } catch { /* The bounded stamp loop tolerates transient public reads. */ }
  }
  if (!verified) throw new ReleaseFailure('Publication not verified: expected stamp was not observed.');
  unlinkSync(archive);
  log(`Verified live stamp ${stamp}. Run scripts/verify-public-release.sh on the stage.`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  publish(process.argv[2], process.env.HOSTINGER_API_TOKEN).catch(error => {
    // HTTP bodies, credential objects and arbitrary provider errors may contain secrets.
    console.error(error instanceof ReleaseFailure ? error.message : 'Release failed; provider details suppressed.');
    process.exitCode = 1;
  });
}

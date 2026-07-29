// Assign a freshly-uploaded TestFlight build to the Internal beta group.
// The group has hasAccessToAllBuilds=false (ASC API forbids flipping it after
// creation), so every CI upload must be linked explicitly or it never shows
// up in TestFlight (builds 13/14 were invisible for this reason).
// Usage: node assign-build-to-group.mjs <cfBundleVersion>
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';

const APP_ID = '6788901240'; // Throttle — Claude Usage (com.lorislab.throttle.ios)
const GROUP_ID = '28f39d55-280c-460c-8bf0-b837f88c105f'; // Internal
const VERSION = process.argv[2];
if (!VERSION) { console.error('missing CFBundleVersion arg'); process.exit(1); }

const KID = process.env.ASC_KEY_ID, ISS = process.env.ASC_ISSUER_ID;
const KEY = fs.readFileSync(`${os.homedir()}/private_keys/AuthKey_${KID}.p8`, 'utf8');

function token() {
  const b64 = (b) => Buffer.from(b).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  const now = Math.floor(Date.now() / 1000);
  const si = b64(JSON.stringify({ alg: 'ES256', kid: KID, typ: 'JWT' })) + '.' +
    b64(JSON.stringify({ iss: ISS, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' }));
  return si + '.' + b64(crypto.sign('sha256', Buffer.from(si), { key: KEY, dsaEncoding: 'ieee-p1363' }));
}

const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

// altool returns before ASC processing finishes; the build record can take many
// minutes to appear AND several more to become assignable. Poll until the build is
// not just visible but PROCESSED (processingState VALID) — assigning a build that's
// still PROCESSING returns 404 on the relationships endpoint, which used to fail the
// job even though the upload was fine (build 18). Up to 30 min.
let build = null;
for (let i = 0; i < 30; i++) {
  const r = await fetch(
    `https://api.appstoreconnect.apple.com/v1/builds?filter[app]=${APP_ID}&filter[version]=${VERSION}&limit=1`,
    { headers: { Authorization: 'Bearer ' + token() } });
  const b = (await r.json()).data?.[0] ?? null;
  const state = b?.attributes?.processingState;
  if (b && state === 'VALID') { build = b; break; }
  console.log(`build ${VERSION} ${b ? `still ${state}` : 'not visible yet'} (attempt ${i + 1}/30)`);
  await sleep(60);
}
if (!build) { console.error(`build ${VERSION} never became assignable (VALID) in ASC`); process.exit(1); }

// The relationships POST can still 404/409 in the moments right after VALID —
// retry a few times before giving up, so a tight race doesn't strand the build.
let assigned = false;
for (let i = 0; i < 8 && !assigned; i++) {
  const r = await fetch(`https://api.appstoreconnect.apple.com/v1/betaGroups/${GROUP_ID}/relationships/builds`, {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + token(), 'Content-Type': 'application/json' },
    body: JSON.stringify({ data: [{ type: 'builds', id: build.id }] }),
  });
  if (r.status === 204) { assigned = true; break; }
  const body = await r.text();
  // A build already in the group comes back as 409 — that's success, not failure.
  if (r.status === 409) { assigned = true; break; }
  console.log(`assign attempt ${i + 1}/8 got ${r.status} ${body.slice(0, 120)}`);
  await sleep(20);
}
if (!assigned) { console.error(`build ${VERSION} (${build.id}) could not be assigned to Internal group`); process.exit(1); }
console.log(`build ${VERSION} (${build.id}) assigned to Internal group`);

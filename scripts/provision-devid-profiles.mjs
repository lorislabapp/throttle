#!/usr/bin/env node
// Provision the Developer ID provisioning profiles that build-dmg.sh needs.
//
// WHY: Throttle uses the CloudKit entitlement (iOS-companion mirror). CloudKit is
// a RESTRICTED entitlement → the signed app must embed a provisioning profile that
// authorizes it. Automatic signing can mint that profile, but only with an Apple ID
// added in Xcode. This build machine signs headlessly (Developer ID cert straight
// from the keychain, no Xcode account), so we mint the profiles out-of-band via the
// App Store Connect API and pin them (manual signing in project.yml).
//
// Idempotent: deletes+recreates the two named profiles, installs them into
// ~/Library/MobileDevice/Provisioning Profiles/. Run once, and again whenever the
// Developer ID certificate rotates.
//
// Credentials (never hardcoded): ASC issuer_id + key_id from Bitwarden item
// "App Store Connect"; the .p8 private key from ~/Downloads/AuthKey_<key_id>.p8.
//
//   node scripts/provision-devid-profiles.mjs
//
// Prereqs on the portal (one-time, done via developer.apple.com):
//   - App IDs com.lorislab.throttle (iCloud+CloudKit, container iCloud.com.lorislab.throttle)
//     and com.lorislab.throttle.widget (App Groups) exist.

import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import { execFileSync } from 'node:child_process';

function bw(field) {
  return execFileSync(os.homedir() + '/.claude/bw-env.py',
    ['--get', 'App Store Connect', '--field', field], { encoding: 'utf8' }).trim();
}

const ISS = bw('issuer_id');
const KID = bw('key_id');
const KEY = fs.readFileSync(os.homedir() + `/Downloads/AuthKey_${KID}.p8`, 'utf8');

const b64url = (b) => Buffer.from(b).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
function jwt() {
  const now = Math.floor(Date.now() / 1000);
  const si = b64url(JSON.stringify({ alg: 'ES256', kid: KID, typ: 'JWT' })) + '.' +
             b64url(JSON.stringify({ iss: ISS, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' }));
  const sig = crypto.sign('sha256', Buffer.from(si), { key: KEY, dsaEncoding: 'ieee-p1363' });
  return si + '.' + b64url(sig);
}
const TOKEN = jwt();
async function api(path, opts = {}) {
  const res = await fetch('https://api.appstoreconnect.apple.com/v1/' + path, {
    ...opts, headers: { Authorization: 'Bearer ' + TOKEN, 'Content-Type': 'application/json', ...(opts.headers || {}) },
  });
  const text = await res.text();
  let json; try { json = JSON.parse(text); } catch { json = text; }
  return { status: res.status, json };
}

const certs = await api('certificates?filter[certificateType]=DEVELOPER_ID_APPLICATION&limit=200');
if (certs.status !== 200 || !certs.json.data?.length) { console.error('cert lookup failed', certs.status); process.exit(1); }
// Include EVERY Developer ID cert so whichever one is in the local keychain matches.
const certData = certs.json.data.map(c => ({ type: 'certificates', id: c.id }));
console.error('certs:', certs.json.data.map(c => c.id + ':' + c.attributes.serialNumber).join(', '));

const DEST = os.homedir() + '/Library/MobileDevice/Provisioning Profiles';
fs.mkdirSync(DEST, { recursive: true });

async function makeProfile(name, bundleIdentifier) {
  const r = await api('bundleIds?filter[identifier]=' + encodeURIComponent(bundleIdentifier) + '&limit=200');
  const b = r.json.data?.find(d => d.attributes?.identifier === bundleIdentifier);
  if (!b) { console.error('BUNDLE MISSING (register it on the portal):', bundleIdentifier); process.exit(1); }
  const existing = await api('profiles?filter[name]=' + encodeURIComponent(name) + '&limit=200');
  for (const p of (existing.json.data || [])) {
    if (p.attributes?.name === name) await api('profiles/' + p.id, { method: 'DELETE' });
  }
  const body = { data: { type: 'profiles', attributes: { name, profileType: 'MAC_APP_DIRECT' },
    relationships: { bundleId: { data: { type: 'bundleIds', id: b.id } }, certificates: { data: certData } } } };
  const res = await api('profiles', { method: 'POST', body: JSON.stringify(body) });
  if (res.status !== 201) { console.error('PROFILE ERR', bundleIdentifier, res.status, JSON.stringify(res.json).slice(0, 600)); process.exit(1); }
  const { uuid, profileContent } = res.json.data.attributes;
  fs.writeFileSync(`${DEST}/${uuid}.provisionprofile`, Buffer.from(profileContent, 'base64'));
  console.error(`OK  ${name}  (${bundleIdentifier})  uuid ${uuid}`);
}

await makeProfile('Throttle DevID iCloud', 'com.lorislab.throttle');
await makeProfile('Throttle Widget DevID', 'com.lorislab.throttle.widget');
console.error('done — profiles installed in', DEST);

#!/usr/bin/env node
// Mint the iOS App Store provisioning profiles the ThrottleiOS companion needs.
//
// WHY: The build machine signs headlessly (no Apple ID in Xcode), so App Store
// distribution profiles are minted out-of-band via the ASC API and pinned via
// manual signing in project.yml (CODE_SIGN_IDENTITY "Apple Distribution").
// Mirrors scripts/provision-devid-profiles.mjs but for the iOS targets.
//
// Idempotent: registers the widget bundle id if missing (+ App Groups capability),
// deletes+recreates the two named IOS_APP_STORE profiles, installs them into
// ~/Library/MobileDevice/Provisioning Profiles/. Re-run whenever the Apple
// Distribution certificate rotates OR after the iCloud container / App Group
// association changes (see scripts/associate-ios-icloud.rb) — the profile only
// embeds the entitlements that were associated at mint time.
//
// Credentials (never hardcoded): ASC issuer_id + key_id from Bitwarden item
// "App Store Connect"; the .p8 from ~/Downloads/AuthKey_<key_id>.p8.
// CI override: set ASC_KEY_ID + ASC_ISSUER_ID + ASC_KEY_P8_PATH env vars and
// Bitwarden is skipped entirely (GitHub runners have no vault).
//
//   node scripts/provision-ios-appstore.mjs
//
// Prereq on the portal (one-time): the iOS App IDs must have the iCloud container
// iCloud.com.lorislab.throttle and App Group group.com.lorislab.throttle ASSOCIATED
// (not merely the capability enabled). The public ASC API cannot do that — run
// scripts/associate-ios-icloud.rb first (Spaceship, needs a fresh FASTLANE_SESSION).

import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import { execFileSync } from 'node:child_process';

function bw(field) {
  return execFileSync(os.homedir() + '/.claude/bw-env.py',
    ['--get', 'App Store Connect', '--field', field], { encoding: 'utf8' }).trim();
}

const ISS = process.env.ASC_ISSUER_ID || bw('issuer_id');
const KID = process.env.ASC_KEY_ID || bw('key_id');
const KEY = fs.readFileSync(process.env.ASC_KEY_P8_PATH || os.homedir() + `/Downloads/AuthKey_${KID}.p8`, 'utf8');

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

// All Apple Distribution certs, so whichever is in the local keychain matches.
const certs = await api('certificates?filter[certificateType]=DISTRIBUTION&limit=200');
if (certs.status !== 200 || !certs.json.data?.length) { console.error('cert lookup failed', certs.status); process.exit(1); }
const certData = certs.json.data.map(c => ({ type: 'certificates', id: c.id }));
console.error('certs:', certs.json.data.map(c => c.id + ':' + c.attributes.serialNumber).join(', '));

const DEST = os.homedir() + '/Library/MobileDevice/Provisioning Profiles';
fs.mkdirSync(DEST, { recursive: true });

async function getBundle(identifier) {
  const r = await api('bundleIds?filter[identifier]=' + encodeURIComponent(identifier) + '&limit=200');
  return r.json.data?.find(d => d.attributes?.identifier === identifier);
}

// The widget bundle id is not published to App Store Connect on its own, so it may
// not exist as a portal identifier — register it (with App Groups) if missing.
let widget = await getBundle('com.lorislab.throttle.ios.widget');
if (!widget) {
  const r = await api('bundleIds', { method: 'POST', body: JSON.stringify({ data: { type: 'bundleIds',
    attributes: { identifier: 'com.lorislab.throttle.ios.widget', name: 'Throttle iOS Widget', platform: 'IOS', seedId: 'TDV6D5L785' } } }) });
  if (r.status !== 201) { console.error('widget bundle register failed', r.status, JSON.stringify(r.json).slice(0, 400)); process.exit(1); }
  widget = r.json.data;
  console.error('registered widget bundle', widget.id);
}
const wcaps = await api('bundleIds/' + widget.id + '?include=bundleIdCapabilities');
if (!(wcaps.json.included || []).some(x => x.attributes?.capabilityType === 'APP_GROUPS')) {
  await api('bundleIdCapabilities', { method: 'POST', body: JSON.stringify({ data: { type: 'bundleIdCapabilities',
    attributes: { capabilityType: 'APP_GROUPS' }, relationships: { bundleId: { data: { type: 'bundleIds', id: widget.id } } } } }) });
  console.error('enabled APP_GROUPS on widget bundle');
}

async function makeProfile(name, bundleIdentifier) {
  const b = await getBundle(bundleIdentifier);
  if (!b) { console.error('BUNDLE MISSING:', bundleIdentifier); process.exit(1); }
  const existing = await api('profiles?filter[name]=' + encodeURIComponent(name) + '&limit=200');
  for (const p of (existing.json.data || [])) {
    if (p.attributes?.name === name) await api('profiles/' + p.id, { method: 'DELETE' });
  }
  const body = { data: { type: 'profiles', attributes: { name, profileType: 'IOS_APP_STORE' },
    relationships: { bundleId: { data: { type: 'bundleIds', id: b.id } }, certificates: { data: certData } } } };
  const res = await api('profiles', { method: 'POST', body: JSON.stringify(body) });
  if (res.status !== 201) { console.error('PROFILE ERR', bundleIdentifier, res.status, JSON.stringify(res.json).slice(0, 600)); process.exit(1); }
  const { uuid, profileContent } = res.json.data.attributes;
  fs.writeFileSync(`${DEST}/${uuid}.mobileprovision`, Buffer.from(profileContent, 'base64'));
  console.error(`OK  ${name}  (${bundleIdentifier})  uuid ${uuid}`);
}

await makeProfile('Throttle iOS App Store', 'com.lorislab.throttle.ios');
await makeProfile('Throttle iOS Widget App Store', 'com.lorislab.throttle.ios.widget');
console.error('done — profiles installed in', DEST);

// tools/check_deploy.mjs against a deployment held in memory: what it accepts, and each thing it
// must flag, including what the audit measured on pwa.buybeam.my (the loader under the page
// policy, no HSTS, no CORS on the app's files, Cloudflare rewriting no-cache to max-age=14400).
import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto, createHash } from 'node:crypto';
import { checkDeploy, expectedHeaders } from '../../tools/check_deploy.mjs';
import { mimeFor, headersFor, CSP, RECOVERY_RELAY, EXPLORER_PROXY } from '../../tools/headers.mjs';
import { RELEASE_APP_ID } from '../../src/lib/release.js';

const s = webcrypto.subtle;
const sha = (b) => createHash('sha256').update(b).digest('hex');
const BASE = 'https://wallet.example/';

async function signer() {
  const k = await s.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const j = await s.exportKey('jwk', k.publicKey);
  return { priv: k.privateKey, pub: { kty: j.kty, crv: j.crv, x: j.x, y: j.y } };
}

/** A small signed deployment: { files: path -> Buffer } including the three release files. */
async function site(priv) {
  const loaderBody = 'self.addEventListener("fetch", () => {});\n';
  const loader = `sw-${sha(Buffer.from(loaderBody)).slice(0, 16)}.js`;
  const files = {
    'index.html': Buffer.from('<!doctype html><title>Beam PWA</title>'),
    'app.js': Buffer.from('console.log(1);'),
    'css/app.css': Buffer.from('body{}'),
    'lib/version.js': Buffer.from(`export const LOADER = ${JSON.stringify(loader)};\n`),
    'vendor/engine/wasm-client.wasm': Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]),
    [loader]: Buffer.from(loaderBody),
  };
  const entries = Object.entries(files).map(([path, b]) => ({ path, sha256: sha(b), size: b.length }));
  const manifest = Buffer.from(JSON.stringify({ app: RELEASE_APP_ID, version: '1.0.0', files: entries }));
  const release = Buffer.from(JSON.stringify({ app: RELEASE_APP_ID, version: '1.0.0', created: '2026-10-12T00:00:00.000Z', manifest_sha256: sha(manifest), file_count: entries.length, loader }));
  const sig = Buffer.from(Buffer.from(await s.sign({ name: 'ECDSA', hash: 'SHA-256' }, priv, release)).toString('base64'));
  return { loader, files: { ...files, 'manifest.json': manifest, 'release.json': release, 'release.sig': sig } };
}

/**
 * A host serving `files` at BASE with the production headers (and the two proxies, and http://
 * redirecting to https://); tweak(rel, headers, method) may change an answer.
 */
function host(files, tweak = () => {}) {
  const asked = [];
  const fetchImpl = async (url, init) => {
    asked.push({ url, method: init.method });
    if (url.startsWith('http://')) return new Response(null, { status: 301, headers: { Location: url.replace('http://', 'https://') } });
    const rel = url.startsWith(BASE) ? decodeURIComponent(url.slice(BASE.length)) : null;
    const proxy = `/${rel}` === RECOVERY_RELAY || `/${rel}` === EXPLORER_PROXY;
    const headers = { ...expectedHeaders(rel || ''), 'Content-Type': mimeFor(rel || '') };
    if (`/${rel}` === RECOVERY_RELAY) Object.assign(headers, { 'Content-Type': 'application/octet-stream', 'Cache-Control': 'max-age=14400', 'Content-Length': '328982248' });
    let body = rel !== null && rel in files ? files[rel] : proxy ? Buffer.from('{}') : null;
    let status = body ? 200 : 404;
    if (init.method === 'OPTIONS') ({ body, status } = proxy ? { body: null, status: 204 } : { body: null, status: 405 });
    const t = tweak(rel, headers, init.method);
    if (t) ({ body = body, status = status } = t);
    return new Response(init.method === 'HEAD' || status === 204 ? null : body || 'not found', { status, headers });
  };
  return { fetchImpl, asked };
}

test('a deployment that matches its signed release: OK, reading only (GET; HEAD and a preflight on the relay)', async () => {
  const k = await signer();
  const { files } = await site(k.priv);
  const h = host(files);
  const r = await checkDeploy({ base: BASE, publicJwk: k.pub, fetchImpl: h.fetchImpl });
  assert.deepEqual(r.problems, []);
  assert.equal(r.ok, true);
  assert.equal(r.files, 6);
  for (const a of h.asked) {
    const relay = a.url === new URL(RECOVERY_RELAY.slice(1), BASE).href;
    assert.ok(a.method === 'GET' || (relay && ['HEAD', 'OPTIONS'].includes(a.method)), `${a.method} ${a.url}`);
  }
  assert.ok(!h.asked.some((a) => a.url.endsWith(RECOVERY_RELAY) && a.method === 'GET'), 'the 330 MB snapshot is never downloaded');
  assert.ok(h.asked.some((a) => /__campfire_check_deploy_/.test(a.url)), 'a 404 was looked at too');
  assert.ok(h.asked.some((a) => a.url === 'http://wallet.example/'), 'and http://');
});

test('what the audit measured on pwa.buybeam.my is flagged, file by file', async () => {
  const k = await signer();
  const { files, loader } = await site(k.priv);
  const live = host(files, (rel, headers) => {
    // The hand-written server config: the page policy on the loader, no HSTS, no CORS on app files.
    if (rel === loader) headers['Content-Security-Policy'] = CSP;
    delete headers['Strict-Transport-Security'];
    if (rel in files) delete headers['Access-Control-Allow-Origin'];
    // Cloudflare: no-cache rewritten for scripts, styles, fonts and images.
    if (/\.(js|css|png|svg|ttf)$/.test(rel || '')) headers['Cache-Control'] = 'max-age=14400';
  });
  const r = await checkDeploy({ base: BASE, publicJwk: k.pub, fetchImpl: live.fetchImpl });
  assert.equal(r.ok, false);
  assert.ok(r.problems.some((p) => p.startsWith(`${loader}: Content-Security-Policy: default-src 'self'`)), 'the loader under the page policy');
  assert.ok(r.problems.includes('index.html: Strict-Transport-Security: missing (want max-age=31536000)'));
  assert.ok(r.problems.includes('app.js: Access-Control-Allow-Origin: missing (want *)'));
  for (const p of ['app.js', 'css/app.css', 'lib/version.js', loader]) assert.ok(r.problems.includes(`${p}: Cache-Control: max-age=14400 (want no-cache)`), p);
  assert.ok(!r.problems.some((p) => p.startsWith('index.html: Cache-Control')), 'index.html kept no-cache');
});

test('the recovery relay must be readable by any copy, and answer its preflight; the explorer proxy must not be', async () => {
  const k = await signer();
  const { files } = await site(k.priv);
  // What the repository's earlier nginx.conf did: no CORS on the relay, limit_except refusing OPTIONS.
  let r = await checkDeploy({
    base: BASE,
    publicJwk: k.pub,
    fetchImpl: host(files, (rel, headers, method) => {
      if (`/${rel}` !== RECOVERY_RELAY) return null;
      for (const h of Object.keys(headers)) if (h.startsWith('Access-Control-')) delete headers[h];
      headers['Cross-Origin-Resource-Policy'] = 'same-origin';
      return method === 'OPTIONS' ? { status: 403 } : null;
    }).fetchImpl,
  });
  assert.ok(r.problems.includes(`${RECOVERY_RELAY.slice(1)}: Access-Control-Allow-Origin: missing (want *)`), r.problems.join('\n'));
  assert.ok(r.problems.includes(`${RECOVERY_RELAY.slice(1)}: Cross-Origin-Resource-Policy: same-origin (want cross-origin)`));
  assert.ok(r.problems.includes(`${RECOVERY_RELAY.slice(1)} (preflight): HTTP 403 (want 204 or 200)`));
  // The explorer proxy open to every origin.
  r = await checkDeploy({ base: BASE, publicJwk: k.pub, fetchImpl: host(files, (rel, headers) => void (`/${rel}` === EXPLORER_PROXY && (headers['Access-Control-Allow-Origin'] = '*'))).fetchImpl });
  assert.ok(r.problems.includes(`${EXPLORER_PROXY.slice(1)}: Access-Control-Allow-Origin: * (want none: this origin's own)`), r.problems.join('\n'));
  // No relay at all (a static host): said once, not a failure of every header.
  r = await checkDeploy({ base: BASE, publicJwk: k.pub, fetchImpl: host(files, (rel) => (`/${rel}` === RECOVERY_RELAY ? { status: 404 } : null)).fetchImpl });
  assert.ok(r.problems.includes(`${RECOVERY_RELAY.slice(1)}: HTTP 404 (no snapshot relay here)`));
  assert.ok(!r.problems.some((p) => p.startsWith(`${RECOVERY_RELAY.slice(1)}: Access`)));
});

test('flagged: an altered file, a wrong type, a missing policy, a forged release, an empty host, no https redirect', async () => {
  const k = await signer();
  const { files } = await site(k.priv);
  let r = await checkDeploy({ base: BASE, publicJwk: k.pub, fetchImpl: host(files, (rel) => (rel === 'app.js' ? { body: Buffer.from('console.log(2);') } : null)).fetchImpl });
  assert.ok(r.problems.some((p) => /^app\.js: not the signed file/.test(p)), r.problems.join('\n'));
  r = await checkDeploy({
    base: BASE,
    publicJwk: k.pub,
    fetchImpl: host(files, (rel, headers) => {
      if (rel === 'index.html') delete headers['Content-Security-Policy'];
      if (rel === 'vendor/engine/wasm-client.wasm') headers['Content-Type'] = 'application/octet-stream';
    }).fetchImpl,
  });
  assert.ok(r.problems.some((p) => p.startsWith('index.html: Content-Security-Policy: missing')));
  assert.ok(r.problems.includes('vendor/engine/wasm-client.wasm: Content-Type application/octet-stream (want application/wasm)'));
  const other = await signer();
  r = await checkDeploy({ base: BASE, publicJwk: other.pub, fetchImpl: host(files).fetchImpl });
  assert.equal(r.ok, false);
  assert.match(r.problems[0], /^release: This update is not signed with the BEAM Campfire release key/);
  r = await checkDeploy({ base: BASE, publicJwk: k.pub, fetchImpl: host({}).fetchImpl });
  assert.match(r.problems[0], /^release: release\.json: HTTP 404/);
  const plain = host(files);
  r = await checkDeploy({ base: BASE, publicJwk: k.pub, fetchImpl: async (url, init) => (url.startsWith('http://') ? new Response('the wallet, over http', { status: 200 }) : plain.fetchImpl(url, init)) });
  assert.ok(r.problems.includes('http://wallet.example/: HTTP 200 (want a redirect to https://)'));
});

test('a public copy (--copy: GitHub Pages, jsDelivr): signature, files and CORS only', async () => {
  const k = await signer();
  const { files } = await site(k.priv);
  // Pages sends none of the security headers, but CORS on every file.
  const pages = host(files, (rel, headers) => {
    for (const h of Object.keys(headers)) if (h !== 'Access-Control-Allow-Origin' && h !== 'Content-Type') delete headers[h];
  });
  const r = await checkDeploy({ base: BASE, publicJwk: k.pub, fetchImpl: pages.fetchImpl, copy: true });
  assert.deepEqual(r.problems, []);
  assert.ok(!pages.asked.some((a) => a.url.includes('recovery') || a.url.includes('explorer') || a.url.startsWith('http://')), 'a copy has no proxies to check');
  const noCors = host(files, (rel, headers) => void delete headers['Access-Control-Allow-Origin']);
  const r2 = await checkDeploy({ base: BASE, publicJwk: k.pub, fetchImpl: noCors.fetchImpl, copy: true });
  assert.ok(r2.problems.includes('release.json: Access-Control-Allow-Origin: missing (want *)'), 'installs elsewhere could not read it');
});

test('expected headers come from tools/headers.mjs', () => {
  assert.deepEqual(expectedHeaders('index.html'), { ...headersFor('index.html'), 'Cache-Control': 'no-cache' });
  assert.equal(expectedHeaders(RECOVERY_RELAY.slice(1))['Cache-Control'], undefined, "the relay keeps BEAM's caching headers");
});

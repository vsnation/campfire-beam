/* BEAM Campfire service worker.
 *
 * It serves the app only from a release it verified itself:
 *   - release.json is signed (ECDSA P-256 / SHA-256) by the BEAM Campfire
 *     release key, whose public half is built into this file;
 *   - manifest.json must hash to the value in release.json;
 *   - every file must match its size and SHA-256 in manifest.json.
 * The first install caches the release only if all of that holds. Later
 * releases are downloaded and verified on request ("check-update") into a
 * separate cache, and become the served copy only on "apply-update", which
 * only the Update button sends. A tampered file or bad signature leaves the
 * current copy in place. Every response gets the security headers (COOP/COEP
 * for the engine's SharedArrayBuffer, CSP, CORP) because a response from the
 * cache would otherwise carry none.
 *
 * Not served from the cache (go to the network as they are): the release
 * files themselves, sw.js, the recovery snapshot, the explorer status and
 * dev-server paths. The BEAM node is a WebSocket, which never passes here.
 *
 * The build (tools/build.mjs) fills in the placeholders and inlines
 * lib/release.js where marked.
 */
'use strict';

const RELEASE_PUBLIC_JWK = /*__RELEASE_PUBLIC_JWK__*/ null;
const SW_VERSION = '__BUILD_VERSION__';
const SECURITY_HEADERS = /*__SECURITY_HEADERS__*/ {};
const MIME = /*__MIME__*/ {};

/*__INLINE_RELEASE_JS__*/

const META_CACHE = 'campfire-meta';
const scopeUrl = new URL(self.registration.scope);
const STATE_KEY = new URL('__campfire_state', scopeUrl).href;
const PASSTHROUGH = [/^release\.json$/, /^release\.sig$/, /^manifest\.json$/, /^sw\.js$/, /^recovery\//, /^explorer\//, /^__dev\//, /^_headers$/];

let stateCache = null;
let updateRun = null;

function mimeFor(path) {
  const i = path.lastIndexOf('.');
  return (i >= 0 && MIME[path.slice(i).toLowerCase()]) || 'application/octet-stream';
}

async function readState() {
  if (stateCache) return stateCache;
  const c = await caches.open(META_CACHE);
  const r = await c.match(STATE_KEY);
  stateCache = r ? await r.json() : { current: null, pending: null };
  return stateCache;
}

async function writeState(st) {
  const c = await caches.open(META_CACHE);
  await c.put(STATE_KEY, new Response(JSON.stringify(st), { headers: { 'Content-Type': 'application/json' } }));
  stateCache = st;
}

function relPath(url) {
  let p = url.pathname;
  if (!p.startsWith(scopeUrl.pathname)) return null;
  p = p.slice(scopeUrl.pathname.length);
  if (p === '' || p.endsWith('/')) p += 'index.html';
  try {
    return decodeURIComponent(p);
  } catch {
    return null;
  }
}

async function fetchBytes(path) {
  let r;
  try {
    r = await fetch(new URL(path, scopeUrl).href, { cache: 'no-store', credentials: 'same-origin' });
  } catch {
    throw new ReleaseError('unreachable', `Could not download ${path}.`);
  }
  if (!r.ok) throw new ReleaseError('unreachable', `${path}: HTTP ${r.status}`);
  return new Uint8Array(await r.arrayBuffer());
}

async function fetchVerifiedRelease() {
  const relBytes = await fetchBytes('release.json');
  const sig = new TextDecoder().decode(await fetchBytes('release.sig'));
  const release = await verifyReleaseSignature(relBytes, sig, RELEASE_PUBLIC_JWK);
  const manifest = await verifyManifest(release, await fetchBytes('manifest.json'));
  return { release, manifest };
}

async function stageRelease({ release, manifest }) {
  const cacheName = `campfire-${release.version}-${release.manifest_sha256.slice(0, 16)}`;
  await caches.delete(cacheName);
  const cache = await caches.open(cacheName);
  try {
    for (const f of manifest.files) {
      const bytes = await fetchBytes(f.path);
      await verifyFile(f, bytes);
      await cache.put(new URL(f.path, scopeUrl).href, new Response(bytes, { headers: { 'Content-Type': mimeFor(f.path) } }));
    }
  } catch (e) {
    await caches.delete(cacheName);
    throw e;
  }
  const files = {};
  for (const f of manifest.files) files[f.path] = f.sha256;
  return { version: release.version, cache: cacheName, files, manifestSha: release.manifest_sha256, verifiedAt: Date.now() };
}

async function cleanup(st) {
  const keep = new Set([META_CACHE, st.current && st.current.cache, st.pending && st.pending.cache].filter(Boolean));
  for (const name of await caches.keys()) if (name.startsWith('campfire-') && !keep.has(name)) await caches.delete(name);
}

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const st = await readState();
      if (!st.current) {
        // First install: nothing is served until a signed release verified.
        const current = await stageRelease(await fetchVerifiedRelease());
        await writeState({ current, pending: null, lastRefusal: null });
      }
      // A later sw.js (the browser re-downloads it on its own) changes how
      // files are served, never which files: it keeps the verified copy.
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const st = await readState();
      await cleanup(st);
      await self.clients.claim();
    })(),
  );
});

function withHeaders(resp, path) {
  const h = new Headers(SECURITY_HEADERS);
  h.set('Content-Type', mimeFor(path));
  h.set('Cache-Control', 'no-cache');
  return new Response(resp.body, { status: 200, headers: h });
}

async function serve(request, path) {
  const st = await readState();
  if (st.current && Object.prototype.hasOwnProperty.call(st.current.files, path)) {
    const cache = await caches.open(st.current.cache);
    const hit = await cache.match(new URL(path, scopeUrl).href);
    if (hit) return withHeaders(hit, path);
  }
  return fetch(request);
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  const path = relPath(url);
  if (path === null || PASSTHROUGH.some((r) => r.test(path))) return;
  event.respondWith(serve(req, path));
});

async function checkUpdate() {
  const st = await readState();
  let rel;
  try {
    rel = await fetchVerifiedRelease();
  } catch (e) {
    const code = e && e.code;
    if (code === 'unreachable') return { result: 'unreachable', reason: e.message };
    st.lastRefusal = { at: Date.now(), reason: e.message };
    await writeState(st);
    return { result: 'refused', reason: e.message };
  }
  const v = rel.release.version;
  if (!st.current) return { result: 'none' };
  const cmp = compareVersions(v, st.current.version);
  if (cmp === 0 && rel.release.manifest_sha256 !== st.current.manifestSha) {
    return { result: 'refused', version: v, reason: `A different release claims version ${v}.` };
  }
  if (cmp <= 0) return { result: 'none', version: st.current.version };
  if (st.pending && st.pending.version === v && st.pending.manifestSha === rel.release.manifest_sha256) return { result: 'ready', version: v };
  try {
    const staged = await stageRelease(rel);
    st.pending = staged;
    st.lastRefusal = null;
    await writeState(st);
    await cleanup(st);
    return { result: 'ready', version: v };
  } catch (e) {
    if (e && e.code === 'unreachable') return { result: 'unreachable', reason: e.message };
    st.lastRefusal = { at: Date.now(), reason: e.message, version: v };
    await writeState(st);
    return { result: 'refused', version: v, reason: e.message };
  }
}

async function applyUpdate() {
  const st = await readState();
  if (!st.pending) return { result: 'none' };
  const next = { current: st.pending, pending: null, lastRefusal: null, previous: st.current && st.current.version };
  await writeState(next);
  await cleanup(next);
  return { result: 'applied', version: next.current.version };
}

self.addEventListener('message', (event) => {
  const port = event.ports && event.ports[0];
  if (!port) return;
  const type = event.data && event.data.type;
  event.waitUntil(
    (async () => {
      try {
        if (type === 'status') {
          const st = await readState();
          port.postMessage({
            swVersion: SW_VERSION,
            current: st.current && st.current.version,
            pending: st.pending && st.pending.version,
            currentSw: st.current && st.current.files['sw.js'],
            pendingSw: st.pending && st.pending.files['sw.js'],
            lastRefusal: st.lastRefusal || null,
          });
        } else if (type === 'check-update') {
          if (!updateRun) updateRun = checkUpdate().finally(() => (updateRun = null));
          port.postMessage(await updateRun);
        } else if (type === 'apply-update') {
          port.postMessage(await applyUpdate());
        } else {
          port.postMessage({ result: 'error', reason: 'unknown request' });
        }
      } catch (e) {
        port.postMessage({ result: 'error', reason: String((e && e.message) || e) });
      }
    })(),
  );
});

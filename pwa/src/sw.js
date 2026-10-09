/* BEAM Campfire service worker (the "loader").
 *
 * It serves the app only from a release it verified itself:
 *   - release.json is signed (ECDSA P-256 / SHA-256) by the BEAM Campfire
 *     release key, whose public half is built into this file;
 *   - manifest.json must hash to the value in release.json;
 *   - every file must match its size and SHA-256 in manifest.json.
 *
 * First install: files are downloaded (6 at a time, largest first) into a staging cache and
 * each is kept only after its hash matched. The install can be interrupted
 * (app closed, connection lost) and continues where it stopped: files already
 * staged are re-checked and kept. Nothing is served until the whole signed
 * release verified. Progress is written to the meta cache, where the page
 * reads it to show "x of y files checked".
 *
 * Installed: every app file comes from the verified copy and nothing else.
 * A path that is not in the release gets a 404 from here, never a network
 * request, so the app keeps working when its web address is down, returns 404
 * everywhere or serves a parking page. Later releases are downloaded and
 * verified only on request ("check-update": the Check for updates button)
 * into a separate cache, and become the served copy only on "apply-update",
 * which only the Update button sends.
 *
 * Every response gets the security headers (COOP/COEP for the engine's
 * SharedArrayBuffer, CSP, CORP): a response from the cache would carry none.
 *
 * dApp frames: a navigation to dapp-run/<policy>/... is answered with the
 * frame document built from the verified dapp-frame.js and the frame's own
 * headers (lib/dapps/frame_policy.js, inlined below): a sandboxed, opaque
 * origin with its own CSP. Nothing for that route ever comes from the network.
 *
 * Not intercepted (they go to the network, and only when the app asks):
 * release.json/.sig, manifest.json, the loader script, the recovery snapshot,
 * the explorer status and dev-server paths. The BEAM node is a WebSocket,
 * which never passes here.
 *
 * This file carries nothing release-specific (no version), so its bytes - and
 * its content-addressed name, sw-<hash>.js - stay the same across releases
 * unless the loader itself changes. A legitimate deployment therefore never
 * changes the bytes at a loader URL a phone has registered, which is what
 * lets the page treat any such change as a warning sign (lib/loader.js).
 *
 * The build (tools/build.mjs) fills in the placeholders and inlines
 * lib/release.js where marked.
 */
'use strict';

const RELEASE_PUBLIC_JWK = /*__RELEASE_PUBLIC_JWK__*/ null;
const SECURITY_HEADERS = /*__SECURITY_HEADERS__*/ {};
const MIME = /*__MIME__*/ {};

/*__INLINE_RELEASE_JS__*/

/*__INLINE_FRAME_POLICY_JS__*/

const META_CACHE = 'campfire-meta';
const scopeUrl = new URL(self.registration.scope);
const STATE_KEY = new URL('__campfire_state', scopeUrl).href;
const PROGRESS_KEY = new URL('__campfire_install', scopeUrl).href;
const PASSTHROUGH = [/^release\.json$/, /^release\.sig$/, /^manifest\.json$/, /^sw(-[0-9a-f]+)?\.js$/, /^recovery\//, /^explorer\//, /^__dev\//, /^_headers$/];
const PARALLEL = 6;
const FRAME_SCRIPT = 'dapp-frame.js';
const FILE_TIMEOUT_MS = 90000; // per file: a stalled connection fails the run, which can then resume

let stateCache = null;
let updateRun = null;
let installAbort = null;

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

/** What the first-run screen shows. The page reads it from the meta cache. */
async function writeProgress(p) {
  try {
    const c = await caches.open(META_CACHE);
    await c.put(PROGRESS_KEY, new Response(JSON.stringify({ ...p, at: Date.now() }), { headers: { 'Content-Type': 'application/json' } }));
  } catch {
    /* progress is only for the screen */
  }
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

async function fetchBytes(path, signal) {
  const ctl = new AbortController();
  const onAbort = () => ctl.abort();
  if (signal) {
    if (signal.aborted) ctl.abort();
    else signal.addEventListener('abort', onAbort);
  }
  const timer = setTimeout(() => ctl.abort(), FILE_TIMEOUT_MS);
  try {
    let r;
    try {
      r = await fetch(new URL(path, scopeUrl).href, { cache: 'no-store', credentials: 'same-origin', signal: ctl.signal });
    } catch {
      throw new ReleaseError('unreachable', `Could not download ${path}.`);
    }
    if (!r.ok) throw new ReleaseError('unreachable', `${path}: HTTP ${r.status}`);
    try {
      return new Uint8Array(await r.arrayBuffer());
    } catch {
      throw new ReleaseError('unreachable', `The download of ${path} was interrupted.`);
    }
  } finally {
    clearTimeout(timer);
    if (signal) signal.removeEventListener('abort', onAbort);
  }
}

/**
 * release.json + its signature + manifest.json. Something that is not a
 * release.json at all (a parking page, an error page) means there is no update
 * source at this address: "unreachable", not "refused". A release.json that
 * names this app but fails the signature is refused.
 */
async function fetchVerifiedRelease(signal) {
  const relBytes = await fetchBytes('release.json', signal);
  let claimed = null;
  try {
    claimed = JSON.parse(new TextDecoder().decode(relBytes));
  } catch {
    claimed = null;
  }
  if (!claimed || claimed.app !== RELEASE_APP_ID) throw new ReleaseError('unreachable', 'No BEAM Campfire release is published at this address.');
  const sig = new TextDecoder().decode(await fetchBytes('release.sig', signal));
  const release = await verifyReleaseSignature(relBytes, sig, RELEASE_PUBLIC_JWK);
  const manifest = await verifyManifest(release, await fetchBytes('manifest.json', signal));
  return { release, manifest };
}

const cacheNameFor = (release) => `campfire-${release.version}-${release.manifest_sha256.slice(0, 16)}`;

/**
 * Downloads and verifies every file of a release into its own cache.
 * Resumable: entries already in that cache are re-checked against the manifest
 * and kept. The cache is recorded as state.staging so cleanup keeps it, and it
 * is never served until it has become state.current (first install, every
 * file verified) or state.pending and then current (Update button).
 */
async function stageRelease({ release, manifest }, { signal = null, report = null } = {}) {
  const cacheName = cacheNameFor(release);
  const st = await readState();
  if (st.staging !== cacheName) await writeState({ ...st, staging: cacheName });
  const cache = await caches.open(cacheName);
  const files = manifest.files;
  const totalBytes = files.reduce((a, f) => a + f.size, 0);
  const prog = { state: 'downloading', version: release.version, total: files.length, totalBytes, done: 0, doneBytes: 0, resumed: 0, error: null };
  const todo = [];
  for (const f of files) {
    const key = new URL(f.path, scopeUrl).href;
    const hit = await cache.match(key);
    if (hit) {
      try {
        await verifyFile(f, new Uint8Array(await hit.arrayBuffer()));
        prog.done++;
        prog.doneBytes += f.size;
        prog.resumed++;
        continue;
      } catch {
        await cache.delete(key);
      }
    }
    todo.push(f);
  }
  if (report) await report(prog);
  // Biggest first, so the engine (5.8 MB) is not the last thing left on a slow line.
  todo.sort((a, b) => b.size - a.size);
  let next = 0;
  let failure = null;
  const run = new AbortController();
  const onOuterAbort = () => run.abort();
  if (signal) signal.addEventListener('abort', onOuterAbort);
  const worker = async () => {
    while (!failure && next < todo.length) {
      const f = todo[next++];
      try {
        const bytes = await fetchBytes(f.path, run.signal);
        await verifyFile(f, bytes);
        await cache.put(new URL(f.path, scopeUrl).href, new Response(bytes, { headers: { 'Content-Type': mimeFor(f.path) } }));
        prog.done++;
        prog.doneBytes += f.size;
        if (report) await report(prog);
      } catch (e) {
        if (!failure) failure = e;
        run.abort();
      }
    }
  };
  try {
    await Promise.all(Array.from({ length: Math.min(PARALLEL, todo.length) }, worker));
  } finally {
    if (signal) signal.removeEventListener('abort', onOuterAbort);
  }
  if (failure) throw failure;
  const map = {};
  for (const f of files) map[f.path] = f.sha256;
  return { version: release.version, cache: cacheName, files: map, manifestSha: release.manifest_sha256, verifiedAt: Date.now() };
}

async function cleanup(st) {
  const keep = new Set([META_CACHE, st.current && st.current.cache, st.pending && st.pending.cache, st.staging].filter(Boolean));
  for (const name of await caches.keys()) if (name.startsWith('campfire-') && !keep.has(name)) await caches.delete(name);
}

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const st = await readState();
      if (!st.current) {
        // First install: nothing is served until a signed release verified.
        installAbort = new AbortController();
        const signal = installAbort.signal;
        try {
          await writeProgress({ state: 'checking', done: 0, total: 0, doneBytes: 0, totalBytes: 0, error: null });
          const rel = await fetchVerifiedRelease(signal);
          let last = null;
          const current = await stageRelease(rel, { signal, report: (p) => writeProgress((last = p)) });
          const now = await readState();
          await writeState({ ...now, current, pending: null, staging: null, lastRefusal: null });
          await writeProgress({ ...(last || {}), state: 'done', version: current.version, error: null });
        } catch (e) {
          const code = signal.aborted ? 'stopped' : (e && e.code) || 'error';
          await writeProgress({ state: 'failed', error: { code, message: String((e && e.message) || e) } });
          throw e;
        } finally {
          installAbort = null;
        }
      }
      // Another loader (the page registers one only after an Update the person
      // approved) changes how files are served, never which files: it keeps
      // the verified copy.
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
  if (!st.current) return fetch(request); // not installed yet: no page is controlled by this worker then
  if (Object.prototype.hasOwnProperty.call(st.current.files, path)) {
    const cache = await caches.open(st.current.cache);
    const hit = await cache.match(new URL(path, scopeUrl).href);
    if (hit) return withHeaders(hit, path);
  }
  // Installed: only the verified copy is served; nothing is fetched from the web address.
  return new Response('Not part of this BEAM Campfire release.', { status: 404, headers: { ...SECURITY_HEADERS, 'Content-Type': 'text/plain; charset=utf-8' } });
}

const notInRelease = () => new Response('Not part of this BEAM Campfire release.', { status: 404, headers: { ...SECURITY_HEADERS, 'Content-Type': 'text/plain; charset=utf-8' } });

/** A dApp frame document: the verified bootstrap under a fresh nonce, with the frame's own headers. */
async function serveFrame(request, policy) {
  if (request.mode !== 'navigate') return notInRelease();
  const st = await readState();
  if (!st.current || !Object.prototype.hasOwnProperty.call(st.current.files, FRAME_SCRIPT)) return notInRelease();
  const cache = await caches.open(st.current.cache);
  const hit = await cache.match(new URL(FRAME_SCRIPT, scopeUrl).href);
  if (!hit) return notInRelease();
  const nonce = newNonce();
  return new Response(frameDocument(await hit.text(), nonce), { status: 200, headers: frameHeaders(policy, nonce) });
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  const path = relPath(url);
  if (path === null || PASSTHROUGH.some((r) => r.test(path))) return;
  if (path.startsWith(FRAME_ROUTE)) {
    const policy = frameRouteFor(path);
    event.respondWith(policy ? serveFrame(req, policy) : Promise.resolve(notInRelease()));
    return;
  }
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
    const now = await readState();
    const next = { ...now, pending: staged, staging: null, lastRefusal: null };
    await writeState(next);
    await cleanup(next);
    return { result: 'ready', version: v };
  } catch (e) {
    if (e && e.code === 'unreachable') return { result: 'unreachable', reason: e.message };
    const now = await readState();
    await writeState({ ...now, lastRefusal: { at: Date.now(), reason: e.message, version: v } });
    return { result: 'refused', version: v, reason: e.message };
  }
}

async function applyUpdate() {
  const st = await readState();
  if (!st.pending) return { result: 'none' };
  const next = { current: st.pending, pending: null, staging: null, lastRefusal: null, previous: st.current && st.current.version };
  await writeState(next);
  await cleanup(next);
  return { result: 'applied', version: next.current.version };
}

self.addEventListener('message', (event) => {
  const type = event.data && event.data.type;
  if (type === 'abort-install') {
    // The first-run screen saw no progress for a while: end this run now. The
    // page registers again, and the next run resumes from what was verified.
    if (installAbort) installAbort.abort();
    return;
  }
  const port = event.ports && event.ports[0];
  if (!port) return;
  event.waitUntil(
    (async () => {
      try {
        if (type === 'status') {
          const st = await readState();
          port.postMessage({
            loader: self.location.pathname.split('/').pop(),
            current: st.current && st.current.version,
            pending: st.pending && st.pending.version,
            currentFiles: st.current ? Object.keys(st.current.files).length : 0,
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

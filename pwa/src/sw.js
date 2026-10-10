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
 * Update sources (lib/update_sources.js, inlined below): this app's own
 * address first, then the public copies the installed release names, then an
 * address the person added. The first that answers with a valid signed release
 * decides; the rest are never contacted. Files from any source go into this
 * app's own cache under its own scope URLs, each only after its hash matched.
 * A release from anywhere but the own address must run under THIS loader (a
 * service worker comes only from its own address), so it is staged only when
 * it ships this loader or one that serves pages the same way (loader_compat).
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

/*__INLINE_UPDATE_SOURCES_JS__*/

/*__INLINE_FRAME_POLICY_JS__*/

const META_CACHE = 'campfire-meta';
const scopeUrl = new URL(self.registration.scope);
const STATE_KEY = new URL('__campfire_state', scopeUrl).href;
const PROGRESS_KEY = new URL('__campfire_install', scopeUrl).href;
const PASSTHROUGH = [/^release\.json$/, /^release\.sig$/, /^manifest\.json$/, /^sw(-[0-9a-f]+)?\.js$/, /^recovery\//, /^explorer\//, /^__dev\//, /^_headers$/];
const PARALLEL = 6;
const FRAME_SCRIPT = 'dapp-frame.js';
const FILE_TIMEOUT_MS = 90000; // per file: a stalled connection fails the run, which can then resume
const PROBE_TIMEOUT_MS = 30000; // release.json/.sig/manifest.json at one update source, then the next
const MAX_META_BYTES = 4 * 1024 * 1024; // release.json, release.sig or manifest.json larger than this is not ours
// The page <-> loader contract. Raise it when page code starts to rely on
// something only a newer loader does (a message, a route, a header): it is
// part of LOADER_COMPAT, so such a release then installs only from the own
// address, where its loader comes along.
const LOADER_API = /*__LOADER_API__*/ 2;
// Hash of what this loader does to pages (security headers, MIME types, dApp
// frame policy, LOADER_API), filled in by the build; release.json carries the
// same value for the release's own loader (see loaderCompatible()).
const LOADER_COMPAT = /*__LOADER_COMPAT__*/ null;
const LOADER_NAME = self.location.pathname.split('/').pop();

let stateCache = null;
let updateRun = null;
const updateListeners = new Set();
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

/** Reads a response body, giving up once it is larger than max bytes. */
async function readCapped(r, max, tooBig) {
  const announced = Number(r.headers.get('content-length'));
  if (Number.isFinite(announced) && announced > max) throw tooBig();
  if (!r.body || !Number.isFinite(max)) return new Uint8Array(await r.arrayBuffer());
  const reader = r.body.getReader();
  const parts = [];
  let n = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    n += value.byteLength;
    if (n > max) {
      reader.cancel().catch(() => {});
      throw tooBig();
    }
    parts.push(value);
  }
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.byteLength;
  }
  return out;
}

/**
 * One file of a release from base (this app's folder or another copy).
 * Another copy gets no cookies and no referrer; it must send CORS headers,
 * or the browser hands nothing over (reported as unreachable).
 */
async function fetchBytes(base, path, { signal = null, timeoutMs = FILE_TIMEOUT_MS, max = Infinity, tooBig = null } = {}) {
  const url = new URL(path, base);
  const own = url.origin === self.location.origin;
  const ctl = new AbortController();
  const onAbort = () => ctl.abort();
  if (signal) {
    if (signal.aborted) ctl.abort();
    else signal.addEventListener('abort', onAbort);
  }
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  const where = own ? '' : ` from ${url.host}`;
  try {
    let r;
    try {
      r = await fetch(url.href, { cache: 'no-store', credentials: own ? 'same-origin' : 'omit', referrerPolicy: 'no-referrer', signal: ctl.signal });
    } catch {
      throw new ReleaseError('unreachable', `Could not download ${path}${where}.`);
    }
    if (!r.ok) throw new ReleaseError('unreachable', `${path}${where}: HTTP ${r.status}`);
    try {
      return await readCapped(r, max, tooBig || (() => new ReleaseError('unreachable', `${path}${where} is far larger than a BEAM Campfire release file.`)));
    } catch (e) {
      if (e instanceof ReleaseError) throw e;
      throw new ReleaseError('unreachable', `The download of ${path}${where} was interrupted.`);
    }
  } finally {
    clearTimeout(timer);
    if (signal) signal.removeEventListener('abort', onAbort);
  }
}

/** release.json + its signature + manifest.json from base, verified (readRelease in lib/update_sources.js). */
function fetchVerifiedRelease(base, { signal = null, timeoutMs = FILE_TIMEOUT_MS } = {}) {
  return readRelease((path) => fetchBytes(base, path, { signal, timeoutMs, max: MAX_META_BYTES }), RELEASE_PUBLIC_JWK);
}

const cacheNameFor = (release) => `campfire-${release.version}-${release.manifest_sha256.slice(0, 16)}`;

/**
 * Downloads and verifies every file of a release into its own cache.
 * Resumable: entries already in that cache are re-checked against the manifest
 * and kept. The cache is recorded as state.staging so cleanup keeps it, and it
 * is never served until it has become state.current (first install, every
 * file verified) or state.pending and then current (Update button).
 */
async function stageRelease({ release, manifest }, { base = scopeUrl, signal = null, report = null } = {}) {
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
        // Never more than the signed size: a larger answer fails the check without being read whole.
        const bytes = await fetchBytes(base, f.path, { signal: run.signal, max: f.size, tooBig: () => new ReleaseError('file_mismatch', `A file in this update (${f.path}) is not the one that was signed.`) });
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
  return {
    version: release.version,
    cache: cacheName,
    files: map,
    manifestSha: release.manifest_sha256,
    verifiedAt: Date.now(),
    // Where the next check looks, from the signed release; the loader that ships with it; and
    // what that loader does to pages (see loaderCompatible()).
    sources: releaseSources(release),
    loader: typeof release.loader === 'string' ? release.loader : null,
    loaderCompat: typeof release.loader_compat === 'string' ? release.loader_compat : null,
  };
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
          const rel = await fetchVerifiedRelease(scopeUrl, { signal });
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

/**
 * "Check for updates": asks the sources in order (findUpdate in
 * lib/update_sources.js) and stages the first newer release it may install.
 * added: addresses the person added. progress(p) gets {step, host, own, ...}.
 */
async function checkUpdate({ added = [], progress = null } = {}) {
  const st = await readState();
  if (!st.current) return { result: 'none' };
  const say = (p) => {
    if (progress) progress(p);
  };
  const sources = updateSources({ own: scopeUrl.href, builtins: Array.isArray(st.current.sources) ? st.current.sources : BUILTIN_SOURCES, added });
  const ownFrom = { host: scopeUrl.host, own: true };
  const r = await findUpdate({
    sources,
    installed: { version: st.current.version, manifestSha: st.current.manifestSha },
    pending: st.pending ? { version: st.pending.version, manifestSha: st.pending.manifestSha, from: st.pending.from || ownFrom } : null,
    loader: { name: LOADER_NAME, compat: LOADER_COMPAT },
    onSource: (src) => say({ step: 'checking', host: src.host, own: src.own }),
    fetchRelease: (src) => fetchVerifiedRelease(src.url, { timeoutMs: PROBE_TIMEOUT_MS }),
    stage: async (src, rel) => {
      const staged = await stageRelease(rel, {
        base: src.url,
        report: (p) => say({ step: 'downloading', host: src.host, own: src.own, version: rel.release.version, done: p.done, total: p.total }),
      });
      const now = await readState();
      const next = { ...now, pending: { ...staged, from: { host: src.host, own: src.own } }, staging: null, lastRefusal: null };
      await writeState(next);
      await cleanup(next);
    },
  });
  if (r.result === 'refused') {
    const now = await readState();
    await writeState({ ...now, lastRefusal: { at: Date.now(), reason: r.reason, version: r.version || undefined, host: r.from && !r.from.own ? r.from.host : undefined } });
  }
  return r;
}

/**
 * Switches to the staged release. A release whose loader this one cannot
 * stand in for (loaderCompatible) is switched to only when the page says its
 * own address just served that loader with the signed bytes (loaderReady): the
 * page then moves to it right after the reload. Otherwise it stays staged.
 */
async function applyUpdate({ loaderReady = false } = {}) {
  const st = await readState();
  if (!st.pending) return { result: 'none' };
  const p = st.pending;
  const compatible = loaderCompatible({ loader: p.loader, loader_compat: p.loaderCompat }, { name: LOADER_NAME, compat: LOADER_COMPAT });
  if (!compatible && !loaderReady) {
    const l = releaseLoaderOf(p);
    return { result: 'needs_loader', version: p.version, loader: l && l.path, loaderSha256: l && l.sha256 };
  }
  const next = { current: p, pending: null, staging: null, lastRefusal: null, previous: st.current && st.current.version };
  await writeState(next);
  await cleanup(next);
  return { result: 'applied', version: next.current.version, from: p.from || null };
}

/** The loader file the installed release ships, with its signed SHA-256 (for the page's move to it). */
function releaseLoaderOf(rec) {
  if (!rec || !rec.files) return null;
  const path = rec.loader || Object.keys(rec.files).find((f) => /^sw(-[0-9a-f]+)?\.js$/.test(f));
  return path && rec.files[path] ? { path, sha256: rec.files[path] } : null;
}

self.addEventListener('message', (event) => {
  const type = event.data && event.data.type;
  if (type === 'abort-install') {
    // The first-run screen saw no progress for a while: end this run now. The
    // page registers again, and the next run resumes from what was verified.
    if (installAbort) installAbort.abort();
    return;
  }
  if (type === 'skip-waiting') {
    // The page moves to this loader once, after an Update the person approved.
    // Chrome can drop the skipWaiting() made during install when the old loader
    // is busy with the page's reload (measured: this loader then waited five
    // minutes behind the old one), so the page asks again once it is waiting.
    event.waitUntil(self.skipWaiting());
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
            loader: LOADER_NAME,
            api: LOADER_API,
            current: st.current && st.current.version,
            currentFrom: (st.current && st.current.from) || null,
            pending: st.pending && st.pending.version,
            pendingFrom: (st.pending && st.pending.from) || null,
            currentFiles: st.current ? Object.keys(st.current.files).length : 0,
            releaseLoader: releaseLoaderOf(st.current),
            sources: st.current ? updateSources({ own: scopeUrl.href, builtins: Array.isArray(st.current.sources) ? st.current.sources : BUILTIN_SOURCES }).map((x) => ({ host: x.host, kind: x.kind })) : [],
            lastRefusal: st.lastRefusal || null,
          });
        } else if (type === 'check-update') {
          // One check at a time; every page that asks hears its progress and its answer.
          const added = Array.isArray(event.data.added) ? event.data.added.slice(0, MAX_ADDED_SOURCES) : [];
          if (event.data.progress === true) updateListeners.add(port);
          if (!updateRun) {
            updateRun = checkUpdate({ added, progress: (p) => updateListeners.forEach((l) => l.postMessage({ progress: p })) }).finally(() => {
              updateRun = null;
              updateListeners.clear();
            });
          }
          const r = await updateRun;
          updateListeners.delete(port);
          port.postMessage(r);
        } else if (type === 'apply-update') {
          port.postMessage(await applyUpdate({ loaderReady: event.data.loaderReady === true }));
        } else {
          port.postMessage({ result: 'error', reason: 'unknown request' });
        }
      } catch (e) {
        port.postMessage({ result: 'error', reason: String((e && e.message) || e) });
      }
    })(),
  );
});

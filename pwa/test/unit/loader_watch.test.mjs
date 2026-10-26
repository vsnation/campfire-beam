// The tripwire's first watch (src/loader-watch.js) runs before every module of the app, and
// lib/loader.js watchLoader() replays what it saw. Without it, a loader swapped at its own URL that
// takes over a page while it is still loading its modules serves every module not loaded yet, and
// the app's own watch, which starts after its last module, never runs (ported from the Firo
// wallet, a15b0b6ba).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src');
const OLD = 'https://wallet.example/sw-0000000000000000.js';

/** A page's navigator.serviceWorker as the watch sees it: a controller, listeners, a registration. */
function fakeServiceWorker(controllerUrl) {
  const listeners = {};
  const regListeners = {};
  const reg = { installing: null, waiting: null, addEventListener: (t, f) => ((regListeners[t] ||= []).push(f)) };
  const sw = {
    controller: controllerUrl ? { scriptURL: controllerUrl } : null,
    addEventListener: (t, f) => ((listeners[t] ||= []).push(f)),
    getRegistration: async () => reg,
    fire: (t) => (listeners[t] || []).forEach((f) => f()),
    install: (url) => {
      reg.installing = { scriptURL: url };
      (regListeners.updatefound || []).forEach((f) => f());
    },
    reg,
  };
  return sw;
}

/** A DOM just big enough for the early warning: elements with children, text and attributes. */
function fakeDocument() {
  const el = (tag) => ({ tag, children: [], attrs: {}, className: '', textContent: '', appendChild(c) { this.children.push(c); return c; }, removeChild(c) { this.children.splice(this.children.indexOf(c), 1); }, get firstChild() { return this.children[0] || null; }, setAttribute(k, v) { this.attrs[k] = v; } });
  const body = el('body');
  body.appendChild(el('div'));
  return { body, documentElement: el('html'), createElement: el, createTextNode: (t) => ({ tag: '#text', textContent: t }) };
}

function runEarlyWatch(sw) {
  const window = { stopped: 0, stop() { this.stopped++; } };
  const document = fakeDocument();
  vm.runInNewContext(readFileSync(join(src, 'loader-watch.js'), 'utf8'), { window, document, navigator: { serviceWorker: sw }, Object, Date });
  return { window, document, watch: window.__campfireLoaderWatch };
}

const texts = (n) => [n.textContent, ...(n.children || []).flatMap(texts)].join(' ');

test('index.html loads the watch as a classic script before anything else of the page', () => {
  const html = readFileSync(join(src, 'index.html'), 'utf8');
  const scripts = [...html.matchAll(/<script[^>]*>/g)].map((m) => m[0]);
  assert.equal(scripts[0], '<script src="loader-watch.js">', 'first, and not a module (modules are deferred)');
  assert.ok(html.indexOf('loader-watch.js') < html.indexOf('<link rel="stylesheet"'));
});

test('the loader that served the page taking over again stops the page at once, before the app watches', async () => {
  const sw = fakeServiceWorker(OLD);
  const { window, document, watch } = runEarlyWatch(sw);
  assert.equal(watch.initial, OLD);
  assert.equal(watch.stopped(), false);
  sw.fire('controllerchange'); // same URL, new bytes: what a takeover looks like
  assert.equal(watch.stopped(), true);
  assert.equal(window.stopped, 1, 'nothing else of the page loads');
  assert.equal(document.body.children[0].attrs['data-testid'], 'tripwire-early');
  assert.match(texts(document.body), /This app's web address is serving code Beam PWA did not sign\. Don't enter your password here\./);
  assert.throws(() => (window.__campfireLoaderWatch = null), 'the record cannot be replaced');
});

test('anything else is recorded for the app, which decides; once it watches, the early watch only reports', async () => {
  const sw = fakeServiceWorker(OLD);
  const { watch, window } = runEarlyWatch(sw);
  await new Promise((r) => setImmediate(r));
  sw.install('https://wallet.example/sw-1111111111111111.js');
  assert.equal(watch.stopped(), false, 'another name: the app decides (a move it expects, or a takeover)');
  const seen = [];
  watch.subscribe((ev) => seen.push([ev.type, ev.url]));
  assert.deepEqual(seen, [['updatefound', 'https://wallet.example/sw-1111111111111111.js']], 'replayed');
  sw.fire('controllerchange');
  assert.deepEqual(seen.at(-1), ['controllerchange', OLD], 'then followed');
  assert.equal(window.stopped, 0, 'the app watches now: it shows its own screen');
});

test('watchLoader replays the early record: a takeover before the app started is not missed', async () => {
  const prev = { window: globalThis.window, navigator: Object.getOwnPropertyDescriptor(globalThis, 'navigator') };
  try {
    const sw = fakeServiceWorker(OLD);
    Object.defineProperty(globalThis, 'navigator', { value: { serviceWorker: sw }, configurable: true, writable: true });
    const early = runEarlyWatch(sw).watch;
    globalThis.window = { __campfireLoaderWatch: early };
    // No registration for the app's own look: what it decides comes from the record alone (and no
    // take-over retries keep the test running).
    sw.getRegistration = async () => null;
    // A first page: no early stop (pretend the app was already watching when it came)...
    early.subscribe(() => {});
    sw.fire('controllerchange'); // ...the takeover happened while the modules loaded
    const { watchLoader } = await import(`../../src/lib/loader.js?early=${Date.now()}`);
    let why = null;
    await watchLoader({ onIntrusion: (w) => (why = w), onMoved: () => (why = 'moved') });
    assert.match(String(why), /changed|replaced/, 'the record says the controller changed: the tripwire fires');
  } finally {
    globalThis.window = prev.window;
    if (prev.navigator) Object.defineProperty(globalThis, 'navigator', prev.navigator);
    else delete globalThis.navigator;
  }
});

// Audit UPD-6: two windows of the app. Window 1 applies an approved Update that brings a new
// loader: moveToLoader() records {path, sha256} in the shared localStorage, then registers it on
// the one registration both windows share. Window 2, still on the older release, saw "a new
// service worker (sw-b….js) is being installed" and stopped the wallet: a false alarm that trains
// people to ignore the real one. The recorded move is expected in every window now, and checked
// there the same way (the bytes at that name against the signed hash) once it takes over.
async function otherWindowMoves({ record, install, takeOver = install, served, firstWindowChecked = false, recordAge = 0 }) {
  const { createHash } = await import('node:crypto');
  const prev = { window: globalThis.window, navigator: Object.getOwnPropertyDescriptor(globalThis, 'navigator'), localStorage: globalThis.localStorage, fetch: globalThis.fetch, document: globalThis.document };
  const store = new Map();
  const signed = 'self.signedLoader = 1;';
  const sha = createHash('sha256').update(signed).digest('hex');
  try {
    const sw = fakeServiceWorker(OLD);
    Object.defineProperty(globalThis, 'navigator', { value: { serviceWorker: sw }, configurable: true, writable: true });
    globalThis.localStorage = { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)), removeItem: (k) => store.delete(k) };
    globalThis.document = { baseURI: 'https://wallet.example/' };
    const asked = [];
    globalThis.fetch = async (url, init) => {
      asked.push({ url: String(url), sw: init && init.headers && init.headers['Service-Worker'] });
      return new Response(served === 'signed' ? signed : 'self.someoneElse = 1;', { status: 200, headers: { 'Content-Type': 'text/javascript' } });
    };
    const early = runEarlyWatch(sw).watch;
    await new Promise((r) => setImmediate(r)); // the early watch has its registration
    sw.getRegistration = async () => null; // the app's own look: from the record alone, no retry timers
    globalThis.window = { __campfireLoaderWatch: early };
    const { watchLoader } = await import(`../../src/lib/loader.js?two-windows=${Date.now()}-${Math.random()}`);
    let why = null;
    let moved = 0;
    await watchLoader({ onIntrusion: (w) => (why = w), onMoved: () => moved++ });
    assert.equal(why, null, 'nothing yet');
    // Window 1, after the Update was approved and the address served the signed loader:
    if (record) store.set('campfire-loader-check', JSON.stringify({ path: record, sha256: sha, at: Date.now() - recordAge }));
    sw.install(`https://wallet.example/${install}`);
    await new Promise((r) => setTimeout(r, 10));
    const afterInstall = why;
    // Re-audit RE2-4: window 1 took over first and its own check of the bytes has answered (the same
    // shared record, the same address); this window's takeover is delivered after that.
    let firstAnswer = null;
    if (firstWindowChecked) {
      const { checkMovedLoader } = await import(`../../src/lib/loader.js?window-one=${Date.now()}-${Math.random()}`);
      firstAnswer = await checkMovedLoader(Date.now(), record);
    }
    sw.controller = { scriptURL: `https://wallet.example/${takeOver}` };
    sw.fire('controllerchange');
    // Wait for the check to finish (it is asynchronous), up to 1.5 s, instead of a fixed 30 ms that a
    // loaded machine could outrun (release audit 0.2.18, NIT).
    for (let i = 0; i < 75 && !moved; i++) await new Promise((r) => setTimeout(r, 20));
    return { afterInstall, why, moved, asked, firstAnswer, record: store.get('campfire-loader-check') };
  } finally {
    globalThis.window = prev.window;
    if (prev.navigator) Object.defineProperty(globalThis, 'navigator', prev.navigator);
    else delete globalThis.navigator;
    globalThis.localStorage = prev.localStorage;
    globalThis.fetch = prev.fetch;
    globalThis.document = prev.document;
  }
}

const B = 'sw-bbbbbbbbbbbbbbbb.js';
const C = 'sw-cccccccccccccccc.js';

test('another window moving to the loader it recorded: no alarm here; checked once it takes over, then moved', async () => {
  const r = await otherWindowMoves({ record: B, install: B, served: 'signed' });
  assert.equal(r.afterInstall, null, 'the recorded loader installing is expected');
  assert.equal(r.why, null, 'its takeover too, once its bytes check out');
  assert.equal(r.moved, 1, 'the page is told it moved (it reloads into the new release, or offers to)');
  assert.ok(r.asked.some((a) => a.url === `https://wallet.example/${B}` && a.sw === 'script'), 'the bytes at that name were checked the way the browser installs them');
  assert.ok(r.record, 'a good answer keeps the record for the other windows (a day at most)');
});

test('re-audit RE2-4: a window whose takeover arrives after the first window\'s check answered is not alarmed; it checks the same signed hash', async () => {
  const r = await otherWindowMoves({ record: B, install: B, served: 'signed', firstWindowChecked: true });
  assert.equal(r.firstAnswer, 'same', "window 1's check answered");
  assert.equal(r.afterInstall, null);
  assert.equal(r.why, null, 'no "the service worker controlling this page changed"');
  assert.equal(r.moved, 1);
  assert.equal(r.asked.filter((a) => a.url === `https://wallet.example/${B}`).length, 2, 'each window checked the bytes itself');
  // Other bytes: the first window's answer ends the record, and the late window still alarms.
  const bad = await otherWindowMoves({ record: B, install: B, served: 'other', firstWindowChecked: true });
  assert.equal(bad.firstAnswer, 'other');
  assert.equal(bad.record, undefined, 'an answer of other bytes ends it');
  assert.match(String(bad.why), /changed|other code/);
  assert.equal(bad.moved, 0);
  // A record older than a day is dropped, and a takeover then alarms as before.
  const old = await otherWindowMoves({ record: B, install: B, served: 'signed', recordAge: 86400000 + 1000 });
  assert.match(String(old.afterInstall), /is being installed/);
});

test('the recorded loader serving other bytes than signed: the alarm, in this window too', async () => {
  const r = await otherWindowMoves({ record: B, install: B, served: 'other' });
  assert.equal(r.afterInstall, null);
  assert.match(String(r.why), /serves other code under the new loader's name/);
  assert.equal(r.moved, 0);
  assert.equal(r.record, undefined, 'other bytes end the record');
});

test('without a recorded move, or a different loader than recorded: the alarm, as before', async () => {
  const none = await otherWindowMoves({ record: null, install: B, served: 'signed' });
  assert.match(String(none.afterInstall), /a new service worker \(sw-bbbbbbbbbbbbbbbb\.js\) is being installed/);
  const other = await otherWindowMoves({ record: B, install: C, served: 'signed' });
  assert.match(String(other.afterInstall), /a new service worker \(sw-cccccccccccccccc\.js\) is being installed/);
  const takeover = await otherWindowMoves({ record: B, install: B, takeOver: C, served: 'signed' });
  assert.equal(takeover.afterInstall, null);
  assert.match(String(takeover.why), /controlling this page changed/);
});

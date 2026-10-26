// Reminders while Beam PWA is closed come from Periodic Background Sync, which wakes the loader
// with no page open; each wake-up is also a moment the browser may install a changed loader that no
// open page can notice (lib/loader.js). So wake-ups are asked for only when the person turns
// "Reminders when Beam PWA is closed" on, and the loader shows nothing (and asks for no more)
// otherwise, including after an earlier release asked for them by itself (ported from the Firo
// wallet, a15b0b6ba).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
import { loadLoader } from './helpers/sw_sandbox.mjs';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src');
// An in-memory IndexedDB (the vendored fake-indexeddb, the same file dApp frames get).
vm.runInThisContext(readFileSync(join(src, 'vendor', 'fake-indexeddb', 'fake-indexeddb.js'), 'utf8'));
const { indexedDB, IDBKeyRange } = globalThis;

async function testPub() {
  const k = await webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const j = await webcrypto.subtle.exportKey('jwk', k.publicKey);
  return { kty: j.kty, crv: j.crv, x: j.x, y: j.y };
}

/** The app's own store (lib/store.js: beam-campfire-app / kv) with these prefs and one due reminder. */
async function appStore(prefs) {
  await new Promise((ok, no) => {
    const d = indexedDB.deleteDatabase('beam-campfire-app');
    d.onsuccess = ok;
    d.onerror = no;
  });
  const db = await new Promise((ok, no) => {
    const r = indexedDB.open('beam-campfire-app', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('kv');
    r.onsuccess = () => ok(r.result);
    r.onerror = () => no(r.error);
  });
  const tx = db.transaction('kv', 'readwrite');
  tx.objectStore('kv').put(prefs, 'prefs');
  tx.objectStore('kv').put([{ id: 'rem-arr-1', at: Date.now() - 1000, kind: 'payment', title: 'A payment is still waiting', body: 'Open Beam PWA to finish it.', url: '#open=home' }], 'w:abc:notify-reminders');
  await new Promise((ok) => (tx.oncomplete = ok));
  db.close();
}

async function wake(prefs) {
  await appStore(prefs);
  const shown = [];
  const unregistered = [];
  const sw = await loadLoader({
    pub: await testPub(),
    fetch: async () => new Response('', { status: 404 }),
    globals: { indexedDB, IDBKeyRange, Notification: { permission: 'granted' } },
    registration: { showNotification: async (title) => shown.push(title), periodicSync: { unregister: async (tag) => unregistered.push(tag) } },
  });
  let done;
  sw.handlers.periodicsync({ tag: 'campfire-reminders', waitUntil: (p) => (done = p) });
  await done;
  return { shown, unregistered };
}

test('a wake-up shows nothing and asks for no more unless reminders while closed were turned on', async () => {
  const off = await wake({ notify: { on: true } });
  assert.deepEqual(off.shown, [], 'notifications on, but not while closed: nothing');
  assert.deepEqual(off.unregistered, ['campfire-reminders'], 'and no more wake-ups');
  const on = await wake({ notify: { on: true, wakeUps: true } });
  assert.deepEqual(on.shown, ['A payment is still waiting']);
  assert.deepEqual(on.unregistered, []);
  const allOff = await wake({ notify: { on: false, wakeUps: true } });
  assert.deepEqual(allOff.shown, []);
  assert.deepEqual(allOff.unregistered, ['campfire-reminders']);
});

test('the page asks for wake-ups only with the switch on, and drops them otherwise', async () => {
  const calls = [];
  const reg = { periodicSync: { register: async (tag) => calls.push(['register', tag]), unregister: async (tag) => calls.push(['unregister', tag]) } };
  const prev = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
  Object.defineProperty(globalThis, 'navigator', { value: { serviceWorker: { getRegistration: async () => reg } }, configurable: true, writable: true });
  try {
    const { applyWakeUps, wakeUpsOn } = await import('../../src/lib/notify.js');
    assert.equal(wakeUpsOn({}), false, 'off by default');
    assert.equal(wakeUpsOn({ notify: { on: true } }), false);
    await applyWakeUps({ prefs: { notify: { on: true } } });
    assert.deepEqual(calls, [['unregister', 'campfire-reminders']]);
    calls.length = 0;
    await applyWakeUps({ prefs: { notify: { on: true, wakeUps: true } } });
    assert.deepEqual(calls, [['register', 'campfire-reminders']]);
    calls.length = 0;
    await applyWakeUps({ prefs: { notify: { on: false, wakeUps: true } } });
    assert.deepEqual(calls, [['unregister', 'campfire-reminders']], 'notifications off: no wake-ups either');
  } finally {
    if (prev) Object.defineProperty(globalThis, 'navigator', prev);
  }
});

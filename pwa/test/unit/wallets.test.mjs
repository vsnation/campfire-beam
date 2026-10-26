// Several wallets on one device (lib/wallets.js, lib/wallet_scope.js): the records list, a
// single-wallet store read as it is (nothing moved), per-wallet keys and preferences, and a delete
// that removes only that wallet's keys and files. A Map stands in for the app's IndexedDB store.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  listWallets, saveRecord, placeFor, nameOf, nextName, nameProblem, sortWallets, initialWallet, recordKey, dbPathOf, balanceKey,
  loadPrefs, savePrefs, removalOps, removeWallet, renameWallet, forgetStoredBalances, selectWallet, MAX_NAME, FIRST_NAME,
} from '../../src/lib/wallets.js';
import {
  mapWalletKey, walletKey, walletStore, keyFor, isWalletKey, inSlot0, WALLET_KEYS, WALLET_KEY_PREFIXES, WALLET_PREF_KEYS, APP_KEYS, APP_KEY_PREFIXES,
  onWalletRemoved, setScopeRecord, setScopeOpen, scopeState,
} from '../../src/lib/wallet_scope.js';
import { removeWalletFiles, isWalletPath, DB_PATH, DB_DIR } from '../../src/lib/engine.js';
import { ETH_RECORD_KEY, ETH_OUTBOX_KEY } from '../../src/lib/eth/record.js';
import { BRIDGE_RECORD_KEY } from '../../src/lib/bridge/store.js';
import { BUY_RECORD_KEY } from '../../src/lib/buy/store.js';

const here = dirname(fileURLToPath(import.meta.url));
const SRC = join(here, '..', '..', 'src');

/** The store's shape (lib/store.js rawStore) over a Map; values are copied in and out like IndexedDB does. */
function memKv(init = {}) {
  const clone = (v) => (v === undefined ? undefined : structuredClone(v));
  const m = new Map(Object.entries(init).map(([k, v]) => [k, clone(v)]));
  return {
    m,
    get: async (k) => clone(m.get(k)),
    set: async (k, v) => void m.set(k, clone(v)),
    del: async (k) => void m.delete(k),
    clear: async () => m.clear(),
    keys: async (p) => [...m.keys()].filter((k) => k.startsWith(p)).sort(),
    batch: async (ops) => {
      for (const [op, k, v] of ops) if (op === 'del') m.delete(k);
      else m.set(k, clone(v));
    },
    update: async (k, fn) => {
      const v = fn(clone(m.get(k)));
      m.set(k, clone(v));
      return v;
    },
    snapshot: () => JSON.stringify([...m.entries()].sort(([a], [b]) => (a < b ? -1 : 1))),
  };
}

const env = (id) => ({ v: 1, kind: 'password', walletId: id, salt: 'c2FsdA==', iv: 'aXY=', ct: 'Y3Q=', iterations: 600000 });
const A = '0123456789abcdef';
const B = 'fedcba9876543210';
const C = 'aaaaaaaaaaaaaaaa';
const rec = (id, extra = {}) => ({ id, createdAt: 1000, restored: false, scan: false, envelopes: { password: env(id), passkey: null }, setupDone: true, ...extra });

/** A device as 0.2.7 left it: one wallet, its data under plain names, its own preferences in 'prefs'. */
function singleWalletDevice() {
  return memKv({
    wallet: rec(A, { exportedAt: 5 }),
    prefs: { node: 'random', ownNodeKey: true, autoLockMin: 15, a2hsDismissed: true, dapps: { ['1'.repeat(32)]: { remote: true } }, backupPromptSnoozedUntil: 99, bridgePrices: true },
    eth: { v: 1, id: 'e1', kind: 'words', envelope: { walletId: A } },
    'eth-outbox': { v: 1, walletId: A },
    bridge: { v: 1, walletId: A },
    buybeam: { v: 1, walletId: A },
    airdropCodes: { v: 1, walletId: A },
    'dapp-files': [{ guid: '2'.repeat(32) }],
    [`dapp-file:${'2'.repeat(32)}`]: { bytes: [1, 2, 3] },
    'uniswap-scan:pools': { at: 1 },
  });
}

test('a single-wallet device: its one wallet is listed as the first slot, "Wallet 1", and nothing is written', async () => {
  const kv = singleWalletDevice();
  const before = kv.snapshot();
  const list = await listWallets(kv);
  assert.equal(list.length, 1);
  assert.equal(list[0].id, A);
  assert.equal(list[0].slot0, true);
  assert.equal(nameOf(list[0]), FIRST_NAME);
  assert.equal(list[0].exportedAt, 5, 'the record as it was');
  assert.equal(dbPathOf(list[0]), DB_PATH, 'its database stays /beam_wallet/wallet.db');
  const prefs = await loadPrefs(list[0], kv);
  assert.equal(prefs.ownNodeKey, true);
  assert.equal(prefs.backupPromptSnoozedUntil, 99);
  assert.deepEqual(prefs.dapps, { ['1'.repeat(32)]: { remote: true } });
  assert.equal(prefs.autoLockMin, 15);
  assert.equal(kv.snapshot(), before, 'listing and reading change nothing');
  assert.deepEqual(initialWallet(list, prefs), list[0]);
});

test('a record without a place is the first slot (a single-wallet version never wrote one)', () => {
  assert.equal(inSlot0({ id: A }), true);
  assert.equal(inSlot0({ id: A, slot0: true }), true);
  assert.equal(inSlot0({ id: A, slot0: false }), false);
  assert.equal(recordKey({ id: A }), 'wallet');
  assert.equal(recordKey({ id: B, slot0: false }), `w:${B}:wallet`);
  assert.equal(dbPathOf({ id: B, slot0: false }), `${DB_DIR}/${B}/wallet.db`);
  assert.equal(balanceKey(B), `w:${B}:balance`);
});

test('records list: the first slot and every other record, by name with numbers in order; broken records skipped', async () => {
  const kv = singleWalletDevice();
  await saveRecord({ ...rec(B), name: 'Wallet 10', slot0: false }, kv);
  await saveRecord({ ...rec(C), name: 'Wallet 2', slot0: false }, kv);
  await kv.set(`w:${'b'.repeat(16)}:wallet`, { id: 'b'.repeat(16) }); // no envelopes
  await kv.set(`w:${'c'.repeat(16)}:wallet`, rec('d'.repeat(16))); // id does not match its key
  await kv.set(`w:${A}:wallet`, rec(A)); // a second copy of the first slot's id
  const list = await listWallets(kv);
  assert.deepEqual(list.map(nameOf), ['Wallet 1', 'Wallet 2', 'Wallet 10']);
  assert.deepEqual(list.map((r) => r.slot0), [true, false, false]);
  assert.deepEqual(placeFor(list), { slot0: false });
  assert.deepEqual(placeFor(list.filter((r) => !r.slot0)), { slot0: true }, 'a free first slot is used');
  assert.deepEqual(sortWallets([{ id: B, name: 'b', createdAt: 2, slot0: false }, { id: C, name: 'B', createdAt: 1, slot0: false }]).map((r) => r.id), [C, B]);
});

test('saveRecord writes where the wallet lives and never over another wallet in the first slot', async () => {
  const kv = singleWalletDevice();
  const before = await kv.get('wallet');
  await assert.rejects(saveRecord({ ...rec(B), slot0: true }, kv), (e) => e.code === 'slot_taken');
  assert.deepEqual(await kv.get('wallet'), before, "the first slot's record and envelopes are unchanged");
  await saveRecord({ ...rec(B), slot0: false, name: 'Two' }, kv);
  assert.equal((await kv.get(`w:${B}:wallet`)).name, 'Two');
  await saveRecord({ ...before, slot0: true, setupDone: false }, kv);
  assert.equal((await kv.get('wallet')).setupDone, false, 'the same wallet can update its own record');
  await assert.rejects(saveRecord({ id: B, slot0: false }, kv), (e) => e.code === 'missing');
});

test('names: "Wallet N" for the next one; empty, too long and taken names refused (any case), a wallet keeps its own', () => {
  const list = [{ id: A, slot0: true }, { id: B, name: 'Savings', slot0: false }];
  assert.equal(nextName(list), 'Wallet 3');
  assert.equal(nextName([{ id: A, slot0: true }, { id: B, name: 'Wallet 2', slot0: false }]), 'Wallet 3');
  assert.equal(nextName([{ id: A, slot0: true }, { id: B, name: 'Wallet 3', slot0: false }]), 'Wallet 4');
  assert.equal(nameProblem('  ', list), 'Give the wallet a name.');
  assert.equal(nameProblem('x'.repeat(MAX_NAME + 1), list), `Use ${MAX_NAME} characters or fewer.`);
  assert.equal(nameProblem('x'.repeat(MAX_NAME), list), null);
  assert.match(nameProblem('savings ', list), /already have a wallet named "savings"/);
  assert.match(nameProblem('wallet 1', list), /already have/, 'the unnamed first wallet is "Wallet 1"');
  assert.equal(nameProblem('Savings', list, B), null, 'renaming to its own name');
  assert.equal(nameProblem('Spending', list), null);
});

test('per-wallet keys: plain names for the first slot, w:<id>: for the others; other keys as they are', () => {
  for (const k of [ETH_RECORD_KEY, ETH_OUTBOX_KEY, BRIDGE_RECORD_KEY, BUY_RECORD_KEY, 'airdropCodes', 'dapp-files', 'dapp-file:abc']) assert.ok(isWalletKey(k), k);
  for (const k of ['prefs', 'wallet', 'uniswap-scan:x', `w:${A}:addressBook`]) assert.equal(isWalletKey(k), false, k);
  const first = { id: A, slot0: true };
  const other = { id: B, slot0: false };
  assert.equal(keyFor(first, 'eth'), 'eth');
  assert.equal(keyFor(other, 'eth'), `w:${B}:eth`);
  assert.equal(keyFor(other, 'dapp-file:abc'), `w:${B}:dapp-file:abc`);
  const open = { record: other, open: true };
  assert.equal(mapWalletKey('bridge', true, open), `w:${B}:bridge`);
  assert.equal(mapWalletKey('prefs', true, open), 'prefs');
  assert.equal(mapWalletKey('bridge', false, { record: first, open: false }), 'bridge', 'read while locked');
  assert.throws(() => mapWalletKey('bridge', true, { record: other, open: false }), (e) => e.code === 'locked', 'no write while locked: a late write from the wallet just left cannot land in this one');
  assert.throws(() => mapWalletKey('eth', false, { record: null, open: false }), (e) => e.code === 'none');
  assert.equal(walletKey({ record: first }, 'addressBook'), `w:${A}:addressBook`, 'new data: always under the prefix, the first slot too');
  assert.equal(walletKey({ record: other }, 'hiddenTokens'), `w:${B}:hiddenTokens`);
  assert.throws(() => walletKey({ record: null }, 'x'), (e) => e.code === 'none');
  assert.throws(() => walletKey({ record: other }, ''), (e) => e.code === 'bad_name');
});

test('the scope follows app.record and app.dbPass (set by app.js)', () => {
  setScopeRecord({ id: B, slot0: false });
  setScopeOpen(true);
  assert.deepEqual(scopeState(), { id: B, slot0: false, open: true });
  setScopeOpen(false);
  setScopeRecord(null);
  assert.deepEqual(scopeState(), { id: null, slot0: false, open: false });
});

test('a store bound to a wallet keeps naming that wallet, and passes other keys through', async () => {
  const kv = memKv();
  const s = walletStore({ id: B, slot0: false }, kv);
  await s.set('buybeam', { x: 1 });
  await s.batch([['set', 'dapp-files', []], ['set', 'prefs', { y: 2 }]]);
  assert.deepEqual([...kv.m.keys()].sort(), ['prefs', `w:${B}:buybeam`, `w:${B}:dapp-files`]);
  assert.deepEqual(await s.get('buybeam'), { x: 1 });
  const first = walletStore({ id: A, slot0: true }, kv);
  await first.set('eth', 1);
  assert.ok(kv.m.has('eth'));
});

test('every per-wallet key the code names is in the list, and every literal store key is classified', () => {
  const air = readFileSync(join(SRC, 'lib', 'airdrop.js'), 'utf8').match(/const VAULT_KEY = '([^']+)'/)[1];
  const list = readFileSync(join(SRC, 'lib', 'dapps', 'installed.js'), 'utf8');
  const dappList = list.match(/const LIST = '([^']+)'/)[1];
  const dappPkg = list.match(/const pkgKey = \(guid\) => `([^$]+)\$\{guid\}`/)[1];
  assert.deepEqual([...WALLET_KEYS].sort(), [ETH_RECORD_KEY, ETH_OUTBOX_KEY, BRIDGE_RECORD_KEY, BUY_RECORD_KEY, air, dappList].sort());
  assert.deepEqual([...WALLET_KEY_PREFIXES], [dappPkg]);
  const files = [];
  const walk = (d) => {
    for (const n of readdirSync(d)) {
      const p = join(d, n);
      if (n === 'vendor') continue;
      if (statSync(p).isDirectory()) walk(p);
      else if (n.endsWith('.js')) files.push(p);
    }
  };
  walk(SRC);
  const literal = /\b(?:store|kv|rawStore)\.(?:get|set|del)\('([^']+)'/g;
  const known = (k) => WALLET_KEYS.includes(k) || APP_KEYS.includes(k) || WALLET_KEY_PREFIXES.some((p) => k.startsWith(p)) || APP_KEY_PREFIXES.some((p) => k.startsWith(p));
  for (const f of files) for (const m of readFileSync(f, 'utf8').matchAll(literal)) assert.ok(known(m[1]), `${f}: store key '${m[1]}' is neither the app's nor a wallet's (lib/wallet_scope.js)`);
});

test('preferences: the first slot keeps its own in "prefs"; another wallet has its own, and the app-wide ones are shared', async () => {
  const kv = singleWalletDevice();
  const first = (await listWallets(kv))[0];
  const other = { ...rec(B), slot0: false, name: 'Two' };
  await saveRecord(other, kv);
  const p0 = await loadPrefs(other, kv);
  assert.equal(p0.ownNodeKey, false, "the first wallet's owner key on the node is not this one's");
  assert.equal(p0.dapps, undefined, "no dApp permissions of the first wallet");
  assert.equal(p0.backupPromptSnoozedUntil, undefined);
  assert.equal(p0.autoLockMin, 15, 'auto-lock is the app\'s');
  assert.equal(p0.bridgePrices, true, 'price consent is the app\'s');
  const prefsBefore = await kv.get('prefs');
  const p1 = await savePrefs(other, { dapps: { g: { remote: false } }, autoLockMin: 1, ownNodeKey: true }, kv);
  assert.deepEqual(p1.dapps, { g: { remote: false } });
  assert.equal(p1.autoLockMin, 1);
  assert.deepEqual(await kv.get(`w:${B}:prefs`), { dapps: { g: { remote: false } }, ownNodeKey: true });
  const prefsAfter = await kv.get('prefs');
  assert.equal(prefsAfter.autoLockMin, 1);
  for (const k of WALLET_PREF_KEYS) assert.deepEqual(prefsAfter[k], prefsBefore[k], `the first wallet's ${k} is untouched`);
  const back = await loadPrefs(first, kv);
  assert.deepEqual(back.dapps, { ['1'.repeat(32)]: { remote: true } });
  assert.equal(back.ownNodeKey, true);
  await savePrefs(first, { backupPromptSnoozedUntil: 7 }, kv);
  assert.equal((await kv.get('prefs')).backupPromptSnoozedUntil, 7);
  assert.equal((await kv.get(`w:${B}:prefs`)).backupPromptSnoozedUntil, undefined);
});

/** Three wallets, each with data of every kind, as the app would keep them. */
async function threeWallets() {
  const kv = singleWalletDevice();
  for (const [id, name] of [[B, 'Two'], [C, 'Three']]) {
    const r = { ...rec(id), slot0: false, name };
    await saveRecord(r, kv);
    const s = walletStore(r, kv);
    for (const k of WALLET_KEYS) await s.set(k, { walletId: id, k });
    await s.set('dapp-file:9', { id });
    await kv.set(`w:${id}:prefs`, { dapps: { z: { remote: true } } });
  }
  for (const id of [A, B, C]) {
    await kv.set(balanceKey(id), { available: '100', at: 1 });
    await kv.set(`w:${id}:addressBook`, [{ id }]); // a newer feature's data, under walletKey()
  }
  return kv;
}

const keysOf = (kv, id) => [...kv.m.keys()].filter((k) => k.startsWith(`w:${id}:`)).sort();

test('deleting a wallet that is not the first: its keys only; the first slot and the third are untouched', async () => {
  const kv = await threeWallets();
  const target = (await listWallets(kv)).find((r) => r.id === B);
  const keep = [...kv.m.entries()].filter(([k]) => !k.startsWith(`w:${B}:`));
  await kv.batch(await removalOps(target, kv));
  assert.deepEqual(keysOf(kv, B), []);
  for (const [k, v] of keep) assert.deepEqual(kv.m.get(k), v, `${k} unchanged`);
  assert.deepEqual((await listWallets(kv)).map((r) => r.id).sort(), [A, C].sort());
});

test('deleting the first slot: its plain keys and its own preferences; the app-wide ones and the others stay', async () => {
  const kv = await threeWallets();
  await kv.set('prefs', { ...(await kv.get('prefs')), lastWalletId: A });
  const target = (await listWallets(kv)).find((r) => r.id === A);
  const others = [...kv.m.entries()].filter(([k]) => k.startsWith(`w:${B}:`) || k.startsWith(`w:${C}:`));
  await kv.batch(await removalOps(target, kv));
  for (const k of ['wallet', ...WALLET_KEYS, `dapp-file:${'2'.repeat(32)}`]) assert.equal(kv.m.has(k), false, `${k} removed`);
  assert.deepEqual(keysOf(kv, A), []);
  const prefs = kv.m.get('prefs');
  for (const k of WALLET_PREF_KEYS) assert.equal(k in prefs, false, `${k} went with it`);
  assert.equal(prefs.lastWalletId, undefined);
  assert.equal(prefs.autoLockMin, 15);
  assert.equal(prefs.bridgePrices, true);
  assert.ok(kv.m.has('uniswap-scan:pools'), 'public chain data stays');
  for (const [k, v] of others) assert.deepEqual(kv.m.get(k), v, `${k} unchanged`);
  const list = await listWallets(kv);
  assert.deepEqual(list.map((r) => r.id).sort(), [B, C].sort());
  assert.deepEqual(placeFor(list), { slot0: true }, 'the next new wallet may take the first slot');
});

function fakeApp(kv, record, { dbPass = 'x', running = null } = {}) {
  const calls = [];
  const app = {
    record,
    dbPass,
    setup: { words: ['w'] },
    afterUnlock: { name: 'bridgeMove' },
    prefs: null,
    nav: { clear: () => calls.push('nav') },
    runLockHooks: () => calls.push('hooks'),
    wallet: { run: running ? { dbPath: running } : null, stop: async () => calls.push('stop'), onChange: () => () => {} },
    setPrefs: async (patch) => (app.prefs = await savePrefs(app.record, patch, kv)),
  };
  return { app, calls };
}

test('removeWallet: the open wallet stops, only its file goes, another is selected (locked); the last one clears the store', async () => {
  const kv = await threeWallets();
  const list = await listWallets(kv);
  const b = list.find((r) => r.id === B);
  const { app, calls } = fakeApp(kv, b, { running: dbPathOf(b) });
  const deleted = [];
  const removedIds = [];
  const off = onWalletRemoved((id) => removedIds.push(id));
  const { others } = await removeWallet(app, b, { kv, deleteDb: async (p) => deleted.push(p) });
  off();
  assert.deepEqual(deleted, [`${DB_DIR}/${B}/wallet.db`], 'its own file only');
  assert.deepEqual(calls, ['nav', 'hooks', 'stop']);
  assert.equal(app.dbPass, null);
  assert.equal(app.setup, null);
  assert.equal(app.afterUnlock, null);
  assert.equal(app.record.id, A, 'the first slot comes up next, locked');
  assert.deepEqual(others.map((r) => r.id).sort(), [A, C].sort());
  assert.deepEqual(removedIds, [B]);

  // Another wallet, not the open one: nothing stops.
  const c = (await listWallets(kv)).find((r) => r.id === C);
  const open = fakeApp(kv, (await listWallets(kv)).find((r) => r.id === A), { running: DB_PATH });
  await removeWallet(open.app, c, { kv, deleteDb: async (p) => deleted.push(p) });
  assert.deepEqual(open.calls, [], 'the open wallet keeps running');
  assert.equal(open.app.dbPass, 'x');
  assert.equal(open.app.record.id, A);
  assert.deepEqual(keysOf(kv, C), []);

  // The last one: everything, as deleting the only wallet always did.
  const last = (await listWallets(kv))[0];
  const one = fakeApp(kv, last, { running: DB_PATH });
  await removeWallet(one.app, last, { kv, deleteDb: async (p) => deleted.push(p) });
  assert.equal(kv.m.size, 0);
  assert.equal(one.app.record, null);
  assert.deepEqual(deleted, [`${DB_DIR}/${B}/wallet.db`, `${DB_DIR}/${C}/wallet.db`, DB_PATH]);
  await assert.rejects(removeWallet(one.app, last, { kv, deleteDb: async () => {} }), (e) => e.code === 'missing');
});

test('removeWallet: a wallet kept running behind the lock for a payment is stopped before its file goes', async () => {
  const kv = await threeWallets();
  const list = await listWallets(kv);
  const a = list.find((r) => r.id === A);
  const c = list.find((r) => r.id === C);
  // C is selected on the unlock screen, A still runs locked: deleting A stops it; C stays selected.
  const { app, calls } = fakeApp(kv, c, { dbPass: null, running: DB_PATH });
  await removeWallet(app, a, { kv, deleteDb: async () => calls.push('delete') });
  assert.deepEqual(calls, ['stop', 'delete']);
  assert.equal(app.record.id, C);
});

test('deleting leaves less behind (ported from the Firo wallet): the passkey is reported gone, shown notifications close; the last wallet also takes the app caches and the app settings in localStorage', async () => {
  const kv = await threeWallets();
  const withKey = { ...(await listWallets(kv)).find((r) => r.id === B), envelopes: { password: env(B), passkey: { v: 1, kind: 'passkey', walletId: B, credId: 'Y3JlZC1C', prfSalt: 'c2FsdA==' } } };
  await saveRecord(withKey, kv);
  const storage = new Map([['campfire-theme', 'dark'], ['campfire-update-source', '"https://mirror.example/"'], ['campfire-last-update-check', '{}'], ['other-site-thing', 'x']]);
  const ls = { get length() { return storage.size; }, key: (i) => [...storage.keys()][i] ?? null, removeItem: (k) => storage.delete(k), getItem: (k) => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, String(v)) };
  const seen = { signalled: [], closed: 0, caches: 0 };
  const deps = {
    kv,
    deleteDb: async () => {},
    clearCaches: async () => void seen.caches++,
    storage: ls,
    signalPasskeyGone: async (credId) => void seen.signalled.push(credId),
    closeNotifications: async () => void seen.closed++,
  };
  const a = (await listWallets(kv)).find((r) => r.id === A);
  const { app } = fakeApp(kv, a);
  await removeWallet(app, (await listWallets(kv)).find((r) => r.id === B), deps);
  assert.deepEqual(seen.signalled, ['Y3JlZC1C'], 'its passkey: the password manager is told it is gone');
  assert.equal(seen.closed, 1, 'notifications already shown are closed');
  assert.equal(seen.caches, 0, 'other wallets still use the own node and the dApps');
  assert.equal(storage.size, 4, "the app's settings stay while other wallets do");
  await removeWallet(app, (await listWallets(kv)).find((r) => r.id === C), deps);
  assert.deepEqual(seen.signalled, ['Y3JlZC1C'], 'no passkey, nothing to tell');
  // A step that fails never fails the delete.
  await removeWallet(app, (await listWallets(kv)).find((r) => r.id === A), { ...deps, closeNotifications: async () => { throw new Error('no service worker'); } });
  assert.equal(seen.caches, 1, 'the last wallet: the own-node address and dApp copies go too');
  assert.deepEqual([...storage.keys()], ['other-site-thing'], "the last wallet: Beam PWA's own localStorage goes (theme, update address)");
  assert.equal(kv.m.size, 0);
});

test('rename: the open wallet in memory and in storage; another wallet in storage; names checked', async () => {
  const kv = await threeWallets();
  const list = await listWallets(kv);
  const a = list.find((r) => r.id === A);
  const { app } = fakeApp(kv, a);
  await renameWallet(app, a, '  Main   wallet ', kv);
  assert.equal(app.record.name, 'Main wallet');
  assert.equal((await kv.get('wallet')).name, 'Main wallet');
  await renameWallet(app, list.find((r) => r.id === B), 'Spending', kv);
  assert.equal((await kv.get(`w:${B}:wallet`)).name, 'Spending');
  assert.deepEqual((await kv.get(`w:${B}:wallet`)).envelopes, rec(B).envelopes, 'envelopes untouched');
  await assert.rejects(renameWallet(app, list.find((r) => r.id === C), 'main WALLET', kv), (e) => e.code === 'name');
});

test('selectWallet refuses while a wallet is open, and loads the chosen one\'s preferences', async () => {
  const kv = await threeWallets();
  const list = await listWallets(kv);
  const { app } = fakeApp(kv, list[0]);
  await assert.rejects(selectWallet(app, list[1], kv), (e) => e.code === 'open');
  app.dbPass = null;
  const b = list.find((r) => r.id === B);
  await selectWallet(app, b, kv);
  assert.equal(app.record.id, B);
  assert.equal(app.afterUnlock, null, "a screen of the wallet left is not reopened in this one");
  assert.deepEqual(app.prefs.dapps, { z: { remote: true } });
});

test('initial wallet: the one last opened, else the first slot, else any', () => {
  const list = [{ id: B, slot0: false }, { id: A, slot0: true }, { id: C, slot0: false }];
  assert.equal(initialWallet(list, { lastWalletId: C }).id, C);
  assert.equal(initialWallet(list, { lastWalletId: 'gone' }).id, A);
  assert.equal(initialWallet([{ id: B, slot0: false }], {}).id, B);
  assert.equal(initialWallet([], {}), null);
});

test('no balance is kept in the clear (audit A-4): an earlier version\'s are removed at start, nothing writes one', async () => {
  const kv = await threeWallets();
  assert.equal(kv.m.has(balanceKey(B)), true, 'as an earlier version left them');
  const others = [...kv.m.entries()].filter(([k]) => !/:balance$/.test(k));
  assert.equal(await forgetStoredBalances(kv), 3);
  assert.deepEqual([...kv.m.keys()].filter((k) => /:balance$/.test(k)), []);
  for (const [k, v] of others) assert.deepEqual(kv.m.get(k), v, `${k} untouched`);
  assert.equal(await forgetStoredBalances(kv), 0);
  // Nothing in the app writes one any more; the switcher says "Locked" for another wallet.
  const files = [];
  const walk = (d) => readdirSync(d).forEach((f) => (statSync(join(d, f)).isDirectory() ? f !== 'vendor' && walk(join(d, f)) : f.endsWith('.js') && files.push(join(d, f))));
  walk(SRC);
  for (const f of files) assert.ok(!/balanceKey\(|watchBalances|lastBalances/.test(readFileSync(f, 'utf8').replace(/export const balanceKey[^\n]*/, '')), f);
  assert.match(readFileSync(join(SRC, 'app.js'), 'utf8'), /forgetStoredBalances\(\)/);
  const { balanceText } = await import('../../src/screens/wallets.js');
  assert.equal(balanceText({ dbPass: null, record: { id: A } }, { id: B }), 'Locked');
});

test('database files: deleting the first slot removes its plain files and never a folder; another wallet, its folder only', () => {
  const files = new Map([
    ['/beam_wallet/wallet.db', 'f'], ['/beam_wallet/wallet.db-journal', 'f'], ['/beam_wallet/import.db', 'f'],
    [`/beam_wallet/${B}`, 'd'], [`/beam_wallet/${B}/wallet.db`, 'f'], [`/beam_wallet/${B}/wallet.db-journal`, 'f'],
    [`/beam_wallet/${C}`, 'd'], [`/beam_wallet/${C}/wallet.db`, 'f'],
  ]);
  const FS = {
    readdir: (d) => ['.', '..', ...[...files.keys()].filter((p) => p.startsWith(`${d}/`) && !p.slice(d.length + 1).includes('/')).map((p) => p.slice(d.length + 1))],
    stat: (p) => {
      if (!files.has(p)) throw new Error('ENOENT');
      return { mode: files.get(p) };
    },
    isDir: (mode) => mode === 'd',
    unlink: (p) => {
      if (files.get(p) !== 'f') throw new Error('EISDIR');
      files.delete(p);
    },
    rmdir: (p) => {
      if ([...files.keys()].some((k) => k.startsWith(`${p}/`))) throw new Error('ENOTEMPTY');
      files.delete(p);
    },
  };
  const all = () => [...files.keys()].sort();
  assert.deepEqual(removeWalletFiles(FS, `/beam_wallet/${B}/wallet.db`).sort(), [`/beam_wallet/${B}`, `/beam_wallet/${B}/wallet.db`, `/beam_wallet/${B}/wallet.db-journal`].sort());
  assert.deepEqual(all(), ['/beam_wallet/import.db', `/beam_wallet/${C}`, `/beam_wallet/${C}/wallet.db`, '/beam_wallet/wallet.db', '/beam_wallet/wallet.db-journal'].sort());
  removeWalletFiles(FS, DB_PATH);
  assert.deepEqual(all(), [`/beam_wallet/${C}`, `/beam_wallet/${C}/wallet.db`], "the other wallet's folder stays");
  assert.throws(() => removeWalletFiles(FS, '/beam_wallet/../etc/wallet.db'), (e) => e.code === 'path');
  assert.throws(() => removeWalletFiles(FS, '/beam_wallet/xyz/wallet.db'), (e) => e.code === 'path');
  assert.equal(isWalletPath(DB_PATH), true);
  assert.equal(isWalletPath(`/beam_wallet/${B}/wallet.db`), true);
  assert.equal(isWalletPath('/beam_wallet/import.db'), false);
  assert.equal(isWalletPath(`/beam_wallet/${B}/x/wallet.db`), false);
});

test('adding wallets beside a single-wallet device leaves everything an older version reads exactly as it was', async () => {
  const kv = singleWalletDevice();
  const before = new Map([...kv.m.entries()].map(([k, v]) => [k, JSON.stringify(v)]));
  for (const [id, name] of [[B, 'Two'], [C, 'Three']]) {
    const r = { ...rec(id), slot0: false, name };
    await saveRecord(r, kv);
    const s = walletStore(r, kv);
    await s.set('eth', { id });
    await s.set('dapp-files', []);
    await savePrefs(r, { dapps: { q: { remote: true } }, ownNodeKey: true, backupPromptSnoozedUntil: 3 }, kv);
  }
  for (const [k, v] of before) {
    if (k === 'prefs') continue;
    assert.equal(JSON.stringify(kv.m.get(k)), v, `${k} unchanged`);
  }
  const prefs = kv.m.get('prefs');
  const old = JSON.parse(before.get('prefs'));
  for (const k of [...WALLET_PREF_KEYS, 'node', 'autoLockMin']) assert.deepEqual(prefs[k], old[k], `prefs.${k} unchanged`);
  // What the single-wallet version reads: getWalletRecord() = 'wallet', its data under the plain names.
  assert.equal(kv.m.get('wallet').id, A);
  assert.ok(![...kv.m.keys()].some((k) => k.startsWith(`w:${A}:`) && k !== `w:${A}:balance`), 'nothing of the first wallet moved under a prefix');
});

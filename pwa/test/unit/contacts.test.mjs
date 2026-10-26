// The address book (lib/contacts.js): one sealed record per wallet under
// payments:<wallet id>; names and addresses checked; a contact never changes
// unless the person changes it (a tampered record does not open and is never
// written over); look-alike addresses are told apart.
import test from 'node:test';
import assert from 'node:assert/strict';
import { newDbPassword } from '../../src/lib/envelope.js';
import * as C from '../../src/lib/contacts.js';

const A1 = `${'3f25d94eac'}${'1'.repeat(47)}c9df9477`;
const A2 = `${'8b11aa20ff'}${'2'.repeat(47)}0de4c1aa`;
const LOOK = `${'3f25d94eac'}${'9'.repeat(47)}c9df9477`; // starts and ends like A1

function memKv() {
  const m = new Map();
  return { m, get: async (k) => (m.has(k) ? structuredClone(m.get(k)) : undefined), set: async (k, v) => void m.set(k, structuredClone(v)) };
}

test('names and addresses as they are kept', () => {
  assert.equal(C.cleanName('  Alice \n Smith '), 'Alice Smith');
  assert.equal([...C.cleanName('x'.repeat(99))].length, C.NAME_MAX);
  assert.equal(C.cleanAddress(` ${A1.slice(0, 20)}\n${A1.slice(20)} `), A1);
  assert.equal(C.looksLikeAddress(A1), true);
  assert.equal(C.looksLikeAddress('short'), false);
  assert.equal(C.looksLikeAddress(`${A1}<`), false);
  assert.equal(C.paymentsKey('a1a1a1a1a1a1a1a1'), 'w:a1a1a1a1a1a1a1a1:payments', 'one record per wallet');
});

test('checkContact: a name, a real-looking address, no duplicate address', () => {
  const list = [{ id: '0'.repeat(16), name: 'Alice', address: A1 }];
  assert.equal(C.checkContact({ name: '', address: A2 }, list).field, 'name');
  assert.equal(C.checkContact({ name: 'Bob', address: '' }, list).field, 'address');
  assert.match(C.checkContact({ name: 'Bob', address: 'hello' }, list).problem, /isn't a BEAM address/);
  const dup = C.checkContact({ name: 'Bob', address: A1 }, list);
  assert.equal(dup.code, 'duplicate');
  assert.match(dup.problem, /already saved as Alice/);
  assert.equal(C.checkContact({ name: 'Alice 2', address: A1 }, list, { editingId: '0'.repeat(16) }).ok, true, 'editing keeps its own address');
  assert.deepEqual(C.checkContact({ name: ' Bob ', address: ` ${A2} ` }, list), { ok: true, name: 'Bob', address: A2 });
});

test('find, look-alike, sort and search', () => {
  const list = [{ id: 'a', name: 'bob', address: A2 }, { id: 'b', name: 'Alice', address: A1 }];
  assert.equal(C.findByAddress(list, ` ${A1}`).name, 'Alice');
  assert.equal(C.findByAddress(list, LOOK), null);
  assert.equal(C.lookalikeOf(list, LOOK).name, 'Alice', 'same start and end, different middle');
  assert.equal(C.lookalikeOf(list, A1), null, 'the saved address itself is no look-alike');
  assert.equal(C.lookalikeOf(list, 'f'.repeat(70)), null);
  assert.deepEqual(C.sortContacts(list).map((c) => c.name), ['Alice', 'bob']);
  assert.deepEqual(C.searchContacts(list, 'BO').map((c) => c.name), ['bob']);
  assert.deepEqual(C.searchContacts(list, A1.slice(-8)).map((c) => c.name), ['Alice']);
});

for (const imported of [false, true]) {
  test(`the sealed record round-trips (${imported ? 'imported wallet: PBKDF2' : 'created wallet: HKDF'}), per wallet, and keeps Receive's address`, async () => {
    const kv = memKv();
    const dbPass = imported ? 'a chosen password' : newDbPassword();
    const v = new C.PaymentsVault({ kv, walletId: 'a1a1a1a1a1a1a1a1', imported, dbPass });
    assert.deepEqual(await v.contacts(), []);
    const a = await v.add({ name: 'Alice', address: A1 }, 1000);
    await v.add({ name: 'Bob', address: A2 }, 2000);
    await assert.rejects(v.add({ name: 'Eve', address: A1 }), (e) => e.code === 'duplicate');
    await v.setReceiveAddress(A2);
    assert.deepEqual([...kv.m.keys()], ['w:a1a1a1a1a1a1a1a1:payments']);
    const env = kv.m.get('w:a1a1a1a1a1a1a1a1:payments');
    assert.equal(env.kdf, imported ? C.KDF_PBKDF2 : C.KDF_HKDF);
    if (imported) assert.equal(env.iterations, 600000);
    assert.ok(!JSON.stringify(env).includes('Alice') && !JSON.stringify(env).includes(A1.slice(10, 30)), 'nothing in the clear');
    const again = new C.PaymentsVault({ kv, walletId: 'a1a1a1a1a1a1a1a1', imported, dbPass });
    const list = await again.contacts();
    assert.deepEqual(list.map((c) => [c.name, c.address]), [['Alice', A1], ['Bob', A2]]);
    assert.equal(await again.receiveAddress(), A2);
    const b = await again.update(a.id, { name: 'Alice S', address: A1 }, 3000);
    assert.equal(b.updatedAt, 3000);
    assert.equal(b.createdAt, 1000);
    assert.equal(await again.remove(a.id), true);
    assert.deepEqual((await again.contacts()).map((c) => c.name), ['Bob']);
    await assert.rejects(again.update(a.id, { name: 'x', address: A1 }), (e) => e.code === 'gone');
  });
}

test('another key, another wallet or an edited record: refused, and nothing is written over', async () => {
  const kv = memKv();
  const dbPass = newDbPassword();
  const v = new C.PaymentsVault({ kv, walletId: 'a1a1a1a1a1a1a1a1', imported: false, dbPass });
  await v.add({ name: 'Alice', address: A1 });
  const before = JSON.stringify(kv.m.get('w:a1a1a1a1a1a1a1a1:payments'));
  const wrong = new C.PaymentsVault({ kv, walletId: 'a1a1a1a1a1a1a1a1', imported: false, dbPass: newDbPassword() });
  await assert.rejects(wrong.contacts(), (e) => e.code === 'wrong_secret');
  await assert.rejects(wrong.add({ name: 'Mallory', address: A2 }), (e) => e.code === 'wrong_secret');
  assert.equal(JSON.stringify(kv.m.get('w:a1a1a1a1a1a1a1a1:payments')), before, 'not written over');
  // The same record placed under another wallet's key.
  kv.m.set('w:b2b2b2b2b2b2b2b2:payments', kv.m.get('w:a1a1a1a1a1a1a1a1:payments'));
  await assert.rejects(new C.PaymentsVault({ kv, walletId: 'b2b2b2b2b2b2b2b2', imported: false, dbPass }).contacts(), (e) => e.code === 'wrong_secret');
  // Someone swaps a byte of the sealed contacts: it does not open (no silent change).
  const env = structuredClone(kv.m.get('w:a1a1a1a1a1a1a1a1:payments'));
  const ct = Buffer.from(env.ct, 'base64');
  ct[5] ^= 1;
  env.ct = ct.toString('base64');
  kv.m.set('w:a1a1a1a1a1a1a1a1:payments', env);
  await assert.rejects(new C.PaymentsVault({ kv, walletId: 'a1a1a1a1a1a1a1a1', imported: false, dbPass }).contacts(), (e) => e.code === 'wrong_secret');
  // A lowered round count or a swapped key derivation is refused before any key is made.
  const kv2 = memKv();
  const v2 = new C.PaymentsVault({ kv: kv2, walletId: 'c3c3c3c3c3c3c3c3', imported: true, dbPass: 'pw' });
  await v2.add({ name: 'A', address: A1 });
  const e2 = structuredClone(kv2.m.get('w:c3c3c3c3c3c3c3c3:payments'));
  kv2.m.set('w:c3c3c3c3c3c3c3c3:payments', { ...e2, iterations: 1000 });
  await assert.rejects(new C.PaymentsVault({ kv: kv2, walletId: 'c3c3c3c3c3c3c3c3', imported: true, dbPass: 'pw' }).contacts(), (e) => e.code === 'weak');
  kv2.m.set('w:c3c3c3c3c3c3c3c3:payments', { ...e2, kdf: C.KDF_HKDF });
  await assert.rejects(new C.PaymentsVault({ kv: kv2, walletId: 'c3c3c3c3c3c3c3c3', imported: true, dbPass: 'pw' }).contacts(), (e) => e.code === 'weak');
  kv2.m.set('w:c3c3c3c3c3c3c3c3:payments', { ...e2, salt: Buffer.alloc(16, 7).toString('base64') });
  await assert.rejects(new C.PaymentsVault({ kv: kv2, walletId: 'c3c3c3c3c3c3c3c3', imported: true, dbPass: 'pw' }).contacts(), (e) => e.code === 'wrong_secret');
});

test('vaultFor: one vault per unlocked wallet; a lock forgets it; locked or no wallet refused', async () => {
  const kv = memKv();
  const app = { record: { id: 'd9d9d9d9d9d9d9d9', imported: false }, dbPass: newDbPassword(), lockHooks: new Set() };
  const v1 = await C.vaultFor(app, kv);
  assert.equal(await C.vaultFor(app, kv), v1);
  await v1.add({ name: 'Alice', address: A1 });
  await C.loadContacts(app);
  assert.equal(C.contactNameFor(A1), 'Alice');
  assert.equal(app.lockHooks.size, 1);
  for (const f of app.lockHooks) f();
  assert.equal(C.cachedContacts(), null);
  assert.equal(C.contactNameFor(A1), null);
  assert.notEqual(await C.vaultFor(app, kv), v1);
  await assert.rejects(C.vaultFor({ record: { id: 'd9d9d9d9d9d9d9d9' }, dbPass: null }, kv), (e) => e.code === 'locked');
  await assert.rejects(C.vaultFor({ record: null, dbPass: 'x' }, kv), (e) => e.code === 'missing');
});

test('BEAM names paid: the owner key each was paid, sealed with the contacts, kept beside them (audit D-1)', async () => {
  const kv = memKv();
  const dbPass = newDbPassword();
  const OWNER = `${'72e368c016'}${'0'.repeat(54)}01`;
  const OTHER = `${'9c'.repeat(32)}00`;
  const v = new C.PaymentsVault({ kv, walletId: 'e5e5e5e5e5e5e5e5', imported: false, dbPass });
  assert.deepEqual(await v.namePins(), {});
  await v.add({ name: 'Alice', address: A1 });
  await v.pinName('alice', OWNER, 1000);
  await v.pinName('bob', OTHER, 2000);
  assert.ok(!JSON.stringify(kv.m.get('w:e5e5e5e5e5e5e5e5:payments')).includes('alice'), 'who you paid is sealed');
  const again = new C.PaymentsVault({ kv, walletId: 'e5e5e5e5e5e5e5e5', imported: false, dbPass });
  assert.deepEqual(await again.namePins(), { alice: OWNER, bob: OTHER });
  assert.deepEqual((await again.contacts()).map((c) => c.name), ['Alice'], 'contacts untouched');
  // A contact change keeps the pins; a new owner, once paid, is the one remembered.
  await again.add({ name: 'Bob', address: A2 });
  await again.pinName('alice', OTHER, 3000);
  assert.deepEqual(await new C.PaymentsVault({ kv, walletId: 'e5e5e5e5e5e5e5e5', imported: false, dbPass }).namePins(), { alice: OTHER, bob: OTHER });
  // Only names and keys.
  await assert.rejects(again.pinName('Alice.beam', OWNER), (e) => e.code === 'invalid');
  await assert.rejects(again.pinName('alice', 'nope'), (e) => e.code === 'invalid');
  // The oldest go first past NAME_PINS_MAX.
  const many = new C.PaymentsVault({ kv: memKv(), walletId: 'f6f6f6f6f6f6f6f6', imported: false, dbPass });
  for (let i = 0; i < C.NAME_PINS_MAX + 2; i++) await many.pinName(`n${String(i).padStart(4, '0')}`, OWNER, i);
  const pins = await many.namePins();
  assert.equal(Object.keys(pins).length, C.NAME_PINS_MAX);
  assert.ok(!('n0000' in pins) && !('n0001' in pins) && 'n0002' in pins);
  // Through the open wallet.
  const app = { record: { id: 'e5e5e5e5e5e5e5e5', imported: false }, dbPass, lockHooks: new Set() };
  assert.equal(await C.namePinFor(app, 'alice', kv), OTHER);
  assert.equal(await C.namePinFor(app, 'carol', kv), null);
  await C.pinNamePayment(app, 'carol', OWNER, kv);
  assert.equal(await C.namePinFor(app, 'carol', kv), OWNER);
  for (const f of app.lockHooks) f();
});

// Audit BC-3: Send and Review read the owner key a name was paid before with
// namePinFor(...).catch(() => null), so a record that does not open (damaged, or a key-derivation
// mismatch) looked exactly like "never paid": the owner-change check went off without a word.
// readNamePin says which it is, and both screens say NAME_PIN_UNREAD.
test('a names-paid record that cannot be read is told apart from "never paid" (audit BC-3)', async () => {
  const kv = memKv();
  const dbPass = newDbPassword();
  const OWNER = `${'72e368c016'}${'0'.repeat(54)}01`;
  const app = { record: { id: 'a7a7a7a7a7a7a7a7', imported: false }, dbPass, lockHooks: new Set() };
  try {
    assert.deepEqual(await C.readNamePin(app, 'alice', kv), { key: null, unread: false }, 'nothing kept yet: never paid');
    await C.pinNamePayment(app, 'alice', OWNER, kv);
    assert.deepEqual(await C.readNamePin(app, 'alice', kv), { key: OWNER, unread: false });
    assert.deepEqual(await C.readNamePin(app, 'bob', kv), { key: null, unread: false });
    // The sealed record damaged: namePinFor throws, readNamePin says it could not read it.
    for (const f of app.lockHooks) f();
    const env = structuredClone(kv.m.get('w:a7a7a7a7a7a7a7a7:payments'));
    const ct = Buffer.from(env.ct, 'base64');
    ct[3] ^= 1;
    env.ct = ct.toString('base64');
    kv.m.set('w:a7a7a7a7a7a7a7a7:payments', env);
    await assert.rejects(C.namePinFor(app, 'alice', kv));
    assert.deepEqual(await C.readNamePin(app, 'alice', kv), { key: null, unread: true });
    // Locked: the same (nothing to compare with).
    assert.deepEqual(await C.readNamePin({ record: app.record, dbPass: null }, 'alice', kv), { key: null, unread: true });
    assert.equal(C.NAME_PIN_UNREAD, 'Beam PWA could not compare this owner with your earlier payments.');
  } finally {
    for (const f of app.lockHooks) f();
  }
});

test('Send and Review never read the names-paid record in a way that hides a failure', async () => {
  const { readFileSync } = await import('node:fs');
  const { join, dirname } = await import('node:path');
  const { fileURLToPath } = await import('node:url');
  const screens = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src', 'screens');
  for (const f of ['send.js', 'review.js']) {
    const s = readFileSync(join(screens, f), 'utf8');
    assert.ok(!/namePinFor\([^)]*\)\s*\.catch\(\s*\(\)\s*=>\s*null\s*\)/.test(s), `${f}: no namePinFor(...).catch(() => null)`);
    assert.ok(s.includes('NAME_PIN_UNREAD'), `${f}: says when the record could not be read`);
  }
});

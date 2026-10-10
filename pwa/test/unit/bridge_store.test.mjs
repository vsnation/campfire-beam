// Crossing records and their store (lib/bridge/store.js): every field survives
// JSON, an unknown state is refused rather than guessed, and the sealed store
// round-trips under the wallet's dbPass (HKDF, or PBKDF2 for imported wallets),
// refuses a wrong key or another wallet's records without writing over them,
// keeps a damaged or newer record exactly as it was, and allows one message id
// per crossing. The cases follow the desktop's bridge_store_test.dart.
import test from 'node:test';
import assert from 'node:assert/strict';
import { newDbPassword, PBKDF2_MIN_ITERATIONS } from '../../src/lib/envelope.js';
import { KDF_HKDF, KDF_PBKDF2 } from '../../src/lib/eth/vault.js';
import * as S from '../../src/lib/bridge/store.js';

const { makeCrossing, changeCrossing, crossingToJson, crossingFromJson, SealedBridgeStore, MemoryBridgeStore, BridgeStoreError, bridgeStoreFor, BRIDGE_RECORD_KEY, BRIDGE_DATA_INFO, STATES } = S;

const T = Date.UTC(2026, 9, 9, 16, 42, 5);
const ETH_ADDRESS = '0x7a3e5b1c2d4f6e8a9b0c1d2e3f4a5b6c7d8e91c4'; // made up

function full(patch = {}) {
  return makeCrossing({
    id: 'x1',
    route: 'usdt',
    direction: 'toBeam',
    state: STATES.claiming,
    amount: 100000000n,
    receives: 10000000000n,
    relayerFee: 157n,
    beamNetworkFee: 12100000n,
    ethNetworkFee: 247333500000000n,
    beamWalletId: 'beam-wallet',
    ethWalletId: 'eth-wallet',
    ethAddress: ETH_ADDRESS,
    beamReceiveKey: `${'ab'.repeat(32)}01`,
    approveHashes: [`0x${'1'.repeat(64)}`, `0x${'2'.repeat(64)}`],
    lockHash: `0x${'3'.repeat(64)}`,
    lockRaw: '0x02f8',
    lockNonce: 12,
    beamTxId: 'tx-send',
    claimTxId: 'tx-claim',
    msgId: 110,
    countBefore: 3,
    height: 26156200,
    createdAt: T,
    updatedAt: T + 5 * 60000,
    dueAt: T + 60000,
    lockedAt: T + 2 * 60000,
    deliveredAt: T + 3 * 60000,
    claimStartedAt: T + 4 * 60000,
    finishedAt: T + 6 * 60000,
    lastError: 'a reason',
    ...patch,
  });
}

const memoryKv = () => {
  const m = new Map();
  return { m, get: async (k) => structuredClone(m.get(k)), set: async (k, v) => void m.set(k, structuredClone(v)) };
};

const created = (kv, dbPass = newDbPassword(), walletId = 'w-created') => new SealedBridgeStore({ kv, walletId, imported: false, dbPass });

test('every field survives JSON; an unknown state, direction, route or field is refused, not guessed', () => {
  const a = full();
  const b = crossingFromJson(JSON.parse(JSON.stringify(crossingToJson(a))));
  assert.deepEqual(b, a);
  assert.ok(Object.isFrozen(b) && Object.isFrozen(b.approveHashes));
  for (const [k, v] of [
    ['state', 'teleported'],
    ['direction', 'sideways'],
    ['route', 'doge'],
    ['amount', '-1'],
    ['amount', '1e9'],
    ['msgId', -1],
    ['somethingNew', 1],
  ]) {
    assert.throws(() => crossingFromJson({ ...crossingToJson(a), [k]: v }), Error, `${k}=${v}`);
  }
  // Absent fields stay absent, and null clears one.
  const bare = makeCrossing({ ...crossingFromJson(crossingToJson(a)), msgId: null, lastError: null, approveHashes: [] });
  const j = crossingToJson(bare);
  assert.ok(!('msgId' in j) && !('lastError' in j) && !('approveHashes' in j));
  assert.equal(changeCrossing(a, { lastError: null }).lastError, null);
  assert.equal(S.isFinal(STATES.claimed) && S.isFinal(STATES.paid) && S.isFinal(STATES.failed) && S.isFinal(STATES.lockFailed), true);
  assert.equal(S.isOpen(full({ state: STATES.unknown })), true);
});

test('sealed store: round trip after a restart, newest first; nothing about the crossing in the clear', async () => {
  const kv = memoryKv();
  const dbPass = newDbPassword();
  const store = created(kv, dbPass);
  assert.deepEqual(await store.all(), []);
  await store.save(full());
  await store.save(full({ id: 'x2', msgId: 111, createdAt: T + 1 }));
  await store.save(changeCrossing(full(), { state: STATES.claimed }));
  const again = created(kv, dbPass);
  const all = await again.all();
  assert.deepEqual(all.map((c) => c.id), ['x2', 'x1']);
  assert.equal((await again.byId('x1')).state, STATES.claimed);
  assert.equal((await again.byId('x1')).claimTxId, 'tx-claim');
  assert.equal(await again.byId('nope'), null);
  const env = kv.m.get(BRIDGE_RECORD_KEY);
  assert.equal(env.kdf, KDF_HKDF);
  assert.equal(env.walletId, 'w-created');
  assert.equal(env.records.length, 2);
  const clear = JSON.stringify(env).toLowerCase();
  for (const secret of [ETH_ADDRESS.slice(2), 'tx-claim', 'usdt', '26156200', 'claimed']) assert.ok(!clear.includes(secret), secret);
  assert.equal(BRIDGE_DATA_INFO, 'beam-campfire-bridge-data-v1');
});

test('sealed store: a wrong key or another wallet is refused, and nothing is written over', async () => {
  const kv = memoryKv();
  const store = created(kv);
  await store.save(full());
  const before = JSON.stringify(kv.m.get(BRIDGE_RECORD_KEY));
  const wrong = created(kv, newDbPassword());
  await assert.rejects(wrong.all(), (e) => e instanceof BridgeStoreError && e.code === 'wrong_secret');
  await assert.rejects(wrong.save(full({ id: 'x9', msgId: 9 })), (e) => e.code === 'wrong_secret');
  const other = created(kv, newDbPassword(), 'w-other');
  await assert.rejects(other.all(), (e) => e.code === 'mismatch');
  assert.equal(JSON.stringify(kv.m.get(BRIDGE_RECORD_KEY)), before);
  // An imported wallet's store under HKDF would be one guessed password away.
  await assert.rejects(new SealedBridgeStore({ kv, walletId: 'w-created', imported: true, dbPass: 'a chosen password' }).all(), (e) => e.code === 'weak');
  assert.throws(() => new SealedBridgeStore({ kv, walletId: 'w', imported: false, dbPass: '' }), (e) => e.code === 'locked');
  assert.throws(() => bridgeStoreFor({ record: { id: 'w' }, dbPass: null }, kv), (e) => e.code === 'locked');
});

test('sealed store: a tampered header is refused; a tampered or newer record is kept as it was, never dropped', async () => {
  const kv = memoryKv();
  const dbPass = newDbPassword();
  await created(kv, dbPass).save(full());
  await created(kv, dbPass).save(full({ id: 'x2', msgId: 111 }));
  // A header field changed: the check value no longer opens.
  const env = kv.m.get(BRIDGE_RECORD_KEY);
  kv.m.set(BRIDGE_RECORD_KEY, { ...env, salt: Buffer.alloc(16, 7).toString('base64') });
  await assert.rejects(created(kv, dbPass).all(), (e) => e.code === 'wrong_secret');
  kv.m.set(BRIDGE_RECORD_KEY, env);
  // One record's ciphertext changed by one bit.
  const damaged = structuredClone(env);
  const ct = Buffer.from(damaged.records[0].ct, 'base64');
  ct[ct.length - 1] ^= 1;
  damaged.records[0].ct = ct.toString('base64');
  kv.m.set(BRIDGE_RECORD_KEY, damaged);
  const store = created(kv, dbPass);
  const left = await store.all();
  assert.equal(left.length, 1, 'the damaged record is not read');
  assert.equal(store.unreadableCount, 1);
  await store.save(changeCrossing(left[0], { state: STATES.claimed }));
  const written = kv.m.get(BRIDGE_RECORD_KEY);
  assert.equal(written.records.length, 2, 'and it is written back');
  assert.ok(written.records.some((r) => r.ct === damaged.records[0].ct));
});

test('sealed store: one message id per route and direction; the same crossing again is fine', async () => {
  for (const store of [created(memoryKv()), new MemoryBridgeStore()]) {
    const make = (id, direction) => full({ id, route: 'eth', direction, state: STATES.locked, msgId: 7 });
    await store.save(make('a', 'toBeam'));
    await store.save(make('a', 'toBeam'));
    await store.save(make('c', 'toEthereum'));
    await assert.rejects(store.save(make('b', 'toBeam')), (e) => e instanceof BridgeStoreError && e.code === 'conflict');
    assert.deepEqual((await store.all()).map((c) => c.id).sort(), ['a', 'c']);
  }
});

test('sealed store: an imported wallet derives with PBKDF2 (>= 600,000 rounds); writes are queued in order', async () => {
  const kv = memoryKv();
  const app = { record: { id: 'w-imported', imported: true }, dbPass: 'the wallet.db password' };
  const store = bridgeStoreFor(app, kv);
  await Promise.all([store.save(full({ id: 'a', msgId: 1 })), store.save(full({ id: 'b', msgId: 2 })), store.save(full({ id: 'a', msgId: 1, state: STATES.claimed }))]);
  const env = kv.m.get(BRIDGE_RECORD_KEY);
  assert.equal(env.kdf, KDF_PBKDF2);
  assert.equal(env.iterations, PBKDF2_MIN_ITERATIONS);
  const again = bridgeStoreFor(app, kv);
  assert.equal((await again.byId('a')).state, STATES.claimed);
  assert.equal((await again.all()).length, 2);
  // A lowered round count does not open (it is bound into every envelope).
  kv.m.set(BRIDGE_RECORD_KEY, { ...env, iterations: 1000 });
  await assert.rejects(bridgeStoreFor(app, kv).all(), (e) => e.code === 'weak');
});

test('a failed write leaves the store as it was', async () => {
  const kv = memoryKv();
  const dbPass = newDbPassword();
  const store = created(kv, dbPass);
  await store.save(full());
  const set = kv.set;
  kv.set = async () => {
    throw new Error('quota');
  };
  await assert.rejects(store.save(full({ id: 'x2', msgId: 2 })), /quota/);
  assert.deepEqual((await store.all()).map((c) => c.id), ['x1']);
  kv.set = set;
  await store.save(full({ id: 'x3', msgId: 3 }));
  assert.deepEqual((await created(kv, dbPass).all()).map((c) => c.id).sort(), ['x1', 'x3']);
});

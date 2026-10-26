// Installing a dApp from BEAM's DApp Store (lib/dapps/store_install.js), with the store's real
// "Test N1" package (QmY2xgq8…, ABRAKADABRA) and its real store entry.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { buildStore } from '../../src/lib/dapps/store.js';
import { installedStore } from '../../src/lib/dapps/installed.js';
import { installFromStore, fetchStorePackage, storeState, checkAgainstEntry, storeInstallErrorText, mirrorPath, StoreInstallError } from '../../src/lib/dapps/store_install.js';
import { readFilePackage } from '../../src/lib/dapps/file_package.js';

const fx = JSON.parse(readFileSync(new URL('../fixtures/dapps_store_views.json', import.meta.url), 'utf8'));
const store = buildStore(fx.view_publishers, fx.view_dapps);
const BYTES = new Uint8Array(readFileSync(new URL('../fixtures/store-test-n1.dapp', import.meta.url)));
const dapp = store.dapps.find((d) => d.cid === 'QmY2xgq85jf6AywaKXTxowiH5GJbN3bHgoGuUtmcEKoC2z');
const publisher = store.publishers.get(dapp.publisher);

function memoryKv() {
  const m = new Map();
  return { m, get: async (k) => (m.has(k) ? structuredClone(m.get(k)) : undefined), batch: async (ops) => { for (const [op, k, v] of ops) op === 'del' ? m.delete(k) : m.set(k, structuredClone(v)); } };
}
const serve = (bytes, status = 200) => {
  const asked = [];
  const f = async (url) => (asked.push(url), { ok: status === 200, status, headers: new Map([['content-length', String(bytes.length)]]), arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length) });
  f.asked = asked;
  return f;
};

test('the entry: Test N1 by ABRAKADABRA, from the copy next to the app', () => {
  assert.equal(dapp.name, 'Test N1');
  assert.equal(publisher.name, 'ABRAKADABRA');
  assert.equal(mirrorPath(dapp.cid), 'dapp-store/QmY2xgq85jf6AywaKXTxowiH5GJbN3bHgoGuUtmcEKoC2z.dapp', 'a path of this app, so no new party sees the IP address');
});

test('install: fetched, its IPFS hash checked, its manifest checked against the entry, kept with where it came from', async () => {
  const installed = installedStore(memoryKv());
  const f = serve(BYTES);
  const rec = await installFromStore(dapp, publisher, { installed, fetchImpl: f });
  assert.deepEqual(f.asked, [mirrorPath(dapp.cid)]);
  assert.equal(rec.guid, dapp.id);
  assert.deepEqual(rec.store, { publisher: dapp.publisher, publisherName: 'ABRAKADABRA', cid: dapp.cid, version: [1, 0, 1, 0] });
  assert.deepEqual(storeState(dapp, await installed.get(dapp.id)).action, 'open');
  // Installed again: nothing fetched, it is open.
  const f2 = serve(BYTES);
  await installFromStore(dapp, publisher, { installed, fetchImpl: f2 });
  assert.equal(f2.asked.length, 0);
});

test('refused: a copy that is not the listed file, a missing copy, a package that is not this entry', async () => {
  const changed = BYTES.slice();
  changed[200] ^= 1;
  await assert.rejects(fetchStorePackage(dapp, { fetchImpl: serve(changed) }), (e) => e instanceof StoreInstallError && e.code === 'hashMismatch');
  await assert.rejects(fetchStorePackage(dapp, { fetchImpl: serve(BYTES, 404) }), (e) => e.code === 'notMirrored');
  assert.match(storeInstallErrorText(new StoreInstallError('notMirrored', ''), 'Test N1'), /isn't in Beam PWA's copy of the store yet\. Ask its publisher for the \.dapp file/);
  const pkg = await readFilePackage(BYTES);
  checkAgainstEntry(pkg, dapp);
  assert.throws(() => checkAgainstEntry(pkg, { ...dapp, name: 'Beam DEX' }), (e) => e.code === 'notThisEntry' && /its name/.test(e.message));
  assert.throws(() => checkAgainstEntry(pkg, { ...dapp, version: [1, 0, 2, 0] }), (e) => /its version/.test(e.message));
  assert.throws(() => checkAgainstEntry(pkg, { ...dapp, id: '33'.repeat(16) }), (e) => /its id/.test(e.message));
  // The other "Test N1" in the store (another publisher, another package) is not this one.
  const other = store.dapps.find((d) => d.name === 'Test N1' && d.cid !== dapp.cid && d.id === dapp.id);
  if (other) assert.notEqual(other.publisher, dapp.publisher);
});

test('the same id: from another publisher or from a file is a different app; only the same publisher updates it', async () => {
  const installed = installedStore(memoryKv());
  await installFromStore(dapp, publisher, { installed, fetchImpl: serve(BYTES) });
  const rec = await installed.get(dapp.id);
  const otherKey = `02${'ab'.repeat(32)}`;
  assert.deepEqual(storeState({ ...dapp, publisher: otherKey }, rec).code, 'otherPublisher');
  await assert.rejects(installFromStore({ ...dapp, publisher: otherKey, version: [9, 0, 0, 0] }, null, { installed, fetchImpl: serve(BYTES) }), (e) => e.code === 'otherPublisher');
  assert.equal(storeState({ ...dapp, version: [1, 0, 2, 0] }, rec).action, 'update');
  assert.equal(storeState({ ...dapp, version: [1, 0, 0, 9] }, rec).action, 'open', 'never an older version');
  assert.deepEqual(storeState(dapp, { ...rec, store: null }).code, 'fromFile');
  assert.match(storeInstallErrorText(new StoreInstallError('otherPublisher', ''), 'Test N1'), /different app/);
});

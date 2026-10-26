// What a dApp may submit through process_invoke_data and sign through sign_message.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { decodeInvokeData, InvokeDataError, FLAG_DEPENDENT, FLAG_SAVE_APP_INVOKE, FLAG_SAVE_SPEND_MAX } from '../../src/lib/dapps/invoke_data.js';
import { checkContractData, PolicyRefusal, RESERVED_KEYS, KNOWN_CONTRACTS, BANS_CID, VAULT_ANON_CID, AIRDROP_CID, AIRDROP_V3_CID, keyHashOf, reservedUseOfKeyMaterial } from '../../src/lib/dapps/policy.js';
import { DappSession } from '../../src/lib/dapps/session.js';
import { readContractTx } from '../../src/lib/contract_tx.js';
import { invokeData, invokeEntry, cid } from './helpers/invoke_builder.mjs';

const pwa = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const DEX = '729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae69b47bcfdeef9cbf';
const refused = (reason) => (e) => e instanceof PolicyRefusal && e.reason === reason;
const someKey = 'ab'.repeat(32);
const swapFixture = join(pwa, '..', 'test', 'beam', 'dapps', 'fixtures', 'dex_dapp_swap_raw_data.json');
const shadersDir = join(pwa, '..', 'assets', 'beam', 'shaders');

test("the Beam DEX dApp's own swap (recorded on mainnet) decodes and is allowed", (t) => {
  const f = join(pwa, '..', 'test', 'beam', 'dapps', 'fixtures', 'dex_dapp_swap_raw_data.json');
  if (!existsSync(f)) return t.skip('desktop fixtures not next to the PWA');
  const raw = Buffer.from(JSON.parse(readFileSync(f, 'utf8')).result.raw_data_base64, 'base64');
  const d = checkContractData(new Uint8Array(raw));
  assert.equal(d.entries.length, 1);
  const e = d.entries[0];
  assert.equal(e.contractId, DEX);
  assert.equal(e.comment, 'Amm trade');
  assert.ok(e.flags & FLAG_DEPENDENT);
  assert.ok(e.flags & FLAG_SAVE_APP_INVOKE);
  assert.equal(d.appPrivilege, 0);
  assert.equal(e.signatureKeyHashes.length, 0);
});

test('a plain call to an unknown contract is allowed; the decoded funds are as built', () => {
  const d = checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xa1), spend: { 0: 100000000, 174: -5 }, comment: 'x' })])));
  assert.equal(d.entries[0].spend.get(0), 100000000n);
  assert.equal(d.entries[0].spend.get(174), -5n);
});

test('privilege above 0 is refused', () => {
  const raw = invokeData([invokeEntry({ contractId: cid(0xa1), flags: FLAG_SAVE_APP_INVOKE })], { firstFlags: FLAG_SAVE_APP_INVOKE, privilege: 1 });
  assert.throws(() => checkContractData(new Uint8Array(raw)), refused('privileged'));
  const ok = invokeData([invokeEntry({ contractId: cid(0xa1), flags: FLAG_SAVE_APP_INVOKE })], { firstFlags: FLAG_SAVE_APP_INVOKE, privilege: 0 });
  checkContractData(new Uint8Array(ok));
});

test('calls to BEAM names or their vault are refused, also as the second call', () => {
  for (const c of [BANS_CID, VAULT_ANON_CID]) {
    assert.throws(() => checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: c })]))), refused('forbidden_contract'));
    assert.throws(() => checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xa1) }), invokeEntry({ contractId: c })]))), refused('forbidden_contract'));
  }
});

test('a call signed with a key Beam PWA uses is refused', () => {
  for (const k of Object.keys(RESERVED_KEYS)) {
    assert.throws(() => checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xa1), sigs: [someKey, k] })]))), refused('reserved_key'));
  }
  checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xa1), sigs: [someKey] })])));
});

test('data that cannot be read in full is refused: trailing bytes, truncation, unknown or advanced flags', () => {
  const good = invokeData([invokeEntry({ contractId: cid(0xa1) })]);
  assert.throws(() => checkContractData(new Uint8Array([...good, 0])), refused('unreadable'));
  assert.throws(() => checkContractData(new Uint8Array(good.slice(0, -3))), refused('unreadable'));
  assert.throws(() => checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xa1), flags: 0x01 })]))), refused('unreadable'));
  assert.throws(() => checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xa1), flags: 0x80 })]))), refused('unreadable'));
  assert.throws(() => decodeInvokeData(new Uint8Array([0x85])), InvokeDataError);
});

test('the reserved key hashes are SHA-256("bvm.m.key\\0" || id) of the BANS, airdrop and owner ids', async () => {
  const h = (id) => createHash('sha256').update(Buffer.concat([Buffer.from('bvm.m.key'), Buffer.from([0]), Buffer.from(id)])).digest('hex');
  const expect = {
    [h(Buffer.from(BANS_CID, 'hex'))]: 'your BEAM names',
    [h(Buffer.concat([Buffer.from(AIRDROP_CID, 'hex'), Buffer.from([0])]))]: 'your airdrops',
    [h(Buffer.from([0xad, 42]))]: 'the airdrop contract',
    // Airdrop v3's CreatorID{cid, 0} (app.cpp): the key that takes back this wallet's v3 batches.
    [h(Buffer.concat([Buffer.from(AIRDROP_V3_CID, 'hex'), Buffer.from([0])]))]: 'your airdrops',
  };
  assert.equal(KNOWN_CONTRACTS[AIRDROP_V3_CID], 'Beam PWA airdrops');
  assert.equal(await reservedUseOfKeyMaterial(`${AIRDROP_V3_CID}00`), 'your airdrops');
  assert.deepEqual({ ...RESERVED_KEYS }, expect);
  assert.equal(await keyHashOf(BANS_CID), h(Buffer.from(BANS_CID, 'hex')));
  assert.equal(await reservedUseOfKeyMaterial(BANS_CID), 'your BEAM names');
  assert.equal(await reservedUseOfKeyMaterial('ad2a'), 'the airdrop contract');
  assert.equal(await reservedUseOfKeyMaterial('00'), null);
});

// The approve sheet shows what the engine reports, get_FullSpend: the entries' own spend. A stored
// spend ceiling (SaveSpendMax, m_SpendMax) is not in it, yet it is what the core lets a rebuilt
// variant of a dependent call spend later, without asking again (contract_transaction.cpp:497-520,
// 534-536, 610-713). The auditor's shape: 0.00000001 BEAM shown, 1,000 BEAM allowed.
test('a stored spend ceiling is refused: the sheet would show the call, not the ceiling', () => {
  const flags = FLAG_DEPENDENT | FLAG_SAVE_APP_INVOKE | FLAG_SAVE_SPEND_MAX;
  const raw = Uint8Array.from(invokeData([invokeEntry({ contractId: cid(0xee), flags, spend: { 0: 1 }, comment: 'claim your reward' })], { firstFlags: FLAG_SAVE_APP_INVOKE | FLAG_SAVE_SPEND_MAX, privilege: 0, spendMax: { 0: 100000000000 } }));
  assert.deepEqual([...readContractTx(raw).pays], [[0, 1n]], 'what the sheet would show');
  assert.equal(decodeInvokeData(raw).spendMax.get(0), 100000000000n, 'what a rebuild could spend');
  assert.throws(() => checkContractData(raw), refused('spend_ceiling'));
  // Not even one equal to what is shown: no BEAM shader sets a ceiling (no Env::SetMaxSpend in
  // bvm/Shaders), so a dApp asking for one is asking for something the sheet cannot show.
  const equal = invokeData([invokeEntry({ contractId: cid(0xee), flags, spend: { 0: 1 } })], { firstFlags: FLAG_SAVE_APP_INVOKE | FLAG_SAVE_SPEND_MAX, spendMax: { 0: 1 } });
  assert.throws(() => checkContractData(new Uint8Array(equal)), refused('spend_ceiling'));
  // Without a stored app body or dependence, too: the flag alone asks for a ceiling.
  const plain = invokeData([invokeEntry({ contractId: cid(0xee), flags: FLAG_SAVE_SPEND_MAX, spend: { 0: 1 } })], { firstFlags: FLAG_SAVE_SPEND_MAX, spendMax: { 0: 5 } });
  assert.throws(() => checkContractData(new Uint8Array(plain)), refused('spend_ceiling'));
});

test('session: a spend ceiling never reaches the wallet; the recorded mainnet DEX swap does', async (t) => {
  const calls = [];
  const refusedWhy = [];
  const app = { async call(method, params) { calls.push({ method, params }); return { txid: '0'.repeat(32) }; } };
  const s = new DappSession({ appName: 'Beam DEX', app, confirmSign: async () => true, onRefused: (w) => refusedWhy.push(w) });
  const flags = FLAG_DEPENDENT | FLAG_SAVE_APP_INVOKE | FLAG_SAVE_SPEND_MAX;
  const bad = invokeData([invokeEntry({ contractId: cid(0xee), flags, spend: { 0: 1 } })], { firstFlags: FLAG_SAVE_APP_INVOKE | FLAG_SAVE_SPEND_MAX });
  const r1 = JSON.parse(await s.handle(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'process_invoke_data', params: { data: bad, confirm_comment: 'Claim 5 FOMO' } })));
  assert.equal(r1.error.code, -32020);
  assert.match(r1.error.data, /more/);
  assert.equal(calls.length, 0);
  assert.equal(refusedWhy.length, 1);
  if (!existsSync(swapFixture)) return t.skip('desktop fixtures not next to the PWA');
  // BEAM's DEX builds every trade as a dependent call with its app body stored and no ceiling:
  // a rebuild is held to the core's implicit 1% over what was approved (m_SpendInitial).
  const raw = Buffer.from(JSON.parse(readFileSync(swapFixture, 'utf8')).result.raw_data_base64, 'base64');
  const d = decodeInvokeData(new Uint8Array(raw));
  assert.equal(d.spendMax, null);
  assert.equal(d.entries[0].flags & FLAG_SAVE_SPEND_MAX, 0);
  const r2 = JSON.parse(await s.handle(JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'process_invoke_data', params: { data: [...raw] } })));
  assert.equal(r2.result.txid, '0'.repeat(32));
  assert.equal(calls.length, 1);
});

// The wallet's own contract calls (Swap, pools, names, airdrops, tokens, burn, bridge) run only
// these pinned shaders. The core stores a ceiling only when the app shader set one with
// Env::SetMaxSpend (shaders_manager.cpp:189-193, bvm2.cpp set_MaxSpend), so none of them can.
test("none of the wallet's own shaders can set a spend ceiling (no SetMaxSpend import)", async (t) => {
  if (!existsSync(shadersDir)) return t.skip('shaders not next to the PWA');
  const { SHADERS } = await import('../../src/lib/shaders.js');
  for (const s of Object.values(SHADERS)) {
    const bytes = readFileSync(join(shadersDir, s.file));
    assert.equal(createHash('sha256').update(bytes).digest('hex'), s.sha256, s.file);
    const imports = WebAssembly.Module.imports(await WebAssembly.compile(bytes)).map((i) => i.name);
    assert.ok(imports.length > 0, s.file);
    assert.deepEqual(imports.filter((n) => /MaxSpend/i.test(n)), [], s.file);
  }
});

// Without confirm_comment the sheet shows the entries' own comments (get_FullComment), which the
// dApp writes into its contract data.
test("a call whose own comment hides characters is refused; a plain one is not", () => {
  for (const c of ['Claim\u202e 5 FOMO', 'a\u200bb', 'a\u0007b']) {
    assert.throws(() => checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xa1), comment: c })]))), refused('hidden_text'), JSON.stringify(c));
    assert.throws(() => checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xa1), comment: 'ok' }), invokeEntry({ contractId: cid(0xa2), comment: c })]))), refused('hidden_text'));
  }
  checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xa1), comment: 'Amm trade' })])));
});

// What a built contract transaction costs and moves (lib/contract_tx.js over
// lib/dapps/invoke_data.js), on real mainnet recordings (built with
// create_tx:false, never sent), and the core's fee rules.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readContractTx as decodeInvokeData, ArgsReader, entryFee, le, fromHex, concat, bytesEqual, singleEntry, spendText, InvokeDataError } from '../../src/lib/contract_tx.js';
import { FLAG_ADVANCED, FLAG_DEPENDENT } from '../../src/lib/dapps/invoke_data.js';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const raw = (dir, name) => JSON.parse(readFileSync(join(REPO, 'test', 'beam', 'contracts', dir, 'fixtures', `${name}.json`), 'utf8')).result.raw_data;
const FAKE_KEY = '5a'.repeat(32) + '00';
const BANS = 'af4550f1f8a6051ffeffea06e0cb978f8076fdfc2101d2273d4e62c86540bc5e';
const VAULT = 'a3385e50cf33afc9f769ee1d82d56b73046d680d343977f36d9a303d7bcdc4da';

// yas compacted unsigned / signed, as raw_data carries them.
const u = (v) => {
  let x = BigInt(v);
  if (x < 128n) return [0x80 | Number(x)];
  const b = [];
  while (x > 0n) {
    b.push(Number(x & 0xffn));
    x >>= 8n;
  }
  return [b.length, ...b];
};
const s = (v) => {
  const neg = v < 0;
  let a = BigInt(Math.abs(Number(v)));
  if (typeof v === 'bigint') a = v < 0n ? -v : v;
  if (a < 64n) return [(neg ? 0x80 : 0) | 0x40 | Number(a)];
  const b = [];
  while (a > 0n) {
    b.push(Number(a & 0xffn));
    a >>= 8n;
  }
  return [(neg ? 0x80 : 0) | b.length, ...b];
};
const blob = (b) => [...u(b.length), ...b];
const entry = ({ method = 7, args = [1, 2, 3], charge = 80150, comment = 'c', spend = { 0: 1000 }, cid = Array(32).fill(0xab) } = {}) => [
  ...u(method),
  ...blob(args),
  ...u(0),
  ...u(charge),
  ...blob([...comment].map((c) => c.charCodeAt(0))),
  ...u(Object.keys(spend).length),
  ...Object.entries(spend).flatMap(([k, v]) => [...u(Number(k)), ...s(v)]),
  ...cid,
];

test('register, 13-char name, 1 period (recorded)', () => {
  const d = decodeInvokeData(raw('bans', 'register5'));
  assert.equal(d.entries.length, 1);
  const e = d.entries[0];
  assert.equal(e.flags, 0);
  assert.equal(e.method, 7);
  assert.equal(e.contractId, BANS);
  assert.equal(e.charge, 80150);
  assert.equal(e.comment, 'BANS: registering domain');
  assert.equal(e.signatureCount, 0);
  assert.deepEqual([...e.spend], [[0, 116213166091n]]);
  const r = new ArgsReader(e.args);
  assert.equal(r.pubKey(), FAKE_KEY);
  assert.equal(r.u8(), 1);
  assert.equal(String.fromCharCode(...r.bytes(r.u8())), 'cfbac2de77099');
  assert.ok(r.atEnd);
  assert.equal(d.fee, 1100000n);
});

test('register, 4-char name, 2 periods; kernel price = floor(usd * 1e8 * n / median) at 0.008604877', () => {
  const d = decodeInvokeData(raw('bans', 'register4'));
  assert.equal(d.spend.get(0), 2789115986201n);
  const r = new ArgsReader(d.entries[0].args);
  r.pubKey();
  assert.equal(r.u8(), 2);
  assert.equal(String.fromCharCode(...r.bytes(r.u8())), 'cf70');
  const price = (usd, n) => (BigInt(usd) * BigInt(n) * 10n ** 8n * 10n ** 9n) / 8604877n;
  assert.equal(decodeInvokeData(raw('bans', 'register5')).spend.get(0), price(10, 1));
  assert.equal(d.spend.get(0), price(120, 2));
});

test('a name payment goes to the Anon-Vault, not the BANS contract (recorded)', () => {
  const d = decodeInvokeData(raw('bans', 'pay_beam'));
  const e = d.entries[0];
  assert.equal(e.contractId, VAULT);
  assert.equal(e.method, 2);
  assert.equal(e.charge, 0);
  assert.equal(e.comment, 'vault_anon send anon');
  assert.deepEqual([...e.spend], [[0, 12345n]]);
  const r = new ArgsReader(e.args);
  assert.equal(r.u64(), 12345n);
  assert.equal(r.u32(), 97);
  assert.notEqual(r.pubKey(), '72e368c016bec94e0aa0274aae5b6e9ef4bbb64d0ce1436acb134488570d51ef01');
  assert.equal(r.u32(), 0);
  assert.equal(r.remaining, 97);
  assert.equal(d.fee, 1100000n, 'charge 0 still pays the BVM minimum');
});

test('an airdrop batch of 2 x 0.001 BEAM (recorded): 0.121 BEAM network fee', () => {
  const d = decodeInvokeData(raw('airdrop', 'create_batch_2x0.001'));
  const e = d.entries[0];
  assert.equal(e.contractId, '8737e0d39575d7015fdea259fa091e41fc293e6c3d54e80d529033c349b5b18e');
  assert.equal(e.method, 2);
  assert.equal(e.charge, 1200000);
  assert.equal(e.comment, 'Create airdrop batch');
  assert.equal(e.signatureCount, 1);
  assert.equal(e.args.length, 41 + 2 * 40);
  assert.deepEqual([...e.args.subarray(0, 33)], [...Array(32).fill(0x5a), 0]);
  assert.deepEqual([...e.args.subarray(33, 41)], [0, 0, 0, 0, 2, 0, 0, 0]);
  assert.equal(d.spend.get(0), 202000n);
  assert.equal(d.pays.get(0), 202000n);
  assert.equal(d.receives.size, 0);
  assert.equal(d.fee, 12100000n);
});

test('multi-byte and negative compacted integers; several entries add up', () => {
  const e = decodeInvokeData([...u(1), ...entry({ charge: 0x123456, spend: { 0: -150000000, 174: 63, 3: -64 } })]).entries[0];
  assert.equal(e.charge, 0x123456);
  assert.deepEqual(Object.fromEntries(e.spend), { 0: -150000000n, 174: 63n, 3: -64n });
  const d = decodeInvokeData([...u(2), ...entry({ spend: { 0: 500 } }), ...entry({ spend: { 0: 700, 7: 9 } })]);
  assert.deepEqual(Object.fromEntries(d.spend), { 0: 1200n, 7: 9n });
  assert.equal(d.fee, 2n * 1100000n);
});

test('fee rules: a BEAM change output, big charges, extra argument bytes', () => {
  const one = (bytes) => decodeInvokeData([...u(1), ...bytes]).entries[0].fee;
  assert.equal(one(entry({ spend: { 7: 5 } })), 100000n + 1000000n);
  assert.equal(one(entry({ charge: 300000 })), 100000n + 3000000n);
  assert.equal(one(entry({ args: Array(40000).fill(1) })), BigInt(18000 + 10000 + 7232 * 50 + 1000000));
  assert.equal(entryFee({ argsBytes: 0, spendAssets: [0], charge: 1200000 }), 12100000n);
  assert.equal(entryFee({ argsBytes: 0, spendAssets: [0], charge: 1800000 }), 18100000n);
});

test('an advanced entry is refused: its fee and heights are not this wallet\'s to wave through', () => {
  const bytes = [
    ...u(1),
    ...u(0x80000000 + FLAG_ADVANCED),
    ...u(3),
    ...blob([9]),
    ...u(0),
    ...u(0),
    ...blob([...'vault_anon receive'].map((c) => c.charCodeAt(0))),
    ...u(1),
    ...u(0),
    ...s(-480000000000n),
    ...Array(32).fill(0xa3),
    ...u(4068103),
    ...u(15),
    ...u(1100000),
    ...Array(65).fill(1),
    ...Array(32).fill(2),
  ];
  assert.throws(() => decodeInvokeData(bytes), InvokeDataError);
});

test('a dependent call is read and marked; received funds come out positive', () => {
  const dep = [...u(0x80000000 + FLAG_DEPENDENT), ...entry({ spend: { 0: -250000 } }), ...u(4068100), ...Array(32).fill(0x5c)];
  const d = decodeInvokeData([...u(1), ...dep]);
  assert.equal(d.entries[0].isDependent, true);
  assert.equal(d.entries[0].parentHeight, 4068100n);
  assert.deepEqual([...d.receives], [[0, 250000n]]);
  assert.equal(d.pays.size, 0);
});

test('the helpers: one call of one contract and method, bytes built and compared', () => {
  const d = decodeInvokeData([...u(1), ...entry({ method: 4 })]);
  const fail = (what) => {
    throw new Error(`expected ${what}`);
  };
  assert.equal(singleEntry(d, 'ab'.repeat(32), 4, fail), d.entries[0]);
  assert.throws(() => singleEntry(d, 'cd'.repeat(32), 4, fail), /expected contract/);
  assert.throws(() => singleEntry(d, 'ab'.repeat(32), 7, fail), /expected method 7/);
  assert.throws(() => singleEntry(decodeInvokeData([...u(2), ...entry(), ...entry()]), 'ab'.repeat(32), 7, fail), /one contract call/);
  assert.ok(bytesEqual(concat(fromHex('0a0b'), le(258, 2)), Uint8Array.from([10, 11, 2, 1])));
  assert.equal(bytesEqual(Uint8Array.from([1]), Uint8Array.from([1, 2])), false);
  assert.equal(spendText(d.spend), '{"0":"1000"}');
  assert.throws(() => fromHex('abc'), InvokeDataError);
});

test('trailing, truncated and absurd data are refused', () => {
  const good = [...u(1), ...entry()];
  assert.throws(() => decodeInvokeData([...good, 0]), InvokeDataError);
  assert.throws(() => decodeInvokeData(good.slice(0, -1)), InvokeDataError);
  assert.throws(() => decodeInvokeData([]), InvokeDataError);
  assert.throws(() => decodeInvokeData([...u(1), ...u(7), 8, 0xff, 0xff, 0xff]), InvokeDataError);
  assert.throws(() => decodeInvokeData([9, ...Array(9).fill(1)]), InvokeDataError);
  assert.throws(() => decodeInvokeData([...u(1), ...u(0x80000000 + 0x08), ...u(7)]), InvokeDataError, 'multisig');
  assert.throws(() => decodeInvokeData([...u(1), ...u(0x80000000 + 0x100), ...u(7)]), InvokeDataError, 'unknown flag');
  assert.throws(() => decodeInvokeData([...u(1), ...entry()].map((b, i) => (i === 3 ? 256 : b))), InvokeDataError, 'a value that is not a byte');
  assert.throws(() => new ArgsReader(new Uint8Array(3)).u32(), InvokeDataError);
  assert.throws(() => le(256, 1), InvokeDataError);
  assert.throws(() => le(-1, 4), InvokeDataError);
});

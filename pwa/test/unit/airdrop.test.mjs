// Airdrops: codes exactly as the shader normalises and hashes them, the 1% fee
// bit for bit, argument builders, answer parsing, the checks on every built
// transaction, one transaction at a time, and saved codes that are never lost.
// Vectors from the desktop's tests (test/beam/contracts/airdrop).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  AIRDROP_CID, DEAD_CIDS, GAS_SUPPORTED, CALL_FEE, CANCEL_FEE, CODE_ALPHABET, METHOD, CHARGE, KERNEL, MAX_TOTAL, args, generateCode, normaliseCode, formatCode,
  isWellFormedCode, codeHash, creationFee, voucherBlob, decodeVoucherBlob, parseVoucherInfo, parseBatches, parseBatchVouchers, codeFor, mapError,
  readSavedBatch, codeVault, createAirdrop, TX_STATUS, CODE_STATUS, batchTotal,
} from '../../src/lib/airdrop.js';
import { parseShaderJson, bindSession, unbindSession, nativeApp, setConsentPresenter } from '../../src/lib/contracts.js';
import { fakeEngine } from './helpers/fake_engine.mjs';
import { readContractTx, toHex, fromHex, le, concat } from '../../src/lib/contract_tx.js';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const fixture = (name) => JSON.parse(readFileSync(join(REPO, 'test', 'beam', 'contracts', 'airdrop', 'fixtures', `${name}.json`), 'utf8'));
const FAKE_KEY = '5a'.repeat(32) + '00';
const OTHER_KEY = '5b'.repeat(32) + '00';
const TXID = 'cd'.repeat(16);

test('the live contract, never the dead v3 one; no gasless claims; fees from the declared charges', () => {
  assert.ok(AIRDROP_CID.startsWith('8737e0d3'));
  assert.ok([...DEAD_CIDS][0].startsWith('00c0dc81'));
  assert.equal(GAS_SUPPORTED, false);
  assert.equal(CALL_FEE, 12100000n);
  assert.equal(CANCEL_FEE, 18100000n);
});

test('codes: 16 symbols of a 32-symbol alphabet without I, O, 0 or 1, grouped by 4', () => {
  assert.equal(CODE_ALPHABET.length, 32);
  for (const ch of 'IO01') assert.ok(!CODE_ALPHABET.includes(ch));
  for (let i = 0; i < 300; i++) {
    const c = generateCode();
    assert.match(c, /^([A-HJ-NP-Z2-9]{4}-){3}[A-HJ-NP-Z2-9]{4}$/);
    assert.ok(isWellFormedCode(c));
  }
  // Each byte maps to alphabet[byte % 32]: 0→A 1→B 31→9 32→A 33→B 255→9 224→A 8→J.
  const bytes = [0, 1, 31, 32, 33, 255, 224, 8];
  assert.equal(generateCode((n) => Uint8Array.from({ length: n }, (_, i) => bytes[i % bytes.length])), 'AB9A-B9AJ-AB9A-B9AJ');
  const seen = new Set();
  for (let i = 0; i < 2000; i++) seen.add(generateCode());
  assert.equal(seen.size, 2000);
});

test('normalise exactly as the app shader does', () => {
  assert.equal(normaliseCode('abcd-efgh jklm_npqr'), 'ABCDEFGHJKLMNPQR');
  assert.equal(normaliseCode('  a.b,c  '), 'ABC');
  assert.equal(normaliseCode('---'), '');
  assert.equal(normaliseCode('io01'), 'IO01', 'look-alikes are kept, not mapped');
  assert.equal(normaliseCode('aßb'), 'AB', 'non-ASCII letters are dropped, not upper-cased');
  assert.equal(normaliseCode('ÄÖÜ'), '');
  assert.equal(normaliseCode('a'.repeat(100)), 'A'.repeat(64));
  assert.equal(formatCode('abcdef'), 'ABCD-EF');
  assert.equal(formatCode('abcd-efgh-jklm-npqr'), 'ABCD-EFGH-JKLM-NPQR');
  assert.equal(formatCode(''), '');
  assert.ok(isWellFormedCode('abcd-efgh-jklm-npqr'));
  assert.ok(!isWellFormedCode('abcd-efgh-jklm-npq'));
  assert.ok(!isWellFormedCode('abcd-efgh-jklm-npq0'));
});

test('a code\'s hash is SHA-256 of the normalised ASCII code', async () => {
  const want = '7cf629bb82226bfb6356859edb341b8f36a74d8997c4fe385dbef6dc85c5c4bb';
  assert.equal(await codeHash('ABCDEFGHJKLMNPQR'), want);
  assert.equal(await codeHash('abcd-efgh-jklm-npqr'), want);
  assert.equal(await codeHash(' Abcd efgh\tJKLM-npqr '), want);
  assert.equal(await codeHash('z-9'), '43f02fcda5eca7b6d0d9c9b1fe1b75dfb5fca6b667b8fc5be65efb1804ba93c6');
  await assert.rejects(codeHash('---'), (e) => e.code === 'invalidCode');
});

test('the 1% creation fee matches the C++ statements bit for bit (wrap-around included)', () => {
  for (const [total, fee] of fixture('fee_vectors').vectors) assert.equal(creationFee(BigInt(total)), BigInt(fee), total);
  assert.equal(creationFee(200000n), 2000n);
  assert.equal(creationFee(1n), 1n, 'never below 1 groth');
  assert.equal(creationFee(0n), 0n);
  assert.equal(MAX_TOTAL, ((1n << 64n) - 1n) / 100n);
  assert.throws(() => creationFee(-1n), RangeError);
  assert.throws(() => creationFee(1n << 64n), RangeError);
});

test('the voucher blob: 32-byte hash then 8-byte little-endian value; refusals', () => {
  const e = [{ hash: '11'.repeat(32), value: 100000n }, { hash: '22'.repeat(32), value: 100000n }];
  assert.equal(toHex(voucherBlob(e)), `${'11'.repeat(32)}a086010000000000${'22'.repeat(32)}a086010000000000`);
  assert.deepEqual(decodeVoucherBlob(voucherBlob(e)), e);
  assert.throws(() => voucherBlob([]), RangeError);
  assert.throws(() => voucherBlob(Array.from({ length: 101 }, (_, i) => ({ hash: i.toString(16).padStart(64, '0'), value: 1n }))), RangeError);
  assert.throws(() => voucherBlob([e[0], e[0]]), RangeError, 'repeated voucher');
  assert.throws(() => voucherBlob([{ hash: '11'.repeat(32), value: MAX_TOTAL + 1n }]), RangeError, 'fee overflow');
  assert.throws(() => voucherBlob([{ hash: '11'.repeat(32), value: 0n }]), RangeError);
  assert.throws(() => voucherBlob([{ hash: 'AB'.repeat(32), value: 1n }]), RangeError);
  assert.throws(() => voucherBlob([{ hash: 'ab'.repeat(31), value: 1n }]), RangeError);
});

test('arguments: roles, the normalised code as the preimage, the dead contract refused', () => {
  const cid = AIRDROP_CID;
  assert.equal(args.viewMyBatches(), `role=user,action=view_my_batches,cid=${cid}`);
  assert.equal(args.getMyKey(), `role=user,action=get_my_key,cid=${cid}`);
  assert.equal(args.checkVoucher({ hash: 'ab'.repeat(32) }), `role=user,action=check_voucher,cid=${cid},hash=${'ab'.repeat(32)}`);
  assert.equal(args.cancelBatch({ batchId: 5n }), `role=user,action=cancel_batch,cid=${cid},batch_id=5`);
  assert.equal(args.viewBatchVouchers({ batchId: 12n }), `role=user,action=view_batch_vouchers,cid=${cid},batch_id=12`);
  assert.equal(
    args.createBatch({ assetId: 0, vouchers: [{ hash: '11'.repeat(32), value: 100000n }, { hash: '22'.repeat(32), value: 100000n }] }),
    `role=user,action=create_batch,cid=${cid},asset_id=0,count=2,vouchers=${'11'.repeat(32)}a086010000000000${'22'.repeat(32)}a086010000000000`,
  );
  assert.equal(args.redeem({ normalisedCode: normaliseCode('abcd-efgh-jklm-npqr') }), `role=user,action=redeem,cid=${cid},code=ABCDEFGHJKLMNPQR`);
  for (const bad of ['ABCD-EFGH', 'abcd', '', 'A'.repeat(65), 'ÄB', 'A,B=C']) assert.throws(() => args.redeem({ normalisedCode: bad }), RangeError, bad);
  for (const dead of DEAD_CIDS) assert.throws(() => args.viewMyBatches({ cid: dead }), RangeError);
  assert.throws(() => args.viewMyBatches({ cid: 'AB'.repeat(32) }), RangeError);
  assert.throws(() => args.checkVoucher({ hash: 'ab'.repeat(31) }), RangeError);
  assert.throws(() => args.cancelBatch({ batchId: -1n }), RangeError);
  assert.throws(() => args.cancelBatch({ batchId: 1n << 64n }), RangeError);
  assert.throws(() => args.createBatch({ assetId: -1, vouchers: [{ hash: '11'.repeat(32), value: 1n }] }), RangeError);
});

test('answers: a voucher, my batches, a batch\'s vouchers; shader errors as codes', () => {
  const v = parseVoucherInfo(parseShaderJson(JSON.stringify({ voucher: { batch_id: 4, asset_id: 174, value: 1000000, redeemed: 1, redeemer: FAKE_KEY, redeemed_at: 4000123 } })), 'ab'.repeat(32));
  assert.deepEqual(v, { hash: 'ab'.repeat(32), batchId: 4n, assetId: 174, value: 1000000n, redeemed: true, redeemerKey: FAKE_KEY, redeemedAtHeight: 4000123n });
  const b = parseBatches(parseShaderJson('{"batches": [{"id": 21,"asset_id": 174,"value_per_voucher": 1000000,"total_count": 3,"redeemed_count": 2,"created_at": 4000000}]}'));
  assert.equal(b[0].id, 21n);
  assert.equal(b[0].unclaimedCount, 1);
  assert.throws(() => parseBatches({ batches: [{ id: 1, asset_id: 0, value_per_voucher: 1, total_count: 1, redeemed_count: 2, created_at: 1 }] }), (e) => e.code === 'unexpected');
  const vs = parseBatchVouchers({ vouchers: [{ hash: 'cd'.repeat(32), value: 7, redeemed: 0 }] });
  assert.equal(vs[0].hash, 'cd'.repeat(32));
  assert.equal(vs[0].redeemed, false);
  assert.throws(() => parseBatchVouchers({ vouchers: [{ hash: 'xyz', value: 1, redeemed: 0 }] }), (e) => e.code === 'unexpected');
  assert.throws(() => parseVoucherInfo({ voucher: { batch_id: 1, asset_id: 0, value: 1, redeemed: 2 } }, 'ab'.repeat(32)), (e) => e.code === 'unexpected');
  assert.throws(() => parseVoucherInfo({ voucher: { batch_id: 1, asset_id: 2 ** 32, value: 1, redeemed: 0 } }, 'ab'.repeat(32)), (e) => e.code === 'unexpected');
  assert.equal(parseShaderJson(fixture('check_voucher_not_found').result.output).error, 'Voucher not found');
  assert.equal(codeFor('Voucher not found'), 'voucherNotFound');
  assert.equal(codeFor('Voucher already redeemed'), 'alreadyRedeemed');
  assert.equal(codeFor('something new'), 'shaderError');
  const m = mapError(Object.assign(new Error('Voucher not found'), { code: 'shader' }));
  assert.equal(m.code, 'voucherNotFound');
  assert.match(m.message, /never contain I, O, 0 or 1/);
});

// ---------------------------------------------------------------- a fake contract

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
const sgn = (v) => {
  const neg = v < 0n;
  let a = neg ? -v : v;
  if (a < 64n) return [(neg ? 0x80 : 0) | 0x40 | Number(a)];
  const b = [];
  while (a > 0n) {
    b.push(Number(a & 0xffn));
    a >>= 8n;
  }
  return [(neg ? 0x80 : 0) | b.length, ...b];
};
/** One plain ContractInvokeEntry, serialized the way the core does. */
function writeInvoke({ method, argBytes, funds, comment, charge, sigs = 1, cid = AIRDROP_CID }) {
  const c = [...new TextEncoder().encode(comment)];
  const f = [...funds].sort((a, b) => a[0] - b[0]);
  return [
    ...u(1),
    ...u(method),
    ...u(argBytes.length),
    ...argBytes,
    ...u(sigs),
    ...Array(32 * sigs).fill(7),
    ...u(charge),
    ...u(c.length),
    ...c,
    ...u(f.length),
    ...f.flatMap(([k, v]) => [...u(k), ...sgn(v)]),
    ...fromHex(cid),
  ];
}

/** Answers like the pinned app shader, from an in-memory contract. */
function fakeShader({ myKey = FAKE_KEY } = {}) {
  const st = { vouchers: new Map(), batches: new Map(), seen: [], tamper: null, signed: 0, consent: null };
  const parse = (a) => Object.fromEntries(a.split(',').map((kv) => [kv.slice(0, kv.indexOf('=')), kv.slice(kv.indexOf('=') + 1)]));
  const built = (e) => (st.tamper ? st.tamper(e) : e);
  st.answer = async (a) => {
    st.seen.push(a);
    const p = parse(a);
    if (p.cid !== AIRDROP_CID) return { output: '{"error": "Contract not found"}' };
    switch (`${p.role}:${p.action}`) {
      case 'user:get_my_key':
        return { output: JSON.stringify({ pk: myKey }) };
      case 'user:check_voucher': {
        const v = st.vouchers.get(p.hash);
        if (!v) return { output: '{"error": "Voucher not found"}' };
        return { output: JSON.stringify({ voucher: { batch_id: Number(v.batchId), asset_id: v.assetId, value: Number(v.value), redeemed: v.redeemed ? 1 : 0, ...(v.redeemed ? { redeemer: OTHER_KEY, redeemed_at: 4000000 } : {}) } }) };
      }
      case 'user:view_my_batches':
        return {
          output: JSON.stringify({
            batches: [...st.batches].map(([id, aid]) => {
              const of = [...st.vouchers.values()].filter((v) => v.batchId === id);
              return { id: Number(id), asset_id: aid, value_per_voucher: Number(of[0].value), total_count: of.length, redeemed_count: of.filter((v) => v.redeemed).length, created_at: 4000000 };
            }),
          }),
        };
      case 'user:view_batch_vouchers': {
        const id = BigInt(p.batch_id);
        if (!st.batches.has(id)) return { output: '{"error": "Batch not found"}' };
        return { output: JSON.stringify({ vouchers: [...st.vouchers].filter(([, v]) => v.batchId === id).map(([h, v]) => ({ hash: h, value: Number(v.value), redeemed: v.redeemed ? 1 : 0, ...(v.redeemed ? { redeemer: OTHER_KEY, redeemed_at: 4000000 } : {}) })) }) };
      }
      case 'user:create_batch': {
        const aid = Number(p.asset_id);
        const n = Number(p.count);
        const blob = fromHex(p.vouchers).subarray(0, 40 * n);
        const total = decodeVoucherBlob(blob).reduce((s, e) => s + e.value, 0n);
        return { output: '{}', raw_data: writeInvoke(built({ method: METHOD.createBatch, argBytes: [...fromHex(myKey), ...le(aid, 4), ...le(n, 4), ...blob], funds: new Map([[aid, total + creationFee(total)]]), comment: KERNEL.createBatch, charge: CHARGE.createBatch })) };
      }
      case 'user:redeem': {
        const h = await codeHash(p.code);
        const v = st.vouchers.get(h);
        if (!v) return { output: '{"error": "Voucher not found"}' };
        if (v.redeemed) return { output: '{"error": "Voucher already redeemed"}' };
        return { output: '{}', raw_data: writeInvoke(built({ method: METHOD.redeem, argBytes: [...fromHex(myKey), ...le(p.code.length, 4), ...new TextEncoder().encode(p.code)], funds: new Map([[v.assetId, -v.value]]), comment: KERNEL.redeem, charge: CHARGE.redeem })) };
      }
      case 'user:cancel_batch': {
        const id = BigInt(p.batch_id);
        const aid = st.batches.get(id);
        if (aid == null) return { output: '{"error": "Batch not found"}' };
        const open = [...st.vouchers].filter(([, v]) => v.batchId === id && !v.redeemed);
        if (!open.length) return { output: '{"error": "No unclaimed vouchers"}' };
        const total = open.reduce((s, [, v]) => s + v.value, 0n);
        return { output: '{}', raw_data: writeInvoke(built({ method: METHOD.cancelBatch, argBytes: [...fromHex(myKey), ...le(id, 8), ...le(open.length, 4), ...open.flatMap(([h]) => [...fromHex(h)])], funds: new Map([[aid, -total]]), comment: KERNEL.cancelBatch, charge: CHARGE.cancelBatch })) };
      }
      default:
        return { output: '{"error": "invalid action"}' };
    }
  };
  return st;
}

const memoryKv = () => {
  const m = new Map();
  return { m, get: async (k) => (m.has(k) ? structuredClone(m.get(k)) : undefined), set: async (k, v) => void m.set(k, structuredClone(v)) };
};

function service(st, { kv = memoryKv(), vault = null, consent = null, beforeSign = null, sendError = null } = {}) {
  const v = vault || codeVault({ kv, walletId: 'w1', secret: 'ab'.repeat(32) });
  const shaderErr = (o) => {
    if (o && typeof o === 'object' && 'error' in o) throw Object.assign(new Error(String(o.error)), { code: 'shader' });
    return o;
  };
  const svc = createAirdrop({
    view: async (a) => {
      const r = await st.answer(a);
      if (r.raw_data) throw Object.assign(new Error('A read-only call produced a transaction.'), { code: 'unexpected' });
      return shaderErr(parseShaderJson(r.output));
    },
    transact: async (a, { inspect, expect }) => {
      const r = await st.answer(a);
      const output = shaderErr(parseShaderJson(r.output));
      // As lib/contracts.js: a copy of the bytes and the parsed output; a truthy
      // answer or a throw refuses, reported as 'unexpected'.
      let refused = null;
      try {
        refused = await inspect(Uint8Array.from(r.raw_data), output);
      } catch (e) {
        throw Object.assign(new Error(e.message), { code: 'unexpected' });
      }
      if (refused) throw Object.assign(new Error(refused.message || String(refused)), { code: refused.code || 'refused' });
      const d = readContractTx(r.raw_data);
      const req = consent ? consent(d) : { kind: 'contract', spends: [...d.pays].map(([assetId, amount]) => ({ assetId, amount })), receives: [...d.receives].map(([assetId, amount]) => ({ assetId, amount })), fee: d.fee };
      const problem = expect(req);
      if (problem) throw Object.assign(new Error(problem.message), { code: problem.code });
      if (beforeSign) await beforeSign();
      if (sendError) throw sendError;
      st.signed++;
      return TXID;
    },
    vault: async () => v,
  });
  return { svc, vault: v, kv };
}

test('create: locks the vouchers plus 1%, saves the codes before signing, then records the tx', async () => {
  const st = fakeShader();
  let savedAtSign = null;
  const { svc, vault } = service(st, { beforeSign: async () => (savedAtSign = await vault.all()) });
  const r = await svc.createBatch({ assetId: 0, values: [100000n, 100000n] });
  assert.equal(r.txId, TXID);
  assert.equal(r.total, 200000n);
  assert.equal(r.fee, 2000n);
  assert.equal(r.built.pays.get(0), 202000n);
  assert.equal(r.built.fee, CALL_FEE);
  assert.equal(savedAtSign.length, 1, 'the codes were saved before the wallet signed');
  assert.equal(savedAtSign[0].txStatus, TX_STATUS.unconfirmed);
  const saved = (await vault.all())[0];
  assert.equal(saved.txId, TXID);
  assert.equal(saved.txStatus, TX_STATUS.broadcast);
  assert.equal(saved.codes.length, 2);
  // The shader got the codes' hashes, never the codes.
  const sent = st.seen.find((a) => a.includes('create_batch'));
  for (const c of saved.codes) {
    assert.ok(isWellFormedCode(c.code));
    assert.ok(!sent.includes(normaliseCode(c.code)));
    assert.ok(sent.includes(await codeHash(c.code)));
  }
  assert.equal(batchTotal(saved), 200000n);
});

test('create: a token batch locks the token plus its fee; refuses 0 or 101 codes before calling anything', async () => {
  const st = fakeShader();
  const { svc } = service(st);
  const r = await svc.createBatch({ assetId: 174, values: [5000000n, 1n, 250n] });
  assert.equal(r.built.pays.get(174), 5000251n + 50002n);
  assert.equal(r.built.pays.has(0), false);
  await assert.rejects(svc.createBatch({ assetId: 0, values: [] }), RangeError);
  await assert.rejects(svc.createBatch({ assetId: 0, values: Array(101).fill(1n) }), RangeError);
});

test('create: a built transaction that differs from the request is never signed, in any way', async () => {
  const cases = {
    'another contract': (e) => ({ ...e, cid: 'ee'.repeat(32) }),
    'another method': (e) => ({ ...e, method: 3 }),
    'more locked than asked': (e) => ({ ...e, funds: new Map([[0, [...e.funds][0][1] + 1n]]) }),
    'another asset as well': (e) => ({ ...e, funds: new Map([...e.funds, [7, 1n]]) }),
    'a different voucher hash': (e) => ({ ...e, argBytes: [...e.argBytes.slice(0, 41), ...Array(32).fill(1), ...e.argBytes.slice(73)] }),
    'another creator key': (e) => ({ ...e, argBytes: [...fromHex(OTHER_KEY), ...e.argBytes.slice(33)] }),
    'a different BVM charge': (e) => ({ ...e, charge: 1200001 }),
    'another kernel comment': (e) => ({ ...e, comment: 'Redeem airdrop voucher' }),
    'two signing keys': (e) => ({ ...e, sigs: 2 }),
  };
  for (const [what, tamper] of Object.entries(cases)) {
    const st = fakeShader();
    st.tamper = tamper;
    const { svc, vault } = service(st);
    await assert.rejects(svc.createBatch({ assetId: 0, values: [100000n, 100000n] }), (e) => e.code === 'unexpected', what);
    assert.equal(st.signed, 0, what);
    assert.equal((await vault.all()).length, 0, `${what}: nothing saved for a transaction that was never shown`);
  }
});

test('create: the approve sheet must show what was built, or it is refused unseen', async () => {
  for (const consent of [(d) => ({ kind: 'contract', spends: [{ assetId: 0, amount: d.pays.get(0) }], receives: [], fee: d.fee + 1n }), (d) => ({ kind: 'contract', spends: [{ assetId: 0, amount: d.pays.get(0) + 1n }], receives: [], fee: d.fee })]) {
    const st = fakeShader();
    const { svc, vault } = service(st, { consent });
    await assert.rejects(svc.createBatch({ assetId: 0, values: [100000n] }), (e) => e.code === 'unexpected');
    assert.equal(st.signed, 0);
    const kept = await vault.all();
    assert.equal(kept.length, 1, 'the codes stay saved');
    assert.equal(kept[0].txStatus, TX_STATUS.failed, 'marked as never sent');
  }
});

test('create: declined on the sheet keeps the codes (failed); a timeout keeps them unconfirmed', async () => {
  let st = fakeShader();
  let s = service(st, { sendError: Object.assign(new Error('Cancelled. Nothing was sent.'), { code: 'rejected' }) });
  await assert.rejects(s.svc.createBatch({ assetId: 0, values: [100000n] }), (e) => e.code === 'rejected');
  assert.equal((await s.vault.all())[0].txStatus, TX_STATUS.failed);
  st = fakeShader();
  s = service(st, { sendError: Object.assign(new Error('The wallet did not answer in time.'), { code: 'timeout' }) });
  await assert.rejects(s.svc.createBatch({ assetId: 0, values: [100000n] }), (e) => e.code === 'timeout');
  const kept = (await s.vault.all())[0];
  assert.equal(kept.txStatus, TX_STATUS.unconfirmed, 'a timeout does not prove it never reached the network');
  assert.equal(kept.codes.length, 1);
});

test('create: nothing is signed when the codes cannot be saved, or do not read back', async () => {
  const st = fakeShader();
  const broken = { all: async () => [], put: async () => { throw new Error('disk full'); } };
  const { svc } = service(st, { vault: broken });
  await assert.rejects(svc.createBatch({ assetId: 0, values: [100000n] }), (e) => e.code === 'codesNotSaved');
  assert.equal(st.signed, 0);
  const dropping = { all: async () => [], put: async () => {} };
  const s2 = service(fakeShader(), { vault: dropping });
  await assert.rejects(s2.svc.createBatch({ assetId: 0, values: [100000n] }), (e) => e.code === 'codesNotSaved');
});

test('one airdrop transaction at a time: a second tap in the same moment is refused', async () => {
  const st = fakeShader();
  const { svc } = service(st);
  const first = svc.createBatch({ assetId: 0, values: [100000n] });
  assert.equal(svc.busy, true);
  await assert.rejects(svc.createBatch({ assetId: 0, values: [100000n] }), (e) => e.code === 'busy');
  await assert.rejects(svc.redeem('ABCD-EFGH-JKLM-NPQR'), (e) => e.code === 'busy');
  await first;
  assert.equal(svc.busy, false);
  assert.equal(st.signed, 1, 'one batch, not two');
  // A failed attempt releases it too.
  st.tamper = (e) => ({ ...e, method: 9 });
  await assert.rejects(svc.createBatch({ assetId: 0, values: [100000n] }));
  assert.equal(svc.busy, false);
});

test('claim: the normalised code as the preimage, exactly the voucher\'s value, plain words otherwise', async () => {
  const st = fakeShader();
  const code = 'abcd-efgh-jklm-npqr';
  st.vouchers.set(await codeHash(code), { batchId: 1n, assetId: 174, value: 500000000n, redeemed: false });
  st.batches.set(1n, 174);
  const { svc } = service(st);
  const info = await svc.checkVoucher(code);
  assert.equal(info.value, 500000000n);
  const r = await svc.redeem(code);
  assert.equal(r.txId, TXID);
  assert.equal(r.built.receives.get(174), 500000000n);
  assert.equal(r.built.fee, CALL_FEE);
  const sent = st.seen.find((a) => a.includes('action=redeem'));
  assert.ok(sent.endsWith('code=ABCDEFGHJKLMNPQR'));
  assert.ok(!sent.includes(await codeHash(code)), 'never the hash');
  assert.equal(await svc.checkVoucher('ZZZZ-ZZZZ-ZZZZ-ZZZZ'), null);
  await assert.rejects(svc.redeem('ZZZZ-ZZZZ-ZZZZ-ZZZZ'), (e) => e.code === 'voucherNotFound' && /letter by letter/.test(e.message));
  await assert.rejects(svc.redeem('----'), (e) => e.code === 'invalidCode');
  st.vouchers.get(await codeHash(code)).redeemed = true;
  await assert.rejects(svc.redeem(code), (e) => e.code === 'alreadyRedeemed');
  // A claim that would pay out something else is refused.
  st.vouchers.get(await codeHash(code)).redeemed = false;
  st.tamper = (e) => ({ ...e, funds: new Map([[174, -500000001n]]) });
  await assert.rejects(svc.redeem(code), (e) => e.code === 'unexpected');
});

test('cancel: exactly the unclaimed vouchers come back; a claim in between is caught', async () => {
  const st = fakeShader();
  const hs = [];
  for (const c of ['AAAA-AAAA-AAAA-AAAA', 'BBBB-BBBB-BBBB-BBBB', 'CCCC-CCCC-CCCC-CCCC']) {
    const h = await codeHash(c);
    hs.push(h);
    st.vouchers.set(h, { batchId: 9n, assetId: 0, value: 100000n, redeemed: false });
  }
  st.vouchers.get(hs[0]).redeemed = true;
  st.batches.set(9n, 0);
  const { svc } = service(st);
  const r = await svc.cancelBatch(9n);
  assert.equal(r.count, 2);
  assert.equal(r.total, 200000n);
  assert.equal(r.built.receives.get(0), 200000n);
  assert.equal(r.built.fee, CANCEL_FEE);
  // The contract lists a different set than the view did.
  const orig = st.answer;
  st.answer = async (a) => {
    if (a.includes('cancel_batch')) st.vouchers.get(hs[1]).redeemed = true;
    return orig(a);
  };
  await assert.rejects(svc.cancelBatch(9n), (e) => e.code === 'unexpected');
  st.answer = orig;
  await assert.rejects(svc.cancelBatch(77n), (e) => e.code === 'batchNotFound');
  for (const h of hs) st.vouchers.get(h).redeemed = true;
  await assert.rejects(svc.cancelBatch(9n), (e) => e.code === 'nothingToCancel');
});

test('saved codes: encrypted, bound to the wallet, never dropped, never deleted', async () => {
  const kv = memoryKv();
  const vault = codeVault({ kv, walletId: 'w1', secret: 'ab'.repeat(32) });
  const st = fakeShader();
  const { svc } = service(st, { vault });
  const { batch } = await svc.createBatch({ assetId: 0, values: [100000n, 100000n] });
  const stored = JSON.stringify(kv.m.get('airdropCodes'));
  for (const c of batch.codes) {
    assert.ok(!stored.includes(normaliseCode(c.code)) && !stored.includes(c.code), 'no code in the clear');
    assert.ok(!stored.includes(c.hash), 'no hash in the clear');
  }
  // Another wallet's secret cannot read them, and they are left untouched.
  await assert.rejects(codeVault({ kv, walletId: 'w1', secret: 'cd'.repeat(32) }).all(), (e) => e.code === 'noCodeStore');
  await assert.rejects(codeVault({ kv, walletId: 'w2', secret: 'ab'.repeat(32) }).all(), (e) => e.code === 'noCodeStore');
  assert.equal(JSON.stringify(kv.m.get('airdropCodes')), stored);
  // A refresh that finds nothing on chain keeps every code.
  const refreshed = await svc.refreshSavedBatch(batch);
  assert.equal(refreshed.codes.length, 2);
  assert.ok(refreshed.codes.every((c) => c.status === CODE_STATUS.notFound));
  assert.equal((await vault.all())[0].codes.length, 2);
  // A write that would drop a code is refused; a second batch keeps the first.
  await assert.rejects(vault.put({ ...batch, codes: batch.codes.slice(1) }), (e) => e.code === 'codesNotSaved');
  await svc.createBatch({ assetId: 0, values: [1n] });
  assert.equal((await vault.all()).length, 2);
  // There is no way to delete through the vault or the service.
  assert.equal(typeof vault.delete, 'undefined');
  assert.equal(Object.keys(svc).some((k) => /delete|forget|remove/i.test(k)), false);
});

test('saved codes: a record whose code does not match its hash is refused; an odd status reads as unconfirmed', async () => {
  const code = 'ABCD-EFGH-JKLM-NPQR';
  const good = { localId: 'b1', contractId: AIRDROP_CID, assetId: 0, createdAt: '2026-10-10T00:00:00.000Z', txId: null, txStatus: 'weird', codes: [{ code, hash: await codeHash(code), value: '100000', status: 'nope' }] };
  const r = await readSavedBatch(good);
  assert.equal(r.txStatus, TX_STATUS.unconfirmed);
  assert.equal(r.codes[0].status, CODE_STATUS.unknown);
  await assert.rejects(readSavedBatch({ ...good, codes: [{ ...good.codes[0], hash: 'ab'.repeat(32) }] }), (e) => e.code === 'unexpected');
  await assert.rejects(readSavedBatch({ ...good, codes: [{ ...good.codes[0], value: '0' }] }), (e) => e.code === 'unexpected');
  await assert.rejects(readSavedBatch({ ...good, codes: [] }), (e) => e.code === 'unexpected');
  // A record the vault cannot read is kept in storage, not shown.
  const kv = memoryKv();
  const vault = codeVault({ kv, walletId: 'w1', secret: 's'.repeat(64) });
  await vault.put(good);
  await vault.put({ ...good, localId: 'b2', codes: [{ ...good.codes[0], hash: 'ab'.repeat(32) }] });
  assert.deepEqual((await vault.all()).map((b) => b.localId), ['b1']);
  await vault.put({ ...good, txStatus: TX_STATUS.confirmed });
  assert.equal((await vault.all()).length, 1, 'the unreadable record is still there, untouched');
});

test('a read-only call never carries a transaction', async () => {
  const st = fakeShader();
  const orig = st.answer;
  st.answer = async (a) => ({ ...(await orig(a)), raw_data: [1, 2, 3] });
  const { svc } = service(st);
  await assert.rejects(svc.myBatches(), (e) => e.code === 'unexpected');
});

test('the recorded create_batch of 2 x 0.001 BEAM passes the same checks', () => {
  const d = readContractTx(fixture('create_batch_2x0.001').result.raw_data);
  const e = d.entries[0];
  assert.equal(e.contractId, AIRDROP_CID);
  assert.equal(e.method, METHOD.createBatch);
  assert.equal(e.charge, CHARGE.createBatch);
  assert.equal(e.comment, KERNEL.createBatch);
  assert.equal(e.signatureCount, 1);
  const entries = decodeVoucherBlob(e.args.subarray(41));
  assert.deepEqual(entries.map((x) => x.value), [100000n, 100000n]);
  const total = entries.reduce((s, x) => s + x.value, 0n);
  assert.equal(d.pays.get(0), total + creationFee(total));
  assert.equal(d.fee, CALL_FEE);
  assert.deepEqual([...e.args.subarray(0, 41)], [...concat(fromHex(FAKE_KEY), le(0, 4), le(2, 4))]);
});

test('through lib/contracts.js: saving the codes lets the request on to the sheet; declined keeps them; a double tap is refused', async () => {
  const st = fakeShader();
  const engine = fakeEngine({
    respond: (req, api) => {
      if (req.method === 'invoke_contract') return st.answer(req.params.args).then((r) => api.reply(req.id, r));
      if (req.method === 'process_invoke_data') {
        const d = readContractTx(req.params.data);
        const amounts = [...d.spend].map(([aid, v]) => ({ assetID: aid, amount: (Number(v < 0n ? -v : v) / 1e8).toFixed(8).replace(/\.?0+$/, ''), spend: v > 0n }));
        return engine.askContract(api, req, { comment: KERNEL.createBatch, fee: '0.121', isEnough: false, isSpend: true }, amounts);
      }
      return api.reply(req.id, {});
    },
  });
  bindSession(engine.session);
  const shown = [];
  let decide;
  const unset = setConsentPresenter((req) => {
    shown.push(req);
    return new Promise((r) => (decide = r));
  });
  try {
    const app = await nativeApp();
    const vault = codeVault({ kv: memoryKv(), walletId: 'w1', secret: 'cd'.repeat(32) });
    const svc = createAirdrop({ view: (a) => app.view(a, [0]), transact: (a, o) => app.transact(a, [0], o), vault: async () => vault });
    const first = svc.createBatch({ assetId: 0, values: [100000n, 100000n] });
    await assert.rejects(svc.createBatch({ assetId: 0, values: [100000n, 100000n] }), (e) => e.code === 'busy', 'a second tap buys nothing');
    while (!shown.length) await new Promise((r) => setTimeout(r, 5));
    assert.equal(shown.length, 1, 'inspect returned nothing, so the request reached the sheet');
    assert.deepEqual(shown[0].intent, { action: 'airdropCreate', count: 2 });
    assert.deepEqual(shown[0].spends.map((a) => [a.assetId, a.amount]), [[0, 202000n]]);
    const atSheet = await vault.all();
    assert.equal(atSheet.length, 1, 'the codes were saved before the sheet opened');
    decide(false);
    await assert.rejects(first, (e) => e.code === 'rejected');
    const kept = await vault.all();
    assert.equal(kept.length, 1);
    assert.equal(kept[0].txStatus, TX_STATUS.failed);
    assert.deepEqual(kept[0].codes.map((c) => c.hash), atSheet[0].codes.map((c) => c.hash), 'every code kept');
    assert.equal(svc.busy, false);
  } finally {
    unset();
    unbindSession();
  }
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { DEX_CID, tradeFee, tradeArgs, poolsViewArgs, parsePools, parseQuote, bestQuote, receivable, tradable, swapExpectation, minReceive, priceImpactBps, feeIsLarge, bpsText, DexError, PROTECTIONS, valueInBeam, swapValue, feeShareBps } from '../../src/lib/dex.js';
import { approveLabel, shortfall, shortAmount, spentUnits } from '../../src/screens/consent.js';

const pool = (aid1, aid2, kind, tok1, tok2, lp = 900 + kind, ctl = 1000n) => ({ aid1, aid2, kind, tok1: BigInt(tok1), tok2: BigInt(tok2), ctl: BigInt(ctl), lpToken: lp });

/** A prediction the way the shader prints it, for a raw price and a fee tier. */
function prediction(kind, payRaw, buy) {
  const f = tradeFee(kind, payRaw);
  return { res: { buy: Number(buy), pay: Number(BigInt(payRaw) + f.pool + f.dao), pay_raw: Number(payRaw), fee_pool: Number(f.pool), fee_dao: Number(f.dao) } };
}

test('trade fees match what the contract charged on mainnet', () => {
  // Measured with bPredictOnly=1 (2026-10-06, height 4068104), see dex_constants.dart.
  const sum = (f) => f.pool + f.dao;
  assert.equal(sum(tradeFee(0, 99950015n)), 49976n);
  assert.equal(sum(tradeFee(1, 99700899n)), 299101n);
  assert.equal(sum(tradeFee(2, 9900990n)), 99010n);
  // Measured from this PWA's engine: paying 1 groth of BEAM into the 1% FOMO pool.
  assert.deepEqual(tradeFee(2, 0n), { pool: 1n, dao: 0n });
  const f = tradeFee(2, 9900990n);
  assert.equal(f.dao, (99010n * 3n) / 10n);
  assert.throws(() => tradeFee(3, 1n));
});

test('trade args: aid1 is what you get, aid2 what you pay; canonical numbers only', () => {
  assert.equal(
    tradeArgs({ payAsset: 0, receiveAsset: 174, kind: 2, payAmount: 1000000n, predictOnly: true }),
    `action=pool_trade,cid=${DEX_CID},aid1=174,aid2=0,kind=2,val1_buy=0,val2_pay=1000000,bPredictOnly=1`,
  );
  assert.equal(tradeArgs({ payAsset: 174, receiveAsset: 0, kind: 0, payAmount: 5n, predictOnly: false }).includes('aid1=0,aid2=174,kind=0'), true);
  assert.throws(() => tradeArgs({ payAsset: 0, receiveAsset: 0, kind: 2, payAmount: 1n, predictOnly: true }), DexError);
  assert.throws(() => tradeArgs({ payAsset: 0, receiveAsset: 1, kind: 2, payAmount: 0n, predictOnly: true }), DexError);
  assert.throws(() => tradeArgs({ payAsset: 0, receiveAsset: 1, kind: 2, payAmount: 1n, receiveAmount: 1n, predictOnly: true }), DexError);
  assert.throws(() => tradeArgs({ payAsset: 0, receiveAsset: 1, kind: 7, payAmount: 1n, predictOnly: true }), DexError);
  assert.throws(() => tradeArgs({ payAsset: -1, receiveAsset: 1, kind: 2, payAmount: 1n, predictOnly: true }), DexError);
  assert.equal(poolsViewArgs(), `action=pools_view,cid=${DEX_CID}`);
});

test('pools: parsed exactly, empty ones recognised, LP tokens and dead pools left out of the pickers', () => {
  const pools = parsePools({
    res: [
      { aid1: 0, aid2: 1, kind: 2, ctl: 0, tok1: 0, tok2: 0, 'lp-token': 72 },
      { aid1: 0, aid2: 174, kind: 2, ctl: '27125190867423', tok1: '8120504552105', tok2: '66136536898747123', 'lp-token': 175 },
      { aid1: 0, aid2: 174, kind: 0, ctl: 5, tok1: 10, tok2: 20, 'lp-token': 176 },
      { aid1: 0, aid2: 36, kind: 2, ctl: 9, tok1: 900000, tok2: 3, 'lp-token': 50 },
      { aid1: 0, aid2: 175, kind: 2, ctl: 9, tok1: 9, tok2: 9, 'lp-token': 51 },
      { aid1: 36, aid2: 174, kind: 1, ctl: 9, tok1: 9, tok2: 9, 'lp-token': 52 },
    ],
  });
  assert.equal(pools[1].tok2, 66136536898747123n);
  assert.deepEqual(receivable(pools, 0), [174, 36], 'deepest BEAM pool first; empty pool (1) and LP token (175) left out');
  assert.deepEqual(receivable(pools, 174), [0, 36]);
  assert.deepEqual([...tradable(pools)].sort((a, b) => a - b), [0, 36, 174]);
  assert.throws(() => parsePools({}), DexError);
});

test('a quote must add up: pay = raw price + both fees, the tier rule, no more than asked', () => {
  const p = pool(0, 174, 2, 8120504552105n, 66136536898747n);
  const out = prediction(2, 990099, 7_000_000);
  const q = parseQuote(out, { pool: p, payAsset: 0, receiveAsset: 174, payAmount: 1000000n });
  assert.equal(q.pay, 1000000n);
  assert.equal(q.fee, q.pay - q.payRaw);
  assert.throws(() => parseQuote({ res: { ...out.res, pay: out.res.pay + 1 } }, { pool: p, payAsset: 0, receiveAsset: 174, payAmount: 2000000n }), /pay != pay_raw/);
  assert.throws(() => parseQuote({ res: { ...out.res, fee_pool: out.res.fee_pool + 1, pay: out.res.pay + 1 } }, { pool: p, payAsset: 0, receiveAsset: 174, payAmount: 2000000n }), /fees do not match/);
  assert.throws(() => parseQuote(out, { pool: p, payAsset: 0, receiveAsset: 174, payAmount: 999999n }), /exceeds/);
  assert.throws(() => parseQuote(out, { pool: p, payAsset: 0, receiveAsset: 36, payAmount: 1000000n }), /does not trade/);
});

test('best quote: every live pool of the pair is asked; the most received wins, ties go to the cheaper', async () => {
  const pools = [pool(0, 174, 0, 100, 100), pool(0, 174, 1, 100, 100), pool(0, 174, 2, 100, 100), pool(0, 174, 2, 0, 0, 1, 0n), pool(0, 36, 2, 5, 5)];
  const asked = [];
  const predict = async (args) => {
    asked.push(args);
    const kind = Number(/kind=(\d)/.exec(args)[1]);
    if (kind === 0) return prediction(0, 999000, 500);
    if (kind === 1) return prediction(1, 996000, 800);
    return prediction(2, 990000, 800); // same receive as kind 1, but costs more
  };
  const q = await bestQuote(predict, { pools, payAsset: 0, receiveAsset: 174, payAmount: 1000000n });
  assert.equal(asked.length, 3);
  assert.equal(q.kind, 1);
  assert.equal(q.receive, 800n);
});

test('best quote: no pool, an empty pool, a tiny amount and shader refusals have names', async () => {
  const live = [pool(0, 174, 2, 100, 100)];
  await assert.rejects(bestQuote(async () => ({}), { pools: live, payAsset: 0, receiveAsset: 36, payAmount: 1n }), (e) => e.code === 'noPool');
  await assert.rejects(bestQuote(async () => ({}), { pools: [pool(0, 36, 2, 0, 0, 1, 0n)], payAsset: 0, receiveAsset: 36, payAmount: 1n }), (e) => e.code === 'poolEmpty');
  await assert.rejects(bestQuote(async () => prediction(2, 0, 0), { pools: live, payAsset: 0, receiveAsset: 174, payAmount: 1n }), (e) => e.code === 'tooSmall');
  const shaderSays = (m) => async () => {
    const e = new Error(m);
    e.code = 'shader';
    throw e;
  };
  await assert.rejects(bestQuote(shaderSays('no such pool'), { pools: live, payAsset: 0, receiveAsset: 174, payAmount: 1n }), (e) => e.code === 'noPool');
  await assert.rejects(bestQuote(shaderSays('no liquidity'), { pools: live, payAsset: 0, receiveAsset: 174, payAmount: 1n }), (e) => e.code === 'poolEmpty');
  await assert.rejects(bestQuote(shaderSays('weird'), { pools: live, payAsset: 0, receiveAsset: 174, payAmount: 1n }), (e) => e.code === 'shader');
});

test('price protection: the built swap may receive at most 1% less, pay no more, and touch no other asset', () => {
  const q = { payAsset: 0, receiveAsset: 174, pay: 1000000n, receive: 37176133894n };
  const check = swapExpectation(q);
  const req = (pay, get, extra = {}) => ({ kind: 'contract', spends: [{ assetId: 0, amount: pay }], receives: [{ assetId: 174, amount: get }], ...extra });
  assert.equal(check(req(1000000n, 37176133894n)), null);
  assert.equal(check(req(999990n, minReceive(q))), null, 'exactly 1% less is allowed');
  const moved = check(req(1000000n, minReceive(q) - 1n));
  assert.equal(moved.code, 'priceMoved');
  assert.match(moved.message, /more than the 1%/);
  assert.equal(check(req(1000001n, 37176133894n)).code, 'unexpected');
  assert.equal(check({ ...req(1000000n, 37176133894n), receives: [{ assetId: 175, amount: 37176133894n }] }).code, 'unexpected');
  assert.equal(check({ ...req(1000000n, 37176133894n), spends: [{ assetId: 0, amount: 1n }, { assetId: 7, amount: 1n }] }).code, 'unexpected');
  assert.equal(check({ ...req(1000000n, 37176133894n), kind: 'send' }).code, 'unexpected');
});

test('a stricter price protection: 0.5% and 0.1%, named in the refusal', () => {
  assert.deepEqual(PROTECTIONS, [100n, 50n, 10n]);
  const q = { payAsset: 0, receiveAsset: 174, pay: 1000000n, receive: 1000000000n };
  const req = (get) => ({ kind: 'contract', spends: [{ assetId: 0, amount: 1000000n }], receives: [{ assetId: 174, amount: get }] });
  const strict = swapExpectation(q, 10n);
  assert.equal(strict(req(999000000n)), null, 'exactly 0.1% less is allowed');
  const moved = strict(req(998999999n));
  assert.equal(moved.code, 'priceMoved');
  assert.match(moved.message, /more than the 0\.1% this swap allows/);
  assert.equal(swapExpectation(q, 50n)(req(995000000n)), null);
  assert.equal(swapExpectation(q, 50n)(req(994999999n)).code, 'priceMoved');
});

test('valuing a swap with no BEAM side: verified at spot, others only from a 1,000-BEAM pool at what it would pay', () => {
  const B = 100000000n;
  const verified = (id) => id === 36;
  const pools = [
    pool(0, 36, 2, 50n * B, 1n * B), // 1 bETH = 50 BEAM (verified, 50 BEAM deep)
    pool(0, 36, 0, 10n * B, 1n * B), // shallower: ignored
    pool(0, 900, 2, 999n * B, 1000n * B), // unverified, under 1,000 BEAM: never values
    pool(0, 901, 2, 2000n * B, 1000n * B), // unverified, 2,000 BEAM deep
  ];
  assert.equal(valueInBeam(pools, 0, 5n, verified), 5n);
  assert.equal(valueInBeam(pools, 36, B / 10n, verified), 5n * B, '0.1 bETH at the deepest pool');
  assert.equal(valueInBeam(pools, 900, B, verified), null);
  assert.equal(valueInBeam(pools, 901, 1000n * B, verified), 1000n * B, 'sold into the pool: 2000*1000/(1000+1000)');
  assert.equal(valueInBeam(pools, 777, B, verified), null);
  // bETH -> asset 901: valued from the paid side; 0.0001 bETH = 0.005 BEAM, so the fee is 220%.
  const q = { payAsset: 36, receiveAsset: 901, pay: 10000n, receive: 1n };
  const v = swapValue(q, pools, verified);
  assert.equal(v, 500000n);
  assert.equal(feeIsLarge(q, undefined, v), true);
  assert.equal(feeShareBps(v), 22000n);
  assert.equal(feeShareBps(null), null);
  // Only the received side has a price.
  assert.equal(swapValue({ payAsset: 777, receiveAsset: 36, pay: 5n, receive: B }, pools, verified), 50n * B);
  assert.equal(swapValue({ payAsset: 777, receiveAsset: 778, pay: 5n, receive: 5n }, pools, verified), null);
});

test('price impact and the small-swap fee warning', () => {
  const p = pool(0, 174, 2, 1000000000n, 8000000000n);
  // 10% of the reserve: x*y=k gives 8e9 - 8e18/1.1e9 = 727,272,727 at most.
  const q = { pool: p, payAsset: 0, receiveAsset: 174, payRaw: 100000000n, receive: 727272727n, pay: 101000001n };
  assert.equal(priceImpactBps(q), 909n);
  assert.equal(bpsText(909n), '9.09%');
  assert.equal(bpsText(100n), '1%');
  assert.equal(feeIsLarge({ payAsset: 0, receiveAsset: 174, pay: 2000000n }), true, '0.011 on 0.02 BEAM');
  assert.equal(feeIsLarge({ payAsset: 0, receiveAsset: 174, pay: 100000000n }), false);
  assert.equal(feeIsLarge({ payAsset: 36, receiveAsset: 174, pay: 1n }), false, 'no BEAM side: no estimate');
});

test('consent wording: outcome on the button, the short asset named', () => {
  const unit = (id) => ({ 0: 'BEAM', 174: 'FOMO' })[id] || `Asset #${id}`;
  const swap = { kind: 'contract', intent: { action: 'swap' }, fee: 1100000n, spends: [{ assetId: 0, amount: 1000000n }], receives: [{ assetId: 174, amount: 37176133894n }] };
  assert.equal(approveLabel(swap, unit), 'Swap 0.01 BEAM for 371.76 FOMO');
  assert.equal(approveLabel({ ...swap, intent: null }, unit), 'Pay 0.01 BEAM, get 371.76 FOMO');
  assert.equal(approveLabel({ ...swap, intent: null, receives: [] }, unit), 'Pay 0.01 BEAM');
  assert.equal(approveLabel({ ...swap, intent: null, spends: [] }, unit), 'Approve and get 371.76 FOMO');
  assert.equal(approveLabel({ ...swap, kind: 'send', spends: [{ assetId: 0, amount: 150000000n }] }, unit), 'Send 1.5 BEAM');
  assert.equal(shortAmount(37176133894n), '371.76');
  assert.equal(shortAmount(1234567n), '0.0123');
  assert.equal(shortAmount(1000n), '0.00001');
  const have = { 0: 0n, 174: 10n };
  assert.deepEqual(shortfall(swap, (id) => have[id] || 0n), { assetId: 0, need: 2100000n, have: 0n, includesFee: true });
  assert.equal(shortfall(swap, () => 10n ** 12n), null);
  assert.equal(spentUnits(swap, unit), 'BEAM');
  assert.equal(spentUnits({ ...swap, spends: [{ assetId: 174, amount: 1n }] }, unit), 'FOMO or BEAM');
});

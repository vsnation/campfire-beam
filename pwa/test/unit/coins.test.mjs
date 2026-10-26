// Coins and Split coins (lib/coins.js): Beam PWA's rules (test/beam/utxo/beam_coins_test.dart
// ported), the engine's get_utxo shape, private (max-privacy) coins, a split in the history, and the
// tx_split hand-over that never splits twice.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  FEES, splitFee, parseCoin, coinKind, coinSummary, emptySummary, roundDown, planSized, planEqual, countChoices, countBySize, splitAdvice, countsFor, chosenCount,
  MAX_COINS, isSplitTx, splitStatusText, privateReady, privateWhen, privateBalanceText, coinStatusText, SPLIT_TEXT, COIN_TEXT, readAllCoins, splitCoins, SplitError, PRIVATE_LIMIT_HOURS,
} from '../../src/lib/coins.js';
import { txStatusText } from '../../src/lib/wallet.js';

const here = dirname(fileURLToPath(import.meta.url));
const g = (n) => BigInt(n);
const coin = (aid, amount, status, extra = {}) => parseCoin({ id: `${aid}-${amount}-${status}-${extra.id || ''}`, asset_id: aid, amount, type: 'norm', status: 1, status_string: status, maturity: 4000000, ...extra });
const coinsOf = (amounts, aid = 0) => coinSummary(amounts.map((a, i) => coin(aid, a, 'available', { id: `c${i}` }))).get(aid);

test('fees: the 100,000 groth minimum, then per output as the engine computes it', () => {
  assert.equal(splitFee(3), 100000n); // 4 outputs + kernel
  assert.equal(splitFee(20), 388000n); // 10,000 + 21 x 18,000
  assert.equal(splitFee(20, { asset: true }), 406000n); // asset change too
  assert.equal(FEES.minimum, 100000n);
});

test('a get_utxo entry: amounts, statuses by name, heights, private coins', () => {
  const c = parseCoin({ id: 'ab', asset_id: 7, amount: 3009531, type: 'norm', status: 1, status_string: 'available', maturity: 3312607, createTxId: 'x', spentTxId: '' });
  assert.deepEqual({ ...c }, { id: 'ab', assetId: 7, amount: 3009531n, exact: true, type: 'norm', status: 'available', maturity: 3312607, createTxId: 'x', spentTxId: null, shielded: false });
  const s = parseCoin({ id: 1234, asset_id: 0, amount: 1000000, type: 'shld', status: 2, status_string: 'maturing', maturity: 4075082 });
  assert.equal(s.id, '1234');
  assert.equal(s.shielded, true);
  assert.equal(s.status, 'maturing');
  // The engine's MaxHeight (not confirmed yet) is no height; an unknown status is unknown.
  assert.equal(parseCoin({ id: 'z', amount: 5, status_string: 'incoming', maturity: 18446744073709551615 }).maturity, null);
  assert.equal(parseCoin({ id: 'z', amount: 5, status_string: 'weird' }).status, 'unknown');
  // An amount past what a JSON number holds exactly is shown, never counted in a split.
  const big = parseCoin({ id: 'b', asset_id: 9, amount: 2 ** 60, status_string: 'available' });
  assert.equal(big.exact, false);
  assert.equal(coinSummary([big]).get(9).availableTotal, 0n);
  assert.equal(coinKind(s), 'Private');
  assert.equal(coinKind(parseCoin({ type: 'chng' })), 'Change coin');
  assert.equal(coinKind(parseCoin({ type: 'mine' })), 'Mined');
  assert.equal(coinKind(parseCoin({ type: 'norm' })), '');
});

test('summary: per asset, spent coins left out, largest first', () => {
  const s = coinSummary([
    coin(0, 10, 'available'),
    coin(0, 30, 'available'),
    coin(0, 5, 'maturing'),
    coin(0, 7, 'outgoing'),
    coin(0, 99, 'spent'),
    coin(174, 3, 'available', { type: 'shld' }),
    coin(0, 1000000, 'maturing', { type: 'shld', id: 'mp' }),
  ]);
  assert.deepEqual([...s.keys()].sort((a, b) => a - b), [0, 174]);
  const beam = s.get(0);
  assert.deepEqual(beam.available.map((c) => c.amount), [30n, 10n]);
  assert.equal(beam.availableTotal, 40n);
  assert.equal(beam.lockedTotal, 1000012n);
  assert.equal(s.get(174).shieldedCount, 1);
  assert.equal(beam.privateMaturing.length, 1);
  assert.equal(emptySummary(0).largestShare, 0);
});

test("reads Beam PWA's recorded get_utxo answer", () => {
  const raw = JSON.parse(readFileSync(join(here, '..', '..', '..', 'test', 'beam', 'fixtures', 'get_utxo.json'), 'utf8')).result;
  const coins = raw.map(parseCoin);
  const s = coinSummary(coins);
  const counted = [...s.values()].reduce((n, c) => n + c.available.length + c.locked.length, 0);
  assert.equal(counted, coins.filter((c) => !['spent', 'consumed', 'unknown'].includes(c.status)).length);
  assert.ok(coins.every((c) => c.exact));
});

test('split plan: the fee is kept back, two significant digits, the rest is change', () => {
  const p = planEqual({ available: g(100000000), count: 9 });
  assert.equal(p.fee, splitFee(9));
  assert.equal(p.coins.length, 9);
  assert.ok(p.total + p.fee <= g(100000000));
  assert.ok(p.size > FEES.minimum);
  // 1 BEAM into 5: (1 - 0.00118) x 0.9 / 5 = 0.1797876 -> 0.17.
  const q = planEqual({ available: g(100000000), count: 5 });
  assert.equal(q.fee, 118000n);
  assert.equal(q.size, 17000000n);
  assert.equal(q.total + q.fee + q.change, 100000000n);
  assert.equal(roundDown(17978760n), 17000000n);
  assert.equal(roundDown(123456789012n), 120000000000n);
  assert.equal(roundDown(99n), 99n);
  assert.equal(SPLIT_TEXT.newCoins(q, 'BEAM'), '5 coins of 0.17 BEAM');
  assert.equal(SPLIT_TEXT.cta(5), 'Split into 5 coins');
  assert.equal(SPLIT_TEXT.fee(q), '0.00118 BEAM');
});

test('split plan: refused when coins would be worth less than a send, or the count is nonsense', () => {
  assert.equal(planEqual({ available: g(1000000), count: 20 }), null);
  assert.equal(planEqual({ available: g(100000000), count: 1 }), null);
  assert.equal(planEqual({ available: g(100000000), count: MAX_COINS + 1 }), null);
  // Rounding never makes a BEAM coin too small: 0.00325 in 2 keeps the unrounded size.
  assert.equal(planEqual({ available: g(350000), count: 2 }).size, 110000n);
  assert.equal(planEqual({ available: g(325000), count: 2 }).size, 101250n);
});

test("an asset split spends the asset; the fee is BEAM's", () => {
  const p = planEqual({ available: g(1000), count: 4, assetId: 174 });
  assert.equal(p.size, 220n);
  assert.equal(p.fee, splitFee(4, { asset: true }));
  assert.equal(p.change, 120n, 'the fee is not taken from FOMO');
  assert.match(SPLIT_TEXT.reviewNote('FOMO', true), /network fee, in BEAM\.$/);
});

test('an exact split is checked like any other', () => {
  const p = planSized({ available: g(10000000), count: 3, size: g(1666666) });
  assert.deepEqual([...p.coins], [1666666n, 1666666n, 1666666n]);
  assert.equal(p.fee, 100000n);
  assert.equal(p.change, 10000000n - 4999998n - 100000n);
  assert.equal(planSized({ available: g(4999998), count: 3, size: g(1666666) }), null, 'no room for the fee');
  assert.equal(planSized({ available: g(10000000), count: 3, size: g(100000) }), null, 'a coin worth only a send fee');
});

test('the counts on offer: the presets plus the advised count', () => {
  assert.deepEqual(countChoices(0), [2, 3, 5, 8, 10]);
  assert.deepEqual(countChoices(5), [2, 3, 5, 8, 10]);
  assert.deepEqual(countChoices(4), [2, 3, 4, 5, 8, 10]);
  assert.deepEqual(countChoices(7), [2, 3, 5, 7, 8, 10]);
  assert.equal(countBySize(g(100000000)), 3);
  assert.equal(countBySize(g(4500000000)), 5);
  assert.equal(countBySize(g(50000000000)), 10);
});

test('advice (BEAM Light Wallet thresholds), dust left out', () => {
  assert.deepEqual(splitAdvice(coinsOf([100000000])), { urgency: 'needed', suggestedCount: 3 });
  assert.equal(splitAdvice(coinsOf([4500000000])).suggestedCount, 5);
  const dusty = coinsOf([100000000, 50000, 50000]);
  assert.equal(dusty.available.length, 3);
  assert.equal(dusty.usable.length, 1);
  assert.equal(splitAdvice(dusty).urgency, 'needed');
  assert.equal(dusty.largestShare, 1);
  assert.deepEqual(splitAdvice(coinsOf([85000000, 15000000])), { urgency: 'worthIt', suggestedCount: 4 });
  assert.equal(splitAdvice(coinsOf([70000000, 30000000])).urgency, 'none');
  assert.deepEqual(splitAdvice(coinsOf([95000000, 2000000, 2000000, 1000000])), { urgency: 'worthIt', suggestedCount: 3 });
  assert.equal(splitAdvice(coinsOf([50000000, 30000000, 20000000])).urgency, 'none');
  assert.equal(splitAdvice(coinsOf([300000])).urgency, 'none');
  assert.deepEqual(splitAdvice(coinsOf([400000])), { urgency: 'needed', suggestedCount: 2 });
  assert.deepEqual(splitAdvice(coinsOf([2500000000], 174)), { urgency: 'needed', suggestedCount: 3 });
  assert.equal(splitAdvice(emptySummary(0)).urgency, 'none');
});

test('the count shown: the picked one, else the advice, else 3; only counts that work', () => {
  const one = coinsOf([100000000]);
  assert.deepEqual(countsFor(one), [2, 3, 5, 8, 10]);
  assert.equal(chosenCount(one), 3);
  assert.equal(chosenCount(one, 8), 8);
  assert.equal(chosenCount(one, 49), 3, 'a count not on offer falls back');
  const small = coinsOf([400000]);
  assert.deepEqual(countsFor(small), [2]);
  assert.equal(chosenCount(small), 2);
  assert.equal(chosenCount(coinsOf([300000])), null);
});

test('words: now, the coin list, each coin', () => {
  assert.equal(SPLIT_TEXT.now(coinsOf([123450000]), 'BEAM'), '1.2345 BEAM in 1 coin: one payment at a time');
  assert.equal(SPLIT_TEXT.now(coinsOf([75000000, 25000000]), 'BEAM'), '1 BEAM in 2 coins; the largest holds 75%');
  assert.equal(SPLIT_TEXT.now(emptySummary(0), 'BEAM'), 'Nothing to split yet');
  const s = coinSummary([coin(0, 10, 'available'), coin(0, 5, 'maturing'), coin(0, 7, 'incoming')]).get(0);
  assert.equal(COIN_TEXT.summary(s), '1 ready to spend · 2 not yet');
  assert.equal(coinStatusText(coin(0, 50000, 'available')), 'Too small to be worth spending');
  assert.equal(coinStatusText(coin(0, 5000000, 'available')), 'Ready to spend');
  assert.equal(coinStatusText(coin(0, 5000000, 'available', { type: 'shld' })), 'Ready to spend · private');
  assert.equal(coinStatusText(coin(0, 5000000, 'maturing', { maturity: 4073500 })), 'Ready soon (after block 4,073,500)');
  assert.equal(coinStatusText(coin(0, 5000000, 'incoming')), 'Arriving');
  assert.equal(coinStatusText(coin(0, 5000000, 'outgoing')), "In a payment that hasn't finished");
  assert.equal(coinStatusText(coin(0, 5000000, 'unavailable')), 'Not spendable right now');
  for (const t of Object.values(SPLIT_TEXT)) if (typeof t === 'string') assert.doesNotMatch(t, /UTXO|utxo|shielded|Lelantus/);
});

test('private coins: spendable when the time limit has passed since they arrived (72 hours by default)', () => {
  assert.equal(PRIVATE_LIMIT_HOURS, 72);
  const mp = coin(0, 1000000, 'maturing', { type: 'shld', maturity: 4075082 });
  // 72 hours = 4,320 blocks after it arrived.
  assert.deepEqual(privateReady(mp, 4075082), { known: true, block: 4079402, hours: 72 });
  assert.deepEqual(privateReady(mp, 4075082 + 660), { known: true, block: 4079402, hours: 61 });
  assert.equal(privateReady(mp, 4079400).hours, 1);
  assert.equal(privateReady(mp, 4079500).hours, 0);
  assert.equal(privateReady(mp, null).known, false);
  assert.equal(privateWhen(privateReady(mp, 4075082 + 660)), 'in about 61 hours');
  assert.equal(privateWhen(privateReady(mp, 4079400)), 'within the hour');
  assert.equal(privateWhen(privateReady(mp, 4079500)), 'once enough other private payments follow it');
  assert.equal(privateWhen(null), 'within 72 hours of arriving');
  assert.equal(coinStatusText(mp, 4075082 + 660), 'Spendable in about 61 hours');
  assert.equal(coinStatusText(mp), 'Spendable within 72 hours of arriving');
  assert.equal(privateBalanceText(1000000n, 'BEAM', [mp], 4075082 + 660), '0.01 BEAM arrived privately: spendable in about 61 hours');
  const later = coin(0, 2000000, 'maturing', { type: 'shld', maturity: 4076000, id: 'later' });
  assert.equal(privateBalanceText(3000000n, 'BEAM', [mp, later], 4075082 + 660), '0.03 BEAM arrived privately: all of it spendable within about 77 hours');
  assert.equal(privateBalanceText(1000000n, 'BEAM', null, 4075742), '0.01 BEAM arrived privately: spendable within 72 hours of arriving');
});

test('a split in the history: told apart from payments, named as Beam PWA names it', () => {
  const split = { tx_type: 0, income: false, sender: '', receiver: '', status: 3, value: 50000000 };
  assert.equal(isSplitTx(split), true);
  assert.equal(isSplitTx({ ...split, receiver: '1c2d' }), false, 'a payment has a receiver');
  assert.equal(isSplitTx({ ...split, income: true }), false);
  assert.equal(isSplitTx({ ...split, tx_type: 7 }), false);
  assert.equal(isSplitTx({ ...split, tx_type: 12 }), false);
  assert.equal(splitStatusText(split), 'Split into coins');
  assert.equal(splitStatusText({ ...split, status: 1 }), 'Splitting coins');
  assert.equal(splitStatusText({ ...split, status: 5 }), 'Splitting coins');
  assert.equal(splitStatusText({ ...split, status: 4 }), 'Split failed');
  // Activity's own wording function says the same.
  assert.equal(txStatusText(split), 'Split into coins');
  assert.equal(txStatusText({ tx_type: 0, income: false, sender: 'a', receiver: 'b', status: 3 }), 'Sent');
});

test('reading every page of coins: until a short page, never a coin twice', async () => {
  const all = Array.from({ length: 7 }, (_, i) => parseCoin({ id: `c${i}`, amount: 1000000, type: 'norm', status_string: 'available' }));
  const asked = [];
  const read = await readAllCoins(async (skip, count) => {
    asked.push([skip, count]);
    const from = skip === 0 ? 0 : skip - 1; // the list moved under the read
    return all.slice(from, from + count);
  }, { pageSize: 3 });
  assert.deepEqual(asked, [[0, 3], [3, 3], [6, 3]]);
  assert.equal(read.length, 7);
});

/** A fake engine session: answers per method, records every call. */
function fakeSession(answers) {
  const calls = [];
  return {
    calls,
    async call(method, params) {
      calls.push({ method, params });
      const a = answers[method];
      if (typeof a === 'function') return a(params);
      return a;
    },
  };
}
const rpcError = (message, code = -32603) => Object.assign(new Error(message), { code: 'rpc', rpc: { code, message } });
const TXID = 'a'.repeat(32);
const plan = planEqual({ available: g(100000000), count: 5 });

test('tx_split: the id first, the plan as JSON numbers, the asset only when it is one', async () => {
  const s = fakeSession({ generate_tx_id: TXID, tx_split: (p) => ({ txId: p.txId }) });
  const hand = {};
  assert.equal(await splitCoins(s, plan, hand), TXID);
  assert.deepEqual(s.calls.map((c) => c.method), ['generate_tx_id', 'tx_split']);
  assert.deepEqual(s.calls[1].params, { coins: [17000000, 17000000, 17000000, 17000000, 17000000], fee: 118000, txId: TXID });
  assert.equal(hand.txId, TXID);
  const a = fakeSession({ generate_tx_id: TXID, tx_split: (p) => ({ txId: p.txId }) });
  await splitCoins(a, planEqual({ available: g(1000), count: 4, assetId: 174 }), {});
  assert.equal(a.calls[1].params.asset_id, 174);
});

test('tx_split: a plain refusal clears the hand-over (nothing started, it may be tried again)', async () => {
  const s = fakeSession({ generate_tx_id: TXID, tx_split: () => { throw rpcError('Not enough funds'); } });
  const hand = {};
  await assert.rejects(splitCoins(s, plan, hand), (e) => e instanceof SplitError && e.code === 'funds' && /Nothing left your wallet/.test(e.message));
  assert.equal(hand.txId, null);
});

test('tx_split: no answer is looked up, never split again; a split already handed over is only looked up', async () => {
  let splits = 0;
  const s = fakeSession({
    generate_tx_id: TXID,
    tx_split: () => {
      splits++;
      throw Object.assign(new Error('The wallet did not answer (tx_split).'), { code: 'timeout' });
    },
    tx_status: (p) => ({ txId: p.txId, status: 0 }),
  });
  const hand = {};
  assert.equal(await splitCoins(s, plan, hand), TXID);
  assert.equal(await splitCoins(s, plan, hand), TXID);
  assert.equal(splits, 1);
  assert.deepEqual(s.calls.map((c) => c.method), ['generate_tx_id', 'tx_split', 'tx_status', 'tx_status']);
  // Unknown to the engine after a lost answer: it says so, and does not try again.
  const lost = fakeSession({ generate_tx_id: TXID, tx_split: () => { throw Object.assign(new Error('x'), { code: 'timeout' }); }, tx_status: () => { throw rpcError('Unknown transaction ID', -32602); } });
  await assert.rejects(splitCoins(lost, plan, {}), (e) => e.code === 'unknown' && /Check Activity/.test(e.message));
  // "already exists": it did start.
  const dup = fakeSession({ generate_tx_id: TXID, tx_split: () => { throw rpcError('Transaction already exists'); }, tx_status: (p) => ({ txId: p.txId }) });
  assert.equal(await splitCoins(dup, plan, {}), TXID);
});

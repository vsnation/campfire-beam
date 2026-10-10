// The Buy BEAM controller over a fake buybeam.my and a fake clock (a port of
// the desktop app's test/beam/buy/buybeam_controller_test.dart): prices asked
// once typing pauses, the latest question only; a deposit address kept on this
// device before it is shown, a request with no answer sent again as it was;
// and each open buy followed as often as buybeam.my says, less often while it
// cannot be reached, never once it has ended.
import test from 'node:test';
import assert from 'node:assert/strict';
import { BuyBeamController } from '../../src/lib/buy/controller.js';
import { BuyBeamClient, BuyBeamAmount, assetFromJson } from '../../src/lib/buy/buybeam.js';
import { memoryBuyStore, makeOrder } from '../../src/lib/buy/store.js';
import { FakeBuyBeam, FakeClock, ASSETS, BTC, BEAM_ADDRESS, BEAM_ADDRESS_2, BTC_REFUND, answer, envelope, errorJson, statusJson, drain } from './buy_fakes.mjs';

const S = 1000;

function rig({ autoPoll = true, store = memoryBuyStore() } = {}) {
  const server = new FakeBuyBeam();
  const clock = new FakeClock();
  const controller = new BuyBeamController({ client: new BuyBeamClient({ fetch: server.fetch }), store, clock, autoPoll });
  const r = {
    server,
    clock,
    store,
    controller,
    made: 0,
    btc: assetFromJson(ASSETS.find((a) => a.asset_id === BTC)),
    newAddress: async () => {
      r.made++;
      return r.made === 1 ? BEAM_ADDRESS : BEAM_ADDRESS_2;
    },
    request: (text) => ({ asset: r.btc, amount: BuyBeamAmount.parse(text, 8).amount, refundAddress: BTC_REFUND }),
    place: (text = '0.0123') => controller.placeOrder({ asset: r.btc, amount: BuyBeamAmount.parse(text, 8).amount, refundAddress: BTC_REFUND, beamWalletId: 'w1', newBeamAddress: r.newAddress }),
  };
  return r;
}

function stored(deposit, { state = null, at = Date.UTC(2026, 9, 9, 11) } = {}) {
  return makeOrder({ depositAddress: deposit, assetId: BTC, symbol: 'BTC', chain: 'btc', decimals: 8, sendAmount: '0.0123', sendAmountRaw: 1230000n, beamAddress: BEAM_ADDRESS, beamWalletId: 'w1', refundAddress: BTC_REFUND, createdAt: at, lastState: state, terminal: ['delivered', 'refunded', 'expired', 'failed'].includes(state) });
}

test('quotes: asked once typing pauses for 400 ms', async () => {
  const r = rig();
  r.controller.requestQuote(r.request('0.0123'));
  assert.equal(r.controller.quoting, true);
  await r.clock.advance(399);
  assert.equal(r.server.count('/quote'), 0);
  await r.clock.advance(1);
  assert.equal(r.server.count('/quote'), 1);
  assert.equal(r.controller.quoting, false);
  assert.ok(r.controller.quote.beamEstimate > 0);
  // Typing again before the pause ends asks once, for the last amount.
  r.controller.requestQuote(r.request('0.02'));
  await r.clock.advance(200);
  r.controller.requestQuote(r.request('0.03'));
  await r.clock.advance(400);
  assert.equal(r.server.count('/quote'), 2);
  assert.equal(r.server.requests.at(-1).url.searchParams.get('amount'), '0.03');
});

test('quotes: a slow answer to an older question is dropped', async () => {
  const r = rig();
  let release;
  r.server.holdQuotes = new Promise((res) => (release = res));
  r.controller.requestQuote(r.request('0.0123'));
  await r.clock.advance(400);
  r.server.holdQuotes = null;
  r.controller.requestQuote(r.request('0.05'));
  await r.clock.advance(400);
  const latest = r.controller.quote;
  release();
  await drain();
  assert.equal(r.controller.quote, latest);
  assert.equal(r.controller.quoteRequest.amount.text, '0.05');
});

test('quotes: clearing drops a price on its way', async () => {
  const r = rig();
  r.controller.requestQuote(r.request('0.0123'));
  r.controller.requestQuote(null);
  await r.clock.advance(1000);
  assert.equal(r.server.count('/quote'), 0);
  assert.equal(r.controller.quoting, false);
  assert.equal(r.controller.quote, null);
});

test("the smallest-buy hint: buybeam.my's observed figure, else a refused price's, else its floor", async () => {
  const r = rig();
  assert.equal(r.controller.minimumHintUsd, null);
  r.controller.requestQuote(r.request('0.001'));
  await r.clock.advance(400);
  assert.equal(r.controller.quoteError.code, 'amount_below_upstream_minimum');
  assert.equal(r.controller.quoteError.minimumUsd, 1000);
  assert.equal(r.controller.minimumHintUsd, 1000);
  r.server.queue('/limits', envelope({ our_minimum_usd: 5, upstream_observed_minimum_usd: 1100 }));
  await r.controller.refreshLimits();
  assert.equal(r.controller.minimumHintUsd, 1100);
  r.server.offline = true;
  await r.controller.refreshLimits();
  assert.equal(r.controller.minimumHintUsd, 1100, 'the last hint is kept');
});

test('orders: the buy is in the store before placeOrder returns', async () => {
  const r = rig();
  const o = await r.place();
  assert.equal(r.store.writes.length, 1);
  assert.equal(r.store.writes[0].depositAddress, o.depositAddress);
  assert.equal(o.beamAddress, BEAM_ADDRESS);
  assert.equal(o.lastState, 'awaiting_deposit');
  assert.equal(o.sendAmount, '0.0123');
  assert.equal(o.deadline, 1791579600000);
  assert.deepEqual(r.controller.orders('w1').map((x) => x.depositAddress), [o.depositAddress]);
  assert.deepEqual(r.controller.orders('other'), []);
});

test('orders: a POST that got no answer is sent again as it was: the same order comes back', async () => {
  const r = rig();
  r.server.queue('/order', new TypeError('Failed to fetch'));
  r.server.queue('/order', answer(403, '<html>Blocked</html>', { 'content-type': 'text/html' }));
  const o = await r.place();
  const posts = r.server.requests.filter((q) => q.method === 'POST');
  assert.equal(posts.length, 3);
  assert.equal(new Set(posts.map((p) => JSON.stringify(p.body))).size, 1);
  assert.equal(r.made, 1);
  assert.equal(o.depositAddress, r.server.depositAddress);
});

test('orders: still no answer: the error, and "Try again" reuses the BEAM address', async () => {
  const r = rig();
  r.server.offline = true;
  await assert.rejects(r.place(), (e) => e.code === 'network');
  assert.equal(r.server.count('/order'), 3);
  r.server.offline = false;
  const o = await r.place();
  assert.equal(r.made, 1);
  assert.equal(o.beamAddress, BEAM_ADDRESS);
  assert.equal(new Set(r.server.requests.filter((q) => q.method === 'POST').map((q) => JSON.stringify(q.body))).size, 1);
});

test('orders: an answer for another order is neither kept nor shown, and not asked again', async () => {
  const r = rig();
  r.server.queue('/order', envelope({ deposit_address: 'd', asset_id: BTC, send_amount_raw: '1230000', beam_wallet: BEAM_ADDRESS_2, payable: true }));
  await assert.rejects(r.place(), (e) => e.code === 'unexpected_answer');
  assert.equal(r.store.writes.length, 0);
  assert.deepEqual(r.controller.orders(), []);
  assert.equal(r.server.count('/order'), 1);
});

test('following: looked at every poll_after_seconds until it ends, never again after', async () => {
  const r = rig();
  const o = await r.place();
  const path = `/order/${o.depositAddress}`;
  assert.equal(r.server.count(path), 0);
  await r.clock.advance(14 * S);
  assert.equal(r.server.count(path), 0);
  await r.clock.advance(1 * S);
  assert.equal(r.server.count(path), 1);
  r.server.queue(path, statusJson('buying', { deposit: o.depositAddress, pollAfter: 5 }));
  await r.clock.advance(15 * S);
  assert.equal(r.server.count(path), 2);
  assert.equal(r.controller.order(o.depositAddress).lastState, 'buying');
  await r.clock.advance(5 * S);
  assert.equal(r.server.count(path), 3);
  r.server.state = 'delivered';
  r.server.txId = 'beamtx1';
  await r.clock.advance(15 * S);
  assert.equal(r.server.count(path), 4);
  const done = r.controller.order(o.depositAddress);
  assert.equal(done.lastState, 'delivered');
  assert.equal(done.terminal, true);
  assert.equal(done.beamTxId, 'beamtx1');
  assert.equal(r.controller.dueAt(o.depositAddress), null);
  await r.clock.advance(3600 * S);
  assert.equal(r.server.count(path), 4);
  assert.equal(r.clock.pending, 0);
});

test('following: an unknown state keeps it followed', async () => {
  const r = rig();
  const o = await r.place();
  r.server.state = 'settling_in_v2';
  await r.clock.advance(15 * S);
  assert.equal(r.controller.order(o.depositAddress).lastState, 'in_progress');
  assert.equal(r.controller.order(o.depositAddress).isOpen, true);
  await r.clock.advance(15 * S);
  assert.equal(r.server.count(`/order/${o.depositAddress}`), 2);
});

test('following: no answer, looked at less often; retry_after honoured; back to normal once answered', async () => {
  const r = rig();
  const o = await r.place();
  const path = `/order/${o.depositAddress}`;
  r.server.offline = true;
  await r.clock.advance(15 * S);
  assert.equal(r.controller.pollError(o.depositAddress).code, 'network');
  assert.equal(r.controller.dueAt(o.depositAddress), r.clock.now() + 30 * S);
  await r.clock.advance(30 * S);
  assert.equal(r.controller.dueAt(o.depositAddress), r.clock.now() + 60 * S);
  r.server.offline = false;
  r.server.queue(path, answer(503, errorJson('upstream_unavailable', { retryAfter: 600 })));
  await r.clock.advance(60 * S);
  assert.equal(r.controller.dueAt(o.depositAddress), r.clock.now() + 600 * S);
  const before = r.server.requests.length;
  await r.clock.advance(599 * S);
  assert.equal(r.server.requests.length, before);
  await r.clock.advance(1 * S);
  assert.equal(r.server.requests.length, before + 1);
  assert.equal(r.controller.pollError(o.depositAddress), null);
  assert.equal(r.controller.dueAt(o.depositAddress), r.clock.now() + 15 * S);
});

test('following: the open buys kept on this device are followed on start; ended ones are not', async () => {
  const store = memoryBuyStore();
  await store.save(stored('open1', { state: 'buying' }));
  await store.save(stored('done1', { state: 'delivered' }));
  const r = rig({ store });
  r.server.depositAddress = 'open1';
  r.server.state = 'sending';
  await r.controller.resumeAll();
  await r.clock.advance(0);
  assert.equal(r.server.count('/order/open1'), 1);
  assert.equal(r.server.count('/order/done1'), 0);
  assert.equal(r.controller.order('open1').lastState, 'sending');
  assert.equal(store.writes.at(-1).lastState, 'sending');
  assert.equal(r.controller.orders().length, 2);
  await r.controller.resumeAll();
  await r.clock.advance(0);
  assert.equal(r.server.count('/order/open1'), 1, 'starting twice follows them once');
});

test('following: nothing while paused; resume catches up; autoPoll off waits for pollDue', async () => {
  const r = rig();
  const o = await r.place();
  r.controller.pause();
  await r.clock.advance(300 * S);
  assert.equal(r.server.count(`/order/${o.depositAddress}`), 0);
  r.controller.resume();
  await r.clock.advance(0);
  assert.equal(r.server.count(`/order/${o.depositAddress}`), 1);

  const m = rig({ autoPoll: false });
  const o2 = await m.place();
  await m.clock.advance(300 * S);
  assert.equal(m.server.count(`/order/${o2.depositAddress}`), 0);
  assert.equal(m.clock.pending, 0);
  await m.controller.pollDue();
  assert.equal(m.server.count(`/order/${o2.depositAddress}`), 1);
});

test('following: the state is written only when it changes; dispose stops everything', async () => {
  const r = rig({ autoPoll: false });
  const o = await r.place();
  await r.controller.poll(o.depositAddress);
  await r.controller.poll(o.depositAddress);
  assert.equal(r.store.writes.length, 1);
  r.server.state = 'deposit_detected';
  await r.controller.poll(o.depositAddress);
  assert.equal(r.store.writes.length, 2);
  assert.equal(r.store.writes.at(-1).lastState, 'deposit_detected');

  const d = rig();
  await d.place();
  let told = 0;
  d.controller.onChange(() => told++);
  d.controller.dispose();
  await d.clock.advance(3600 * S);
  assert.equal(d.server.count('/order/'), 0);
  assert.equal(told, 0);
});

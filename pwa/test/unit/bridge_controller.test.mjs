// The bridge controller (lib/bridge/controller.js) over fake halves
// (helpers/bridge_fakes.mjs): every rule a quote follows, both directions end
// to end, finding the BEAM message a send made, a wallet that throws after it
// may have sent (never sent again), a restart in the middle, one message per
// crossing, and the slow ways a crossing can go. A port of the desktop's
// test/beam/bridge/bridge_controller_test.dart, adapted where the web wallet
// works differently: the BEAM transactions ask for consent inside the wallet's
// own app, an Ethereum transaction is signed and written before it is
// broadcast (and its identical bytes re-sent when the server forgets it), and
// nothing is collected automatically.
import test from 'node:test';
import assert from 'node:assert/strict';
import { BridgeController, nothingSent, sameBlock, beamSide } from '../../src/lib/bridge/controller.js';
import { MemoryBridgeStore, STATES, makeCrossing } from '../../src/lib/bridge/store.js';
import { routeById, SEND_FEE, CLAIM_FEE } from '../../src/lib/bridge/routes.js';
import { e2bRelayerFee } from '../../src/lib/bridge/fees.js';
import { BLOCKS, totalSource, TIMING } from '../../src/lib/bridge/quote.js';
import { FakeClock, FakeBeamSide, FakeEthSide, FakePrices, FAKE_ETH_ADDRESS, beams, ethUnits, b2eFee, PRICES } from './helpers/bridge_fakes.mjs';

const toEth = 'toEthereum';
const toBeam = 'toBeam';
const beamRoute = routeById('beam');
const ethRoute = routeById('eth');
const usdtRoute = routeById('usdt');
const wbtcRoute = routeById('wbtc');
const daiRoute = routeById('dai');
const S = 1000;
const MIN = 60 * S;

class Rig {
  constructor({ beam, eth, store, clock } = {}) {
    this.clock = clock || new FakeClock();
    this.beam = beam || new FakeBeamSide();
    this.eth = eth || new FakeEthSide({ clock: this.clock });
    this.eth.clock = this.clock;
    this.prices = new FakePrices(this.clock);
    this.store = store || new MemoryBridgeStore();
    this.c = this.controller();
  }

  controller() {
    const c = new BridgeController({ beam: this.beam, eth: this.eth, prices: this.prices, store: this.store, beamWalletId: 'beam-wallet', ethWalletId: 'eth-wallet', clock: this.clock, autoPoll: false });
    c.setActive({ visible: true, unlocked: true });
    return c;
  }

  quote(r, d, a) {
    return this.c.quote(r, d, a);
  }

  /** Quote, prepare and start a of r going d; waits for its Ethereum steps. */
  async move(r, d, a) {
    const q = await this.quote(r, d, a);
    assert.equal(q.block, null, JSON.stringify(q.block));
    const x = await this.c.start(await this.c.prepare(q));
    await this.c.idle();
    return this.c.crossing(x.id);
  }

  /** Advances the clock by ms and polls whatever is due. */
  async after(ms, id) {
    this.clock.advance(ms);
    await this.c.pollDue();
    await this.c.idle();
    return this.c.crossing(id);
  }

  sends() {
    return this.beam.calls.filter((c) => c.startsWith('send') || c.startsWith('claim'));
  }
}

const code = (c) => (e) => e && e.code === c;
const flush = () => new Promise((r) => setImmediate(r));

// ---------------------------------------------------------------- quote, to Ethereum

test('quote to Ethereum: the BEAM fee follows the relayer (96,000 gas, ×1.3, ~72.57 BEAM)', async () => {
  const rig = new Rig();
  const q = await rig.quote(beamRoute, toEth, beams(1000));
  assert.equal(q.block, null);
  assert.equal(q.fee, b2eFee(beamRoute));
  assert.equal(q.fee / 1000000n, 7256n); // 72.56…
  assert.equal(q.amount, beams(1000));
  assert.equal(q.receives, beams(1000)); // WBEAM: 8 decimals both sides
  assert.equal(q.beamNetworkFee, SEND_FEE);
  assert.equal(q.ethAddress, FAKE_ETH_ADDRESS);
  assert.equal(totalSource(q), beams(1000) + q.fee + SEND_FEE);
  assert.deepEqual(q.warnings, []);
  assert.ok(q.feeNow < q.fee, 'the margin is on top of the relayer’s own price');
});

test('quote to Ethereum: an amount is floored to the route grid (USDT: 100 groth)', async () => {
  const q = await new Rig().quote(usdtRoute, toEth, 1234567891n);
  assert.equal(q.amount, 1234567800n);
  assert.equal(q.receives, 12345678n); // 12.345678 USDT
  assert.equal(q.fee % 100n, 0n);
});

test('quote to Ethereum: a fee as large as the amount blocks it; above a tenth it is pointed out', async () => {
  const rig = new Rig();
  const q = await rig.quote(beamRoute, toEth, beams(50));
  assert.equal(q.block.code, BLOCKS.belowFee);
  assert.equal(q.block.title, 'The bridge fee is more than the amount');
  assert.equal(q.canMove, false);
  const w = await rig.quote(beamRoute, toEth, beams(500));
  assert.equal(w.block, null);
  assert.equal(w.warnings.length, 1);
  assert.equal(w.warnings[0].code, 'highFee');
  assert.match(w.warnings[0].title, /^The bridge fee is 15%/);
});

test('quote to Ethereum: more than 3,000,000 BEAM in one move is refused', async () => {
  const rig = new Rig({ beam: new FakeBeamSide({ available: { 0: beams(4000000) } }) });
  const q = await rig.quote(beamRoute, toEth, beams(3000001));
  assert.equal(q.block.code, BLOCKS.aboveMax);
  assert.equal(q.block.title, 'At most 3,000,000 BEAM per move');
  assert.equal((await rig.quote(beamRoute, toEth, beams(2999000))).block, null);
  // Prepare refuses it too, should a quote ever slip through.
  const bad = { ...(await rig.quote(beamRoute, toEth, beams(2999000))), amount: beams(3000001) };
  await assert.rejects(rig.c.prepare(bad), code('badAmount'));
});

test('quote to Ethereum: BEAM needs amount + fee + 0.011; a wrapped asset needs 0.011 BEAM besides it', async () => {
  const q = await new Rig({ beam: new FakeBeamSide({ available: { 0: beams(1072.5) } }) }).quote(beamRoute, toEth, beams(1000));
  assert.equal(q.block.code, BLOCKS.notEnough);
  assert.match(q.block.detail, /Your wallet has 1,072\.5 BEAM/);
  const noFee = await new Rig({ beam: new FakeBeamSide({ available: { 0: 0n, 37: beams(250) } }) }).quote(usdtRoute, toEth, beams(100));
  assert.equal(noFee.block.code, BLOCKS.noBeamForFee);
  const short = await new Rig({ beam: new FakeBeamSide({ available: { 0: beams(1), 37: beams(100) } }) }).quote(usdtRoute, toEth, beams(100));
  assert.equal(short.block.code, BLOCKS.notEnough);
});

test('quote to Ethereum: a frozen route says why; a freeze that cannot be read blocks too', async () => {
  const rig = new Rig();
  rig.eth.frozen.set('beam', [{ reason: 'WBEAM is paused by its issuer' }]);
  const q = await rig.quote(beamRoute, toEth, beams(1000));
  assert.equal(q.block.code, BLOCKS.frozen);
  assert.equal(q.block.detail, 'WBEAM is paused by its issuer');
  const unsure = new Rig();
  unsure.eth.freezeFails = true;
  assert.equal((await unsure.quote(usdtRoute, toEth, beams(100))).block.code, BLOCKS.network);
});

test('quote to Ethereum: no price, a missing price or a stale one: no quote', async () => {
  const none = new Rig();
  none.prices.fail = true;
  assert.equal((await none.quote(beamRoute, toEth, beams(1000))).block.code, BLOCKS.noPrice);
  const missing = new Rig();
  missing.prices.missing.add('tether');
  assert.equal((await missing.quote(usdtRoute, toEth, beams(100))).block.code, BLOCKS.noPrice);
  const stale = new Rig();
  stale.prices.ageMs = 11 * MIN;
  assert.equal((await stale.quote(beamRoute, toEth, beams(1000))).block.code, BLOCKS.noPrice);
  const fresh = new Rig();
  fresh.prices.ageMs = 9 * MIN;
  assert.equal((await fresh.quote(beamRoute, toEth, beams(1000))).block, null);
});

test('quote to Ethereum: Max keeps the fee and the network fee back', async () => {
  const rig = new Rig({ beam: new FakeBeamSide({ available: { 0: beams(1000) } }) });
  const max = await rig.c.maxAmount(beamRoute, toEth);
  assert.equal(max, beams(1000) - b2eFee(beamRoute) - SEND_FEE);
  assert.equal((await rig.quote(beamRoute, toEth, max)).block, null);
});

test('quote: conditions are read at most once a minute', async () => {
  const rig = new Rig();
  await rig.quote(beamRoute, toEth, beams(1000));
  await rig.quote(beamRoute, toEth, beams(2000));
  assert.equal(rig.prices.asked, 1);
  rig.clock.advance(MIN);
  await rig.quote(beamRoute, toEth, beams(1000));
  assert.equal(rig.prices.asked, 2);
});

// ---------------------------------------------------------------- quote, to BEAM

test('quote to BEAM: ETH floored to 10^10 wei, 0.02 BEAM worth of fee, one transaction', async () => {
  const rig = new Rig();
  const q = await rig.quote(ethRoute, toBeam, 1234567891234567n);
  assert.equal(q.block, null);
  assert.equal(q.amount, 1234560000000000n); // 0.00123456 ETH
  assert.equal(q.receives, 123456n); // groth of bETH
  assert.equal(q.fee, e2bRelayerFee(ethRoute, PRICES));
  assert.equal(q.fee % ethRoute.ethGrid, 0n);
  assert.equal(q.plan.steps.length, 1);
  assert.equal(q.beamNetworkFee, CLAIM_FEE);
  assert.deepEqual(q.receiveKey, FakeBeamSide.keyFor(ethRoute));
  assert.equal(totalSource(q), q.amount + q.fee + q.plan.maxGasCost);
});

test('quote to BEAM: value + fee must be in the wallet; ETH for the network fee, with the value on the ETH route', async () => {
  assert.equal((await new Rig().quote(usdtRoute, toBeam, 500000000n)).block.code, BLOCKS.notEnough);
  // 0.01 ETH + fee + 40,000 gas × 1.8321 gwei > 0.01005 ETH.
  const rig = new Rig();
  rig.eth.ethBal = ethUnits(0.01005);
  const q = await rig.quote(ethRoute, toBeam, ethUnits(0.01));
  assert.equal(q.block.code, BLOCKS.noEthForGas);
  assert.equal(q.block.title, 'Not enough ETH');
  const t = new Rig();
  t.eth.ethBal = 100000000000000n;
  const u = await t.quote(usdtRoute, toBeam, 100000000n);
  assert.equal(u.block.code, BLOCKS.noEthForGas);
  assert.equal(u.block.title, 'Not enough ETH for the Ethereum network fee');
});

test('quote to BEAM: a BEAM wallet without 0.121 BEAM cannot collect: blocked, with the next step', async () => {
  const q = await new Rig({ beam: new FakeBeamSide({ available: { 0: beams(0.12) } }) }).quote(usdtRoute, toBeam, 100000000n);
  assert.equal(q.block.code, BLOCKS.noClaimFee);
  assert.match(q.block.title, /0\.121 BEAM/);
  assert.match(q.block.detail, /Receive a little BEAM first/);
});

test('quote to BEAM: a frozen token blocks the way back too; WBEAM needs no price (its fee is 0.02 WBEAM)', async () => {
  const rig = new Rig();
  rig.eth.frozen.set('usdt', [{ reason: "Tether has frozen the bridge's USDT" }]);
  assert.equal((await rig.quote(usdtRoute, toBeam, 100000000n)).block.code, BLOCKS.frozen);
  const w = new Rig();
  w.prices.fail = true;
  const q = await w.quote(beamRoute, toBeam, beams(100));
  assert.equal(q.block, null);
  assert.equal(q.fee, 2000000n);
  assert.equal(q.prices, null);
  const old = new Rig();
  old.prices.ageMs = 59 * MIN;
  assert.equal((await old.quote(ethRoute, toBeam, ethUnits(0.01))).block, null, 'an hour-old price will do to BEAM');
  old.prices.ageMs = 61 * MIN;
  assert.equal((await old.quote(ethRoute, toBeam, ethUnits(0.01))).block, null, 'conditions kept a minute');
  old.clock.advance(MIN);
  assert.equal((await old.quote(ethRoute, toBeam, ethUnits(0.01))).block.code, BLOCKS.noPrice);
});

test('quote to BEAM: a token without allowance plans an exact approval first; USDT resets a stale one', async () => {
  const rig = new Rig();
  assert.deepEqual((await rig.quote(daiRoute, toBeam, ethUnits(10))).plan.steps.map((s) => s.kind), ['approve', 'lock']);
  rig.eth.allowance.set('usdt', 5n);
  assert.deepEqual((await rig.quote(usdtRoute, toBeam, 100000000n)).plan.steps.map((s) => s.kind), ['approveReset', 'approve', 'lock']);
});

test('quote to BEAM: a receive key Campfire does not trust: no quote', async () => {
  const rig = new Rig();
  rig.beam.keyFails = true;
  const q = await rig.quote(ethRoute, toBeam, ethUnits(0.01));
  assert.equal(q.block.code, BLOCKS.network);
  assert.equal(q.block.title, "Couldn't check the bridge from these wallets");
  assert.equal(q.plan, null);
});

// ---------------------------------------------------------------- to Ethereum, end to end

test('to Ethereum: send → mined → its message → 61 blocks → paid (the relayer pays; nothing to collect)', async () => {
  const rig = new Rig();
  rig.beam.addLocal(beamRoute, { amount: beams(10), fee: beams(70), height: 4072700 }); // someone else's
  let storedAtSend = null;
  rig.beam.onSend = () => {
    storedAtSend = [...rig.store.byIdMap.values()].map((c) => c.state);
  };
  let x = await rig.move(beamRoute, toEth, beams(1000));
  assert.deepEqual(storedAtSend, ['sending'], 'written before sending');
  assert.equal(x.state, STATES.sent);
  assert.equal(x.countBefore, 1);
  assert.match(x.beamTxId, /^b+0+1$/);
  assert.equal(x.beamNetworkFee, SEND_FEE);
  assert.equal((await rig.store.byId(x.id)).beamTxId, x.beamTxId);
  x = await rig.after(20 * S, x.id);
  assert.equal(x.state, STATES.sent, 'not mined yet');

  rig.beam.mine(x.beamTxId, 4072810);
  rig.beam.tip = 4072810;
  x = await rig.after(20 * S, x.id);
  assert.equal(x.state, STATES.confirmed);
  assert.equal(x.msgId, 2);
  assert.equal(x.height, 4072810);
  assert.equal(rig.c.blocksLeft(x), 61);

  rig.beam.tip = 4072840;
  x = await rig.after(MIN, x.id);
  assert.equal(rig.c.blocksLeft(x), 31);
  assert.equal(x.dueAt, null);
  rig.beam.tip = 4072871;
  x = await rig.after(MIN, x.id);
  assert.equal(x.state, STATES.confirmed);
  assert.notEqual(x.dueAt, null);
  rig.eth.paid.add(2);
  x = await rig.after(MIN, x.id);
  assert.equal(x.state, STATES.paid);
  assert.notEqual(x.finishedAt, null);
  assert.equal((await rig.store.byId(x.id)).state, STATES.paid);
  assert.deepEqual(rig.sends(), ['send beam']);
});

test('to Ethereum: its message is the one with this receiver, amount, fee and block, among several', async () => {
  const rig = new Rig();
  const fee = b2eFee(beamRoute);
  const x = await rig.move(beamRoute, toEth, beams(1000));
  assert.equal(x.countBefore, 0);
  rig.beam.addLocal(beamRoute, { amount: beams(1000), fee, height: 4072811 });
  rig.beam.addLocal(beamRoute, { receiver: FAKE_ETH_ADDRESS, amount: beams(999), fee, height: 4072811 });
  rig.beam.addLocal(beamRoute, { receiver: FAKE_ETH_ADDRESS, amount: beams(1000), fee, height: 4072790 }); // same everything, another block
  rig.beam.mine(x.beamTxId, 4072811); // ours: message 4
  rig.beam.addLocal(beamRoute, { amount: beams(5), fee, height: 4072812 });
  rig.beam.calls.length = 0;
  const found = await rig.after(20 * S, x.id);
  assert.equal(found.msgId, 4);
  // Scanned from the top (5) down to countBefore + 1, no further.
  assert.deepEqual(rig.beam.calls.filter((c) => c.startsWith('localMessage')), [5, 4, 3, 2, 1].map((i) => `localMessage beam ${i}`));
});

test('to Ethereum: its message is stamped one block below the transaction, as on mainnet; two below is not it', async () => {
  const rig = new Rig();
  const fee = b2eFee(beamRoute);
  let x = await rig.move(beamRoute, toEth, beams(1000));
  rig.beam.status.set(x.beamTxId, { state: 'completed', height: 4072998, reason: null });
  rig.beam.addLocal(beamRoute, { receiver: FAKE_ETH_ADDRESS, amount: beams(1000), fee, height: 4072996 });
  x = await rig.after(20 * S, x.id);
  assert.equal(x.state, STATES.sent);
  assert.equal(x.msgId, null);
  rig.beam.addLocal(beamRoute, { receiver: FAKE_ETH_ADDRESS, amount: beams(1000), fee, height: 4072997 });
  x = await rig.after(20 * S, x.id);
  assert.equal(x.state, STATES.confirmed);
  assert.equal(x.msgId, 2);
  assert.equal(x.height, 4072998);
  assert.ok(sameBlock(4072997, 4072998) && sameBlock(4072998, 4072998) && !sameBlock(4072996, 4072998));
});

test('to Ethereum: a failed BEAM transaction: failed, nothing left the wallet', async () => {
  const rig = new Rig();
  let x = await rig.move(usdtRoute, toEth, beams(100));
  rig.beam.status.set(x.beamTxId, { state: 'failed', height: null, reason: 'rejected' });
  x = await rig.after(20 * S, x.id);
  assert.equal(x.state, STATES.failed);
  assert.equal(x.lastError, 'rejected');
});

test('to Ethereum: the person declines the consent sheet: failed, nothing left the wallet, nothing followed', async () => {
  const rig = new Rig();
  rig.beam.mode = 'reject';
  const x = await rig.move(usdtRoute, toEth, beams(100));
  assert.equal(x.state, STATES.failed);
  assert.match(x.lastError, /did not approve/);
  assert.equal((await rig.store.byId(x.id)).state, STATES.failed);
  assert.ok(nothingSent({ code: 'rejected' }) && nothingSent({ code: 'unexpected', message: 'The bridge transfer the wallet built is not the one you asked for. Nothing was sent.' }));
  assert.ok(!nothingSent({ code: 'unexpected', message: 'The wallet did not return a transaction id.' }) && !nothingSent({ code: 'timeout' }) && !nothingSent(null));
});

test('to Ethereum: not paid 30 minutes after it was due: waiting for gas, then paid', async () => {
  const rig = new Rig();
  let x = await rig.move(beamRoute, toEth, beams(1000));
  rig.beam.mine(x.beamTxId, 4072810);
  rig.beam.tip = 4072871;
  x = await rig.after(20 * S, x.id);
  assert.equal(x.state, STATES.confirmed);
  x = await rig.after(29 * MIN, x.id);
  assert.equal(x.state, STATES.confirmed);
  x = await rig.after(2 * MIN, x.id);
  assert.equal(x.state, STATES.waitingForGas);
  rig.eth.paid.add(x.msgId);
  x = await rig.after(MIN, x.id);
  assert.equal(x.state, STATES.paid);
});

test('to Ethereum: the wallet throws after it may have sent: unknown, never sent again, found by its message', async () => {
  const rig = new Rig();
  rig.beam.mode = 'throwAfterBroadcast';
  let x = await rig.move(beamRoute, toEth, beams(1000));
  assert.equal(x.state, STATES.unknown);
  assert.equal(x.beamTxId, null);
  assert.equal(x.lastError, 'no answer');
  x = await rig.after(MIN, x.id);
  assert.equal(x.state, STATES.unknown, 'nothing on BEAM yet, and nothing sent again');
  const [txId] = rig.beam.executed.keys();
  rig.beam.mine(txId, 4072815);
  rig.beam.tip = 4072820;
  x = await rig.after(MIN, x.id);
  assert.equal(x.state, STATES.confirmed);
  assert.equal(x.msgId, 1);
  assert.equal(x.height, 4072815);
  assert.deepEqual(rig.sends(), ['send beam']);
});

test('to Ethereum: a prepared send is sent at most once; a review left for 16 minutes is checked again first', async () => {
  const rig = new Rig();
  const p = await rig.c.prepare(await rig.quote(beamRoute, toEth, beams(1000)));
  await rig.c.start(p);
  await assert.rejects(rig.c.start(p), code('alreadySent'));
  const late = new Rig();
  const old = await late.c.prepare(await late.quote(beamRoute, toEth, beams(1000)));
  late.clock.advance(16 * MIN);
  await assert.rejects(late.c.start(old), code('reviewExpired'));
  assert.deepEqual(late.sends(), []);
});

// ---------------------------------------------------------------- to BEAM, end to end

test('to BEAM, ETH: lock → mined → delivered → ready to collect, and only an explicit collect claims it', async () => {
  const rig = new Rig();
  let x = await rig.move(ethRoute, toBeam, ethUnits(0.01));
  assert.equal(x.state, STATES.locking);
  assert.notEqual(x.lockHash, null);
  assert.equal(rig.eth.signed.length, 1);
  assert.equal(rig.eth.signed[0].value, x.amount + x.relayerFee);
  assert.equal(x.beamReceiveKey.length, 66);
  x = await rig.after(15 * S, x.id);
  assert.equal(x.state, STATES.locking);
  rig.eth.mineLock(x.lockHash, { msgId: 128 });
  x = await rig.after(15 * S, x.id);
  assert.equal(x.state, STATES.locked);
  assert.equal(x.msgId, 128);
  rig.beam.deliver(ethRoute, 128, x.receives);
  x = await rig.after(30 * S, x.id);
  assert.equal(x.state, STATES.delivered);
  // Nothing collects it by itself, however long it waits (owner decision pending).
  for (let i = 0; i < 5; i++) x = await rig.after(30 * MIN, x.id);
  assert.equal(x.state, STATES.delivered);
  assert.deepEqual(rig.sends(), []);
  x = await rig.c.collect(x.id);
  assert.equal(x.state, STATES.claiming);
  assert.notEqual(x.claimTxId, null);
  assert.equal(x.beamNetworkFee, CLAIM_FEE);
  rig.beam.mine(x.claimTxId, 4072830);
  x = await rig.after(20 * S, x.id);
  assert.equal(x.state, STATES.claimed);
  assert.deepEqual(rig.sends(), ['claim eth']);
});

test('to BEAM, USDT: the approval is mined before the lock is signed; each hash, and the lock’s bytes, are written before they are broadcast', async () => {
  const rig = new Rig();
  const writtenAtBroadcast = [];
  rig.eth.onBroadcast = async (tx, hash) => {
    const stored = [...rig.store.byIdMap.values()][0];
    writtenAtBroadcast.push({ kind: tx.kind, state: stored.state, hasHash: stored.lockHash === hash || stored.approveHashes.includes(hash), raw: stored.lockRaw });
  };
  let x = await rig.move(usdtRoute, toBeam, 100000000n);
  assert.deepEqual(rig.eth.signed.map((t) => t.kind), ['approve', 'lock']);
  assert.equal(x.approveHashes.length, 1);
  assert.notEqual(x.lockHash, null);
  assert.equal(x.lockNonce, 41);
  assert.deepEqual(writtenAtBroadcast, [
    { kind: 'approve', state: 'approving', hasHash: true, raw: null },
    { kind: 'lock', state: 'locking', hasHash: true, raw: x.lockRaw },
  ]);
  const states = rig.store.writes.filter((w) => w.id === x.id).map((w) => w.state);
  assert.equal(states[0], 'approving');
  assert.ok(states.includes('locking'));
  rig.eth.mineLock(x.lockHash, { msgId: 109 });
  x = await rig.after(15 * S, x.id);
  assert.equal(x.state, STATES.locked);
});

test('to BEAM: an approval that fails, or is not mined in 30 minutes, ends it: nothing locked, no lock signed', async () => {
  const fails = new Rig();
  fails.eth.approvalsFail = true;
  const x = await fails.move(daiRoute, toBeam, ethUnits(10));
  assert.equal(x.state, STATES.lockFailed);
  assert.match(x.lastError, /nothing was moved/);
  assert.deepEqual(fails.eth.signed.map((t) => t.kind), ['approve']);
  const slow = new Rig();
  slow.eth.approvalsMineAtOnce = false;
  const y = await slow.move(daiRoute, toBeam, ethUnits(10));
  assert.equal(y.state, STATES.lockFailed);
  assert.match(y.lastError, /30 minutes/);
  assert.deepEqual(slow.eth.signed.map((t) => t.kind), ['approve']);
});

test('to BEAM: an approval whose broadcast fails ends it; one the server forgets while it waits goes again, identical', async () => {
  const fails = new Rig();
  fails.eth.mode = 'throwBeforeBroadcast';
  fails.eth.modeStep = 0;
  const x = await fails.move(wbtcRoute, toBeam, 10000n);
  assert.equal(x.state, STATES.lockFailed);
  assert.match(x.lastError, /nothing was moved/);
  assert.deepEqual(fails.eth.signed.map((t) => t.kind), ['approve'], 'the lock is not signed');

  const rig = new Rig();
  rig.eth.approvalsMineAtOnce = false;
  const hash = `0x${'1'.padStart(64, '0')}`;
  let looks = 0;
  const succeeded = rig.eth.succeeded.bind(rig.eth);
  rig.eth.succeeded = async (h) => {
    looks++;
    if (looks === 3) rig.eth.knownHashes.delete(h); // dropped from the server's pool
    if (looks === 6) rig.eth.mined.set(h, true);
    return succeeded(h);
  };
  const y = await rig.move(wbtcRoute, toBeam, 10000n);
  const approvalRaws = rig.eth.broadcasts.filter((r) => r === rig.eth.broadcasts[0]);
  assert.equal(approvalRaws.length, 2, 'the approval went twice, the same bytes');
  assert.deepEqual(rig.eth.signed.map((t) => t.kind), ['approve', 'lock'], 'signed once each');
  assert.equal(rig.eth.broadcasts.length, 3);
  assert.equal(y.state, STATES.locking);
  assert.equal(y.approveHashes[0], hash);
});

test('to BEAM: a lock Ethereum refused: nothing locked', async () => {
  const rig = new Rig();
  let x = await rig.move(ethRoute, toBeam, ethUnits(0.01));
  rig.eth.mineLock(x.lockHash, { success: false });
  x = await rig.after(15 * S, x.id);
  assert.equal(x.state, STATES.lockFailed);
});

test('to BEAM: the lock broadcast throws after it may have gone out: its hash is kept, the identical bytes go again, it is never signed twice', async () => {
  const rig = new Rig();
  rig.eth.mode = 'throwAfterBroadcast';
  let x = await rig.move(ethRoute, toBeam, ethUnits(0.01));
  assert.equal(x.state, STATES.locking);
  assert.notEqual(x.lockHash, null);
  assert.match(x.lastError, /never signs a second one/);
  assert.equal(rig.eth.broadcasts.length, 1);
  // The server does not have it: the next look sends exactly the same bytes.
  x = await rig.after(15 * S, x.id);
  assert.equal(rig.eth.broadcasts.length, 2);
  assert.equal(rig.eth.broadcasts[1], rig.eth.broadcasts[0]);
  assert.equal(rig.eth.broadcasts[1], x.lockRaw);
  // Now it has it: nothing more is sent.
  x = await rig.after(15 * S, x.id);
  assert.equal(rig.eth.broadcasts.length, 2);
  rig.eth.mineLock(x.lockHash, { msgId: 300 });
  x = await rig.after(15 * S, x.id);
  assert.equal(x.state, STATES.locked);
  assert.equal(x.lastError, null);
  assert.equal(rig.eth.signed.length, 1);
});

test('to BEAM: frozen between the review and signing, or a step that cannot be signed: nothing locked, nothing broadcast', async () => {
  const rig = new Rig();
  const p = await rig.c.prepare(await rig.quote(beamRoute, toBeam, beams(100)));
  rig.eth.frozen.set('beam', [{ reason: 'WBEAM is paused by its issuer' }]);
  const x = await rig.c.start(p);
  await rig.c.idle();
  const y = rig.c.crossing(x.id);
  assert.equal(y.state, STATES.lockFailed);
  assert.match(y.lastError, /paused by its issuer/);
  assert.deepEqual(rig.eth.broadcasts, []);
  const cannot = new Rig();
  cannot.eth.mode = 'throwBeforeSign';
  cannot.eth.modeStep = 0;
  const z = await cannot.move(wbtcRoute, toBeam, 10000n);
  assert.equal(z.state, STATES.lockFailed);
  assert.deepEqual(cannot.eth.signed, []);
  assert.deepEqual(cannot.eth.broadcasts, []);
});

test('to BEAM: not on BEAM 30 minutes after the lock says so, and keeps looking', async () => {
  const rig = new Rig();
  let x = await rig.move(ethRoute, toBeam, ethUnits(0.01));
  rig.eth.mineLock(x.lockHash, { msgId: 129 });
  x = await rig.after(15 * S, x.id);
  x = await rig.after(31 * MIN, x.id);
  assert.equal(x.state, STATES.notDeliveredYet);
  rig.beam.deliver(ethRoute, 129, x.receives);
  x = await rig.after(30 * S, x.id);
  assert.equal(x.state, STATES.delivered);
});

test('to BEAM: a different amount on BEAM is not collected', async () => {
  const rig = new Rig();
  let x = await rig.move(ethRoute, toBeam, ethUnits(0.01));
  rig.eth.mineLock(x.lockHash, { msgId: 130 });
  rig.beam.deliver(ethRoute, 130, x.receives - 1n);
  x = await rig.after(15 * S, x.id);
  assert.equal(x.state, STATES.unknown);
  await assert.rejects(rig.c.collect(x.id), code('badAmount'));
  assert.deepEqual(rig.sends(), []);
});

test('to BEAM: a claim that failed goes back to "ready to collect", and only the person starts it again', async () => {
  const rig = new Rig();
  let x = await rig.move(beamRoute, toBeam, beams(100));
  rig.eth.mineLock(x.lockHash, { msgId: 223 });
  rig.beam.deliver(beamRoute, 223, x.receives);
  x = await rig.after(15 * S, x.id);
  assert.equal(x.state, STATES.delivered);
  x = await rig.c.collect(x.id);
  assert.equal(x.state, STATES.claiming);
  rig.beam.status.set(x.claimTxId, { state: 'failed', height: null, reason: 'expired' });
  x = await rig.after(20 * S, x.id);
  assert.equal(x.state, STATES.delivered);
  assert.match(x.lastError, /Nothing was lost/);
  x = await rig.after(5 * MIN, x.id);
  assert.equal(x.state, STATES.delivered);
  assert.deepEqual(rig.sends(), ['claim beam']);
});

test('to BEAM: the person declines the claim: back to ready to collect, nothing sent', async () => {
  const rig = new Rig();
  let x = await rig.move(ethRoute, toBeam, ethUnits(0.01));
  rig.eth.mineLock(x.lockHash, { msgId: 132 });
  rig.beam.deliver(ethRoute, 132, x.receives);
  x = await rig.after(15 * S, x.id);
  rig.beam.mode = 'reject';
  await assert.rejects(rig.c.collect(x.id), code('rejected'));
  x = rig.c.crossing(x.id);
  assert.equal(x.state, STATES.delivered);
  assert.equal(x.lastError, null);
  assert.equal((await rig.store.byId(x.id)).state, STATES.delivered);
  rig.beam.mode = 'ok';
  assert.equal((await rig.c.collect(x.id)).state, STATES.claiming);
});

test('to BEAM: a claim that threw: claimed once the message is gone', async () => {
  const rig = new Rig();
  let x = await rig.move(ethRoute, toBeam, ethUnits(0.01));
  rig.eth.mineLock(x.lockHash, { msgId: 131 });
  rig.beam.deliver(ethRoute, 131, x.receives);
  x = await rig.after(15 * S, x.id);
  rig.beam.mode = 'throwAfterBroadcast';
  x = await rig.c.collect(x.id);
  assert.equal(x.state, STATES.claiming);
  assert.equal(x.claimTxId, null);
  const [txId] = rig.beam.executed.keys();
  rig.beam.mine(txId, 4072900);
  x = await rig.after(20 * S, x.id);
  assert.equal(x.state, STATES.claimed);
});

test('to BEAM: a claim that threw and is still claimable 10 minutes later did not go out', async () => {
  const rig = new Rig();
  let x = await rig.move(ethRoute, toBeam, ethUnits(0.01));
  rig.eth.mineLock(x.lockHash, { msgId: 133 });
  rig.beam.deliver(ethRoute, 133, x.receives);
  x = await rig.after(15 * S, x.id);
  rig.beam.mode = 'throwBeforeBroadcast';
  x = await rig.c.collect(x.id);
  assert.equal(x.state, STATES.claiming);
  x = await rig.after(5 * MIN, x.id);
  assert.equal(x.state, STATES.claiming);
  x = await rig.after(TIMING.claimWaitMs, x.id);
  assert.equal(x.state, STATES.delivered);
  assert.match(x.lastError, /did not reach BEAM/);
});

test('to BEAM: collected elsewhere first: no claim is sent, it says so', async () => {
  const rig = new Rig();
  let x = await rig.move(daiRoute, toBeam, ethUnits(10));
  rig.eth.mineLock(x.lockHash, { msgId: 0 }); // Ethereum ids start at 0
  rig.beam.deliver(daiRoute, 0, x.receives);
  x = await rig.after(15 * S, x.id);
  assert.equal(x.state, STATES.delivered);
  assert.equal(x.msgId, 0);
  rig.beam.remote.get('dai').delete(0); // the same wallet on another device collects it
  await assert.rejects(rig.c.collect(x.id), (e) => /already collected/.test(e.message));
  x = rig.c.crossing(x.id);
  assert.equal(x.state, STATES.claimed);
  assert.match(x.lastError, /outside this screen/);
  assert.deepEqual(rig.sends(), []);
});

test('to BEAM: collecting needs 0.121 BEAM in the BEAM wallet at that time', async () => {
  const rig = new Rig();
  let x = await rig.move(usdtRoute, toBeam, 100000000n);
  rig.eth.mineLock(x.lockHash, { msgId: 110 });
  rig.beam.deliver(usdtRoute, 110, x.receives);
  x = await rig.after(15 * S, x.id);
  rig.beam.balances.set(0, beams(0.1));
  await assert.rejects(rig.c.collect(x.id), (e) => /0\.121 BEAM/.test(e.message));
  assert.equal(rig.c.crossing(x.id).state, STATES.delivered);
  await assert.rejects(rig.c.collect('no-such-crossing'), code('badAmount'));
});

// ---------------------------------------------------------------- restart, uniqueness, polling

test('restart: a crossing to Ethereum resumes from the store and is paid', async () => {
  const store = new MemoryBridgeStore();
  const beam = new FakeBeamSide();
  const first = new Rig({ beam, store });
  const x = await first.move(beamRoute, toEth, beams(1000));
  first.c.dispose();
  beam.mine(x.beamTxId, 4072810);
  beam.tip = 4072900;
  const second = new Rig({ beam, store, clock: first.clock });
  second.eth.paid.add(1);
  assert.deepEqual(second.c.crossings, []);
  await second.c.resumeAll();
  assert.equal(second.c.crossings[0].state, STATES.sent);
  await second.c.pollDue();
  const y = second.c.crossing(x.id);
  assert.equal(y.state, STATES.paid);
  assert.equal(y.msgId, 1);
  assert.deepEqual(beam.calls.filter((c) => c.startsWith('send')), ['send beam']);
});

test('restart: closed between the approval and the lock: nothing was locked', async () => {
  const store = new MemoryBridgeStore();
  const first = new Rig({ store });
  first.eth.approvalsMineAtOnce = false;
  first.clock.hold = true; // the approval wait never ends
  const x = await first.c.start(await first.c.prepare(await first.quote(daiRoute, toBeam, ethUnits(10))));
  for (let i = 0; i < 5; i++) await flush();
  first.c.dispose();
  assert.equal((await store.byId(x.id)).state, STATES.approving);
  const second = new Rig({ store, eth: first.eth, clock: first.clock });
  await second.c.resumeAll();
  const y = second.c.crossing(x.id);
  assert.equal(y.state, STATES.lockFailed);
  assert.match(y.lastError, /nothing was moved/);
  assert.deepEqual(first.eth.signed.map((t) => t.kind), ['approve']);
});

const stored = (patch) =>
  makeCrossing({
    id: 'x1',
    route: 'usdt',
    direction: toEth,
    state: STATES.sending,
    amount: beams(100),
    receives: 100000000n,
    relayerFee: beams(0.7),
    beamNetworkFee: SEND_FEE,
    beamWalletId: 'beam-wallet',
    ethWalletId: 'eth-wallet',
    ethAddress: FAKE_ETH_ADDRESS,
    countBefore: 0,
    createdAt: Date.UTC(2026, 9, 9, 16, 42),
    updatedAt: Date.UTC(2026, 9, 9, 16, 42),
    ...patch,
  });

test('restart: closed while sending to Ethereum: unknown, then found (mined one above the stamp)', async () => {
  const store = new MemoryBridgeStore();
  await store.save(stored());
  const rig = new Rig({ store });
  rig.beam.addLocal(usdtRoute, { receiver: FAKE_ETH_ADDRESS, amount: beams(100), fee: beams(0.7), height: 4072805 });
  await rig.c.resumeAll();
  assert.equal(rig.c.crossing('x1').state, STATES.unknown);
  await rig.c.pollDue();
  assert.equal(rig.c.crossing('x1').state, STATES.confirmed);
  assert.equal(rig.c.crossing('x1').msgId, 1);
  assert.equal(rig.c.crossing('x1').height, 4072806);
});

test('restart: a lock signed and written but not known to the server goes again, identical; one with no hash is looked for', async () => {
  const store = new MemoryBridgeStore();
  const key = Array.from(FakeBeamSide.keyFor(ethRoute), (b) => b.toString(16).padStart(2, '0')).join('');
  await store.save(stored({ id: 'l1', route: 'eth', direction: toBeam, state: STATES.locking, amount: ethUnits(0.01), receives: 1000000n, relayerFee: 10n ** 12n, beamNetworkFee: CLAIM_FEE, beamReceiveKey: key, countBefore: null }));
  const rig = new Rig({ store });
  // The signature the closed page made: the fake knows it as step 0.
  const plan = await rig.eth.planLock(ethRoute, { value: ethUnits(0.01), fee: 10n ** 12n, receiverKey: FakeBeamSide.keyFor(ethRoute) });
  const signed = await rig.eth.sign(plan.steps[0]);
  await store.save(makeCrossing({ ...(await store.byId('l1')), lockHash: signed.hash, lockRaw: signed.raw, lockNonce: signed.nonce }));
  await store.save(stored({ id: 'l2', route: 'eth', direction: toBeam, state: STATES.locking, amount: ethUnits(0.02), receives: 2000000n, relayerFee: 10n ** 12n, beamNetworkFee: CLAIM_FEE, beamReceiveKey: key, countBefore: null, createdAt: Date.UTC(2026, 9, 9, 16, 43) }));
  await rig.c.resumeAll();
  assert.equal(rig.c.crossing('l1').state, STATES.locking);
  assert.equal(rig.c.crossing('l2').state, STATES.unknown);
  await rig.c.pollDue();
  assert.deepEqual(rig.eth.broadcasts, [signed.raw]);
  rig.beam.deliver(ethRoute, 400, 2000000n);
  await rig.after(MIN, 'l2');
  assert.equal(rig.c.crossing('l2').state, STATES.delivered);
  assert.equal(rig.c.crossing('l2').msgId, 400);
  assert.equal(rig.eth.signed.length, 1, 'nothing signed again');
});

test('uniqueness: two identical sends in one block take one message each', async () => {
  const rig = new Rig();
  const a = await rig.move(beamRoute, toEth, beams(1000));
  const b = await rig.move(beamRoute, toEth, beams(1000));
  rig.beam.mine(a.beamTxId, 4072810);
  rig.beam.mine(b.beamTxId, 4072810);
  await rig.after(20 * S, a.id);
  assert.deepEqual(new Set([rig.c.crossing(a.id).msgId, rig.c.crossing(b.id).msgId]), new Set([1, 2]));
});

test('uniqueness: a lock naming a message another crossing has is not collected', async () => {
  const rig = new Rig();
  let a = await rig.move(ethRoute, toBeam, ethUnits(0.01));
  let b = await rig.move(ethRoute, toBeam, ethUnits(0.02));
  rig.eth.mineLock(a.lockHash, { msgId: 140 });
  rig.eth.mineLock(b.lockHash, { msgId: 140 });
  a = await rig.after(15 * S, a.id);
  b = rig.c.crossing(b.id);
  assert.equal(a.state, STATES.locked);
  assert.equal(b.state, STATES.unknown);
  assert.equal(b.msgId, null);
});

test('polling runs only while the caller says visible and unlocked; an explicit look still answers', async () => {
  const rig = new Rig();
  let x = await rig.move(ethRoute, toBeam, ethUnits(0.01));
  rig.eth.mineLock(x.lockHash, { msgId: 150 });
  rig.c.setActive({ visible: false, unlocked: true });
  assert.equal(rig.c.active, false);
  x = await rig.after(MIN, x.id);
  assert.equal(x.state, STATES.locking, 'hidden: nothing polled');
  rig.c.setActive({ visible: true, unlocked: false });
  x = await rig.after(MIN, x.id);
  assert.equal(x.state, STATES.locking, 'locked: nothing polled');
  await rig.c.poll(x.id);
  assert.equal(rig.c.crossing(x.id).state, STATES.locked, 'the screen asked');
  rig.beam.deliver(ethRoute, 150, x.receives);
  rig.c.setActive({ visible: true, unlocked: true });
  x = await rig.after(MIN, x.id);
  assert.equal(x.state, STATES.delivered);
  const changes = [];
  rig.c.onChange(() => changes.push(1));
  await rig.c.collect(x.id);
  assert.ok(changes.length >= 1);
});

test('crossings of another wallet pair are not this controller’s', async () => {
  const store = new MemoryBridgeStore();
  await store.save(stored({ id: 'theirs', beamWalletId: 'another' }));
  await store.save(stored({ id: 'mine', countBefore: 0 }));
  const rig = new Rig({ store });
  await rig.c.resumeAll();
  assert.deepEqual(rig.c.crossings.map((c) => c.id), ['mine']);
});

test('beamSide maps the wallet: tx_status 3 with a height is completed, 2 and 4 failed, the rest pending', async () => {
  const statuses = { a: { status: 3, height: 4072810 }, b: { status: 4, failure_reason: 'expired' }, c: { status: 2, status_string: 'cancelled' }, d: { status: 1 }, e: { status: 3 } };
  const wallet = { txStatus: async (id) => statuses[id], available: (aid) => (aid === 0 ? 5n : 0n), state: { status: { current_height: 4072900 } } };
  const side = beamSide({ pipe: {}, wallet });
  assert.deepEqual({ ...(await side.txStatus('a')) }, { state: 'completed', height: 4072810, reason: null });
  assert.deepEqual({ ...(await side.txStatus('b')) }, { state: 'failed', height: null, reason: 'expired' });
  assert.equal((await side.txStatus('c')).reason, 'cancelled');
  assert.equal((await side.txStatus('d')).state, 'pending');
  assert.equal((await side.txStatus('e')).state, 'pending', 'completed without a height is not trusted yet');
  assert.equal(await side.tipHeight(), 4072900);
  assert.equal(await side.available(0), 5n);
  await assert.rejects(beamSide({ pipe: {}, wallet: { state: { status: {} } } }).tipHeight(), code('network'));
});

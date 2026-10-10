// The two halves of the bridge and its price feed, faked from the interfaces
// only (lib/bridge/controller.js): a BEAM wallet whose pipe records messages
// when its sends are mined, and an Ethereum wallet whose locks are mined when
// the test says so. A port of the desktop's test/beam/bridge/bridge_fakes.dart.
// Prices and gas are the ones read on 2026-10-09 16:42 UTC (research note 06,
// D). Every address and key here is made up.
import { BridgeError } from '../../../src/lib/bridge/beam_pipe.js';
import { routeById, SEND_FEE, CLAIM_FEE } from '../../../src/lib/bridge/routes.js';
import { b2eRelayerFeeGroth } from '../../../src/lib/bridge/fees.js';

/** A made-up Ethereum address (nobody's), and someone else's. */
export const FAKE_ETH_ADDRESS = '0x7a3e5b1c2d4f6e8a9b0c1d2e3f4a5b6c7d8e91c4';
export const OTHER_ETH_ADDRESS = '0x00000000000000000000000000000000000c0ffe';

export const beams = (v) => BigInt(Math.round(v * 1e8));
/** v whole ETH (or DAI) in wei, exactly for up to 8 decimals. */
export const ethUnits = (v) => BigInt(Math.round(v * 1e8)) * 10n ** 10n;

export const PRICES = Object.freeze({ ethereum: 2487.25, beam: 0.00783632, 'wrapped-bitcoin': 82567.0, tether: 0.999262, dai: 0.999917 });
export const GAS = Object.freeze({ baseFee: 701400000n, tip: 429200000n, maxFeePerGas: 2n * 701400000n + 429200000n });

/** The b2e fee these prices and this gas give (×1.3). */
export const b2eFee = (route) => b2eRelayerFeeGroth(route, GAS, PRICES);

export class FakeClock {
  constructor(t = Date.UTC(2026, 9, 9, 16, 42)) {
    this.t = t;
    /** Sleeps never end (a wait that outlives the test). */
    this.hold = false;
  }

  now() {
    return this.t;
  }

  sleep(ms) {
    if (this.hold) return new Promise(() => {});
    this.t += ms;
    return Promise.resolve();
  }

  advance(ms) {
    this.t += ms;
  }
}

const err = (code, message) => Object.assign(new Error(message), { code });

export class FakeBeamSide {
  constructor({ available = null } = {}) {
    this.balances = new Map(Object.entries(available || { 0: beams(5000), 37: beams(250), 36: beams(1) }).map(([k, v]) => [Number(k), v]));
    this.local = new Map(); // route → [{receiver, amount, relayerFee, height}], id = index + 1
    this.remote = new Map(); // route → Map(msgId → {amount, relayerFee, receiver})
    this.status = new Map(); // txId → {state, height, reason}
    this.executed = new Map(); // txId → what it did
    this.calls = [];
    /** Runs inside send/claim before anything is "sent" (tests read the store then). */
    this.onSend = null;
    /** ok | reject (the person said no) | throwAfterBroadcast | throwBeforeBroadcast */
    this.mode = 'ok';
    this.tip = 4072800;
    this.keyFails = false;
    this.txs = 0;
  }

  static keyFor(route) {
    return Uint8Array.from([...Array.from({ length: 32 }, (_, i) => (i * 7 + route.id.length) & 0xff), 0x01]);
  }

  localOf(route) {
    if (!this.local.has(route.id)) this.local.set(route.id, []);
    return this.local.get(route.id);
  }

  /** A b2e message someone made (another person, or this wallet). */
  addLocal(route, { receiver = OTHER_ETH_ADDRESS, amount, fee, height }) {
    this.localOf(route).push({ receiver, amount, relayerFee: fee, height });
  }

  /** The relayer brings e2b message msgId to BEAM. */
  deliver(route, msgId, amount) {
    if (!this.remote.has(route.id)) this.remote.set(route.id, new Map());
    this.remote.get(route.id).set(msgId, { amount, relayerFee: 0n, receiver: FakeBeamSide.keyFor(route) });
  }

  /** Mines txId at height: a send records its message (stamped one below, as the pipe does), a claim takes its message away. */
  mine(txId, height) {
    const p = this.executed.get(txId);
    this.status.set(txId, { state: 'completed', height, reason: null });
    if (p.call === 'send') this.addLocal(p.route, { receiver: p.ethReceiver, amount: p.amount, fee: p.fee, height: height - 1 });
    else this.remote.get(p.route.id)?.delete(p.msgId);
  }

  async receiveKey(route) {
    this.calls.push(`receiveKey ${route.id}`);
    if (this.keyFails) throw new BridgeError('badPipe', 'get_pk pk: the receive key is not a secp256k1 point');
    return FakeBeamSide.keyFor(route);
  }

  async localMessageCount(route) {
    return this.localOf(route).length;
  }

  async localMessage(route, msgId) {
    this.calls.push(`localMessage ${route.id} ${msgId}`);
    const l = this.localOf(route);
    return msgId >= 1 && msgId <= l.length ? l[msgId - 1] : null;
  }

  async remoteMessage(route, msgId) {
    return this.remote.get(route.id)?.get(msgId) || null;
  }

  async incoming(route, { startFrom = 0 } = {}) {
    return [...(this.remote.get(route.id) || new Map())].filter(([id]) => id >= startFrom).map(([msgId, m]) => ({ msgId, amount: m.amount }));
  }

  #run(call, what) {
    if (this.onSend) this.onSend(what);
    this.calls.push(`${call} ${what.route.id}`);
    if (this.mode === 'reject') throw err('rejected', 'Cancelled. Nothing was sent.');
    if (this.mode === 'throwBeforeBroadcast') throw err('rpc', 'node down');
    const id = `${'b'.repeat(26)}${String(++this.txs).padStart(6, '0')}`;
    this.executed.set(id, { call, ...what });
    this.status.set(id, { state: 'pending', height: null, reason: null });
    if (this.mode === 'throwAfterBroadcast') throw err('timeout', 'no answer');
    return id;
  }

  async send(route, { ethReceiver, amount, fee }) {
    return this.#run('send', { route, ethReceiver: ethReceiver.toLowerCase(), amount, fee, networkFee: SEND_FEE });
  }

  async claim(route, { msgId, amount }) {
    if (!this.remote.get(route.id)?.get(msgId)) {
      this.calls.push(`claim ${route.id} (absent)`);
      throw new BridgeError('badPipe', 'the pipe said "msg with current id is absent"');
    }
    return this.#run('claim', { route, msgId, amount, networkFee: CLAIM_FEE });
  }

  async txStatus(txId) {
    return this.status.get(txId) || { state: 'pending', height: null, reason: null };
  }

  async tipHeight() {
    return this.tip;
  }

  async available(assetId) {
    return this.balances.get(assetId) ?? 0n;
  }
}

export class FakeEthSide {
  constructor({ eth = 42000000000000000n, tokens = null, clock } = {}) {
    this.ethBal = eth; // 0.042 ETH
    this.tokenBal = new Map(Object.entries(tokens || { beam: beams(20000), usdt: 500000000n, wbtc: 100000n, dai: 300000000000000000000n }));
    this.allowance = new Map();
    this.frozen = new Map();
    this.freezeFails = false;
    this.clock = clock;
    this.mined = new Map(); // approval hash → true | false | null (pending)
    this.locks = new Map(); // lock hash → {hash, success, blockNumber, msgId}
    this.signed = []; // the steps signed, in order
    this.broadcasts = []; // every raw broadcast, in order (re-sends too)
    this.knownHashes = new Set();
    this.paid = new Set();
    /** Per step (0 based): 'ok' | 'throwBeforeSign' | 'throwAfterBroadcast' | 'throwBeforeBroadcast'; null: every step. */
    this.mode = 'ok';
    this.modeStep = null;
    this.approvalsMineAtOnce = true;
    this.approvalsFail = false;
    /** Runs inside broadcast before anything is "sent". */
    this.onBroadcast = null;
    this.owner = FAKE_ETH_ADDRESS;
  }

  async freezes(route) {
    if (this.freezeFails) throw new BridgeError('network', 'no answer');
    return this.frozen.get(route.id) || [];
  }

  async relayerGas() {
    return { ...GAS, at: this.clock.now() };
  }

  async balance(route) {
    return route.isNativeEth ? this.ethBal : this.tokenBal.get(route.id) ?? 0n;
  }

  async ethBalance() {
    return this.ethBal;
  }

  async planLock(route, { value, fee, receiverKey }) {
    if (value <= 0n || value % route.ethGrid !== 0n) throw new BridgeError('badAmount', 'off the grid');
    const need = value + fee;
    const have = this.allowance.get(route.id) ?? 0n;
    const maxFeePerGas = 1832100000n;
    const step = (kind, to, gas, v) => Object.freeze({ kind, to, value: v, gasLimit: BigInt(gas), maxGasCost: BigInt(gas) * maxFeePerGas, route: route.id });
    const steps = [];
    if (!route.isNativeEth && have < need) {
      if (have > 0n && route.id === 'usdt') steps.push(step('approveReset', route.ethToken, 50000, 0n));
      steps.push(step('approve', route.ethToken, 60000, 0n));
    }
    steps.push(step('lock', route.ethPipe, route.isNativeEth ? 40000 : 75000, route.isNativeEth ? need : 0n));
    return Object.freeze({ route, value, fee, receiverKey, steps: Object.freeze(steps), maxGasCost: steps.reduce((s, t) => s + t.maxGasCost, 0n) });
  }

  #modeFor(i) {
    return this.modeStep === null || this.modeStep === i ? this.mode : 'ok';
  }

  async sign(tx) {
    const i = this.signed.length;
    if (this.#modeFor(i) === 'throwBeforeSign') throw new BridgeError('network', 'rpc down');
    // As the real one: a fresh freeze check right before signing.
    const f = await this.freezes(routeById(tx.route));
    if (f.length) throw new BridgeError('frozen', f.map((x) => x.reason).join('\n'));
    if (this.signed.includes(tx)) throw new BridgeError('alreadySent', 'signed once');
    this.signed.push(tx);
    const hash = `0x${(i + 1).toString(16).padStart(64, '0')}`;
    return Object.freeze({ raw: `0x02${(i + 1).toString(16).padStart(8, '0')}`, hash, nonce: 40 + i, step: i });
  }

  async broadcast(raw) {
    const i = parseInt(raw.slice(4), 16) - 1;
    const tx = this.signed[i];
    const hash = `0x${(i + 1).toString(16).padStart(64, '0')}`;
    if (this.onBroadcast) await this.onBroadcast(tx, hash);
    const mode = this.broadcasts.includes(raw) ? 'ok' : this.#modeFor(i);
    if (mode === 'throwBeforeBroadcast') throw new BridgeError('network', 'rpc down');
    this.broadcasts.push(raw);
    this.knownHashes.add(hash);
    if (tx.kind !== 'lock' && !this.mined.has(hash)) this.mined.set(hash, this.approvalsMineAtOnce ? !this.approvalsFail : null);
    if (mode === 'throwAfterBroadcast') {
      // It reached the network, and then the server's answer was lost; and the
      // server forgot it again (dropped from its pool).
      this.knownHashes.delete(hash);
      throw new BridgeError('network', 'no answer');
    }
    return hash;
  }

  async known(hash) {
    return this.knownHashes.has(hash);
  }

  /** Mines lock hash as message msgId (or reverted). */
  mineLock(hash, { msgId = 222, success = true } = {}) {
    this.locks.set(hash, { hash, success, blockNumber: 26156200, msgId: success ? msgId : null });
  }

  async succeeded(hash) {
    return this.mined.has(hash) ? this.mined.get(hash) : null;
  }

  async lockResult(route, hash) {
    return this.locks.get(hash) || null;
  }

  async isPaid(route, msgId) {
    return this.paid.has(msgId);
  }
}

export class FakePrices {
  constructor(clock) {
    this.clock = clock;
    this.fail = false;
    this.ageMs = 0;
    this.missing = new Set();
    this.asked = 0;
  }

  async usd(ids) {
    this.asked++;
    if (this.fail) throw new BridgeError('noPrice', 'no prices');
    const usd = {};
    for (const id of ids) if (PRICES[id] && !this.missing.has(id)) usd[id] = PRICES[id];
    return { usd, at: this.clock.now() - this.ageMs };
  }
}

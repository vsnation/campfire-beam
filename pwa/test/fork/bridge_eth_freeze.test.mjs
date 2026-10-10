// Freezes, on a local anvil mainnet fork (127.0.0.1:8545 only, under the
// shared fork lock, put back with evm_revert): the real issuers freeze the
// real tokens - WBEAM paused by the key that holds its PAUSER_ROLE (found from
// the contract's RoleGranted / RoleRevoked events, confirmed with hasRole),
// Tether blacklisting the USDT pipe (then pausing and charging a fee), WBTC
// paused by its owner - and then:
//
// * a quote asked now refuses, both ways, saying why;
// * a review made before the freeze, whose "not frozen" answer may still be
//   shown for ten minutes, cannot be signed: EthPipe.sign asks Ethereum again
//   right before signing and refuses, directly and through the controller,
//   and nothing reaches the chain;
// * with the Ethereum server gone (a local port where nothing listens), no
//   quote and no signature: fail closed.
//
//   node --test --test-concurrency=1 --test-timeout=300000 test/fork/bridge_eth_freeze.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { ROUTES, routeById } from '../../src/lib/bridge/routes.js';
import { BridgeError } from '../../src/lib/bridge/beam_pipe.js';
import { BridgeController } from '../../src/lib/bridge/controller.js';
import { MemoryBridgeStore, STATES, DIRECTIONS } from '../../src/lib/bridge/store.js';
import { BLOCKS } from '../../src/lib/bridge/quote.js';
import { encodeCall, abiDecode, selector, eventTopic } from '../../src/lib/eth/abi.js';
import { keccak256 } from '../../src/lib/eth/crypto.js';
import { bytesToHex, utf8ToBytes } from '../../src/lib/eth/hex.js';
import { forkProblem, withFork, forkRpc, switchableRpc, freshSigner, ethPipeFor, AMOUNTS, e2bFee, giveTokens, sendAs, raw, call, uint, hex, fixturePrices, forkBeamSide } from './bridge_eth_support.mjs';

const skip = await forkProblem();
const T = { skip: skip || false, timeout: 300000 };
const MIN = 60000;
const groth = (v) => BigInt(Math.round(v * 1e8));

/** BEAM the controller's BEAM half has: BEAM for the fees, and each wrapped asset to move back. */
const BEAM_BALANCES = Object.freeze({ 0: groth(5000), 36: groth(10), 37: groth(1000), 38: groth(1), 39: groth(1000) });
/** What the quotes to Ethereum move (groth, on each route's BEAM grid, above the bridge fee at the fork's gas). */
const TO_ETHEREUM = Object.freeze({ beam: groth(1000), eth: groth(0.1), wbtc: groth(0.01), usdt: groth(100), dai: groth(10) });

const isCode = (code, re = null) => (e) => e instanceof BridgeError && e.code === code && (re === null || re.test(e.message));

function controllerFor(eth, beam) {
  const c = new BridgeController({ beam, eth, prices: fixturePrices().feed, store: new MemoryBridgeStore(), beamWalletId: 'beam-fork', ethWalletId: 'eth-fork', autoPoll: false });
  c.setActive({ visible: true, unlocked: true });
  return c;
}

const amountFor = (route, d) => (d === DIRECTIONS.toBeam ? AMOUNTS[route.id] : TO_ETHEREUM[route.id]);

// ---------------------------------------------------------------- who can freeze

/** WBEAM's code first appears in this block (a binary search on eth_getCode on this fork; checked below). */
const WBEAM_DEPLOYED = 18190063;
const ROLE_GRANTED = eventTopic('RoleGranted(bytes32,address,address)');
const ROLE_REVOKED = eventTopic('RoleRevoked(bytes32,address,address)');
const PAUSER_ROLE = keccak256(utf8ToBytes('PAUSER_ROLE'));

/**
 * The key that can pause WBEAM, from the contract's roles: OpenZeppelin's
 * AccessControl here keeps no list, so its grants and revocations of
 * PAUSER_ROLE are replayed from the events of the 100,000 blocks after it was
 * deployed (one log request), and each holder confirmed with hasRole now.
 */
async function wbeamPauser() {
  const wbeam = routeById('beam').ethToken;
  assert.equal(await raw('eth_getCode', [wbeam, hex(WBEAM_DEPLOYED - 1)]), '0x');
  assert.notEqual(await raw('eth_getCode', [wbeam, hex(WBEAM_DEPLOYED)]), '0x');
  const logs = await raw('eth_getLogs', [{ address: wbeam, topics: [[ROLE_GRANTED, ROLE_REVOKED], bytesToHex(PAUSER_ROLE)], fromBlock: hex(WBEAM_DEPLOYED), toBlock: hex(WBEAM_DEPLOYED + 99999) }]);
  const holders = new Set();
  for (const l of logs) {
    const account = `0x${l.topics[2].slice(26)}`;
    if (l.topics[0] === ROLE_GRANTED) holders.add(account);
    else holders.delete(account);
  }
  const now = [];
  for (const h of holders) if (abiDecode('bool', await call(wbeam, encodeCall('hasRole(bytes32,address)', [PAUSER_ROLE, h])))[0]) now.push(h);
  assert.equal(now.length, 1, `one key holds WBEAM's pause (${logs.length} role events)`);
  return now[0];
}

const ownerOf = async (token) => abiDecode('address', await call(token, selector('owner()')))[0].toLowerCase();

// ---------------------------------------------------------------- the checks

/**
 * Sets up a crossing of `route` to BEAM that can go (a quote, its review and a
 * plan), then `freeze()`s the token on the fork, and checks that a quote asked
 * now refuses both ways with `reasons`, and that the review and the plan made
 * before cannot be signed (fail closed), with nothing sent.
 */
async function frozenOnFork(t, route, freeze, reasons) {
  const value = AMOUNTS[route.id];
  const fee = e2bFee(route);
  const total = value + fee;
  const rpc = forkRpc();
  const who = await freshSigner();
  await giveTokens(route, who.address, total);
  const beam = forkBeamSide({ available: BEAM_BALANCES });

  // Before: it can go. This side keeps its "not frozen" answer for quotes.
  const kept = ethPipeFor(who, { rpc });
  const before = controllerFor(kept, beam);
  for (const d of [DIRECTIONS.toBeam, DIRECTIONS.toEthereum]) {
    const q = await before.quote(route, d, amountFor(route, d));
    assert.equal(q.block, null, `${d} before the freeze: ${q.block && q.block.title}`);
  }
  const review = await before.prepare(await before.quote(route, DIRECTIONS.toBeam, value));
  const plan = await kept.planLock(route, { value, fee, receiverKey: beam.key });
  assert.equal(plan.steps[0].kind, 'approve');

  await freeze();

  // A quote asked now refuses, both ways, and says why.
  const asked = controllerFor(ethPipeFor(who, { rpc }), beam);
  for (const d of [DIRECTIONS.toBeam, DIRECTIONS.toEthereum]) {
    const q = await asked.quote(route, d, amountFor(route, d));
    assert.equal(q.canMove, false, d);
    assert.equal(q.block.code, BLOCKS.frozen, d);
    assert.equal(q.block.title, `${route.name} cannot be moved right now`);
    assert.equal(q.block.detail, reasons.join('\n'), d);
  }

  // The answer kept from before may still be shown for up to ten minutes...
  assert.deepEqual(await kept.freezes(route), []);
  const nonce = await rpc.getTransactionCount(who.address, 'pending');
  // ...but signing asks Ethereum again first, and refuses.
  await assert.rejects(kept.sign(plan.steps[0]), isCode('frozen', new RegExp(reasons[0].replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))));
  // The controller, started from the review made before the freeze: nothing moves.
  const c = await before.start(review);
  await before.idle();
  const done = before.crossing(c.id);
  assert.equal(done.state, STATES.lockFailed);
  assert.ok(done.lastError.includes(reasons[0]), done.lastError);
  assert.equal(done.lockHash, null);
  assert.deepEqual(done.approveHashes, []);
  assert.equal(await rpc.getTransactionCount(who.address, 'pending'), nonce, 'nothing signed reached the fork');
  assert.equal(await rpc.getTransactionCount(who.address, 'latest'), nonce);
  assert.equal(await kept.allowance(route), 0n, 'nothing approved');
  assert.equal(await kept.balance(route), total, 'nothing moved');
  t.diagnostic(`${route.ethSymbol}: quote refused (${reasons.join('; ')}); sign refused; controller: ${done.state}: ${done.lastError}`);
}

// ---------------------------------------------------------------- tests

test('fork: nothing is frozen on the fork as it is', T, () =>
  withFork(async () => {
    const pipe = ethPipeFor(await freshSigner(0n));
    for (const r of ROUTES) assert.deepEqual(await pipe.freezes(r, { fresh: true }), [], r.id);
  }));

test('fork: WBEAM paused by the key holding its PAUSER_ROLE: no quote, no signature', T, (t) =>
  withFork(async () => {
    const route = routeById('beam');
    const pauser = await wbeamPauser();
    t.diagnostic(`WBEAM's pauser, from its roles: ${pauser}`);
    await frozenOnFork(
      t,
      route,
      async () => {
        await sendAs(pauser, route.ethToken, selector('pause()'));
        assert.equal(await uint(route.ethToken, selector('paused()')), 1n);
      },
      ['WBEAM is paused by its issuer'],
    );
    // The other routes are not affected.
    const other = ethPipeFor(await freshSigner(0n));
    for (const id of ['eth', 'wbtc', 'usdt', 'dai']) assert.deepEqual(await other.freezes(routeById(id), { fresh: true }), [], id);
  }));

test("fork: Tether blacklists the USDT pipe: no quote, no signature; then pauses and charges a fee", T, (t) =>
  withFork(async () => {
    const route = routeById('usdt');
    const owner = await ownerOf(route.ethToken);
    await frozenOnFork(
      t,
      route,
      async () => {
        await sendAs(owner, route.ethToken, encodeCall('addBlackList(address)', [route.ethPipe]));
        assert.equal(abiDecode('bool', await call(route.ethToken, encodeCall('isBlackListed(address)', [route.ethPipe])))[0], true);
      },
      ["Tether has frozen the bridge's USDT"],
    );
    await sendAs(owner, route.ethToken, selector('pause()'));
    await sendAs(owner, route.ethToken, encodeCall('setParams(uint256,uint256)', [10n, 10n]));
    const now = ethPipeFor(await freshSigner(0n));
    assert.deepEqual(
      (await now.freezes(route, { fresh: true })).map((f) => f.reason),
      ['Tether has paused USDT', "Tether has frozen the bridge's USDT", 'USDT now charges a transfer fee'],
    );
  }));

test('fork: WBTC paused by its owner: no quote, no signature', T, (t) =>
  withFork(async () => {
    const route = routeById('wbtc');
    const owner = await ownerOf(route.ethToken);
    await frozenOnFork(
      t,
      route,
      async () => {
        await sendAs(owner, route.ethToken, selector('pause()'));
        assert.equal(await uint(route.ethToken, selector('paused()')), 1n);
      },
      ['WBTC is paused by its issuer'],
    );
  }));

test('fork: with the Ethereum server gone, nothing is quoted and nothing is signed', T, (t) =>
  withFork(async () => {
    const beamRoute = routeById('beam');
    const ethRoute = routeById('eth');
    const who = await freshSigner();
    await giveTokens(beamRoute, who.address, AMOUNTS.beam + e2bFee(beamRoute));
    const beam = forkBeamSide({ available: BEAM_BALANCES });
    const { rpc, state } = await switchableRpc();
    const clock = { t: Date.now() };
    const pipe = ethPipeFor(who, { rpc, clock: () => clock.t });

    // Planned while the server answers; WBEAM checked and found not frozen.
    const plan = await pipe.planLock(beamRoute, { value: AMOUNTS.beam, fee: e2bFee(beamRoute), receiverKey: beam.key });
    const ethPlan = await pipe.planLock(ethRoute, { value: AMOUNTS.eth, fee: e2bFee(ethRoute), receiverKey: beam.key });
    assert.deepEqual(await pipe.freezes(beamRoute), []);
    const nonce = await rpc.getTransactionCount(who.address, 'pending');

    state.dead = true;
    // Signing asks again right before, gets no answer, and refuses.
    await assert.rejects(pipe.sign(plan.steps[0]), isCode('network', /Could not reach Ethereum to check WBEAM/));
    // ETH has no issuer to ask; the chain-id check right before signing refuses instead.
    await assert.rejects(pipe.sign(ethPlan.steps[0]), isCode('network'));
    assert.ok(state.deadRequests >= 2, 'both asked the dead server');

    // A quote may still show the kept answer while it is under an hour old, not after.
    clock.t += 30 * MIN;
    assert.deepEqual(await pipe.freezes(beamRoute), []);
    clock.t += 31 * MIN;
    await assert.rejects(pipe.freezes(beamRoute), isCode('network'));

    // A screen opened on the dead server quotes nothing. (To BEAM the balances
    // come from that server too, and the quote names the balances.)
    const ctl = controllerFor(ethPipeFor(who, { rpc }), beam);
    const expect = [
      [beamRoute, DIRECTIONS.toBeam, BLOCKS.network, "Couldn't read your balances"],
      [beamRoute, DIRECTIONS.toEthereum, BLOCKS.network, "Couldn't check that WBEAM can be moved right now"],
      [ethRoute, DIRECTIONS.toBeam, BLOCKS.network, "Couldn't read your balances"],
      [ethRoute, DIRECTIONS.toEthereum, BLOCKS.noPrice, 'Prices are unavailable right now'],
    ];
    for (const [route, d, code, title] of expect) {
      const q = await ctl.quote(route, d, amountFor(route, d));
      assert.equal(q.canMove, false, `${route.id} ${d}`);
      assert.equal(q.block.code, code, `${route.id} ${d}`);
      assert.equal(q.block.title, title, `${route.id} ${d}`);
    }

    // The server is back: nothing was signed or sent meanwhile.
    state.dead = false;
    assert.equal(await rpc.getTransactionCount(who.address, 'pending'), nonce);
    assert.equal(await rpc.getTransactionCount(who.address, 'latest'), nonce);
    // A request whose signing failed is never signed later; planned again, it is.
    await assert.rejects(pipe.sign(plan.steps[0]), isCode('alreadySent'));
    const again = await pipe.planLock(beamRoute, { value: AMOUNTS.beam, fee: e2bFee(beamRoute), receiverKey: beam.key });
    const signed = await pipe.sign(again.steps[0]);
    assert.equal(BigInt(signed.nonce), nonce);
    t.diagnostic(`dead port ${state.port}: ${state.deadRequests} requests refused; sign refused (WBEAM: freeze check, ETH: chain id); quotes blocked; signed again only after planning again`);
  }));

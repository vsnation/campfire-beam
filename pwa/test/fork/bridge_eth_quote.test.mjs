// Quotes on a local anvil mainnet fork (127.0.0.1:8545 only, under the shared
// fork lock, put back with evm_revert), one route each way, through the
// controller with the fork as the Ethereum side and the fixture prices
// injected (the real PriceFeed; nothing is asked of CoinGecko):
//
// * to Ethereum (BEAM → WBEAM): the bridge fee is fees.js's, from the fork's
//   own eth_feeHistory and the fixture prices, and agrees with the relayer's
//   formula worked out here by hand;
// * to BEAM (USDT → bUSDT): the fee, what arrives, and the Ethereum plan
//   priced from the fork (eth_estimateGas, eth_feeHistory) exactly; then the
//   controller sends what it quoted and reads the lock back.
//
//   node --test --test-concurrency=1 --test-timeout=300000 test/fork/bridge_eth_quote.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { routeById, SEND_FEE, CLAIM_FEE, ethToGroth, grothToEth } from '../../src/lib/bridge/routes.js';
import { relayerGas, b2eRelayerMinimum, b2eRelayerFeeGroth, e2bRelayerFee, FEE_MARGIN } from '../../src/lib/bridge/fees.js';
import { totalSource, BLOCKS } from '../../src/lib/bridge/quote.js';
import { STATES, DIRECTIONS } from '../../src/lib/bridge/store.js';
import { erc20ApproveCall, SEND_FUNDS_GAS_TOKEN, STEP_KINDS } from '../../src/lib/bridge/eth_pipe.js';
import { walletFees, gasWithHeadroom } from '../../src/lib/eth/rpc.js';
import { bytesToHex } from '../../src/lib/eth/hex.js';
import { forkProblem, withFork, freshSigner, ethPipeFor, fixturePrices, forkController, forkBeamSide, BEAM_BALANCES, PRICES, AMOUNTS, giveTokens, raw, mined, groth, nextMsgId, pipeHoldings, ETHER } from './bridge_eth_support.mjs';

const skip = await forkProblem();
const T = { skip: skip || false, timeout: 300000 };
const gwei = (wei) => Number(wei) / 1e9;

test('fork: to Ethereum (BEAM → WBEAM): the bridge fee from the fork\'s gas and the fixture prices, as fees.js and the relayer work it out', T, (t) =>
  withFork(async () => {
    const route = routeById('beam');
    const who = await freshSigner(0n); // nothing on Ethereum is needed to receive
    const beam = forkBeamSide();
    const { feed, asked } = fixturePrices();
    const ctl = forkController(ethPipeFor(who), beam, feed);
    const amount = groth(1000);

    const history = await raw('eth_feeHistory', ['0xa', 'latest', [50]]);
    const q = await ctl.quote(route, DIRECTIONS.toEthereum, amount);
    // Nothing was mined in between: the controller read the same history.
    assert.deepEqual(await raw('eth_feeHistory', ['0xa', 'latest', [50]]), history);

    const gas = relayerGas(history);
    const minimum = b2eRelayerMinimum(route, gas, PRICES);
    assert.equal(q.block, null, q.block && q.block.title);
    assert.equal(q.canMove, true);
    assert.equal(q.fee, b2eRelayerFeeGroth(route, gas, PRICES));
    assert.equal(q.feeNow, b2eRelayerFeeGroth(route, gas, PRICES, { margin: 1 }));
    // WBEAM has BEAM's 8 decimals: the relayer's minimum is in groth as it is,
    // and the fee is 1.3 times it, rounded up.
    assert.equal(q.feeNow, minimum);
    assert.equal(q.fee, (minimum * BigInt(FEE_MARGIN * 1000) + 999n) / 1000n);
    // The relayer's formula by hand: relayGas × (2 × base fee + tip) in ETH, at ETH/USD over BEAM/USD.
    assert.equal(gas.baseFee, BigInt(history.baseFeePerGas.at(-1)));
    const tips = history.reward.map((r) => BigInt(r[0])).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    assert.equal(gas.tip, tips[Math.floor(tips.length / 2)]);
    assert.equal(gas.maxFeePerGas, 2n * gas.baseFee + gas.tip);
    const byHand = ((route.relayGas * Number(gas.maxFeePerGas)) / 1e18) * (PRICES.ethereum / PRICES.beam);
    assert.ok(Math.abs(Number(minimum) / 1e8 - byHand) < 1e-6 * byHand, `${Number(minimum) / 1e8} BEAM vs ${byHand} by hand`);

    assert.equal(q.receives, grothToEth(route, amount));
    assert.equal(q.receives, amount);
    assert.equal(q.beamNetworkFee, SEND_FEE);
    assert.equal(totalSource(q), amount + q.fee + SEND_FEE);
    assert.equal(q.ethAddress, who.address);
    assert.equal(asked.length, 1, 'one price request, answered from the fixture');

    // Too little to pay the fee; more than the wallet has.
    assert.equal((await ctl.quote(route, DIRECTIONS.toEthereum, q.fee)).block.code, BLOCKS.belowFee);
    assert.equal((await ctl.quote(route, DIRECTIONS.toEthereum, BEAM_BALANCES[0])).block.code, BLOCKS.notEnough);
    t.diagnostic(
      `fork gas: base ${gwei(gas.baseFee)} gwei, tip ${gwei(gas.tip)} gwei, max ${gwei(gas.maxFeePerGas)} gwei; relayer minimum ${Number(minimum) / 1e8} BEAM, fee ${Number(q.fee) / 1e8} BEAM (×${FEE_MARGIN}) for ${Number(amount) / 1e8} BEAM`,
    );
  }));

test('fork: to BEAM (USDT → bUSDT): the fee, what arrives and the plan priced from the fork; the controller then sends exactly that', T, (t) =>
  withFork(async () => {
    const route = routeById('usdt');
    const value = AMOUNTS.usdt;
    const fee = e2bRelayerFee(route, PRICES);
    const total = value + fee;
    const who = await freshSigner(ETHER);
    await giveTokens(route, who.address, total);
    const beam = forkBeamSide();
    const eth = ethPipeFor(who);
    const ctl = forkController(eth, beam);

    const history = await raw('eth_feeHistory', ['0x5', 'latest', [50]]);
    const approveEstimate = BigInt(await raw('eth_estimateGas', [{ from: who.address, to: route.ethToken, data: bytesToHex(erc20ApproveCall(route.ethPipe, total)) }]));
    const q = await ctl.quote(route, DIRECTIONS.toBeam, value);
    assert.deepEqual(await raw('eth_feeHistory', ['0x5', 'latest', [50]]), history, 'nothing mined in between');

    assert.equal(q.block, null, q.block && q.block.title);
    // 0.02 BEAM worth of USDT at the fixture prices, rounded up to whole USDT units.
    assert.equal(q.fee, fee);
    assert.equal(fee, BigInt(Math.ceil(((0.02 * PRICES.beam) / PRICES.tether) * 1e6)));
    assert.equal(q.amount, value);
    assert.equal(q.receives, ethToGroth(route, value));
    assert.equal(q.receives, value * 100n);
    assert.equal(q.beamNetworkFee, CLAIM_FEE);
    assert.equal(bytesToHex(q.receiveKey), bytesToHex(beam.key));
    assert.deepEqual({ ...q.balances }, { source: total, eth: ETHER, beam: BEAM_BALANCES[0] });
    assert.equal(totalSource(q), total, 'a token: no gas in it');

    // The plan, priced from the fork: an exact approval, then the lock.
    const fees = await walletFees({ feeHistory: async () => history });
    const plan = q.plan;
    assert.deepEqual({ ...plan.fees }, fees);
    assert.deepEqual(
      plan.steps.map((s) => [s.kind, s.gasLimit, s.maxFeePerGas, s.maxPriorityFeePerGas]),
      [
        [STEP_KINDS.approve, gasWithHeadroom(approveEstimate), fees.maxFeePerGas, fees.maxPriorityFeePerGas],
        [STEP_KINDS.lock, SEND_FUNDS_GAS_TOKEN, fees.maxFeePerGas, fees.maxPriorityFeePerGas],
      ],
    );
    const limits = gasWithHeadroom(approveEstimate) + SEND_FUNDS_GAS_TOKEN;
    assert.equal(plan.maxGasCost, limits * fees.maxFeePerGas);
    assert.equal(plan.expectedGasCost, limits * (fees.baseFee + fees.maxPriorityFeePerGas));
    assert.equal((await ctl.quote(route, DIRECTIONS.toBeam, value + 1000000n)).block.code, BLOCKS.notEnough);

    // The controller sends what it quoted, and reads the lock back.
    const msgId = await nextMsgId(route);
    const holdings = await pipeHoldings(route);
    const p = await ctl.prepare(q);
    const c = await ctl.start(p);
    assert.equal(c.state, STATES.approving);
    await ctl.idle();
    const sent = ctl.crossing(c.id);
    assert.equal(sent.state, STATES.locking, sent.lastError);
    assert.equal(sent.approveHashes.length, 1);
    assert.match(sent.lockHash, /^0x[0-9a-f]{64}$/);
    // anvil mines right after it answers the broadcast: once the lock is mined, one look reads it back.
    await mined(sent.lockHash);
    const locked = await ctl.poll(c.id);
    assert.equal(locked.state, STATES.locked, locked.lastError);
    assert.equal(locked.msgId, msgId);
    assert.equal(locked.amount, value);
    assert.equal(locked.relayerFee, fee);
    assert.equal(locked.receives, q.receives);
    assert.equal(locked.beamReceiveKey, bytesToHex(beam.key, false));
    assert.equal((await pipeHoldings(route)) - holdings, total);
    assert.equal(await eth.balance(route), 0n);
    assert.equal(await eth.allowance(route), 0n);
    const receipts = await Promise.all([...sent.approveHashes, sent.lockHash].map((h) => raw('eth_getTransactionReceipt', [h])));
    const spent = receipts.reduce((s, r) => s + BigInt(r.gasUsed) * BigInt(r.effectiveGasPrice), 0n);
    assert.ok(spent <= plan.maxGasCost);
    assert.equal(ETHER - (await eth.ethBalance()), spent);
    t.diagnostic(
      `fork fees: base ${fees.baseFee} wei, tip ${fees.maxPriorityFeePerGas} wei, max ${fees.maxFeePerGas} wei; quoted: ${value} + fee ${fee} USDT units → ${q.receives} groth; plan approve ${plan.steps[0].gasLimit} + lock ${plan.steps[1].gasLimit} gas at most ${plan.maxGasCost} wei; sent: msgId ${locked.msgId}, gas used ${receipts.map((r) => BigInt(r.gasUsed)).join(' + ')}, ${spent} wei, lock ${sent.lockHash}`,
    );
  }));

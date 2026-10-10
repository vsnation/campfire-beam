// Moving coins to BEAM, on a local anvil mainnet fork (127.0.0.1:8545 only,
// under the shared fork lock, put back with evm_revert after each test): for
// each of the five real pipes a fresh wallet plans the lock with the library
// (lib/bridge/eth_pipe.js planLock), the library signs each step (tx.js
// signTransaction, inside EthPipe.sign) and broadcasts it to the fork, and the
// lock is read back from its receipt (decodeLockReceipt): the message id the
// pipe was about to give, the amount, the fee and the receive key that were
// sent. For a token, exactly value + fee is approved and exactly that is spent;
// USDT with an allowance left over is reset to 0 first.
//
//   node --test --test-concurrency=1 --test-timeout=300000 test/fork/bridge_eth_lock.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { ROUTES, routeById, NEW_LOCAL_MESSAGE_TOPIC } from '../../src/lib/bridge/routes.js';
import { BridgeError } from '../../src/lib/bridge/beam_pipe.js';
import { decodeLockReceipt, decodePipeMessage, erc20ApproveCall, ERC20_TRANSFER_TOPIC, ZERO_ADDRESS, STEP_KINDS } from '../../src/lib/bridge/eth_pipe.js';
import { decodeCall, addressTopic } from '../../src/lib/eth/abi.js';
import { bytesToHex, hexToBytes } from '../../src/lib/eth/hex.js';
import { signTransaction, parseSignedTransaction, MAINNET_CHAIN_ID } from '../../src/lib/eth/tx.js';
import { forkProblem, withFork, forkRpc, freshSigner, ethPipeFor, randomReceiverKey, AMOUNTS, e2bFee, mined, giveTokens, sendSigned, nextMsgId, pipeHoldings, ethBalance } from './bridge_eth_support.mjs';

const skip = await forkProblem();
const T = { skip: skip || false, timeout: 300000 };
const refusal = (e) => e instanceof BridgeError && e.code === 'unexpectedTransaction';

/** Locks the route's amount from a fresh wallet, step by step through the library, and checks what moved. */
async function lockOnFork(t, route, { leftover = null, kinds = null } = {}) {
  const rpc = forkRpc();
  const value = AMOUNTS[route.id];
  const fee = e2bFee(route);
  const total = value + fee;
  const who = await freshSigner();
  const pipe = ethPipeFor(who, { rpc });
  const receiverKey = randomReceiverKey();

  if (!route.isNativeEth) {
    await giveTokens(route, who.address, total);
    assert.equal(await pipe.balance(route), total);
    assert.equal(await pipe.allowance(route), 0n);
  }
  if (leftover !== null) {
    // An approval left from before, signed and sent straight from the key.
    await sendSigned(who, { to: route.ethToken, data: erc20ApproveCall(route.ethPipe, leftover), gasLimit: 100000n });
    assert.equal(await pipe.allowance(route), leftover);
  }
  assert.deepEqual(await pipe.freezes(route, { fresh: true }), [], 'nothing frozen on the fork');

  const msgId = await nextMsgId(route);
  const holdingsBefore = await pipeHoldings(route);
  const ethBefore = await ethBalance(who.address);

  const plan = await pipe.planLock(route, { value, fee, receiverKey });
  const expectKinds = kinds ?? [...(route.isNativeEth ? [] : [STEP_KINDS.approve]), STEP_KINDS.lock];
  assert.deepEqual(
    plan.steps.map((s) => s.kind),
    expectKinds,
  );
  assert.equal(plan.value, value);
  assert.equal(plan.fee, fee);
  assert.equal(bytesToHex(plan.receiverKey), bytesToHex(receiverKey));
  for (const s of plan.steps) {
    if (s.kind === STEP_KINDS.lock) {
      assert.equal(s.to, route.ethPipe);
      assert.equal(s.value, route.isNativeEth ? total : 0n, 'ETH goes with the call; a token goes by transferFrom');
      const [v, f, k] = decodeCall('sendFunds(uint256,uint256,bytes)', s.data);
      assert.deepEqual([v, f, bytesToHex(k)], [value, fee, bytesToHex(receiverKey)]);
    } else {
      // Never "any amount": exactly what this lock takes (0 for USDT's reset).
      assert.equal(s.to, route.ethToken);
      const [spender, amount] = decodeCall('approve(address,uint256)', s.data);
      assert.equal(spender.toLowerCase(), route.ethPipe);
      assert.equal(amount, s.kind === STEP_KINDS.approveReset ? 0n : total);
    }
  }

  const gas = [];
  let gasPaid = 0n;
  let lockHash = null;
  let lockReceipt = null;
  for (const step of plan.steps) {
    const nonce = await rpc.getTransactionCount(who.address, 'pending');
    const signed = await pipe.sign(step);
    // The library signs with tx.js: the same fields signed here give the same
    // bytes (RFC 6979 signatures are deterministic).
    const direct = signTransaction(
      { chainId: MAINNET_CHAIN_ID, nonce, to: step.to, data: step.data, value: step.value, gasLimit: step.gasLimit, maxFeePerGas: step.maxFeePerGas, maxPriorityFeePerGas: step.maxPriorityFeePerGas },
      who.sk,
    );
    assert.equal(signed.raw, direct.raw);
    assert.equal(signed.hash, direct.hash);
    assert.equal(BigInt(signed.nonce), nonce);
    const parsed = parseSignedTransaction(signed.raw);
    assert.equal(parsed.tx.chainId, 1n);
    assert.equal(parsed.from.toLowerCase(), who.address);
    assert.equal(await pipe.broadcast(signed.raw), signed.hash);
    const receipt = await mined(signed.hash);
    assert.equal(receipt.status, '0x1', `${step.kind} mined`);
    const used = BigInt(receipt.gasUsed);
    assert.ok(used <= step.gasLimit, `${step.kind}: gas used within the limit`);
    gasPaid += used * BigInt(receipt.effectiveGasPrice);
    assert.ok(BigInt(receipt.effectiveGasPrice) <= step.maxFeePerGas);
    gas.push(`${step.kind} ${used}/${step.gasLimit}`);
    if (step.kind === STEP_KINDS.lock) {
      lockHash = signed.hash;
      lockReceipt = receipt;
    } else {
      assert.equal(await pipe.succeeded(signed.hash), true);
      assert.equal(await pipe.allowance(route), step.kind === STEP_KINDS.approveReset ? 0n : total, `${step.kind}: the allowance after it`);
    }
  }
  assert.ok(gasPaid <= plan.maxGasCost, 'paid no more gas than the plan said it could cost');

  // The receipt, read by the library.
  const lock = decodeLockReceipt(route, lockReceipt, { owner: who.address, value, fee, receiverKey });
  assert.deepEqual({ ...lock }, { hash: lockHash, success: true, blockNumber: Number(lockReceipt.blockNumber), msgId });
  assert.deepEqual(await pipe.lockResult(route, lockHash, { value, fee, receiverKey }), lock);
  assert.equal(await nextMsgId(route), msgId + 1, 'the pipe counted one message');
  // The message itself, field by field.
  const messages = lockReceipt.logs.filter((l) => l.topics[0] === NEW_LOCAL_MESSAGE_TOPIC);
  assert.equal(messages.length, 1);
  assert.equal(messages[0].address.toLowerCase(), route.ethPipe);
  const m = decodePipeMessage(hexToBytes(messages[0].data));
  assert.equal(m.msgId, msgId);
  assert.equal(m.amount, value);
  assert.equal(m.relayerFee, fee);
  assert.equal(bytesToHex(m.receiver), bytesToHex(receiverKey));
  // Read as anyone else's lock, it is refused.
  const otherKey = randomReceiverKey();
  const grid = route.ethGrid;
  for (const [what, args] of [
    ['another receiver', { owner: who.address, value, fee, receiverKey: otherKey }],
    ['another amount', { owner: who.address, value: value + grid, fee, receiverKey }],
    ['another fee', { owner: who.address, value, fee: fee + grid, receiverKey }],
    ['another sender', { owner: (await freshSigner(0n)).address, value, fee, receiverKey }],
  ]) {
    assert.throws(() => decodeLockReceipt(route, lockReceipt, args), refusal, what);
  }

  // What moved: value + fee into the pipe (WBEAM: burnt), and only gas besides.
  const holdingsAfter = await pipeHoldings(route);
  assert.equal(route.isBeam ? holdingsBefore - holdingsAfter : holdingsAfter - holdingsBefore, total, route.isBeam ? 'WBEAM burnt' : 'the pipe took value + fee');
  assert.equal(ethBefore - (await ethBalance(who.address)), gasPaid + (route.isNativeEth ? total : 0n), 'ETH: the lock (for the ETH route) and gas, nothing else');
  if (!route.isNativeEth) {
    assert.equal(await pipe.balance(route), 0n, 'exactly value + fee spent');
    assert.equal(await pipe.allowance(route), 0n, 'nothing left approved');
    const transfers = lockReceipt.logs.filter((l) => l.address.toLowerCase() === route.ethToken && l.topics[0] === ERC20_TRANSFER_TOPIC);
    assert.equal(transfers.length, 1);
    assert.deepEqual(transfers[0].topics.slice(1), [addressTopic(who.address), addressTopic(route.isBeam ? ZERO_ADDRESS : route.ethPipe)]);
    assert.equal(BigInt(transfers[0].data), total);
  }
  t.diagnostic(`${route.ethSymbol} → ${route.beamSymbol}: msgId ${msgId}, value ${value}, fee ${fee} (${route.ethSymbol} units), gas ${gas.join(', ')}, block ${lock.blockNumber}, lock ${lockHash}`);
  return { msgId, gas, lock };
}

for (const route of ROUTES) {
  test(`fork: ${route.ethSymbol} → ${route.beamSymbol}: planLock, sign, broadcast, and the lock read back from its receipt`, T, (t) => withFork(() => lockOnFork(t, route)));
}

test('fork: USDT with an allowance left over: reset to 0, approve exactly, lock', T, (t) =>
  withFork(async () => {
    const usdt = routeById('usdt');
    // USDT refuses to change a non-zero allowance: the direct approve reverts.
    await lockOnFork(t, usdt, { leftover: 5n, kinds: [STEP_KINDS.approveReset, STEP_KINDS.approve, STEP_KINDS.lock] });
  }));

test('fork: DAI with an allowance left over: changed directly, no reset', T, (t) =>
  withFork(async () => {
    await lockOnFork(t, routeById('dai'), { leftover: 5n, kinds: [STEP_KINDS.approve, STEP_KINDS.lock] });
  }));

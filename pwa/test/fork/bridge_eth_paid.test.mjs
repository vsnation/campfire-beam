// Coming from BEAM, the paid flag (lib/bridge/eth_pipe.js isPaid: one
// eth_getStorageAt of processed[msgId] in the route's pipe), on a local anvil
// mainnet fork (127.0.0.1:8545 only, under the shared fork lock, put back with
// evm_revert): messages the relayer paid on mainnet read as paid and the next
// ones do not; then, for each pipe, its own relayer (read from the pipe's
// storage and impersonated) pays a BEAM-side message with processRemoteMessage
// and the flag flips for exactly that message.
//
//   node --test --test-concurrency=1 --test-timeout=300000 test/fork/bridge_eth_paid.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { ROUTES, routeById } from '../../src/lib/bridge/routes.js';
import { processedKey } from '../../src/lib/bridge/eth_pipe.js';
import { encodeCall } from '../../src/lib/eth/abi.js';
import { forkProblem, withFork, freshSigner, ethPipeFor, AMOUNTS, e2bFee, raw, sendAs, relayerOf, erc20Balance, ethBalance, hex } from './bridge_eth_support.mjs';

const skip = await forkProblem();
const T = { skip: skip || false, timeout: 300000 };
const PROCESS = 'processRemoteMessage(uint64,uint256,uint256,address)';

test('fork: the paid flag of BEAM-side messages the relayer paid on mainnet, and of the next ones, which it has not', T, () =>
  withFork(async () => {
    const pipe = ethPipeFor(await freshSigner(0n));
    // Research note 06 (Summary 13), WBTC and DAI checked the same way with
    // cast on this fork (block 26,155,400): the last paid id of each pipe and
    // the one after it; BEAM 563 is the uint64-overflow message, never paid.
    const known = [
      ['eth', 107, true],
      ['eth', 108, false],
      ['usdt', 108, true],
      ['usdt', 109, false],
      ['beam', 639, true],
      ['beam', 640, false],
      ['beam', 563, false],
      ['wbtc', 19, true],
      ['wbtc', 20, false],
      ['dai', 40, true],
      ['dai', 41, false],
    ];
    for (const [id, msgId, paid] of known) {
      const route = routeById(id);
      assert.equal(await pipe.isPaid(route, msgId), paid, `${id} ${msgId}`);
      // The word isPaid reads is the pipe's own storage at processedKey.
      const word = BigInt(await raw('eth_getStorageAt', [route.ethPipe, processedKey(msgId, route.processedSlot), 'latest']));
      assert.equal(word, paid ? 1n : 0n, `${id} ${msgId}: storage`);
    }
  }));

for (const route of ROUTES) {
  test(`fork: ${route.ethSymbol}: the pipe's relayer pays a BEAM-side message and the paid flag flips`, T, (t) =>
    withFork(async () => {
      const pipe = ethPipeFor(await freshSigner(0n));
      const value = AMOUNTS[route.id];
      const fee = e2bFee(route);
      const relayer = await relayerOf(route);
      assert.notEqual(relayer, '0x0000000000000000000000000000000000000000');
      const user = (await freshSigner(0n)).address;
      const msgId = 1000000; // far beyond any real BEAM-side id
      // Note the order: (msgId, relayerFee, amount, receiver), not the event's (msgId, amount, relayerFee, receiver).
      const pay = encodeCall(PROCESS, [BigInt(msgId), fee, value, user]);
      // Only the relayer may pay: anyone else is refused (so this is the relayer, and the slot layout is right).
      const stranger = (await freshSigner(10n ** 18n)).address;
      await assert.rejects(raw('eth_call', [{ from: stranger, to: route.ethPipe, data: `0x${Buffer.from(pay).toString('hex')}` }, 'latest']), /revert/i, 'a stranger cannot pay');

      assert.equal(await pipe.isPaid(route, msgId), false);
      const balanceOf = (who) => (route.isNativeEth ? ethBalance(who) : erc20Balance(route.ethToken, who));
      const before = await balanceOf(user);
      const relayerBefore = route.isNativeEth ? null : await balanceOf(relayer);
      const r = await sendAs(relayer, route.ethPipe, pay);
      assert.equal(await pipe.isPaid(route, msgId), true, 'paid');
      assert.equal(await pipe.isPaid(route, msgId + 1), false, 'only that message');
      assert.equal(await pipe.isPaid(route, msgId - 1), false, 'only that message');
      assert.equal((await balanceOf(user)) - before, value, 'the user is paid the amount');
      if (!route.isNativeEth) assert.equal((await balanceOf(relayer)) - relayerBefore, fee, 'the relayer keeps the fee');
      // The flag is what the pipe itself checks: the same message cannot be paid twice.
      await raw('anvil_impersonateAccount', [relayer]);
      try {
        await assert.rejects(raw('eth_call', [{ from: relayer, to: route.ethPipe, data: `0x${Buffer.from(pay).toString('hex')}` }, 'latest']), /revert/i, 'paid once only');
      } finally {
        await raw('anvil_stopImpersonatingAccount', [relayer]).catch(() => {});
      }
      t.diagnostic(`${route.ethSymbol}: relayer ${relayer}, processed slot ${route.processedSlot}, key ${processedKey(msgId, route.processedSlot)}, paid ${value} + fee ${fee}, gas ${BigInt(r.gasUsed)}, tx ${r.transactionHash} (${hex(BigInt(r.blockNumber))})`);
    }));
}

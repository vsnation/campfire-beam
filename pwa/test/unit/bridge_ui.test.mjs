// The words and numbers of the bridge screens (screens/bridge_text.js,
// screens/bridge_words.js): amounts typed in each chain's decimals, the
// buttons' outcome labels, the limits said before typing, the approve sheet's
// bridge rows (only when the engine's report agrees with the request), where a
// move is in plain words, and the copies of library values held to them.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ROUTES, routeById, SEND_FEE, CLAIM_FEE } from '../../src/lib/bridge/routes.js';
import { TIMING, toEthereumSlowestMs, coinText, sourceSymbol as qSourceSymbol, destinationSymbol as qDestinationSymbol, sourceDecimals as qSourceDecimals, destinationDecimals as qDestinationDecimals, movableDecimals as qMovable } from '../../src/lib/bridge/quote.js';
import { DIRECTIONS, STATES, makeCrossing, BRIDGE_RECORD_KEY } from '../../src/lib/bridge/store.js';
import * as T from '../../src/screens/bridge_text.js';
import { crossingWords, crossingSteps, headline, lockedNote } from '../../src/screens/bridge_words.js';

const here = dirname(fileURLToPath(import.meta.url));
const beam = routeById('beam');
const eth = routeById('eth');
const usdt = routeById('usdt');
const E18 = 10n ** 18n;

test('copies of library values equal the library: timings, directions, symbols, decimals, the store key', () => {
  assert.equal(T.ABOUT_TO_ETHEREUM_MS, TIMING.toEthereumMs);
  assert.equal(T.ABOUT_TO_BEAM_MS, TIMING.toBeamMs);
  assert.equal(T.TO_ETHEREUM, DIRECTIONS.toEthereum);
  assert.equal(T.TO_BEAM, DIRECTIONS.toBeam);
  for (const r of ROUTES) {
    assert.equal(T.slowestToEthereumMs(r), toEthereumSlowestMs(r));
    assert.equal(T.movableDecimals(r), qMovable(r));
    for (const d of [T.TO_ETHEREUM, T.TO_BEAM]) {
      assert.equal(T.sourceSymbol(r, d), qSourceSymbol(r, d));
      assert.equal(T.destinationSymbol(r, d), qDestinationSymbol(r, d));
      assert.equal(T.sourceDecimals(r, d), qSourceDecimals(r, d));
      assert.equal(T.destinationDecimals(r, d), qDestinationDecimals(r, d));
    }
  }
  for (const [v, d] of [[0n, 8], [1n, 8], [107250000000n, 8], [123456789012345678901n, 18], [5n, 6], [-150000000n, 8], [1234n, 0]]) assert.equal(T.exact(v, d), coinText(v, d));
  // eth_screens.js reads the store key without importing store.js (it pulls in the Ethereum code).
  assert.equal(BRIDGE_RECORD_KEY, 'bridge');
  assert.match(readFileSync(join(here, '..', '..', 'src', 'screens', 'eth_screens.js'), 'utf8'), /store\.get\('bridge'\)/);
});

test('amounts: each chain\'s decimals, at most what a move carries, never a comma or a guess', () => {
  assert.deepEqual(T.parseBridgeAmount('', beam, T.TO_ETHEREUM), { value: null, error: null });
  assert.deepEqual(T.parseBridgeAmount('300', beam, T.TO_ETHEREUM), { value: 30000000000n, error: null });
  assert.deepEqual(T.parseBridgeAmount('0.5', eth, T.TO_BEAM), { value: E18 / 2n, error: null });
  assert.deepEqual(T.parseBridgeAmount('.25', eth, T.TO_ETHEREUM), { value: 25000000n, error: null });
  assert.deepEqual(T.parseBridgeAmount('1.123456', usdt, T.TO_BEAM), { value: 1123456n, error: null });
  assert.equal(T.parseBridgeAmount('1,5', beam, T.TO_ETHEREUM).error, 'Use a dot for decimals, like 0.5');
  assert.equal(T.parseBridgeAmount('1e5', beam, T.TO_ETHEREUM).error, 'Enter a number, like 0.5');
  assert.equal(T.parseBridgeAmount('.', beam, T.TO_ETHEREUM).error, 'Enter a number, like 0.5');
  assert.equal(T.parseBridgeAmount('0.123456789', eth, T.TO_BEAM).error, 'ETH moves with at most 8 decimals');
  assert.equal(T.parseBridgeAmount('1.1234567', usdt, T.TO_ETHEREUM).error, 'bUSDT moves with at most 6 decimals');
  assert.equal(T.parseBridgeAmount('100000000000', beam, T.TO_ETHEREUM).error, 'That amount is too large');
});

test('labels say the outcome; limits and the claim requirement are words before typing', () => {
  assert.equal(T.moveLabel(beam, T.TO_ETHEREUM, 30000000000n), 'Move 300 BEAM to Ethereum');
  assert.equal(T.moveLabel(eth, T.TO_BEAM, E18 / 2n), 'Move 0.5 ETH to BEAM');
  assert.equal(T.moveLabel(usdt, T.TO_ETHEREUM, null), 'Move to Ethereum');
  assert.equal(T.collectLabel(eth, 50000000n), 'Collect 0.5 bETH');
  assert.equal(T.limitsText(beam, T.TO_ETHEREUM, null), 'At most 3,000,000 BEAM per move.');
  assert.equal(T.limitsText(beam, T.TO_ETHEREUM, 2437123456n), 'More than the bridge fee (now 24.3713 BEAM), at most 3,000,000 BEAM per move.');
  assert.equal(T.limitsText(eth, T.TO_ETHEREUM, 12345n), 'More than the bridge fee (now 0.00012345 bETH).');
  assert.equal(T.limitsText(eth, T.TO_BEAM), 'Collecting it on BEAM costs 0.121 BEAM from your BEAM wallet.');
  assert.equal(T.needsPrices(beam, T.TO_BEAM), false, 'WBEAM to BEAM pays a fixed fee');
  for (const r of ROUTES) assert.equal(T.needsPrices(r, T.TO_ETHEREUM), true);
  assert.equal(T.needsPrices(eth, T.TO_BEAM), true);
  assert.equal(T.arrivesText(beam, T.TO_ETHEREUM), 'About 1 hour; up to 11 hours when Ethereum is busy');
  assert.equal(T.arrivesText(eth, T.TO_BEAM), 'About 2 minutes, then you collect it');
  assert.equal(T.roundedUp(1234567891n, 18, 6), '0.000001');
  assert.equal(T.feeText(2437123456n, 8), '24.3713', 'a fee is never understated');
  assert.equal(T.feeText(12345n, 8), '0.00012345');
  assert.equal(T.feeText(30000000000001n, 18), '0.00003001');
  assert.equal(T.rounded(1234567891n, 18, 6), '0.0000000012', 'a tiny amount keeps its first digits');
  assert.equal(T.grouped('0x1f3A9c00000000000000000000000000000000aB'), '0x 1f3A 9c00 0000 0000 0000 0000 0000 0000 0000 00aB');
});

const ADDR = '0x5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a';
const sendReq = (over = {}) => ({
  kind: 'contract',
  native: true,
  fee: SEND_FEE,
  spends: [{ assetId: 0, amount: 30000000000n + 2437123456n }],
  receives: [],
  intent: { action: 'bridge', direction: 'toEthereum', route: 'beam', amount: 30000000000n, fee: 2437123456n, receiver: ADDR },
  ...over,
});

test('the approve sheet\'s bridge rows: only when what the engine reports is exactly what was asked for', () => {
  const b = T.bridgeConsent(sendReq());
  assert.equal(b.kind, 'send');
  assert.equal(b.label, 'Move 300 BEAM to Ethereum');
  assert.equal(b.receives, 30000000000n, 'WBEAM 1:1');
  assert.equal(b.out, 30000000000n + 2437123456n + SEND_FEE);
  assert.equal(b.receiver, ADDR);
  // bETH to ETH: what arrives is in wei; the network fee is BEAM, apart from bETH.
  const e = T.bridgeConsent(sendReq({ spends: [{ assetId: 36, amount: 50000000n + 12345n }], intent: { action: 'bridge', direction: 'toEthereum', route: 'eth', amount: 50000000n, fee: 12345n, receiver: ADDR } }));
  assert.equal(e.receives, E18 / 2n);
  assert.equal(e.out, 50000000n + 12345n);
  assert.equal(e.label, 'Move 0.5 bETH to Ethereum');
  // Anything that does not agree: the plain rows.
  assert.equal(T.bridgeConsent(sendReq({ spends: [{ assetId: 0, amount: 30000000000n }] })), null, 'the fee missing from what leaves');
  assert.equal(T.bridgeConsent(sendReq({ fee: 100000n })), null, 'another network fee');
  assert.equal(T.bridgeConsent(sendReq({ receives: [{ assetId: 0, amount: 1n }] })), null);
  assert.equal(T.bridgeConsent(sendReq({ native: false })), null, 'only the wallet itself may describe a request');
  assert.equal(T.bridgeConsent(sendReq({ intent: { ...sendReq().intent, receiver: '0x12' } })), null);
  assert.equal(T.bridgeConsent(sendReq({ intent: { ...sendReq().intent, route: 'nope' } })), null);
  assert.equal(T.bridgeConsent(sendReq({ intent: { action: 'swap' } })), null);
  // Collecting.
  const collectReq = { kind: 'contract', native: true, fee: CLAIM_FEE, spends: [], receives: [{ assetId: 36, amount: 50000000n }], intent: { action: 'bridge', direction: 'toBeam', route: 'eth', amount: 50000000n, msgId: 222 } };
  const c = T.bridgeConsent(collectReq);
  assert.deepEqual([c.kind, c.label, c.msgId], ['collect', 'Collect 0.5 bETH', 222]);
  assert.equal(T.bridgeConsent({ ...collectReq, receives: [{ assetId: 36, amount: 49999999n }] }), null);
  assert.equal(T.bridgeConsent({ ...collectReq, fee: SEND_FEE }), null);
});

const crossing = (over = {}) =>
  makeCrossing({
    id: 'x1',
    route: 'beam',
    direction: 'toEthereum',
    state: STATES.confirmed,
    amount: 30000000000n,
    receives: 30000000000n,
    relayerFee: 2437123456n,
    beamNetworkFee: SEND_FEE,
    beamWalletId: 'b',
    ethWalletId: 'e',
    ethAddress: ADDR,
    createdAt: Date.now() - 5 * 60000,
    updatedAt: Date.now(),
    msgId: 12,
    height: 4100000,
    ...over,
  });

test('where a move is, in words: blocks to go, waiting for Ethereum, ready to collect', () => {
  assert.equal(headline(crossing()), '300 BEAM → Ethereum');
  assert.equal(crossingWords(crossing(), { blocksLeft: 34 }).title, 'On its way: 34 BEAM blocks to go');
  assert.equal(crossingWords(crossing(), { blocksLeft: 1 }).short, '1 block to go');
  assert.equal(crossingWords(crossing(), { blocksLeft: 0 }).title, 'Due now: the bridge is paying it');
  assert.equal(crossingWords(crossing({ state: STATES.paid })).title, '300 WBEAM arrived in your Ethereum wallet');
  const notApproved = crossingWords(crossing({ state: STATES.failed, msgId: null, lastError: 'You did not approve it, so nothing left your wallet.' }));
  assert.deepEqual([notApproved.title, notApproved.mood], ['Not sent', 'error']);
  const toBeam = { route: 'eth', direction: 'toBeam', amount: E18 / 100n, receives: 1000000n, relayerFee: 3000000000000n, beamNetworkFee: CLAIM_FEE, msgId: null, height: null };
  const locking = crossingWords(crossing({ ...toBeam, state: STATES.locking, lockHash: `0x${'ab'.repeat(32)}` }));
  assert.equal(locking.short, 'Waiting for Ethereum');
  assert.match(locking.detail, /^Waiting for Ethereum/);
  const ready = crossingWords(crossing({ ...toBeam, state: STATES.delivered, msgId: 9 }));
  assert.deepEqual([ready.title, ready.short, ready.needsYou], ['Ready to collect', 'Collect', true]);
  assert.match(ready.detail, /0\.121 BEAM network fee/);
  assert.equal(crossingWords(crossing({ ...toBeam, state: STATES.claimed, msgId: 9 })).title, '0.01 bETH is in your BEAM wallet');
});

test('the steps of a move, each done, under way or still to come', () => {
  const s = crossingSteps(crossing(), { blocksLeft: 34 });
  assert.deepEqual(
    s.map((x) => [x.label, x.status, x.note]),
    [
      ['Sent from your BEAM wallet', 'done', '5 min ago'],
      ['In BEAM block 4,100,000', 'done', null],
      ['61 BEAM blocks', 'active', '34 to go'],
      ['Paid to your Ethereum wallet', 'waiting', null],
    ],
  );
  const toBeam = { route: 'beam', direction: 'toBeam', amount: 10000000000n, receives: 10000000000n, relayerFee: 2000000n, beamNetworkFee: CLAIM_FEE, msgId: null, height: null };
  const approving = crossingSteps(crossing({ ...toBeam, state: STATES.approving }));
  assert.deepEqual(approving.map((x) => x.status), ['active', 'waiting', 'waiting', 'waiting']);
  assert.equal(approving[0].label, 'Bridge allowed to take your WBEAM');
  const locked = crossingSteps(crossing({ ...toBeam, state: STATES.locked, msgId: 400, approveHashes: [`0x${'01'.repeat(32)}`], lockHash: `0x${'02'.repeat(32)}` }));
  assert.deepEqual(locked.map((x) => x.status), ['done', 'done', 'active', 'waiting']);
  const eth = crossingSteps(crossing({ ...toBeam, route: 'eth', state: STATES.delivered, msgId: 7 }));
  assert.deepEqual(eth.map((x) => [x.status, x.note]), [['done', '5 min ago'], ['done', null], ['active', 'Your turn']]);
});

test('the lock screen says where a move is, never its amount or address', () => {
  const note = lockedNote(crossing(), { blocksLeft: 34 });
  assert.equal(note, 'Your move to Ethereum was at "34 blocks to go" when BEAM Campfire locked.');
  assert.ok(!/300|5a5a|WBEAM/.test(note));
  assert.equal(lockedNote(crossing({ route: 'eth', direction: 'toBeam', state: STATES.delivered, receives: 1000000n, amount: E18 / 100n, relayerFee: 1n, beamNetworkFee: CLAIM_FEE })), 'Your move to BEAM is ready to collect.');
  assert.equal(lockedNote(crossing({ state: STATES.paid })), null);
});

// D-2: an Ethereum network fee is one server's number (eth_feeHistory), and the tip of it is paid
// in full to whoever builds the block. A lying or broken server must not be able to set it: the
// tip is bounded (lib/eth/rpc.js walletFees), base fees Ethereum cannot have produced are refused,
// a fee that is a large share of an ETH payment is pointed out (lib/eth/send.js), and the bridge
// fee, which the relayer keeps above its minimum, is priced at no more than a set gas price
// (lib/bridge/fees.js cappedGas). The audit's proof of concept is the first test, as it was.
import test from 'node:test';
import assert from 'node:assert/strict';
import { baseFeeKind, walletFees, baseFeeProblem, EthRpcError, EASY_TIP_WEI, MAX_TIP_WEI, MAX_BASE_FEE_WEI, MIN_TIP_WEI } from '../../src/lib/eth/rpc.js';
import { prepareSend, feeShare, isHighFee, HIGH_FEE_SHARE } from '../../src/lib/eth/send.js';
import { ETH, WBEAM } from '../../src/lib/eth/tokens.js';
import { relayerGas, b2eRelayerFeeGroth, cappedGas, MAX_FEE_GAS_PRICE } from '../../src/lib/bridge/fees.js';
import { readConditions, quoteToEthereum } from '../../src/lib/bridge/quote.js';
import { routeById } from '../../src/lib/bridge/routes.js';

const GWEI = 1000000000n;
const ETHER = 10n ** 18n;
const hex = (v) => '0x' + v.toString(16);
const FROM = '0x1111111111111111111111111111111111111111';
const TO = '0x2222222222222222222222222222222222222222';

/** A server that answers eth_feeHistory with these base fees and 50th-percentile tips (wei). */
function server(bases, tips) {
  return {
    host: { name: 'Test server' },
    async feeHistory(n) {
      return { baseFeePerGas: bases.map(hex), reward: tips.map((t) => [hex(t)]) };
    },
    async estimateGas() {
      return 21000n;
    },
    async getCode() {
      return new Uint8Array(0);
    },
    async ethCall() {
      return new Uint8Array(32).fill(0).map((_, i) => (i === 31 ? 1 : 0));
    },
  };
}

test('D-2 proof of concept: a 40,000 gwei "median tip" no longer becomes a 0.84 ETH fee on a 0.1 ETH payment', async () => {
  // As the audit ran it: an honest-looking 1 gwei base fee, a lying 40,000 gwei tip in every block.
  const liar = server(Array(6).fill(1n * GWEI), Array(5).fill(40000n * GWEI));
  const fees = await walletFees(liar);
  assert.equal(fees.maxPriorityFeePerGas, EASY_TIP_WEI, 'at most 3 gwei while Ethereum is quiet');
  const p = await prepareSend(liar, { from: FROM, asset: ETH, recipient: TO, amount: ETHER / 10n, balances: { eth: ETHER } });
  assert.equal(p.fees.likely, 21000n * 4n * GWEI, 'base 1 + tip 3 gwei: 0.000084 ETH, not 0.84');
  assert.ok(p.fees.upTo <= 21000n * 5n * GWEI);
  assert.equal(p.highFee, false);
});

test('the tip: the median as before, at most 3 gwei, or 3 x the base fee when Ethereum is busy, never above 20 gwei', async () => {
  assert.equal(EASY_TIP_WEI, 3n * GWEI);
  assert.equal(MAX_TIP_WEI, 20n * GWEI);
  // Honest, quiet: base 0.5 gwei, tips around 0.1-2 gwei: the median, untouched.
  const quiet = await walletFees(server(Array(6).fill(GWEI / 2n), [1n, 2n, 20n, 5n, 3n].map((t) => (t * GWEI) / 10n)));
  assert.equal(quiet.maxPriorityFeePerGas, (3n * GWEI) / 10n);
  // Busy: base 4 gwei, median tip 9 gwei: under 3 x 4 = 12, kept.
  assert.equal((await walletFees(server(Array(6).fill(4n * GWEI), Array(5).fill(9n * GWEI)))).maxPriorityFeePerGas, 9n * GWEI);
  // A tip of 13 gwei on a base of 4: held at 12.
  assert.equal((await walletFees(server(Array(6).fill(4n * GWEI), Array(5).fill(13n * GWEI)))).maxPriorityFeePerGas, 12n * GWEI);
  // Very busy: base 100 gwei, any tip above 20 gwei is held at 20.
  const busy = await walletFees(server(Array(6).fill(100n * GWEI), Array(5).fill(500n * GWEI)));
  assert.equal(busy.maxPriorityFeePerGas, MAX_TIP_WEI);
  assert.equal(busy.maxFeePerGas, 200n * GWEI + MAX_TIP_WEI);
  // The floor is unchanged.
  assert.equal((await walletFees(server([5n, 5n], [1n]))).maxPriorityFeePerGas, MIN_TIP_WEI);
});

test('base fees Ethereum cannot have produced are refused, not paid: too high, or jumping between blocks', async () => {
  assert.equal(MAX_BASE_FEE_WEI, 1000n * GWEI);
  const refused = async (bases) => {
    const e = await walletFees(server(bases, [GWEI])).catch((x) => x);
    assert.ok(e instanceof EthRpcError && e.code === 'bad_fees', `${bases.map((b) => b / GWEI)}: ${e}`);
    assert.match(e.message, /Test server gave network fee figures Ethereum cannot have/);
    assert.equal(e.data.problem, 'jump');
  };
  // BM-6: too high is a fee Ethereum has charged (over 8,000 gwei for a few blocks on 2022-05-01): said
  // as more than Beam PWA pays, not as impossible.
  const high = await walletFees(server(Array(6).fill(5000n * GWEI), [GWEI])).catch((x) => x); // the bridge proof of concept's base fee
  assert.ok(high instanceof EthRpcError && high.code === 'bad_fees');
  assert.equal(high.data.problem, 'high');
  assert.equal(high.message, 'Test server says Ethereum\'s network fee is a base fee of 5000 gwei, far above anything Beam PWA will pay.');
  assert.equal(baseFeeKind(Array(6).fill(5000n * GWEI)), 'high');
  assert.equal(baseFeeKind([...Array(5).fill(GWEI), 2n * GWEI]), 'jump');
  assert.equal(baseFeeKind([GWEI, GWEI]), null);
  await refused([...Array(5).fill(GWEI), 2n * GWEI]); // doubled in one block
  await refused([10n * GWEI, 10n * GWEI, 6n * GWEI]); // dropped by 40%
  // Ethereum's own steps (at most an eighth either way) pass, and so does twice that.
  const real = [1000000000n, 1125000000n, 1265625000n, 1107421875n, 1245849609n, 1090118408n];
  assert.equal(baseFeeProblem(real), null);
  assert.equal(baseFeeProblem([4n * GWEI, 5n * GWEI]), null, '+25%');
  assert.equal(baseFeeProblem([MAX_BASE_FEE_WEI]), null);
  assert.match(baseFeeProblem([MAX_BASE_FEE_WEI + 1n]), /1000 gwei/);
  // A real answer of 2026-10-09 (eth_feeHistory 0xa): fine.
  assert.equal(baseFeeProblem(['0xd296a7d', '0xce68b9b', '0xd540d04', '0xc0f5918', '0xd1cf3ec', '0xd0e69ff', '0xeb01e7d', '0x1085fd37', '0x122be423', '0x1416d60d', '0x153f25be'].map(BigInt)), null);
});

test('a fee above 10% of an ETH payment is flagged for a tick; a token payment has nothing to compare', async () => {
  assert.equal(HIGH_FEE_SHARE, 0.1);
  assert.equal(feeShare(10n, 100n), 0.1);
  assert.equal(isHighFee(0.1), false);
  assert.equal(isHighFee(0.100001), true);
  assert.equal(isHighFee(null), false);
  assert.equal(feeShare(1n, 0n), null);
  const s = server(Array(6).fill(10n * GWEI), Array(5).fill(3n * GWEI)); // 13 gwei: 0.000273 ETH for a payment
  const small = await prepareSend(s, { from: FROM, asset: ETH, recipient: TO, amount: 10n ** 14n, balances: { eth: ETHER } });
  assert.equal(small.fees.likely, 273000000000000n);
  assert.equal(small.feeShare, 2.73);
  assert.equal(small.highFee, true);
  const fine = await prepareSend(s, { from: FROM, asset: ETH, recipient: TO, amount: 10n ** 16n, balances: { eth: ETHER } });
  assert.equal(fine.highFee, false, '2.7%');
  const token = await prepareSend(s, { from: FROM, asset: WBEAM, recipient: TO, amount: 1n, balances: { eth: ETHER, WBEAM: 10n } });
  assert.equal(token.feeShare, null);
  assert.equal(token.highFee, false);
});

// ---------------------------------------------------------------- the bridge fee

const beam = routeById('beam');
const PRICES = { ethereum: 2500, beam: 0.02, 'wrapped-bitcoin': 60000, tether: 1, dai: 1 };
const history = (baseGwei, tipGwei = 1n) => ({ baseFeePerGas: Array(11).fill(hex(baseGwei * GWEI)), reward: Array(10).fill([hex(tipGwei * GWEI)]) });

test('the bridge fee is priced at no more than 100 gwei of gas: the proof of concept\'s 156,015 BEAM is a few thousand at most', () => {
  assert.equal(MAX_FEE_GAS_PRICE, 100n * GWEI);
  const honest = b2eRelayerFeeGroth(beam, cappedGas(relayerGas(history(1n))), PRICES);
  assert.equal(honest, 4680000000n, '46.8 BEAM at 1 gwei, as the audit measured');
  assert.equal(cappedGas(relayerGas(history(1n))).capped, undefined, 'not touched below the cap');
  // The audit's 5,000 gwei base fee: refused by the pipe (bridge_eth_pipe.test.mjs); priced here, capped.
  const liar = cappedGas(relayerGas(history(5000n)));
  assert.equal(liar.capped, true);
  assert.equal(liar.maxFeePerGas, MAX_FEE_GAS_PRICE);
  const fee = b2eRelayerFeeGroth(beam, liar, PRICES);
  assert.ok(fee <= (honest * 100n) / 3n + beam.beamGrid, `${Number(fee) / 1e8} BEAM`);
  assert.ok(fee < 1600n * 10n ** 8n, `${Number(fee) / 1e8} BEAM, not 156,015`);
});

test('to Ethereum: a gas price above the cap is said ("Ethereum is unusually busy"), and the fee follows the cap', async () => {
  const now = Date.UTC(2026, 9, 12, 12);
  const eth = (gwei) => ({ freezes: async () => [], relayerGas: async () => relayerGas(history(gwei), now) });
  const prices = { usd: async (ids) => ({ usd: Object.fromEntries(ids.map((id) => [id, PRICES[id]])), at: now }) };
  const busy = await readConditions({ route: beam, direction: 'toEthereum', eth: eth(400n), prices, now });
  assert.equal(busy.gasCapped, true);
  assert.equal(busy.fee, b2eRelayerFeeGroth(beam, cappedGas(busy.gas), PRICES));
  assert.ok(busy.feeNow > busy.fee, 'the relayer\'s price now is above what is paid: it waits for gas');
  const q = quoteToEthereum({ route: beam, amount: 100000n * 10n ** 8n, cond: busy, balances: { source: 10n ** 15n, beam: 10n ** 15n, eth: 0n }, ethAddress: TO, now });
  const w = q.warnings.find((x) => x.code === 'gasHigh');
  assert.ok(w, JSON.stringify(q.warnings));
  assert.equal(w.title, 'Ethereum is unusually busy right now');
  assert.match(w.detail, /capped fee and no more/);
  assert.match(w.detail, /which can take hours or days\./, 'BM-7: sustained high gas has lasted days');
  assert.doesNotMatch(w.detail, /gwei/, 'no jargon');
  const calm = await readConditions({ route: beam, direction: 'toEthereum', eth: eth(1n), prices, now });
  assert.equal(calm.gasCapped, false);
  assert.equal(quoteToEthereum({ route: beam, amount: 100000n * 10n ** 8n, cond: calm, balances: { source: 10n ** 15n, beam: 10n ** 15n, eth: 0n }, ethAddress: TO, now }).warnings.some((x) => x.code === 'gasHigh'), false);
});

test('BM-6: the words for a fee Beam PWA will not pay, and for figures that cannot be right', async () => {
  const { badFeesWords } = await import('../../src/screens/eth_ui.js');
  const high = badFeesWords({ code: 'bad_fees', data: { problem: 'high' } }, 'Stack Wallet');
  assert.equal(high.title, 'The network fee is far above anything Beam PWA will pay. ');
  assert.equal(high.detail, "Stack Wallet's Ethereum server says Ethereum is that expensive right now. It has been, but only for minutes at a time. Nothing was sent, and nothing was paid. Try again in a few minutes, or use another server.");
  assert.doesNotMatch(high.detail, /gwei|cannot have/);
  const jump = badFeesWords({ code: 'bad_fees', data: { problem: 'jump' } }, 'PublicNode');
  assert.equal(jump.title, "PublicNode's Ethereum server gave a network fee that can't be right. ");
  assert.equal(jump.detail, 'Nothing was sent, and nothing was paid. Try again in a minute, or use another server.');
});

// The bridge fee against the relayer's own code: one fixture, two apps.
//
// test/beam/bridge/fixtures/relayer_fee_vectors.json (the desktop app's) was
// written by running BeamMW's beam-bridge-ethrelay utils/eth_gas.js and
// utils/eth_fee.js, unmodified, on 401 fee histories and price sets. For every
// one this module must compute the same gas price and the same minimum fee, to
// the unit, for all five routes; and the fee it locks must be the least the
// relayer accepts (no margin) or more (with the margin). The named cases are
// the desktop's (relayer_parity_test.dart, eth_relayer_fee_test.dart).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { REPO_ROOT } from '../../tools/shader_check.mjs';
import { ROUTES, routeById } from '../../src/lib/bridge/routes.js';
import { relayerGas, b2eRelayerMinimum, b2eRelayerFeeGroth, relayerReads, e2bRelayerFee, weiAsGwei, floorToGrid, ceilToGrid, priceOf, FEE_MARGIN, MIN_TIP, MAX_TIP, E2B_FEE_BEAM, FEE_WARN_SHARE } from '../../src/lib/bridge/fees.js';

const fixture = JSON.parse(readFileSync(join(REPO_ROOT, 'test', 'beam', 'bridge', 'fixtures', 'relayer_fee_vectors.json'), 'utf8'));
const vectors = fixture.vectors;

test('the vectors come from the relayer itself', () => {
  assert.match(fixture.source, /beam-bridge-ethrelay/);
  assert.ok(vectors.length > 400);
});

test('the same gas price as the relayer (eth_gas.js), every vector', () => {
  for (const v of vectors) {
    const gas = relayerGas(v.history);
    assert.equal(gas.maxFeePerGas, BigInt(v.maxFeePerGas));
    assert.equal(gas.tip, BigInt(v.maxPriorityFeePerGas));
  }
});

test('the same minimum fee as the relayer (eth_fee.js), every vector and route', () => {
  let checked = 0;
  for (const v of vectors) {
    const gas = relayerGas(v.history);
    for (const r of ROUTES) {
      assert.equal(b2eRelayerMinimum(r, gas, v.prices), BigInt(v.minimum[r.id]), `${r.id}, ${v.maxFeePerGas} wei, ${JSON.stringify(v.prices)}`);
      checked++;
    }
  }
  assert.equal(checked, vectors.length * 5);
  assert.equal(checked, 2005);
});

test('with no margin the fee is the least the relayer accepts', () => {
  for (const v of vectors) {
    const gas = relayerGas(v.history);
    for (const r of ROUTES) {
      const minimum = BigInt(v.minimum[r.id]);
      const fee = b2eRelayerFeeGroth(r, gas, v.prices, { margin: 1.0 });
      assert.equal(fee % r.beamGrid, 0n);
      assert.ok(relayerReads(r, fee) >= minimum);
      if (fee > r.beamGrid) assert.ok(relayerReads(r, fee - r.beamGrid) < minimum, `${r.id}: ${fee} groth is more than needed`);
    }
  }
});

test('the quoted fee covers the 1.3 margin on top of the minimum', () => {
  assert.equal(FEE_MARGIN, 1.3);
  for (const v of vectors) {
    const gas = relayerGas(v.history);
    for (const r of ROUTES) {
      const minimum = BigInt(v.minimum[r.id]);
      const fee = b2eRelayerFeeGroth(r, gas, v.prices);
      assert.ok(relayerReads(r, fee) >= (minimum * 1300n) / 1000n);
      assert.equal(fee % r.beamGrid, 0n);
      assert.ok(fee >= r.beamGrid, 'never zero');
    }
  }
});

test('the live case of 2026-10-09, in plain numbers', () => {
  const v = vectors[0];
  const gas = relayerGas(v.history);
  // 96,000 gas at 1.043282187 gwei, ETH $2,485.63, BEAM $0.00795925.
  assert.equal(b2eRelayerMinimum(routeById('beam'), gas, v.prices), 3127788375n);
  assert.equal(b2eRelayerFeeGroth(routeById('beam'), gas, v.prices, { margin: 1.0 }), 3127788375n);
  // USDT has 6 decimals: the relayer cuts the last two digits of groth.
  assert.equal(b2eRelayerMinimum(routeById('usdt'), gas, v.prices), 311435n);
  assert.equal(b2eRelayerFeeGroth(routeById('usdt'), gas, v.prices, { margin: 1.0 }), 31143500n);
});

// ---------------------------------------------------------------- eth_feeHistory

function gwei(g) {
  const [w, f = ''] = g.split('.');
  return '0x' + (BigInt(w) * 1000000000n + BigInt(f.padEnd(9, '0'))).toString(16);
}
const g = (v) => BigInt(gwei(v));
const history = (bases, tips) => ({ oldestBlock: '0x18f1a2d', baseFeePerGas: bases.map(gwei), reward: tips.map((t) => (t == null ? [] : [gwei(t)])) });

test('gas: the base fee is the last entry (the block being built)', () => {
  assert.equal(relayerGas(history(['0.75', '0.78', '0.7014'], ['0.4', '0.5'])).baseFee, g('0.7014'));
});

test('gas: the tip is the upper middle of an even count (sorted[floor(n / 2)])', () => {
  const gas = relayerGas(history(['1'], ['0.4', '0.1', '0.3', '0.2']));
  // Sorted 0.1 0.2 0.3 0.4: index 2. An average (0.25) would quote below the relayer's minimum.
  assert.equal(gas.tip, g('0.3'));
  assert.equal(gas.maxFeePerGas, g('2.3'));
  assert.equal(relayerGas(history(['1'], ['0.5', null, '0.1', '0.9', null])).tip, g('0.5'), 'odd count; empty rows skipped');
});

test('gas: the tip is clamped to 0.01–3 gwei, and no tips means 0.01', () => {
  assert.equal(MIN_TIP, 10000000n);
  assert.equal(MAX_TIP, 3000000000n);
  assert.equal(relayerGas(history(['1'], ['0.001', '0.002', '0.003'])).tip, MIN_TIP);
  assert.equal(relayerGas(history(['1'], ['5', '7', '9'])).tip, MAX_TIP);
  assert.equal(relayerGas(history(['1'], [])).tip, MIN_TIP);
  assert.equal(relayerGas({ baseFeePerGas: ['0x1'] }).tip, MIN_TIP);
});

test('gas: "0x" reads as zero; no base fee, or a non-hex value, is refused', () => {
  const gas = relayerGas({ baseFeePerGas: ['0x'], reward: [['0x']] });
  assert.equal(gas.baseFee, 0n);
  assert.equal(gas.tip, MIN_TIP);
  assert.throws(() => relayerGas({ baseFeePerGas: [] }));
  assert.throws(() => relayerGas({ baseFeePerGas: [12] }));
  assert.throws(() => relayerGas({ baseFeePerGas: ['0x1'], reward: ['0x1'] }));
});

test('gas: a real answer (eth_feeHistory 0xa, latest, [50])', () => {
  const gas = relayerGas({
    oldestBlock: '0x18f1dd5',
    baseFeePerGas: ['0xd296a7d', '0xce68b9b', '0xd540d04', '0xc0f5918', '0xd1cf3ec', '0xd0e69ff', '0xeb01e7d', '0x1085fd37', '0x122be423', '0x1416d60d', '0x153f25be'],
    gasUsedRatio: [0.42, 0.63, 0.12, 0.85, 0.48, 1, 1, 0.9, 0.92, 0.73],
    reward: [['0x8f0d180'], ['0x36d3d15'], ['0x3f0d30b'], ['0x5f5e100'], ['0x52e77ff'], ['0x7ce2981'], ['0x8f0d180'], ['0x5f5e100'], ['0xbebc200'], ['0x5dc1f7f']],
  });
  assert.equal(gas.baseFee, 356459966n);
  assert.equal(gas.tip, 100000000n);
  assert.equal(gas.maxFeePerGas, 812919932n);
});

test('fromWei(…, gwei) text: exact, no trailing zeros', () => {
  assert.equal(weiAsGwei(1043282187n), '1.043282187');
  assert.equal(weiAsGwei(1832064250n), '1.83206425');
  assert.equal(weiAsGwei(2000000000n), '2');
  assert.equal(weiAsGwei(10000000n), '0.01');
  assert.equal(weiAsGwei(0n), '0');
});

// ---------------------------------------------------------------- research §D

// §D's fees were computed from the unrounded 1.83206425 gwei (base 0.7014, tip 0.42926425).
const sectionD = { ethereum: 2487.25, beam: 0.00783632, 'wrapped-bitcoin': 82567, tether: 0.999262, dai: 0.999917 };
const sectionDGas = { baseFee: g('0.7014'), tip: g('0.42926425'), maxFeePerGas: g('0.7014') * 2n + g('0.42926425') };

test('b2e fee, research §D, margin 1.0', () => {
  assert.equal(sectionDGas.maxFeePerGas, 1832064250n);
  const expected = { beam: 5582377612n, eth: 21985n, wbtc: 662n, usdt: 54722000n, dai: 54686161n };
  for (const [id, groth] of Object.entries(expected)) {
    const r = routeById(id);
    const fee = b2eRelayerFeeGroth(r, sectionDGas, sectionD, { margin: 1.0 });
    assert.equal(fee, groth, id);
    assert.equal(fee % r.beamGrid, 0n);
    assert.ok(b2eRelayerFeeGroth(r, sectionDGas, sectionD) >= fee, `${id}: the default margin pays more, never less`);
  }
});

test('no price, no fee; a margin below 1 is refused', () => {
  const beam = routeById('beam');
  assert.equal(b2eRelayerFeeGroth(beam, sectionDGas, { beam: 0.0078 }), null);
  assert.equal(b2eRelayerFeeGroth(beam, sectionDGas, { ethereum: 2487.25, beam: 0 }), null);
  assert.equal(b2eRelayerFeeGroth(beam, sectionDGas, { ethereum: 2487.25, beam: '0.0078' }), null);
  assert.equal(b2eRelayerFeeGroth(beam, sectionDGas, sectionD, { margin: 0.99 }), null);
  assert.equal(b2eRelayerFeeGroth(beam, sectionDGas, sectionD, { margin: NaN }), null);
  assert.equal(b2eRelayerMinimum(beam, { maxFeePerGas: 0n }, sectionD), null, 'no gas price, no fee');
  assert.equal(priceOf(null, 'beam'), null);
});

test('e2b fee: 0.02 BEAM worth, on the Ethereum grid; WBEAM a fixed 2,000,000', () => {
  assert.equal(E2B_FEE_BEAM, 0.02);
  const expected = { beam: 2000000n, eth: 70000000000n, wbtc: 1n, usdt: 157n, dai: 156740000000000n };
  for (const [id, units] of Object.entries(expected)) {
    const r = routeById(id);
    const fee = e2bRelayerFee(r, sectionD);
    assert.equal(fee, units, id);
    assert.equal(fee % r.ethGrid, 0n);
  }
  // WBEAM needs no price at all.
  assert.equal(e2bRelayerFee(routeById('beam'), {}), 2000000n);
  assert.equal(e2bRelayerFee(routeById('eth'), { ethereum: 2487.25 }), null);
});

test('grid rounding and the warning share', () => {
  assert.equal(floorToGrid(12345n, 100n), 12300n);
  assert.equal(ceilToGrid(12345n, 100n), 12400n);
  assert.equal(ceilToGrid(12300n, 100n), 12300n);
  assert.equal(FEE_WARN_SHARE, 0.1);
});

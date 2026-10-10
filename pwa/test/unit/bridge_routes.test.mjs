// The bridge registry, value for value against the desktop app's
// lib/wallets/bridge/bridge_routes.dart (read from the repository, so the two
// apps cannot drift apart).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { REPO_ROOT } from '../../tools/shader_check.mjs';
import { ROUTES, routeById, routeForBeamAsset, routeForEthToken, ethToGroth, grothToEth, SEND_FEE, CLAIM_FEE, BEAM_CONFIRMATIONS, NEW_LOCAL_MESSAGE_TOPIC, SEND_FUNDS_SIGNATURE, PIPE_SHADERS, BEAM_DECIMALS } from '../../src/lib/bridge/routes.js';
import { SHADERS } from '../../src/lib/shaders.js';

const dart = readFileSync(join(REPO_ROOT, 'lib', 'wallets', 'bridge', 'bridge_routes.dart'), 'utf8');

/** The desktop's BridgeRoute(...) literals, as { field: source text }. */
function dartRoutes() {
  const out = [];
  for (const m of dart.matchAll(/ {2}BridgeRoute\(\n([\s\S]*?)\n {2}\),/g)) {
    const r = {};
    for (const f of m[1].matchAll(/(\w+):\s*([^,]+),/g)) r[f[1]] = f[2].trim();
    out.push(r);
  }
  return out;
}

test('the five routes, field for field as the desktop has them', () => {
  const d = dartRoutes();
  assert.equal(d.length, 5);
  assert.deepEqual(ROUTES.map((r) => r.id), d.map((r) => JSON.parse(r.id.replace(/'/g, '"'))));
  const str = (v) => (v === 'null' ? null : v.replace(/^'|'$/g, ''));
  for (const [i, r] of ROUTES.entries()) {
    const x = d[i];
    assert.equal(r.beamSymbol, str(x.beamSymbol));
    assert.equal(r.ethSymbol, str(x.ethSymbol));
    assert.equal(r.name, str(x.name));
    assert.equal(r.beamAssetId, Number(x.beamAssetId));
    assert.equal(r.beamPipeCid, str(x.beamPipeCid));
    assert.equal(r.shader, x.shader.replace('BridgeShader.', ''));
    assert.equal(r.sendMethod, Number(x.sendMethod));
    assert.equal(r.receiveMethod, Number(x.receiveMethod));
    assert.equal(r.ethPipe, str(x.ethPipe));
    assert.equal(r.ethToken, str(x.ethToken));
    assert.equal(r.ethDecimals, Number(x.ethDecimals));
    assert.equal(r.relayGas, Number(x.relayGas));
    assert.equal(r.processedSlot, Number(x.processedSlot));
    assert.equal(r.coingeckoId, str(x.coingeckoId));
    assert.equal(r.maxCoins, x.maxCoins == null ? null : Number(x.maxCoins));
  }
});

test('the constants, as the desktop has them', () => {
  assert.equal(SEND_FEE, 1100000n);
  assert.equal(CLAIM_FEE, 12100000n);
  assert.match(dart, /kBridgeSendFeeGroth = BigInt\.from\(1100000\);/);
  assert.match(dart, /kBridgeClaimFeeGroth = BigInt\.from\(12100000\);/);
  assert.equal(BEAM_CONFIRMATIONS, 61);
  assert.match(dart, /kBridgeBeamConfirmations = 61;/);
  assert.equal(NEW_LOCAL_MESSAGE_TOPIC, '0x5f52670be4e2f3d7b079180b485ab44712641a10d1c77e843355f96036608ac7');
  assert.ok(dart.includes(`'${NEW_LOCAL_MESSAGE_TOPIC}'`));
  assert.ok(dart.includes(`'${SEND_FUNDS_SIGNATURE}'`));
  assert.equal(BEAM_DECIMALS, 8);
});

test('values that move money, spelled out', () => {
  const beam = routeById('beam');
  assert.equal(beam.beamPipeCid, 'e63bd26ca5b226558686dd191122a8e5d6861a97597db9f40bda48aef6dbe835');
  assert.deepEqual([beam.shader, beam.sendMethod, beam.receiveMethod, beam.relayGas, beam.processedSlot], ['reverse', 4, 6, 96000, 2]);
  assert.equal(beam.maxGroth, 300000000000000n); // 3,000,000 BEAM
  for (const id of ['eth', 'wbtc', 'usdt', 'dai']) {
    const r = routeById(id);
    assert.deepEqual([r.shader, r.sendMethod, r.receiveMethod, r.relayGas, r.maxGroth], ['forward', 3, 4, 120000, null], id);
  }
  assert.equal(routeById('eth').processedSlot, 1);
  assert.deepEqual(ROUTES.map((r) => r.beamAssetId), [0, 36, 38, 37, 39]);
  assert.ok(ROUTES.every((r) => Object.isFrozen(r)) && Object.isFrozen(ROUTES));
  assert.ok(ROUTES.every((r) => /^[0-9a-f]{64}$/.test(r.beamPipeCid) && /^0x[0-9a-f]{40}$/.test(r.ethPipe) && (r.ethToken === null || /^0x[0-9a-f]{40}$/.test(r.ethToken))));
});

test('each route names a pinned pipe shader', () => {
  assert.deepEqual(PIPE_SHADERS, { forward: 'pipe', reverse: 'pipeReverse' });
  for (const r of ROUTES) assert.ok(SHADERS[r.shaderKey], r.id);
  assert.equal(routeById('beam').shaderKey, 'pipeReverse');
  assert.equal(routeById('usdt').shaderKey, 'pipe');
});

test('grids: ETH and DAI 10^10 wei per groth, USDT 100 groth per unit, the rest 1', () => {
  const g = Object.fromEntries(ROUTES.map((r) => [r.id, [r.ethGrid, r.beamGrid]]));
  assert.deepEqual(g, { beam: [1n, 1n], eth: [10000000000n, 1n], wbtc: [1n, 1n], usdt: [1n, 100n], dai: [10000000000n, 1n] });
  const eth = routeById('eth');
  const usdt = routeById('usdt');
  assert.equal(ethToGroth(eth, 123456789012345678n), 12345678n); // truncated
  assert.equal(grothToEth(eth, 12345678n), 123456780000000000n);
  assert.equal(ethToGroth(usdt, 1234567n), 123456700n);
  assert.equal(grothToEth(usdt, 123456789n), 1234567n); // truncated
  assert.equal(ethToGroth(routeById('wbtc'), 777n), 777n);
});

test('lookups', () => {
  assert.equal(routeForBeamAsset(37).id, 'usdt');
  assert.equal(routeForBeamAsset(174), null);
  assert.equal(routeForEthToken(null).id, 'eth');
  assert.equal(routeForEthToken('0xE5ACBB03D73267C03349C76EAD672EE4D941F499').id, 'beam');
  assert.equal(routeForEthToken('0x' + '1'.repeat(40)), null);
  assert.throws(() => routeById('btc'));
});

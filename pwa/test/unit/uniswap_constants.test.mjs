// The Uniswap addresses and numbers against the desktop app's own files
// (read by path, so the two apps cannot drift), and the shipped pool list
// against the Dart list it is generated from.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ADDRESSES, DEPLOY_BLOCKS, TOPICS, V3_FEE_TICK_SPACING, V4_PROBE_KEYS, V4_DYNAMIC_FEE_FLAG, UR_COMMAND, V4_ACTION, UR_CONSTANTS, ROUTE_BASES, ETH_CHAIN_ID } from '../../src/lib/eth/uniswap/constants.js';
import { PERMIT2_ADDRESS } from '../../src/lib/eth/tx.js';
import { MULTICALL3 } from '../../src/lib/eth/rpc.js';
import { WBEAM, TOKENS } from '../../src/lib/eth/tokens.js';
import { eventTopic, selectorHex } from '../../src/lib/eth/abi.js';
import { parseKnownPools } from '../../src/lib/eth/uniswap/discovery.js';
import { parseDartKnownPools, expandKnownPools, knownPoolsText, JSON_FILE, DART_FILE } from '../../tools/uniswap_pools.mjs';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const DART = readFileSync(join(REPO, 'lib', 'wallets', 'ethereum', 'uniswap', 'uniswap_constants.dart'), 'utf8');
const QUOTER_DART = readFileSync(join(REPO, 'lib', 'wallets', 'ethereum', 'uniswap', 'uniswap_quoter.dart'), 'utf8');

/** `static const name = value;` inside `abstract final class Klass { … }`. */
function dartClass(name) {
  const start = DART.indexOf(`abstract final class ${name} {`);
  assert.ok(start >= 0, name);
  const body = DART.slice(start, DART.indexOf('\n}', start));
  const out = {};
  for (const m of body.matchAll(/static (?:const|final) (\w+) =\s*([^;]+);/g)) out[m[1]] = m[2].trim().replace(/^'|'$/g, '');
  return out;
}

test('every Uniswap address is the desktop app\'s', () => {
  const dart = dartClass('UniswapAddresses');
  assert.deepEqual(Object.keys(dart).sort(), Object.keys(ADDRESSES).sort());
  for (const [k, v] of Object.entries(ADDRESSES)) {
    assert.equal(v, dart[k], k);
    assert.match(v, /^0x[0-9a-f]{40}$/, `${k} lowercase`);
  }
  // And the same as the rest of the PWA's Ethereum code.
  assert.equal(ADDRESSES.permit2, PERMIT2_ADDRESS.toLowerCase());
  assert.equal(ADDRESSES.multicall3, MULTICALL3.toLowerCase());
  assert.equal(ETH_CHAIN_ID, Number(/const int kEthChainId = (\d+);/.exec(DART)[1]));
});

test('deploy blocks, topics, fee tiers and probe keys are the desktop app\'s', () => {
  const blocks = dartClass('UniswapDeployBlocks');
  for (const [k, v] of Object.entries(DEPLOY_BLOCKS)) assert.equal(v, Number(blocks[k]), k);
  const topics = dartClass('UniswapTopics');
  for (const k of ['v2PairCreated', 'v3PoolCreated', 'v4Initialize']) assert.equal(TOPICS[k], topics[k], k);
  // And each is the keccak of its event signature.
  assert.equal(TOPICS.v2PairCreated, eventTopic('PairCreated(address,address,address,uint256)'));
  assert.equal(TOPICS.v3PoolCreated, eventTopic('PoolCreated(address,address,uint24,int24,address)'));
  assert.equal(TOPICS.v4Initialize, eventTopic('Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)'));
  assert.equal(TOPICS.erc20Transfer, eventTopic('Transfer(address,address,uint256)'));

  const tiers = /kV3FeeTickSpacing = \{([^}]*)\}/.exec(DART)[1];
  assert.deepEqual(
    V3_FEE_TICK_SPACING.map((x) => [...x]),
    [...tiers.matchAll(/(\d+): (\d+)/g)].map((m) => [Number(m[1]), Number(m[2])]),
  );
  const probes = DART.slice(DART.indexOf('kV4ProbeKeys'), DART.indexOf('];', DART.indexOf('kV4ProbeKeys')));
  assert.deepEqual(
    V4_PROBE_KEYS.map((k) => ({ ...k })),
    [...probes.matchAll(/fee: (\d+), tickSpacing: (\d+)/g)].map((m) => ({ fee: Number(m[1]), tickSpacing: Number(m[2]) })),
  );
  assert.equal(V4_DYNAMIC_FEE_FLAG, Number(/kV4DynamicFeeFlag = (0x[0-9a-f]+);/.exec(DART)[1]));
});

test('router commands, v4 actions and special values are the desktop app\'s', () => {
  const cmd = dartClass('URCommand');
  assert.deepEqual(Object.keys(cmd).sort(), Object.keys(UR_COMMAND).sort());
  for (const [k, v] of Object.entries(UR_COMMAND)) assert.equal(v, Number(cmd[k]), k);
  const act = dartClass('V4Action');
  assert.deepEqual(Object.keys(act).sort(), Object.keys(V4_ACTION).sort());
  for (const [k, v] of Object.entries(V4_ACTION)) assert.equal(v, Number(act[k]), k);
  const c = dartClass('URConstants');
  assert.equal(UR_CONSTANTS.msgSender, c.msgSender);
  assert.equal(UR_CONSTANTS.addressThis, c.addressThis);
  assert.equal(c.contractBalance, 'BigInt.one << 255');
  assert.equal(UR_CONSTANTS.contractBalance, 1n << 255n);
  assert.equal(c.openDelta, 'BigInt.zero');
  assert.equal(UR_CONSTANTS.openDelta, 0n);
  assert.equal(selectorHex('execute(bytes,bytes[],uint256)'), '0x3593564c');
});

test('the route bases are the quoter\'s, and WBEAM is the token list\'s', () => {
  const block = QUOTER_DART.slice(QUOTER_DART.indexOf('kUniRouteBases = ['), QUOTER_DART.indexOf('];', QUOTER_DART.indexOf('kUniRouteBases = [')));
  const dart = [...block.matchAll(/'(0x[0-9a-f]{40})'|UniswapAddresses\.(\w+)/g)].map((m) => m[1] || ADDRESSES[m[2]]);
  assert.deepEqual([...ROUTE_BASES], dart);
  assert.ok(ROUTE_BASES.includes(WBEAM.address));
  for (const t of TOKENS) assert.ok(ROUTE_BASES.includes(t.address), `${t.symbol} is a route base`);
  // The quoter's gas figures.
  assert.match(QUOTER_DART, /kV2HopGas = BigInt\.from\(90000\)/);
  assert.match(QUOTER_DART, /kRouterOverheadGas = BigInt\.from\(80000\)/);
  assert.match(QUOTER_DART, /kHookedEdgeBips = 100;/);
});

test('known_pools.json is exactly the desktop app\'s list, regenerated by tools/uniswap_pools.mjs', () => {
  const dart = parseDartKnownPools(readFileSync(DART_FILE, 'utf8'));
  const shipped = readFileSync(JSON_FILE, 'utf8');
  assert.equal(shipped, knownPoolsText(), 'run node tools/uniswap_pools.mjs');
  const json = JSON.parse(shipped);
  assert.deepEqual(expandKnownPools(json), dart);
  assert.equal(dart.block, 26155432);
  assert.equal(dart.pools.length, 1275);
  // The desktop's count of WBEAM pools: 26 v4, 4 v3, 1 v2.
  const wbeam = dart.pools.filter((p) => p.c0 === WBEAM.address || p.c1 === WBEAM.address);
  assert.deepEqual(
    ['v2', 'v3', 'v4'].map((v) => wbeam.filter((p) => p.v === v).length),
    [1, 4, 26],
  );
  // It parses into pools the rest of the code uses, ids computed.
  const known = parseKnownPools(json);
  assert.equal(known.pools.length, 1275);
  assert.equal(new Set(known.pools.map((p) => p.id)).size, 1275, 'no pool twice');
  assert.ok(known.pools.some((p) => p.id === '0xce7ff1b044aaee5bf9e632a3b537e10fbca0222004ee50348d492c1e5b54419c'), 'the ETH/WBEAM v4 pool');
  assert.ok(shipped.length < 64 * 1024, `${shipped.length} bytes`);
});

test('the pool list parser refuses what it does not understand', () => {
  const ok = "const int kUniKnownPoolsBlock = 5;\nconst List<Map<String, Object>> kUniKnownPools = [\n  {\n    'v': 'v2',\n    'pair': '0x231b7589426ffe1b75405526fc32ac09d44364c4',\n    'c0': '0x2260fac5e5542a773aa44fbcfedf7c193bc2c599',\n    'c1': '0x6b175474e89094c44da98b954eedeac495271d0f',\n  },\n];\n";
  assert.equal(parseDartKnownPools(ok).pools.length, 1);
  assert.throws(() => parseDartKnownPools(ok.replace("'v2'", "'v5'")));
  assert.throws(() => parseDartKnownPools(ok.replace('0x231b', '0xZZ1b')));
  assert.throws(() => parseDartKnownPools(ok.replace("'c0': '0x2260", "'c0': '0x9260")), /out of order/);
  assert.throws(() => parseDartKnownPools(ok.replace("    'c1'", "    'fee': 3,\n    'c1'")));
  assert.throws(() => parseKnownPools({ format: 2, block: 1, currencies: [], hooks: [], pools: [] }));
  assert.throws(() => parseKnownPools({ format: 1, block: 1, currencies: [], hooks: [], pools: [[4, 0, 1, 3000, 60, 0]] }));
});

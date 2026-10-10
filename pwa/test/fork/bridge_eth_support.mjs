// What the bridge's Ethereum fork tests (bridge_eth_*.test.mjs) share: the
// local anvil mainnet fork on 127.0.0.1:8545 and nothing else. Before anything
// is sent the node must call itself anvil and answer chain id 1 (forkProblem),
// checked again under the shared lock right before each test changes state
// (withFork), and the fork is put back with evm_snapshot / evm_revert.
//
// The library talks to the fork through its own EthRpc: whichever listed host
// it names, every request goes to 127.0.0.1:8545 (forkRpc), or to a port where
// nothing listens (switchableRpc, deadPort). Prices come from the fixture the
// unit tests use, through the real PriceFeed with a fetch that never leaves the
// process. Senders are fresh random keys given ETH with anvil_setBalance (never
// anvil's key 0: on mainnet it carries EIP-7702 code). Tokens come from their
// pipe: impersonated, the WBEAM pipe mints (it holds MINTER_ROLE) and the
// USDT, WBTC and DAI pipes pay out of what they hold on this fork.
import { createServer } from 'node:net';
import assert from 'node:assert/strict';
import { takeLock } from './fork_support.mjs';
import { EthRpc, walletFees } from '../../src/lib/eth/rpc.js';
import { privateKeyToAddress } from '../../src/lib/eth/crypto.js';
import { signTransaction, MAINNET_CHAIN_ID } from '../../src/lib/eth/tx.js';
import { encodeCall, abiDecode, selector } from '../../src/lib/eth/abi.js';
import { bytesToHex, hexToBytes } from '../../src/lib/eth/hex.js';
import { EthPipe, isBeamReceiverKey } from '../../src/lib/bridge/eth_pipe.js';
import { PriceFeed } from '../../src/lib/bridge/prices.js';
import { e2bRelayerFee } from '../../src/lib/bridge/fees.js';
import { routeById } from '../../src/lib/bridge/routes.js';
import { PRICES } from '../unit/helpers/bridge_fakes.mjs';

export { PRICES };
export const ANVIL = 'http://127.0.0.1:8545';
export const ETHER = 10n ** 18n;
const U64 = (1n << 64n) - 1n;
const U160 = (1n << 160n) - 1n;
export const hex = (n) => `0x${BigInt(n).toString(16)}`;

/** One JSON-RPC request to the fork. A fork reads state from its source node the first time, so it is given two minutes. */
export async function raw(method, params = [], timeoutMs = 120000) {
  const r = await fetch(ANVIL, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }), signal: AbortSignal.timeout(timeoutMs) });
  const j = await r.json();
  if (j.error) throw Object.assign(new Error(`${method}: ${j.error.message}`), { code: j.error.code, data: j.error.data });
  return j.result;
}

/** Why the fork cannot be used (null when 127.0.0.1:8545 is anvil answering chain id 0x1). */
export async function forkProblem() {
  try {
    if (!/anvil/i.test(String(await raw('web3_clientVersion', [], 5000)))) return 'the node on 127.0.0.1:8545 is not anvil';
    if ((await raw('eth_chainId', [], 5000)) !== '0x1') return 'the node on 127.0.0.1:8545 is not chain 1';
    return null;
  } catch {
    return 'no anvil on 127.0.0.1:8545';
  }
}

/** Runs fn() with the fork to itself (the shared lock), checked again right before anything is sent, and puts it back. */
export async function withFork(fn) {
  const release = await takeLock();
  try {
    const problem = await forkProblem();
    if (problem) throw new Error(`nothing was sent: ${problem}`);
    const snapshot = await raw('evm_snapshot');
    let passed = false;
    try {
      const out = await fn();
      passed = true;
      return out;
    } finally {
      const back = await raw('evm_revert', [snapshot]).then(
        (r) => r === true,
        () => false,
      );
      if (!back && passed) throw new Error('the fork could not be put back (evm_revert)');
    }
  } finally {
    release();
  }
}

/** The app's Ethereum client; every request it makes goes to the fork, whatever host it names. */
export function forkRpc() {
  return new EthRpc('stackwallet', { fetch: (_url, init) => fetch(ANVIL, init), timeoutMs: 120000 });
}

/** A local port where nothing listens (connections are refused at once). */
export async function deadPort() {
  const srv = createServer();
  await new Promise((resolve) => srv.listen(0, '127.0.0.1', resolve));
  const { port } = srv.address();
  await new Promise((resolve) => srv.close(resolve));
  return port;
}

/** The app's client on the fork until state.dead is set; then on a port where nothing listens. */
export async function switchableRpc() {
  const port = await deadPort();
  const state = { dead: false, port, deadRequests: 0 };
  const rpc = new EthRpc('stackwallet', {
    timeoutMs: 20000,
    fetch: (_url, init) => {
      if (!state.dead) return fetch(ANVIL, init);
      state.deadRequests++;
      return fetch(`http://127.0.0.1:${port}/`, init);
    },
  });
  return { rpc, state };
}

/** A fresh key nobody else has, given `eth` on the fork; withKey as lib/eth/vault.js withEthKey hands it out. */
export async function freshSigner(eth = 10n * ETHER) {
  const sk = new Uint8Array(32);
  globalThis.crypto.getRandomValues(sk);
  sk[0] &= 0x7f; // below the curve order
  sk[31] |= 1; // never zero
  const address = privateKeyToAddress(sk).toLowerCase();
  assert.equal(await raw('eth_getCode', [address, 'latest']), '0x', 'a fresh address has no code');
  await raw('anvil_setBalance', [address, hex(eth)]);
  return Object.freeze({ sk, address, withKey: async (fn) => fn({ sk: Uint8Array.from(sk), address }) });
}

/** The library's Ethereum side for `who`. */
export function ethPipeFor(who, { rpc = forkRpc(), clock } = {}) {
  return new EthPipe({ rpc, owner: who.address, withKey: who.withKey, ...(clock ? { clock } : {}) });
}

/** A 33-byte BEAM receive key in the pipe's format (X ‖ parity 0/1) on secp256k1, new each time. */
export function randomReceiverKey() {
  for (let i = 0; i < 256; i++) {
    const k = new Uint8Array(33);
    globalThis.crypto.getRandomValues(k.subarray(0, 32));
    k[32] = i & 1;
    if (isBeamReceiverKey(k)) return k;
  }
  throw new Error('no curve point in 256 tries');
}

/** What the e2b tests move on each route: on the grid, well inside what each pipe holds (so its relayer can pay it out too). */
export const AMOUNTS = Object.freeze({
  beam: 10500000000n, // 105 WBEAM
  eth: ETHER / 10n, // 0.1 ETH
  wbtc: 100000n, // 0.001 WBTC
  usdt: 100000000n, // 100 USDT
  dai: 10n * ETHER, // 10 DAI
});

/** The fee Campfire pays for an e2b crossing at the fixture prices (0.02 BEAM worth). */
export const e2bFee = (route) => e2bRelayerFee(route, PRICES);

export async function mined(hash, tries = 300) {
  for (let i = 0; i < tries; i++) {
    const r = await raw('eth_getTransactionReceipt', [hash]);
    if (r && r.blockNumber != null) return r;
    await new Promise((res) => setTimeout(res, 200));
  }
  throw new Error(`not mined: ${hash}`);
}

/** Sends a transaction as `from` (impersonated; topped up with ETH for gas when it has less than 1 ETH) and requires status 1. */
export async function sendAs(from, to, data) {
  await raw('anvil_impersonateAccount', [from]);
  try {
    if (BigInt(await raw('eth_getBalance', [from, 'latest'])) < ETHER) await raw('anvil_setBalance', [from, hex(10n * ETHER)]);
    const hash = await raw('eth_sendTransaction', [{ from, to, data: bytesToHex(data), gas: '0x7a120' }]);
    const r = await mined(hash);
    assert.equal(r.status, '0x1', `impersonated call reverted: ${hash}`);
    return r;
  } finally {
    await raw('anvil_stopImpersonatingAccount', [from]).catch(() => {});
  }
}

/** Signs `tx` with who's key (tx.js, chain 1, the fork's fees and nonce), sends it to the fork and requires status 1. */
export async function sendSigned(who, { to, data, value = 0n, gasLimit }) {
  const rpc = forkRpc();
  const fees = await walletFees(rpc);
  const nonce = await rpc.getTransactionCount(who.address, 'pending');
  const signed = signTransaction({ chainId: MAINNET_CHAIN_ID, nonce, to, data, value, gasLimit, maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas }, who.sk);
  await rpc.sendRawTransaction(signed.raw);
  const r = await mined(signed.hash);
  assert.equal(r.status, '0x1', `reverted: ${signed.hash}`);
  return r;
}

export const call = async (to, data, from) => hexToBytes(await raw('eth_call', [{ to, data: bytesToHex(data), ...(from ? { from } : {}) }, 'latest']));
export const uint = async (to, data) => abiDecode('uint256', await call(to, data))[0];
export const erc20Balance = (token, who) => uint(token, encodeCall('balanceOf(address)', [who]));
export const ethBalance = async (who) => BigInt(await raw('eth_getBalance', [who, 'latest']));
export const storageWord = async (contract, slot) => BigInt(await raw('eth_getStorageAt', [contract, hex(slot), 'latest']));

/** Gives `to` `amount` of the route's token: the WBEAM pipe mints it; the other pipes pay it from what they hold. */
export async function giveTokens(route, to, amount) {
  assert.ok(route.ethToken, 'ETH comes from anvil_setBalance');
  const data = route.isBeam ? encodeCall('mint(address,uint256)', [to, amount]) : encodeCall('transfer(address,uint256)', [to, amount]);
  await sendAs(route.ethPipe, route.ethToken, data);
  assert.equal(await erc20Balance(route.ethToken, to), amount);
}

/**
 * The pipe's next Ethereum-side message id: the uint64 at the bottom of slot 0,
 * under the token (ERC20Pipe, the WBEAM pipe) or the relayer (EthPipe). The
 * token is checked to be where it is expected, so a different layout fails
 * here instead of reading a wrong id.
 */
export async function nextMsgId(route) {
  const w = await storageWord(route.ethPipe, 0);
  if (route.ethToken) assert.equal(`0x${((w >> 64n) & U160).toString(16).padStart(40, '0')}`, route.ethToken, 'slot 0 holds the token above the counter');
  return Number(w & U64);
}

/** The pipe's relayer, from storage: EthPipe packs it above the counter in slot 0; ERC20Pipe and the WBEAM pipe keep it in slot 1. */
export async function relayerOf(route) {
  const w = route.isNativeEth ? (await storageWord(route.ethPipe, 0)) >> 64n : await storageWord(route.ethPipe, 1);
  return `0x${(w & U160).toString(16).padStart(40, '0')}`;
}

/** What the route's pipe holds (ETH or the token); for WBEAM its total supply (the pipe burns and mints, it holds none). */
export async function pipeHoldings(route) {
  if (route.isNativeEth) return ethBalance(route.ethPipe);
  if (route.isBeam) return uint(route.ethToken, selector('totalSupply()'));
  return erc20Balance(route.ethToken, route.ethPipe);
}

/** The real PriceFeed answering from the fixture prices: nothing leaves the process. */
export function fixturePrices(clock = () => Date.now()) {
  const asked = [];
  const answer = Object.fromEntries(Object.entries(PRICES).map(([id, usd]) => [id, { usd }]));
  const feed = new PriceFeed({
    allowed: () => true,
    clock,
    fetch: async (url) => {
      const u = new URL(url);
      assert.equal(u.hostname, 'api.coingecko.com', 'only the price host is ever named');
      asked.push(u);
      return new Response(JSON.stringify(answer), { status: 200 });
    },
  });
  return { feed, asked };
}

/**
 * The controller's BEAM half for the fork tests: the receive key, BEAM to pay
 * the network fees with, and a pipe on BEAM that has not seen anything yet.
 */
export function forkBeamSide({ key = randomReceiverKey(), available = { 0: 5000n * 10n ** 8n } } = {}) {
  return Object.freeze({
    key,
    receiveKey: async () => Uint8Array.from(key),
    available: async (aid) => BigInt(available[aid] ?? 0n),
    localMessageCount: async () => 0,
    localMessage: async () => null,
    remoteMessage: async () => null,
    incoming: async () => [],
    tipHeight: async () => 4100000,
    txStatus: async () => ({ state: 'pending', height: null, reason: null }),
    send: async () => {
      throw Object.assign(new Error('no BEAM sends in the Ethereum fork tests'), { code: 'refused' });
    },
    claim: async () => {
      throw Object.assign(new Error('no BEAM claims in the Ethereum fork tests'), { code: 'refused' });
    },
  });
}

/** The pending nonce and whether the pool holds anything from `who`: proof that nothing was sent. */
export async function nothingSentBy(who) {
  const latest = BigInt(await raw('eth_getTransactionCount', [who.address, 'latest']));
  const pending = BigInt(await raw('eth_getTransactionCount', [who.address, 'pending']));
  return { latest, pending, none: latest === pending };
}

export { routeById };

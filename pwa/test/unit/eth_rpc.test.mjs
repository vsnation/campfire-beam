// The Ethereum RPC client, the host list and the token list, offline: a fake
// fetch stands in for the server and records what the client sends.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { EthRpc, EthRpcError, walletFees, gasWithHeadroom, MULTICALL3, MIN_TIP_WEI } from '../../src/lib/eth/rpc.js';
import { ETH_RPC_HOSTS, DEFAULT_ETH_RPC, PRICE_HOST, ethRpcHost, rpcUrl, priceUrl, connectSources } from '../../src/lib/eth/hosts.js';
import { TOKENS, ETH, WBEAM, tokenByAddress, tokenBySymbol } from '../../src/lib/eth/tokens.js';
import { toChecksumAddress, isAddress } from '../../src/lib/eth/crypto.js';
import { abiEncode, decodeCall } from '../../src/lib/eth/abi.js';
import { bytesToHex } from '../../src/lib/eth/hex.js';

const MAINNET = JSON.parse(readFileSync(new URL('./fixtures/eth/mainnet_tx.json', import.meta.url), 'utf8'));
const ADDR = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';

/** A fake server: handler(method, params) → result, or throws {code, message} for a JSON-RPC error. */
function fakeServer(handler, { batches = true } = {}) {
  const seen = [];
  const answer = (req) => {
    try {
      return { jsonrpc: '2.0', id: req.id, result: handler(req.method, req.params) };
    } catch (e) {
      return { jsonrpc: '2.0', id: req.id, error: { code: e.code ?? -32000, message: e.message, ...(e.data ? { data: e.data } : {}) } };
    }
  };
  const fetch = async (url, init) => {
    seen.push({ url, init, body: JSON.parse(init.body) });
    const body = JSON.parse(init.body);
    let out;
    if (Array.isArray(body)) out = batches ? body.map(answer) : { jsonrpc: '2.0', id: null, error: { code: -32600, message: 'batch not supported' } };
    else out = answer(body);
    return new Response(JSON.stringify(out), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { fetch, seen };
}

test('hosts: the five servers the desktop app offers and CoinGecko, nothing else', () => {
  assert.deepEqual(
    ETH_RPC_HOSTS.map((h) => h.host),
    ['eth2.stackwallet.com', 'ethereum-rpc.publicnode.com', 'eth.drpc.org', 'rpc.mevblocker.io', 'eth-mainnet.public.blastapi.io'],
  );
  assert.equal(DEFAULT_ETH_RPC, 'stackwallet');
  assert.equal(rpcUrl(ethRpcHost('stackwallet')), 'https://eth2.stackwallet.com');
  assert.throws(() => ethRpcHost('infura'));
  assert.throws(() => rpcUrl({ id: 'x', host: 'evil.example' }), 'only listed entries make a URL');
  assert.equal(priceUrl(['beam', 'ethereum']), 'https://api.coingecko.com/api/v3/simple/price?ids=beam,ethereum&vs_currencies=usd');
  assert.throws(() => priceUrl(['beam&x=1']));
  // Exactly the connect-src addition the plan names for Phase 1b.
  assert.deepEqual(connectSources(), [
    'https://eth2.stackwallet.com',
    'https://ethereum-rpc.publicnode.com',
    'https://eth.drpc.org',
    'https://rpc.mevblocker.io',
    'https://eth-mainnet.public.blastapi.io',
    'https://api.coingecko.com/api/v3/simple/price',
  ]);
  assert.equal(PRICE_HOST.host, 'api.coingecko.com');
  assert.ok(Object.isFrozen(ETH_RPC_HOSTS) && ETH_RPC_HOSTS.every(Object.isFrozen));
});

test('tokens: WBEAM, USDT, USDC, WBTC and DAI with the desktop app’s addresses and decimals', () => {
  assert.deepEqual(
    TOKENS.map((t) => [toChecksumAddress(t.address), t.symbol, t.name, t.decimals]),
    [
      ['0xE5AcBB03D73267c03349c76EaD672Ee4d941F499', 'WBEAM', 'Wrapped BEAM', 8],
      ['0xdAC17F958D2ee523a2206206994597C13D831ec7', 'USDT', 'Tether', 6],
      ['0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', 'USDC', 'USD Coin', 6],
      ['0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599', 'WBTC', 'Wrapped BTC', 8],
      ['0x6B175474E89094C44Da98b954EedeAC495271d0F', 'DAI', 'Dai', 18],
    ],
  );
  for (const t of TOKENS) assert.equal(t.address, t.address.toLowerCase());
  assert.equal(tokenByAddress('0xE5AcBB03D73267c03349c76EaD672Ee4d941F499'), WBEAM);
  assert.equal(tokenByAddress('0x0000000000000000000000000000000000000001'), null);
  assert.equal(tokenBySymbol('ETH'), ETH);
  assert.equal(ETH.decimals, 18);
  assert.deepEqual(TOKENS.map((t) => t.bridge), ['beam', 'usdt', null, 'wbtc', 'dai']);
});

test('requests: one listed host, no credentials, no cache, no redirects, no referrer', async () => {
  const s = fakeServer(() => '0x1');
  const rpc = new EthRpc('stackwallet', { fetch: s.fetch });
  assert.equal(await rpc.chainId(), 1n);
  const { url, init, body } = s.seen[0];
  assert.equal(url, 'https://eth2.stackwallet.com');
  assert.equal(init.method, 'POST');
  assert.equal(init.credentials, 'omit');
  assert.equal(init.cache, 'no-store');
  assert.equal(init.redirect, 'error');
  assert.equal(init.referrerPolicy, 'no-referrer');
  assert.deepEqual(init.headers, { 'content-type': 'application/json' });
  assert.ok(init.signal instanceof AbortSignal);
  assert.deepEqual(body, { jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] });
  assert.throws(() => new EthRpc({ id: 'custom', name: 'Mine', host: 'my.node' }));
  assert.throws(() => new EthRpc('nope'));
});

test('chain id: anything but mainnet is refused before signing', async () => {
  await new EthRpc('drpc', { fetch: fakeServer(() => '0x1').fetch }).assertMainnet();
  await assert.rejects(new EthRpc('drpc', { fetch: fakeServer(() => '0x5').fetch }).assertMainnet(), (e) => e instanceof EthRpcError && e.code === 'wrong_chain');
});

test('answers are checked: errors, wrong ids, non-JSON, busy servers, timeouts', async () => {
  const err = new EthRpc('blast', { fetch: fakeServer(() => { throw Object.assign(new Error('execution reverted'), { code: 3, data: '0x08c379a0' }); }).fetch });
  await assert.rejects(err.call('eth_call', []), (e) => e.code === 3 && e.message === 'execution reverted' && e.data === '0x08c379a0');
  const wrongId = new EthRpc('blast', { fetch: async () => new Response(JSON.stringify({ jsonrpc: '2.0', id: 99, result: '0x1' })) });
  await assert.rejects(wrongId.chainId(), (e) => e.code === 'bad_response');
  const html = new EthRpc('blast', { fetch: async () => new Response('<html>', { status: 502 }) });
  await assert.rejects(html.chainId(), (e) => e.code === 'http');
  const busy = new EthRpc('blast', { fetch: async () => new Response('', { status: 429 }) });
  await assert.rejects(busy.chainId(), (e) => e.code === 'busy');
  const down = new EthRpc('blast', { fetch: async () => { throw new TypeError('Failed to fetch'); } });
  await assert.rejects(down.chainId(), (e) => e.code === 'network');
  const slow = new EthRpc('blast', { timeoutMs: 20, fetch: (url, init) => new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')))) });
  await assert.rejects(slow.chainId(), (e) => e.code === 'timeout');
  const notHex = new EthRpc('blast', { fetch: fakeServer(() => 12).fetch });
  await assert.rejects(notHex.getBalance(ADDR), (e) => e.code === 'bad_response');
});

test('batch: in order, each its own result or error; falls back when batches are refused', async () => {
  const handler = (m, p) => {
    if (m === 'eth_getBalance') return '0x10';
    if (m === 'eth_blockNumber') return '0x18f2682';
    throw new Error('method not found');
  };
  for (const batches of [true, false]) {
    const s = fakeServer(handler, { batches });
    const rpc = new EthRpc('mevblocker', { fetch: s.fetch, maxBatch: 2 });
    const r = await rpc.batch([['eth_getBalance', [ADDR.toLowerCase(), 'latest']], ['eth_blockNumber', []], ['eth_nope', []]]);
    assert.equal(r[0], '0x10');
    assert.equal(r[1], '0x18f2682');
    assert.ok(r[2] instanceof EthRpcError && r[2].message === 'method not found');
    if (batches) assert.equal(s.seen.length, 2, 'split into batches of maxBatch');
  }
});

test('wallet calls: pending nonce, balance, eth_call, estimateGas, storage, receipts', async () => {
  const s = fakeServer((m, p) => {
    switch (m) {
      case 'eth_getTransactionCount':
        return p[1] === 'pending' ? '0x7' : '0x5';
      case 'eth_getBalance':
        return '0xde0b6b3a7640000';
      case 'eth_call':
        return '0x' + '00'.repeat(31) + '08';
      case 'eth_estimateGas':
        return '0xbeef';
      case 'eth_getStorageAt':
        return '0x01';
      case 'eth_getTransactionReceipt':
        return p[0] === MAINNET.hash
          ? { transactionHash: MAINNET.hash, status: '0x1', blockNumber: '0x18f1adc', gasUsed: '0x1e00d', effectiveGasPrice: '0x299f27eb', from: MAINNET.from, to: MAINNET.to, logs: [{ address: '0xE5ACBB03D73267C03349C76EAD672EE4D941F499', topics: ['0xDDF252AD1BE2C89B69C2B068FC378DAA952BA7F163C4A11628F55A4DF523B3EF'], data: '0x01', blockNumber: '0x18f1adc', logIndex: '0x3', transactionHash: MAINNET.hash }] }
          : null;
      default:
        throw new Error(`unexpected ${m}`);
    }
  });
  const rpc = new EthRpc('stackwallet', { fetch: s.fetch });
  assert.equal(await rpc.getTransactionCount(ADDR), 7n, "the nonce counts pending transactions by default");
  assert.equal(s.seen[0].body.params[0], ADDR.toLowerCase());
  assert.equal(await rpc.getTransactionCount(ADDR, 'latest'), 5n);
  assert.equal(await rpc.getBalance(ADDR), 10n ** 18n);
  assert.equal((await rpc.ethCall({ to: WBEAM.address, data: '0x313ce567' }))[31], 8);
  assert.deepEqual(s.seen.at(-1).body.params, [{ to: WBEAM.address, data: '0x313ce567' }, 'latest']);
  assert.equal(await rpc.estimateGas({ from: ADDR, to: ADDR, value: 1n }), 0xbeefn);
  assert.equal(s.seen.at(-1).body.params[0].value, '0x1');
  const word = await rpc.getStorageAt('0x6063024646e8a1561970840a4b0e0f1082f5a670', 2n);
  assert.equal(word.length, 32);
  assert.equal(word[31], 1, 'a short answer is left-padded');
  assert.equal(s.seen.at(-1).body.params[1], '0x' + '00'.repeat(31) + '02');
  const receipt = await rpc.getTransactionReceipt(MAINNET.hash);
  assert.equal(receipt.status, 1);
  assert.equal(receipt.blockNumber, MAINNET.blockNumber);
  assert.equal(receipt.logs[0].address, WBEAM.address, 'addresses and topics are lowercased');
  assert.equal(receipt.logs[0].topics[0], '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef');
  assert.equal(await rpc.getTransactionReceipt('0x' + '11'.repeat(32)), null);
  await assert.rejects(rpc.getBalance('0xF39Fd6e51aad88F6F4ce6aB8827279cffFb92266'), 'a bad checksum never reaches the server');
});

test('sendRawTransaction: the answer must be keccak(raw); a resend of known bytes counts as sent', async () => {
  const good = new EthRpc('stackwallet', { fetch: fakeServer(() => MAINNET.hash).fetch });
  assert.equal(await good.sendRawTransaction(MAINNET.raw), MAINNET.hash);
  const lying = new EthRpc('stackwallet', { fetch: fakeServer(() => '0x' + '22'.repeat(32)).fetch });
  await assert.rejects(lying.sendRawTransaction(MAINNET.raw), (e) => e.code === 'hash_mismatch');
  const known = new EthRpc('stackwallet', { fetch: fakeServer(() => { throw Object.assign(new Error('already known'), { code: -32000 }); }).fetch });
  assert.equal(await known.sendRawTransaction(MAINNET.raw), MAINNET.hash);
  const low = new EthRpc('stackwallet', { fetch: fakeServer(() => { throw Object.assign(new Error('nonce too low'), { code: -32000 }); }).fetch });
  await assert.rejects(low.sendRawTransaction(MAINNET.raw), (e) => e.message === 'nonce too low');
});

test('getLogs: bounded; chunked searches stop gracefully when a server refuses ranges', async () => {
  const rpc0 = new EthRpc('publicnode', { fetch: fakeServer(() => []).fetch });
  await assert.rejects(rpc0.getLogs({ fromBlock: 0, toBlock: 10000 }), (e) => e.code === 'range', 'over 10,000 blocks is refused locally');
  await assert.rejects(rpc0.getLogs({ fromBlock: 5, toBlock: 4 }), (e) => e.code === 'range');
  assert.deepEqual(await rpc0.getLogs({ address: WBEAM.address, topics: [null], fromBlock: 1, toBlock: 10000 }), []);

  // A server that takes at most 2,000 blocks and says so.
  const calls = [];
  const s = fakeServer((m, [f]) => {
    const from = Number(f.fromBlock);
    const to = Number(f.toBlock);
    calls.push([from, to]);
    if (to - from + 1 > 2000) throw new Error('eth_getLogs is limited to a 2,000 block range');
    return from === 1 ? [{ address: WBEAM.address, topics: [], data: '0x', blockNumber: '0x1', logIndex: '0x0', transactionHash: '0x' + '33'.repeat(32) }] : [];
  });
  const r = await new EthRpc('mevblocker', { fetch: s.fetch }).getLogsChunked({ address: WBEAM.address, fromBlock: 1, toBlock: 5000 });
  assert.equal(r.complete, true);
  assert.equal(r.scannedTo, 5000);
  assert.equal(r.logs.length, 1);
  assert.deepEqual(calls, [[1, 5000], [1, 2000], [2001, 4000], [4001, 5000]]);

  // A server that only searches 10 blocks: the search ends with what it has, without throwing.
  const tiny = fakeServer(() => { throw new Error('block range is too wide, maximum allowed is 10 blocks'); });
  const t = await new EthRpc('blast', { fetch: tiny.fetch }).getLogsChunked({ fromBlock: 100, toBlock: 90000 });
  assert.equal(t.complete, false);
  assert.equal(t.scannedTo, 99);
  assert.ok(t.refused instanceof EthRpcError);

  // A request budget: partial result and where to carry on.
  const budget = await new EthRpc('stackwallet', { fetch: fakeServer(() => []).fetch }).getLogsChunked({ fromBlock: 0, toBlock: 99999 }, { maxRequests: 3 });
  assert.deepEqual([budget.complete, budget.scannedTo], [false, 29999]);
  // Anything else than a range refusal is a real error.
  const broken = fakeServer(() => { throw new Error('internal error'); });
  await assert.rejects(new EthRpc('stackwallet', { fetch: broken.fetch }).getLogsChunked({ fromBlock: 0, toBlock: 10 }), /internal error/);
});

test('multicall: aggregate3 to Multicall3, chunked, each call may fail on its own', async () => {
  const s = fakeServer((m, [call]) => {
    assert.equal(call.to, MULTICALL3.toLowerCase());
    const [calls] = decodeCall('aggregate3((address,bool,bytes)[])', call.data);
    for (const c of calls) assert.equal(c[1], true, 'allowFailure');
    // Within each chunk, every second call fails.
    return bytesToHex(abiEncode('(bool,bytes)[]', [calls.map(([, , data], i) => [i % 2 === 0, data])]));
  });
  const rpc = new EthRpc('stackwallet', { fetch: s.fetch });
  const calls = Array.from({ length: 5 }, (_, i) => ({ to: TOKENS[i].address, data: Uint8Array.of(i, 1, 2, 3) }));
  const r = await rpc.multicall(calls, { chunk: 2, parallel: 2 });
  assert.equal(s.seen.length, 3);
  assert.deepEqual(r.map((x) => [x.success, bytesToHex(x.data)]), [
    [true, '0x00010203'],
    [false, '0x01010203'],
    [true, '0x02010203'],
    [false, '0x03010203'],
    [true, '0x04010203'],
  ]);
  assert.ok(isAddress(MULTICALL3));
});

test("walletFees: the desktop app's arithmetic (feeHistory(5, latest, [50]), 2 × next base + median tip, tip ≥ 0.01 gwei)", async () => {
  const history = (bases, tips) => ({ oldestBlock: '0x1', baseFeePerGas: bases.map((b) => '0x' + b.toString(16)), reward: tips.map((t) => ['0x' + t.toString(16)]) });
  let asked;
  const make = (h) => new EthRpc('stackwallet', { fetch: fakeServer((m, p) => ((asked = [m, p]), h)).fetch });
  const f = await walletFees(make(history([10n, 11n, 12n, 13n, 14n, 2000000000n], [5000000000n, 1000000000n, 3000000000n, 2000000000n, 4000000000n])));
  assert.deepEqual(asked, ['eth_feeHistory', ['0x5', 'latest', [50]]]);
  assert.equal(f.baseFee, 2000000000n, 'the last entry is the next block');
  assert.equal(f.maxPriorityFeePerGas, 3000000000n, 'median of the sorted tips');
  assert.equal(f.maxFeePerGas, 2n * 2000000000n + 3000000000n);
  // Four tips: the upper median (index n/2), as Dart's ~/ gives.
  assert.equal((await walletFees(make(history([1n, 1n], [4n * MIN_TIP_WEI, MIN_TIP_WEI, 3n * MIN_TIP_WEI, 2n * MIN_TIP_WEI])))).maxPriorityFeePerGas, 3n * MIN_TIP_WEI);
  // Tiny or missing tips are lifted to 0.01 gwei.
  const low = await walletFees(make(history([7n, 100n], [1n, 2n, 3n])));
  assert.equal(low.maxPriorityFeePerGas, 10000000n);
  assert.equal(low.maxFeePerGas, 200n + 10000000n);
  assert.equal((await walletFees(make({ baseFeePerGas: ['0x64'], reward: [] }))).maxPriorityFeePerGas, MIN_TIP_WEI);
  await assert.rejects(walletFees(make({ baseFeePerGas: [] })), EthRpcError);
});

test('gasWithHeadroom: a quarter more, at least 20,000 more', () => {
  assert.equal(gasWithHeadroom(21000n), 41000n);
  assert.equal(gasWithHeadroom(80000n), 100000n);
  assert.equal(gasWithHeadroom(200000n), 250000n);
  assert.equal(gasWithHeadroom(122893), 153616n);
});

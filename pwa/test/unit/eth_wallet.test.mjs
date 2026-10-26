// The Ethereum wallet's own logic, offline: the sealed data store, the outbox
// (written before anything is broadcast), the history index parser and merge,
// recipient checks, preparing a payment with its fees, signing and sending,
// and following a transaction to its receipt (or to "replaced").
import test from 'node:test';
import assert from 'node:assert/strict';
import { sealData, openData, forgetDataKeys, ETH_DATA_INFO } from '../../src/lib/eth/sealed.js';
import { loadOutbox, addToOutbox, updateOutbox, clearOutbox, validEntry, trimOutbox, OUTBOX_MAX } from '../../src/lib/eth/outbox.js';
import { parseTransactions, parseTokenTransfers, mergeActivity, fetchHistory, HistoryError, PAGE } from '../../src/lib/eth/history.js';
import { recipientProblem, transferCall, prepareSend, signAndSend, followOnce, classify, findNonceTaker, maxSendable, costRose, entryFee, SendError, BRIDGE_PIPES, ETH_TRANSFER_GAS, NONCE_LOOK_MS, REFUSAL_WATCH_MS } from '../../src/lib/eth/send.js';
import { ethWallet, removeEthWallet, ethPrefs, forgetEthWallet } from '../../src/lib/eth/wallet.js';
import { saveEthKey, getEthRecord, VaultError } from '../../src/lib/eth/vault.js';
import { hasEthWallet, ETH_OUTBOX_KEY, ETH_RECORD_KEY } from '../../src/lib/eth/record.js';
import { ethKeyFromMnemonic, toChecksumAddress } from '../../src/lib/eth/crypto.js';
import { EthRpc } from '../../src/lib/eth/rpc.js';
import { parseSignedTransaction, transactionHash, signTransaction } from '../../src/lib/eth/tx.js';
import { decodeCall, abiEncode } from '../../src/lib/eth/abi.js';
import { bytesToHex } from '../../src/lib/eth/hex.js';
import { ETH, WBEAM, TOKENS, tokenBySymbol } from '../../src/lib/eth/tokens.js';
import { ROUTES } from '../../src/lib/bridge/routes.js';
import { newDbPassword, PBKDF2_MIN_ITERATIONS } from '../../src/lib/envelope.js';
import * as F from './fixtures/eth/history_export.mjs';

const JUNK = 'test test test test test test test test test test test junk';
const ME = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';
const ALICE = toChecksumAddress(F.ALICE);
const GWEI = 10n ** 9n;
const ETHER = 10n ** 18n;

const memoryKv = () => {
  const m = new Map();
  return { m, get: async (k) => structuredClone(m.get(k)), set: async (k, v) => void m.set(k, structuredClone(v)), del: async (k) => void m.delete(k) };
};
const newApp = (over = {}) => ({ record: { id: 'w-1', imported: false }, dbPass: newDbPassword(), prefs: {}, ...over });

async function walletWithKey({ imported = false } = {}) {
  const kv = memoryKv();
  const app = newApp({ record: { id: 'w-1', imported }, dbPass: imported ? 'file password' : newDbPassword() });
  const { sk, address } = await ethKeyFromMnemonic(JUNK);
  const record = await saveEthKey(app, { sk, address, words: 12 }, { kv });
  return { app, kv, record, ethId: record.id };
}

function entry(over = {}) {
  return {
    hash: `0x${'11'.repeat(32)}`,
    raw: '0x02f8aa',
    nonce: '0',
    from: ME,
    to: ALICE,
    asset: 'ETH',
    token: null,
    amount: '10000000000000000',
    gasLimit: '21000',
    maxFeePerGas: '3000000000',
    maxPriorityFeePerGas: '1000000000',
    createdAt: 1000,
    sentAt: null,
    state: 'signed',
    receipt: null,
    error: null,
    ...over,
  };
}

// ---------------------------------------------------------------- sealed

test('sealed data: round trip under the BEAM database password; nothing in the clear; bound to its wallet and name', async () => {
  const { app, kv, ethId } = await walletWithKey();
  const value = [{ hash: '0xabc', to: ALICE }];
  const env = await sealData(app, 'eth-test', value, { ethId, kv });
  assert.equal(env.kind, 'eth-data');
  assert.equal(env.kdf, 'hkdf-sha256');
  assert.equal(ETH_DATA_INFO, 'beam-campfire-eth-data-v1');
  assert.ok(!JSON.stringify(env).toLowerCase().includes(F.ALICE.slice(2)), 'the address is only inside');
  assert.deepEqual(await openData(app, 'eth-test', { ethId, kv }), value);
  // The salt (and so the derived key) is kept across rewrites; the iv is not.
  const env2 = await sealData(app, 'eth-test', [...value, { hash: '0xdef' }], { ethId, kv });
  assert.equal(env2.salt, env.salt);
  assert.notEqual(env2.iv, env.iv);
  forgetDataKeys();
  assert.equal((await openData(app, 'eth-test', { ethId, kv })).length, 2, 'opens again after the keys are forgotten');
  // Another dbPass, another wallet, another Ethereum wallet, a renamed record.
  await assert.rejects(openData({ ...app, dbPass: newDbPassword() }, 'eth-test', { ethId, kv }), (e) => e instanceof VaultError && e.code === 'wrong_secret');
  await assert.rejects(openData({ ...app, record: { id: 'w-2', imported: false } }, 'eth-test', { ethId, kv }), (e) => e.code === 'mismatch');
  assert.equal(await openData(app, 'eth-test', { ethId: 'other', kv }), null, "a removed Ethereum wallet's data is not shown for a new one");
  kv.m.set('eth-other', { ...kv.m.get('eth-test'), name: 'eth-other' });
  await assert.rejects(openData(app, 'eth-other', { ethId, kv }), (e) => e.code === 'wrong_secret', 'the name is bound');
  assert.equal(await openData(app, 'nothing-here', { ethId, kv }), null);
  await assert.rejects(openData({ ...app, dbPass: null }, 'eth-test', { ethId, kv }), (e) => e.code === 'locked');
});

test('sealed data: an imported wallet uses PBKDF2 at 600,000 rounds or more, and refuses fewer or a swapped KDF', async () => {
  const { app, kv, ethId } = await walletWithKey({ imported: true });
  const env = await sealData(app, 'eth-test', { a: 1 }, { ethId, kv });
  assert.equal(env.kdf, 'pbkdf2-sha256');
  assert.equal(env.iterations, PBKDF2_MIN_ITERATIONS);
  assert.ok(env.iterations >= 600000);
  assert.deepEqual(await openData(app, 'eth-test', { ethId, kv }), { a: 1 });
  kv.m.set('eth-test', { ...env, iterations: 1000 });
  await assert.rejects(openData(app, 'eth-test', { ethId, kv }), (e) => e.code === 'weak');
  await assert.rejects(sealData(app, 'eth-test', { a: 2 }, { ethId, kv }), (e) => e.code === 'weak', 'a lowered count is not carried into the next write');
  kv.m.set('eth-test', { ...env, kdf: 'hkdf-sha256', iterations: undefined });
  await assert.rejects(openData(app, 'eth-test', { ethId, kv }), (e) => e.code === 'weak');
});

// ---------------------------------------------------------------- outbox

test('outbox: add, update, newest first; checked entries only; hash, raw, nonce and sender cannot be changed', async () => {
  const { app, kv, ethId } = await walletWithKey();
  assert.deepEqual(await loadOutbox(app, { ethId, kv }), []);
  await addToOutbox(app, entry(), { ethId, kv });
  await addToOutbox(app, entry({ hash: `0x${'22'.repeat(32)}`, createdAt: 2000 }), { ethId, kv });
  let list = await loadOutbox(app, { ethId, kv });
  assert.deepEqual(list.map((e) => e.hash.slice(0, 4)), ['0x22', '0x11']);
  const u = await updateOutbox(app, `0x${'11'.repeat(32)}`, { state: 'pending', sentAt: 5, raw: '0x02ff', nonce: '9' }, { ethId, kv });
  assert.equal(u.state, 'pending');
  assert.equal(u.raw, '0x02f8aa');
  assert.equal(u.nonce, '0');
  await assert.rejects(updateOutbox(app, `0x${'11'.repeat(32)}`, { state: 'lost' }, { ethId, kv }));
  assert.equal(await updateOutbox(app, `0x${'33'.repeat(32)}`, { state: 'pending' }, { ethId, kv }), null);
  await assert.rejects(addToOutbox(app, { ...entry(), hash: 'nope' }, { ethId, kv }));
  for (const bad of [null, {}, entry({ raw: '0x01aa' }), entry({ amount: '-1' }), entry({ to: 'bob' }), entry({ state: 'done' })]) assert.equal(validEntry(bad), false);
  // Two quick updates do not lose each other.
  await Promise.all([updateOutbox(app, `0x${'11'.repeat(32)}`, { error: 'x' }, { ethId, kv }), updateOutbox(app, `0x${'22'.repeat(32)}`, { state: 'pending' }, { ethId, kv })]);
  list = await loadOutbox(app, { ethId, kv });
  assert.equal(list.find((e) => e.hash.startsWith('0x11')).error, 'x');
  assert.equal(list.find((e) => e.hash.startsWith('0x22')).state, 'pending');
  assert.ok(!JSON.stringify([...kv.m.values()]).toLowerCase().includes(F.ALICE.slice(2)), 'nothing readable in storage');
  await clearOutbox(kv);
  assert.equal(kv.m.has(ETH_OUTBOX_KEY), false);
});

test('outbox: trimming keeps every open transaction and the newest closed ones', () => {
  const list = [];
  for (let i = 0; i < OUTBOX_MAX + 20; i++) list.push(entry({ hash: `0x${i.toString(16).padStart(64, '0')}`, state: i % 30 === 29 ? 'pending' : 'confirmed', createdAt: 10000 - i }));
  const t = trimOutbox(list);
  assert.equal(t.length, OUTBOX_MAX);
  assert.equal(t.filter((e) => e.state === 'pending').length, list.filter((e) => e.state === 'pending').length);
  assert.equal(t[0].hash, list[0].hash);
});

// ---------------------------------------------------------------- history

test('history index: transactions parsed exactly, junk dropped, fee from gasUsed x effectiveGasPrice', () => {
  const txs = parseTransactions(F.txs(), ME);
  assert.deepEqual(txs.map((t) => t.hash), [F.h(1), F.h(2), F.h(3), F.h(4)]);
  assert.equal(txs[0].value, ETHER);
  assert.equal(txs[0].from, F.ALICE);
  assert.equal(txs[1].fee, 21000n * 12345678901n, 'not the gasCost number');
  assert.equal(txs[2].contractCall, true);
  assert.equal(txs[3].failed, true);
  assert.throws(() => parseTransactions({ message: 'nope' }, ME), HistoryError);
});

test('history index: only Transfer events of the token itself, naming this address', () => {
  const xs = parseTokenTransfers(F.wbeamLogs(), ME, WBEAM);
  assert.deepEqual(xs.map((x) => [x.hash, x.from, x.to, x.amount]), [
    [F.h(3), F.ME, F.BOB, 1250000000n],
    [F.h(7), F.ALICE, F.ME, 10000000000n],
  ]);
});

test('activity: one row per movement, token transfers instead of their 0-ETH call, what this device sent wins, open ones first', () => {
  const txs = parseTransactions(F.txs(), ME);
  const transfers = parseTokenTransfers(F.wbeamLogs(), ME, WBEAM);
  const sentHere = entry({ hash: F.h(2), state: 'confirmed', amount: '250000000000000000', to: toChecksumAddress(F.BOB), receipt: { blockNumber: 200, status: 1, gasUsed: '21000', effectiveGasPrice: '12345678901' } });
  const open = entry({ hash: `0x${'aa'.repeat(32)}`, state: 'pending', createdAt: 1 });
  const items = mergeActivity({ address: ME, outbox: [sentHere, open], txs, transfers });
  assert.equal(items[0].hash, open.hash, 'open first');
  assert.equal(items[0].state, 'pending');
  const rows = items.map((i) => [i.hash, i.asset.symbol, i.direction, i.amount, i.state]);
  assert.deepEqual(rows.slice(1), [
    [F.h(7), 'WBEAM', 'in', 10000000000n, 'confirmed'],
    [F.h(4), 'ETH', 'out', 5n, 'failed'],
    [F.h(3), 'WBEAM', 'out', 1250000000n, 'confirmed'],
    [F.h(2), 'ETH', 'out', 250000000000000000n, 'confirmed'],
    [F.h(1), 'ETH', 'in', ETHER, 'confirmed'],
  ]);
  assert.equal(items.find((i) => i.hash === F.h(3)).fee, 51000n * 2000000000n, "the token transfer carries its call's fee");
  assert.equal(items.find((i) => i.hash === F.h(2)).local, true);
  assert.equal(items.find((i) => i.hash === F.h(1)).fee, null, 'nothing paid on what came in');
});

test('history fetch: Stack Wallet only, no credentials, pages by firstBlock, an empty body is an empty history', async () => {
  const seen = [];
  // Page 2 starts at the last block of page 1, so that block's transaction comes again.
  const page = (from, n) => ({ data: Array.from({ length: n }, (_, i) => ({ hash: F.h(from + i), from: F.ALICE, to: F.ME, value: '1', blockNumber: from + i, timestamp: 1 })) });
  const fetch = async (url, init) => {
    seen.push({ url, init });
    const u = new URL(url);
    let body;
    if (u.searchParams.get('emitter')) body = u.searchParams.get('emitter') === F.WBEAM_ADDR ? JSON.stringify(F.wbeamLogs()) : '';
    else body = JSON.stringify(Number(u.searchParams.get('firstBlock')) === 0 ? page(1, PAGE) : page(PAGE, 3));
    return { ok: true, status: 200, text: async () => body };
  };
  const { txs, transfers } = await fetchHistory(ME, { fetch });
  assert.equal(txs.length, PAGE + 2, 'the overlapping block is not counted twice');
  assert.equal(transfers.length, 2);
  for (const s of seen) {
    assert.match(s.url, /^https:\/\/eth2\.stackwallet\.com\/export\?addrs=0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266&/);
    assert.equal(s.init.credentials, 'omit');
    assert.equal(s.init.referrerPolicy, 'no-referrer');
    assert.equal(s.init.redirect, 'error');
  }
  assert.equal(seen.filter((s) => s.url.includes('emitter=')).length, TOKENS.length);
  await assert.rejects(fetchHistory(ME, { fetch: async () => ({ ok: false, status: 502, text: async () => '' }) }), (e) => e instanceof HistoryError && e.code === 'http');
  await assert.rejects(fetchHistory(ME, { fetch: async () => { throw new TypeError('x'); } }), (e) => e.code === 'network');
});

// ---------------------------------------------------------------- recipients

test('recipients: format, checksum, own, zero, the bridge pipes and token contracts are refused in words', () => {
  assert.equal(recipientProblem(ALICE, { own: ME }), null);
  assert.equal(recipientProblem(F.ALICE, { own: ME }), null, 'all lowercase carries no checksum and is fine');
  assert.equal(recipientProblem('').code, 'empty');
  assert.equal(recipientProblem('0x123').code, 'format');
  assert.equal(recipientProblem(F.ALICE.slice(2)).code, 'format');
  assert.match(recipientProblem(F.ALICE.slice(2)).message, /starts with 0x/);
  const typo = ALICE.slice(0, -1) + (ALICE.at(-1) === 'C' ? 'c' : 'C');
  assert.equal(recipientProblem(typo === ALICE ? ALICE.replace('9', 'a') : typo).code, 'checksum');
  assert.equal(recipientProblem(ME.toLowerCase(), { own: ME }).code, 'own');
  assert.equal(recipientProblem('0x0000000000000000000000000000000000000000').code, 'zero');
  assert.equal(BRIDGE_PIPES.length, ROUTES.length);
  for (const r of ROUTES) assert.equal(recipientProblem(r.ethPipe).code, 'bridge', r.id);
  for (const t of TOKENS) assert.equal(recipientProblem(toChecksumAddress(t.address)).code, 'token', t.symbol);
  assert.match(recipientProblem(WBEAM.address).message, /WBEAM token's own contract/);
});

test('transfer calls: ETH goes to the person; a token goes to its contract as transfer(to, amount)', () => {
  assert.deepEqual(transferCall(ETH, F.ALICE, 5n), { to: ALICE, value: 5n, data: '0x' });
  const t = transferCall(WBEAM, F.ALICE, 7n);
  assert.equal(t.to, toChecksumAddress(WBEAM.address));
  assert.equal(t.value, 0n);
  assert.deepEqual(decodeCall('transfer(address,uint256)', t.data), [ALICE, 7n]);
  assert.throws(() => transferCall({ symbol: 'FAKE', address: F.BOB, decimals: 18 }, F.ALICE, 1n), SendError);
});

// ---------------------------------------------------------------- a fake chain

const word = (n) => `0x${BigInt(n).toString(16).padStart(64, '0')}`;
const q = (n) => `0x${BigInt(n).toString(16)}`;

/** A signed transaction as a server's JSON shows it (eth_getTransactionByHash, a full block). */
function txJson(raw, blockNumber = null) {
  const p = parseSignedTransaction(raw);
  const t = p.tx;
  return {
    type: '0x2',
    chainId: q(t.chainId),
    nonce: q(t.nonce),
    maxPriorityFeePerGas: q(t.maxPriorityFeePerGas),
    maxFeePerGas: q(t.maxFeePerGas),
    gas: q(t.gasLimit),
    to: t.to.toLowerCase(),
    value: q(t.value),
    input: t.data,
    accessList: [],
    v: q(p.yParity),
    yParity: q(p.yParity),
    r: q(p.r),
    s: q(p.s),
    hash: p.hash,
    from: p.from.toLowerCase(),
    blockHash: blockNumber === null ? null : F.h(0xb000 + blockNumber),
    blockNumber: blockNumber === null ? null : q(blockNumber),
  };
}

/**
 * A tiny chain behind EthRpc's own fetch: one account, a pool, receipts on demand, blocks from
 * 100 on with the transactions mined in them, and the account's count at each block. st.latest
 * is what 'latest' answers (a test sets it to lie); st.lieAll makes every block's count lie too;
 * st.noOldState refuses counts at past blocks, as a server without old state does; st.relayOnRefuse
 * keeps refused bytes (a server that passed them on and then said no).
 */
function fakeChain({ eth = ETHER, nonce = 0n, transferReturns = word(1), estimate = null, codeAt = {}, onSend = null } = {}) {
  const st = { eth, latest: nonce, pending: nonce, pool: new Map(), mined: new Map(), byHash: new Map(), blocks: new Map(), own: [], head: 100, sends: [], calls: [], down: false, refuse: null, relayed: new Map(), relayOnRefuse: false, lieAll: false, noOldState: false };
  const countAt = (n) => {
    if (st.lieAll) return st.latest;
    if (st.noOldState && n < st.head) throw Object.assign(new Error('missing trie node'), { code: -32000 });
    return nonce + BigInt(st.own.filter((b) => b <= n).length);
  };
  const handle = async (method, params) => {
    st.calls.push(method);
    switch (method) {
      case 'eth_chainId':
        return '0x1';
      case 'eth_blockNumber':
        return q(st.head);
      case 'eth_getBlockByNumber': {
        const n = Number(BigInt(params[0]));
        if (n > st.head) return null;
        return { number: q(n), hash: F.h(0xb000 + n), transactions: st.blocks.get(n) || [] };
      }
      case 'eth_feeHistory':
        // base fee 10 gwei (next block), tips 1..5 gwei -> median 3
        return { oldestBlock: '0x60', baseFeePerGas: Array(6).fill(q(10n * GWEI)), reward: [1, 2, 3, 4, 5].map((g) => [q(BigInt(g) * GWEI)]) };
      case 'eth_estimateGas': {
        if (estimate instanceof Error) throw estimate;
        if (estimate != null) return q(estimate);
        return params[0].data && params[0].data !== '0x' ? q(51000) : q(21000);
      }
      case 'eth_getCode':
        return codeAt[params[0]] || '0x';
      case 'eth_call':
        if (transferReturns instanceof Error) throw transferReturns;
        return transferReturns;
      case 'eth_getBalance':
        return q(st.eth);
      case 'eth_getTransactionCount':
        if (params[1] === 'pending') return q(st.pending);
        if (params[1] === 'latest') return q(st.latest);
        return q(countAt(Number(BigInt(params[1]))));
      case 'eth_sendRawTransaction': {
        if (onSend) await onSend(params[0]);
        if (st.refuse) {
          if (st.relayOnRefuse) st.relayed.set(transactionHash(params[0]), params[0]);
          throw st.refuse;
        }
        const hash = transactionHash(params[0]);
        st.sends.push(params[0]);
        st.pool.set(hash, params[0]);
        st.pending += 1n;
        return hash;
      }
      case 'eth_getTransactionReceipt':
        return st.mined.get(params[0]) || null;
      case 'eth_getTransactionByHash': {
        const h = params[0];
        if (st.byHash.has(h)) return st.byHash.get(h);
        if (st.mined.has(h)) return { hash: h, blockHash: F.h(0xbb) };
        if (st.pool.has(h)) return { hash: h, blockHash: null };
        return null;
      }
      default:
        throw Object.assign(new Error(`unexpected ${method}`), { code: -32601 });
    }
  };
  const fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    if (st.down === true || (st.down && body.method === st.down)) throw new TypeError('Failed to fetch');
    const one = async (r) => {
      try {
        return { jsonrpc: '2.0', id: r.id, result: await handle(r.method, r.params) };
      } catch (e) {
        return { jsonrpc: '2.0', id: r.id, error: { code: e.code ?? -32000, message: e.message } };
      }
    };
    const out = Array.isArray(body) ? await Promise.all(body.map(one)) : await one(body);
    return { status: 200, text: async () => JSON.stringify(out) };
  };
  const receiptOf = (hash, n, status) => ({ transactionHash: hash, status: q(status), blockNumber: q(n), blockHash: F.h(0xb000 + n), from: ME.toLowerCase(), to: F.ALICE, gasUsed: q(21000), effectiveGasPrice: q(13n * GWEI), logs: [] });
  const mine = (hash, status = 1) => {
    const raw = st.pool.get(hash) || st.relayed.get(hash);
    st.pool.delete(hash);
    st.relayed.delete(hash);
    st.latest += 1n;
    const n = ++st.head;
    st.own.push(n);
    if (raw) st.blocks.set(n, [txJson(raw, n)]);
    st.mined.set(hash, receiptOf(hash, n, status));
  };
  /** Mines signed bytes this server never had in its pool (sent elsewhere); `json` as the block shows it. */
  const mineRaw = (raw, { json = txJson(raw, st.head + 1), receipt = true } = {}) => {
    const n = ++st.head;
    st.latest += 1n;
    st.own.push(n);
    st.blocks.set(n, [json]);
    st.byHash.set(json.hash, json);
    if (receipt) st.mined.set(json.hash, receiptOf(json.hash, n, 1));
    return n;
  };
  return { st, rpc: new EthRpc('stackwallet', { fetch }), mine, mineRaw };
}

// ---------------------------------------------------------------- prepare

test('prepare ETH: 21,000 gas for a plain account; "likely" and "up to" fees; refuses what the fee leaves no room for', async () => {
  const { rpc } = fakeChain();
  const balances = { eth: ETHER };
  const p = await prepareSend(rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 10n ** 16n, balances });
  assert.equal(p.tx.gasLimit, ETH_TRANSFER_GAS);
  assert.equal(p.tx.maxPriorityFeePerGas, 3n * GWEI, 'the median tip');
  assert.equal(p.tx.maxFeePerGas, 23n * GWEI, '2 x base + tip');
  assert.equal(p.fees.upTo, 21000n * 23n * GWEI);
  assert.equal(p.fees.likely, 21000n * 13n * GWEI);
  assert.equal(p.recipient, ALICE);
  assert.equal(p.tx.to, ALICE);
  assert.equal(p.tx.value, 10n ** 16n);
  const max = maxSendable(ETH, balances, p.fees.upTo);
  assert.equal(max, ETHER - p.fees.upTo);
  await prepareSend(rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: max, balances });
  await assert.rejects(prepareSend(rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: max + 1n, balances }), (e) => e.code === 'not_enough' && /You can send up to/.test(e.message));
  await assert.rejects(prepareSend(rpc, { from: ME, asset: ETH, recipient: ME, amount: 1n, balances }), (e) => e.code === 'recipient');
  await assert.rejects(prepareSend(rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 0n, balances }), (e) => e.code === 'not_enough');
});

test('prepare ETH to a contract: the estimate with headroom; a refusing contract is said plainly', async () => {
  const { rpc } = fakeChain({ estimate: 30000n, codeAt: { [F.BOB]: '0x6080' } });
  const p = await prepareSend(rpc, { from: ME, asset: ETH, recipient: F.BOB, amount: 1n, balances: { eth: ETHER } });
  assert.equal(p.tx.gasLimit, 50000n, '+20,000 at least');
  const refusing = fakeChain({ estimate: Object.assign(new Error('execution reverted: no thanks'), { code: 3 }), codeAt: { [F.BOB]: '0x6080' } });
  await assert.rejects(prepareSend(refusing.rpc, { from: ME, asset: ETH, recipient: F.BOB, amount: 1n, balances: { eth: ETHER } }), (e) => e.code === 'would_fail' && /no thanks/.test(e.message));
  const plain = fakeChain({ estimate: Object.assign(new Error('some node quirk'), { code: -32000 }) });
  assert.equal((await prepareSend(plain.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 1n, balances: { eth: ETHER } })).tx.gasLimit, 21000n, 'an account without code cannot refuse ETH');
});

test('prepare a token: transfer() to the token, simulated first; the fee must be there in ETH', async () => {
  const { rpc } = fakeChain();
  const balances = { eth: ETHER, WBEAM: 5n * 10n ** 8n };
  const p = await prepareSend(rpc, { from: ME, asset: WBEAM, recipient: F.ALICE, amount: 10n ** 8n, balances });
  assert.equal(p.tx.to, toChecksumAddress(WBEAM.address));
  assert.equal(p.tx.value, 0n);
  assert.deepEqual(decodeCall('transfer(address,uint256)', p.tx.data), [ALICE, 10n ** 8n]);
  assert.equal(p.tx.gasLimit, 71000n, '51,000 + 20,000');
  assert.equal(maxSendable(WBEAM, balances, p.fees.upTo), 5n * 10n ** 8n);
  await assert.rejects(prepareSend(rpc, { from: ME, asset: WBEAM, recipient: F.ALICE, amount: 6n * 10n ** 8n, balances }), (e) => e.code === 'not_enough');
  await assert.rejects(prepareSend(rpc, { from: ME, asset: WBEAM, recipient: F.ALICE, amount: 1n, balances: { eth: 1000n, WBEAM: 10n } }), (e) => e.code === 'no_gas' && /paid in ETH/.test(e.message));
  const no = fakeChain({ transferReturns: word(0) });
  await assert.rejects(prepareSend(no.rpc, { from: ME, asset: WBEAM, recipient: F.ALICE, amount: 1n, balances }), (e) => e.code === 'would_fail');
  const usdt = fakeChain({ transferReturns: '0x' });
  const usdtToken = tokenBySymbol('USDT');
  await prepareSend(usdt.rpc, { from: ME, asset: usdtToken, recipient: F.ALICE, amount: 1n, balances: { eth: ETHER, USDT: 1n } }); // returns nothing, like USDT
  const reverts = fakeChain({ transferReturns: Object.assign(new Error('execution reverted: blacklisted'), { code: 3 }) });
  await assert.rejects(prepareSend(reverts.rpc, { from: ME, asset: WBEAM, recipient: F.ALICE, amount: 1n, balances }), (e) => e.code === 'would_fail' && /blacklisted/.test(e.message));
});

test('a fresh preparation that costs more than the reviewed one is noticed', () => {
  const a = { fees: { upTo: 100n }, tx: { gasLimit: 21000n, to: ALICE, value: 1n } };
  assert.equal(costRose(a, a), false);
  assert.equal(costRose(a, { ...a, fees: { upTo: 101n } }), true);
  assert.equal(costRose(a, { ...a, fees: { upTo: 99n } }), false);
  assert.equal(costRose(a, { ...a, tx: { ...a.tx, value: 2n } }), true);
});

// ---------------------------------------------------------------- sign, save, send, follow

test('send: signed with a fresh nonce, saved BEFORE it is broadcast, then pending; the key opens only with the wallet unlocked', async () => {
  const { app, kv, ethId } = await walletWithKey();
  let savedBeforeSend = null;
  const chain = fakeChain({
    nonce: 4n,
    onSend: async (raw) => {
      const list = await loadOutbox(app, { ethId, kv });
      savedBeforeSend = list.find((e) => e.raw === raw) || null;
    },
  });
  const p = await prepareSend(chain.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 10n ** 16n, balances: { eth: ETHER } });
  const r = await signAndSend(app, chain.rpc, p, { ethId, kv, now: () => 42 });
  assert.equal(r.sent, true);
  assert.ok(savedBeforeSend, 'the outbox held the bytes when they were broadcast');
  assert.equal(savedBeforeSend.state, 'signed');
  assert.equal(r.entry.state, 'pending');
  const parsed = parseSignedTransaction(r.entry.raw);
  assert.equal(parsed.from, ME);
  assert.equal(parsed.tx.nonce, 4n);
  assert.equal(parsed.tx.chainId, 1n);
  assert.equal(parsed.tx.to, ALICE);
  assert.equal(parsed.tx.value, 10n ** 16n);
  assert.equal(parsed.tx.gasLimit, p.tx.gasLimit);
  assert.equal(parsed.tx.maxFeePerGas, p.tx.maxFeePerGas, 'exactly what was reviewed');
  assert.equal(r.entry.hash, parsed.hash);
  assert.equal(chain.st.calls.filter((m) => m === 'eth_chainId').length, 1, 'chain id checked right before signing');
  // Followed: pending, then mined.
  assert.equal((await followOnce(app, chain.rpc, r.entry, { ethId, kv })).state, 'pending');
  chain.mine(r.entry.hash);
  const done = await followOnce(app, chain.rpc, r.entry, { ethId, kv });
  assert.equal(done.state, 'confirmed');
  assert.equal(entryFee(done).wei, 21000n * 13n * GWEI);
  assert.equal(entryFee(done).final, true);
  await assert.rejects(signAndSend({ ...app, dbPass: null }, chain.rpc, p, { ethId, kv }), (e) => e.code === 'locked');
});

test('send: a network error leaves it signed; following sends the identical bytes again, never re-signed', async () => {
  const { app, kv, ethId } = await walletWithKey();
  const chain = fakeChain();
  const p = await prepareSend(chain.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 1n, balances: { eth: ETHER } });
  chain.st.down = 'eth_sendRawTransaction';
  const r = await signAndSend(app, chain.rpc, p, { ethId, kv });
  assert.equal(r.sent, false);
  assert.equal(r.entry.state, 'signed');
  assert.equal(r.error.code, 'network');
  chain.st.down = null;
  const again = await followOnce(app, chain.rpc, r.entry, { ethId, kv });
  assert.equal(again.state, 'pending');
  assert.deepEqual(chain.st.sends, [r.entry.raw], 'the saved bytes, once they could go');
  assert.equal((await loadOutbox(app, { ethId, kv })).length, 1);
});

test('send (D-3): bytes the server refuses stay open and checked; "never sent" only after 30 minutes of refusals', async () => {
  const { app, kv, ethId } = await walletWithKey();
  const chain = fakeChain();
  const p = await prepareSend(chain.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 1n, balances: { eth: ETHER } });
  chain.st.refuse = Object.assign(new Error('insufficient funds for gas * price + value'), { code: -32000 });
  let now = 1000;
  const r = await signAndSend(app, chain.rpc, p, { ethId, kv, now: () => now });
  assert.equal(r.sent, false);
  assert.equal(r.entry.state, 'signed', 'not "Nothing was spent": the server may have passed it on');
  assert.equal(r.entry.refusedAt, 1000);
  assert.match(r.entry.error, /insufficient funds/);
  assert.equal((await loadOutbox(app, { ethId, kv }))[0].refusedAt, 1000, 'kept with the entry');
  // Followed: its hash asked, its bytes offered again, still refused: still open.
  now += REFUSAL_WATCH_MS - 1;
  let e = await followOnce(app, chain.rpc, r.entry, { ethId, kv, now: () => now });
  assert.equal(e.state, 'signed');
  assert.equal(e.refusedAt, 1000, 'since the first refusal');
  assert.ok(chain.st.calls.includes('eth_getTransactionByHash'));
  assert.equal(chain.st.calls.filter((m) => m === 'eth_sendRawTransaction').length, 2, 'the same bytes, again');
  // Half an hour of refusals with the hash unknown and the nonce free: never sent.
  now += 1;
  e = await followOnce(app, chain.rpc, e, { ethId, kv, now: () => now });
  assert.equal(e.state, 'rejected');
  assert.equal((await followOnce(app, chain.rpc, e, { ethId, kv })).state, 'rejected', 'not followed any more');
});

test('send (D-3): a server that refused the bytes but had passed them on: the payment is followed to its receipt', async () => {
  const { app, kv, ethId } = await walletWithKey();
  const chain = fakeChain();
  const p = await prepareSend(chain.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 1n, balances: { eth: ETHER } });
  chain.st.refuse = Object.assign(new Error('transaction underpriced'), { code: -32000 });
  chain.st.relayOnRefuse = true;
  const r = await signAndSend(app, chain.rpc, p, { ethId, kv, now: () => 5 });
  assert.equal(r.entry.state, 'signed');
  // Another node mined it.
  chain.mine(r.entry.hash);
  const e = await followOnce(app, chain.rpc, r.entry, { ethId, kv, now: () => 5 + REFUSAL_WATCH_MS * 2 });
  assert.equal(e.state, 'confirmed', 'mined, whatever the server said when it was sent');
  assert.equal(e.refusedAt, null);
  // And a server that takes the bytes on a later try clears the doubt.
  const { app: app2, kv: kv2, ethId: id2 } = await walletWithKey();
  const c2 = fakeChain();
  const p2 = await prepareSend(c2.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 2n, balances: { eth: ETHER } });
  c2.st.refuse = Object.assign(new Error('txpool is full'), { code: -32000 });
  const r2 = await signAndSend(app2, c2.rpc, p2, { ethId: id2, kv: kv2 });
  c2.st.refuse = null;
  const e2 = await followOnce(app2, c2.rpc, r2.entry, { ethId: id2, kv: kv2 });
  assert.equal(e2.state, 'pending');
  assert.equal(e2.refusedAt, null);
});

test('follow: a used-up nonce alone is "unsure", never "replaced"; mined, or in a block, wins', () => {
  assert.equal(classify({ receipt: { status: 1 }, minedNonce: 9n, nonce: '0', known: true }), 'confirmed');
  assert.equal(classify({ receipt: { status: 0 }, minedNonce: 9n, nonce: '0', known: true }), 'failed');
  assert.equal(classify({ receipt: null, minedNonce: 1n, nonce: '0', known: false }), 'unsure');
  assert.equal(classify({ receipt: null, minedNonce: 8n, nonce: '7', known: false }), 'unsure', 'the audit\'s PoC: a mined payment seen through a lagging backend');
  assert.equal(classify({ receipt: null, minedNonce: 1n, nonce: '0', known: true, inBlock: true }), 'pending', 'mined, the receipt is on its way');
  assert.equal(classify({ receipt: null, minedNonce: 0n, nonce: '0', known: false }), 'unknown');
  assert.equal(classify({ receipt: null, minedNonce: 0n, nonce: '0', known: true }), 'pending');
});

// followOnce looks into a used-up nonce at most once a minute per transaction, and the test key
// signs the same bytes in every test: one clock for all of them, moved past that minute each time.
let clock = 10 ** 9;
const later = () => (clock += NONCE_LOOK_MS);

/** A wallet with one 1-wei payment sent and waiting on `chain`. */
async function sentOne(chain = fakeChain()) {
  const { app, kv, ethId } = await walletWithKey();
  const p = await prepareSend(chain.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 1n, balances: { eth: ETHER } });
  const r = await signAndSend(app, chain.rpc, p, { ethId, kv });
  assert.equal(r.entry.state, 'pending');
  return { app, kv, ethId, chain, entry: r.entry, p };
}

/** Another transaction from this wallet with `entry`'s nonce (what another device with the same words would send). */
async function sameNonce(entry, { chainId = 1n, to = F.BOB, words = JUNK } = {}) {
  const { sk } = await ethKeyFromMnemonic(words);
  if (chainId === 1n) return signTransaction({ chainId, nonce: BigInt(entry.nonce), to: toChecksumAddress(to), value: 5n, gasLimit: 21000n, maxFeePerGas: 40n * GWEI, maxPriorityFeePerGas: 2n * GWEI }, sk);
  // This wallet signs for Ethereum only: another chain's transaction is built here by hand.
  const { rlpEncode } = await import('../../src/lib/eth/rlp.js');
  const { signDigest, keccak256 } = await import('../../src/lib/eth/crypto.js');
  const { hexToBytes, concatBytes } = await import('../../src/lib/eth/hex.js');
  const fields = [chainId, BigInt(entry.nonce), 2n * GWEI, 40n * GWEI, 21000n, hexToBytes(to), 5n, new Uint8Array(0), []];
  const sig = signDigest(keccak256(concatBytes(Uint8Array.of(2), rlpEncode(fields))), sk);
  const raw = bytesToHex(concatBytes(Uint8Array.of(2), rlpEncode([...fields, sig.yParity, sig.r, sig.s])));
  return { raw, hash: transactionHash(raw) };
}

test('follow (D-3): one server saying the nonce is used up cannot turn a waiting payment into "replaced"', async () => {
  const { app, kv, ethId, chain, entry } = await sentOne();
  // The PoC: the server still holds the payment, waiting, but says the account's nonce moved on.
  chain.st.latest = 1n;
  let now = later();
  const first = now;
  const look = () => followOnce(app, chain.rpc, entry, { ethId, kv, now: () => now });
  let e = await look();
  assert.equal(e.state, 'pending', 'still open: it may yet be mined');
  assert.equal(e.unsureSince, first, 'the screens are told not to send it again yet');
  assert.deepEqual(chain.st.sends, [entry.raw, entry.raw], 'the same bytes offered again, never re-signed');
  assert.equal((await loadOutbox(app, { ethId, kv }))[0].unsureSince, first, 'kept with the entry');
  // A server that lies about every block too, and forgets the payment: still no evidence, still not replaced.
  chain.st.lieAll = true;
  chain.st.pool.delete(entry.hash);
  const counts = () => chain.st.calls.filter((m) => m === 'eth_getTransactionCount').length;
  now += 1000;
  const before = counts();
  e = await look();
  assert.equal(e.state, 'pending');
  assert.equal(counts() - before, 1, 'looked into a moment ago: only the nonce is asked, no search');
  for (let i = 0; i < 5; i++) {
    now += NONCE_LOOK_MS;
    e = await look();
    assert.equal(e.state, 'pending', `look ${i}: never replaced on the server's word`);
    assert.equal(e.unsureSince, first, 'since the first time');
  }
  clock = now;
  // The payment was in fact still out there: it is mined, and that is what counts.
  chain.st.lieAll = false;
  chain.st.latest = 0n;
  chain.st.pool.set(entry.hash, entry.raw);
  chain.mine(entry.hash);
  e = await look();
  assert.equal(e.state, 'confirmed');
  assert.equal(e.unsureSince, null, 'no longer in doubt');
});

test('follow (D-3): "replaced" only once the server shows the transaction that took the nonce, signed by this wallet, with a receipt', async () => {
  const { app, kv, ethId, chain, entry } = await sentOne();
  const other = await sameNonce(entry);
  chain.st.pool.delete(entry.hash);
  const block = chain.mineRaw(other.raw);
  const e = await followOnce(app, chain.rpc, entry, { ethId, kv, now: later });
  assert.equal(e.state, 'replaced');
  assert.equal(e.replacedBy, other.hash);
  assert.equal(e.replacedIn, block);
  assert.equal(e.unsureSince, null);
  assert.ok(chain.st.calls.includes('eth_getBlockByNumber'), 'found in the block where the count passed the nonce');
});

test('follow (D-3): made-up, altered, foreign-chain or unmined "replacements" are not evidence', async () => {
  const STRANGER = 'legal winner thank year wave sausage worth useful legal winner thank yellow';
  const cases = {
    'signed by another key, labelled as this wallet': async (entry) => ({ ...txJson((await sameNonce(entry, { words: STRANGER })).raw), from: ME.toLowerCase() }),
    'a real one of ours with its amount changed': async (entry) => ({ ...txJson((await sameNonce(entry)).raw), value: q(10n ** 18n) }),
    'ours, but signed for another chain': async (entry) => txJson((await sameNonce(entry, { chainId: 56n })).raw),
  };
  for (const [name, make] of Object.entries(cases)) {
    const { app, kv, ethId, chain, entry } = await sentOne();
    chain.st.pool.delete(entry.hash);
    const json = await make(entry);
    chain.mineRaw(null, { json: { ...json, blockHash: F.h(0xb065), blockNumber: q(chain.st.head + 1) } });
    const e = await followOnce(app, chain.rpc, entry, { ethId, kv, now: later });
    assert.equal(e.state, 'pending', name);
    assert.ok(e.unsureSince, name);
  }
  // Genuinely ours and in the block, but the server serves no receipt for it: not yet evidence.
  const { app, kv, ethId, chain, entry } = await sentOne();
  chain.st.pool.delete(entry.hash);
  chain.mineRaw((await sameNonce(entry)).raw, { receipt: false });
  assert.equal((await followOnce(app, chain.rpc, entry, { ethId, kv, now: later })).state, 'pending');
});

test('follow (D-3): our own payment found in the block (its receipt not served yet) is waiting, not replaced', async () => {
  const { app, kv, ethId, chain, entry } = await sentOne();
  // A server whose receipt lags its blocks: the count moved, the block holds our bytes, no receipt yet.
  const json = txJson(entry.raw, chain.st.head + 1);
  chain.st.pool.delete(entry.hash);
  chain.mineRaw(entry.raw, { json, receipt: false });
  chain.st.byHash.delete(entry.hash); // and it says it does not know the hash
  const e = await followOnce(app, chain.rpc, entry, { ethId, kv, now: later });
  assert.equal(e.state, 'pending');
  assert.ok(!e.unsureSince);
});

test('follow (D-3): a hash the wallet already knows proves it where the server keeps no old state', async () => {
  const { app, kv, ethId, chain, entry } = await sentOne();
  const other = await sameNonce(entry);
  chain.st.pool.delete(entry.hash);
  chain.mineRaw(other.raw);
  chain.st.head += 500; // long ago
  chain.st.noOldState = true;
  assert.equal(await findNonceTaker(chain.rpc, entry).catch((err) => err.code), -32000, 'the block search needs old state');
  assert.equal((await followOnce(app, chain.rpc, entry, { ethId, kv, now: later })).state, 'pending');
  const e = await followOnce(app, chain.rpc, entry, { ethId, kv, candidates: [F.h(0xdead), other.hash], now: later });
  assert.equal(e.state, 'replaced');
  assert.equal(e.replacedBy, other.hash);
  // The wallet offers its outbox's same-nonce entries and the history index's as candidates.
  const w = await ethWallet(app, { kv });
  w.state.history = { txs: [{ hash: other.hash, from: ME.toLowerCase(), nonce: Number(entry.nonce) }, { hash: F.h(7), from: ME.toLowerCase(), nonce: 99 }], transfers: [], error: null, at: 1 };
  assert.deepEqual(w.nonceTwins(entry), [other.hash]);
  w.state.history = { txs: [], transfers: [], error: null, at: null };
  forgetEthWallet();
});

// ---------------------------------------------------------------- the wallet object

test('wallet: the address comes from the sealed key; prefs default to Stack Wallet and history on; removal forgets everything', async () => {
  const { app, kv, ethId } = await walletWithKey();
  assert.deepEqual(ethPrefs(app).rpcId, 'stackwallet');
  assert.equal(ethPrefs(app).history, true);
  assert.equal(ethPrefs({ prefs: { ethRpc: 'publicnode', ethHistory: false } }).rpcId, 'publicnode');
  assert.equal(ethPrefs({ prefs: { ethRpc: 'evil.example' } }).rpcId, 'stackwallet', 'only listed servers');
  assert.equal(ethPrefs({ prefs: { ethHistory: false } }).history, false);
  const w = await ethWallet(app, { kv });
  assert.equal(w.state.address, ME);
  assert.equal(w.ethId, ethId);
  assert.equal(await ethWallet(app, { kv }), w, 'one object per unlocked wallet');
  await addToOutbox(app, entry(), { ethId, kv });
  assert.equal(await hasEthWallet(kv), true);
  await removeEthWallet(kv);
  assert.equal(await hasEthWallet(kv), false);
  assert.equal(kv.m.has(ETH_OUTBOX_KEY), false);
  assert.equal(kv.m.has(ETH_RECORD_KEY), false);
  assert.equal(await ethWallet(app, { kv }), null);
  await assert.rejects(ethWallet({ ...app, dbPass: null }, { kv }), (e) => e.code === 'locked');
  forgetEthWallet();
});

// ---------------------------------------------------------------- a transaction in doubt gates the next (BM-1)

test('BM-1: while a payment is "Not sent yet" or "Not sure yet", nothing new is signed from this wallet; settled, the next one goes', async () => {
  const D = await import('../../src/lib/eth/doubt.js');
  const { app, kv, ethId } = await walletWithKey();
  const chain = fakeChain({ nonce: 7n });
  const p1 = await prepareSend(chain.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 1n, balances: { eth: ETHER } });
  // The server refuses the bytes (it may have passed them on first): "Not sent yet", nonce 7.
  chain.st.refuse = Object.assign(new Error('insufficient funds for gas * price + value'), { code: -32000 });
  const first = await signAndSend(app, chain.rpc, p1, { ethId, kv, now: () => 1000 });
  assert.equal(first.entry.state, 'signed');
  assert.equal(first.entry.refusedAt, 1000);
  chain.st.refuse = null;
  const p2 = await prepareSend(chain.rpc, { from: ME, asset: ETH, recipient: F.BOB, amount: 2n, balances: { eth: ETHER } });
  const asked = chain.st.calls.length;
  const refused = (title) => (e) => e.code === 'in_doubt' && e.entry.hash === first.entry.hash && e.message.includes(`is "${title}"`) && e.message.includes(D.DOUBT_WAY_OUT);
  await assert.rejects(signAndSend(app, chain.rpc, p2, { ethId, kv }), refused('Not sent yet'));
  assert.equal(chain.st.calls.length, asked, 'nothing asked of the server: no chain id, no nonce, no broadcast');
  assert.equal((await loadOutbox(app, { ethId, kv })).length, 1, 'no second transaction signed');
  // The server took it, then said its nonce is used up without showing by what: "Not sure yet".
  await updateOutbox(app, first.entry.hash, { state: 'pending', refusedAt: null, unsureSince: 2000 }, { ethId, kv });
  await assert.rejects(signAndSend(app, chain.rpc, p2, { ethId, kv }), refused('Not sure yet'));
  assert.equal(chain.st.calls.length, asked);
  // Settled (mined, replaced with evidence, or never sent after the watch): the next payment goes.
  for (const settled of ['confirmed', 'rejected']) {
    await updateOutbox(app, first.entry.hash, { state: settled, unsureSince: null, refusedAt: settled === 'rejected' ? 1000 : null }, { ethId, kv });
    assert.equal(D.entryInDoubt(await loadOutbox(app, { ethId, kv })), null, `${settled} is not in doubt`);
  }
  const r = await signAndSend(app, chain.rpc, p2, { ethId, kv });
  assert.equal(r.sent, true);
  assert.equal(parseSignedTransaction(r.entry.raw).tx.nonce, 7n);
});

test('BM-1: doubt in words: which transaction, "Not sure yet" / "Not sent yet", and the way out', async () => {
  const D = await import('../../src/lib/eth/doubt.js');
  const pay = entry({ hash: F.h(1), state: 'signed', refusedAt: 5, createdAt: 2 });
  const swap = entry({ hash: F.h(2), state: 'pending', unsureSince: 9, kind: 'swap', createdAt: 3 });
  const allow = entry({ hash: F.h(3), state: 'pending', unsureSince: 9, kind: 'approve', asset: 'WBEAM', token: WBEAM.address, amount: '1250000000', createdAt: 4 });
  assert.equal(D.doubtOf(pay), 'refused');
  assert.equal(D.doubtOf(swap), 'unsure');
  assert.equal(D.doubtOf(entry({ state: 'pending' })), null);
  assert.equal(D.doubtOf(entry({ state: 'rejected', refusedAt: 5 })), null, 'closed: settled, not in doubt');
  assert.equal(D.doubtOf(entry({ state: 'replaced', unsureSince: 5 })), null);
  assert.equal(D.entryInDoubt([entry({ hash: F.h(9), state: 'confirmed' }), allow, swap, pay]), allow, 'the newest in doubt');
  assert.equal(D.entryInDoubt([]), null);
  assert.equal(D.entryInDoubt(undefined), null);
  assert.equal(D.doubtName(pay), `your payment of 0.01 ETH to ${ALICE.slice(0, 6)}…${ALICE.slice(-4)}`);
  assert.equal(D.doubtName(swap), 'your swap of 0.01 ETH');
  assert.equal(D.doubtName(allow), 'your WBEAM permission for Uniswap');
  assert.deepEqual([pay, swap, allow].map(D.doubtNoun), ['payment', 'swap', 'permission']);
  const m = D.doubtMessage(pay);
  assert.ok(m.startsWith(`Your payment of 0.01 ETH to ${ALICE.slice(0, 6)}`), m);
  assert.match(m, /is "Not sent yet"\. It may still go through, so nothing new is sent from this Ethereum wallet until it is settled, or both could go through\. Wait/);
  assert.deepEqual(D.doubtNameParts(pay), { lead: 'your payment of 0.01 ETH to', address: `${ALICE.slice(0, 6)}…${ALICE.slice(-4)}` });
  assert.deepEqual(D.doubtNameParts(swap), { lead: 'your swap of 0.01 ETH', address: null });
  assert.ok(m.endsWith('Wait until Beam PWA knows what happened to it, or choose another Ethereum server in Settings: it is checked there.'));
  assert.ok(!/nothing was sent/i.test(m), 'never "nothing was sent" about the doubtful one');
});

// Re-audit RE2-2: a "Not sure yet" that no listed server can settle (no state at past blocks, History
// off) never cleared, and the notice named only exits that do not work then (wait; another
// server). Now the notice names History from Stack Wallet when it is off, and once the payment has
// been in doubt for a day with every look since failing the same way, it can be forgotten: that
// entry only, after a plain warning, and sending opens up again.
const HOUR = 3600000;
/** A public pool whose count says the nonce moved on, that knows neither the hash nor any old state, and refuses the bytes. */
function stuckServer(EthRpcError, { count = 1n, refuse = 'nonce too low' } = {}) {
  return {
    async getTransactionCount(addr, tag) {
      if (tag === 'latest' || tag === 'pending') return count;
      throw new EthRpcError(-32000, 'missing trie node: state not available for block');
    },
    async getTransactionReceipt() {
      return null;
    },
    async getTransactionByHash() {
      return null;
    },
    async blockNumber() {
      return 23000000;
    },
    async getBlockByNumber() {
      return null;
    },
    async sendRawTransaction() {
      throw new EthRpcError(-32000, refuse);
    },
  };
}

test('RE2-2: "Not sure yet" that no server can settle: after a day of failed looks it can be forgotten, that payment only', async () => {
  const D = await import('../../src/lib/eth/doubt.js');
  const { EthRpcError } = await import('../../src/lib/eth/rpc.js');
  const { app, kv, ethId } = await walletWithKey();
  const rpc = stuckServer(EthRpcError);
  const doubtful = entry({ hash: F.h(0x4101), from: ME, nonce: '0', state: 'pending', sentAt: 1000, createdAt: 2000 });
  const older = entry({ hash: F.h(0x4102), from: ME, nonce: '5', state: 'confirmed', createdAt: 1500, receipt: { blockNumber: 9, status: 1, gasUsed: '21000', effectiveGasPrice: '1' } });
  await addToOutbox(app, older, { ethId, kv });
  await addToOutbox(app, doubtful, { ethId, kv });
  let t = 10000;
  const now = () => t;
  const stored = async () => (await loadOutbox(app, { ethId, kv })).find((e) => e.hash === doubtful.hash);
  const look = async () => followOnce(app, rpc, await stored(), { ethId, kv, candidates: [], now });
  let e = await look();
  assert.equal(D.doubtOf(e), 'unsure');
  assert.equal(D.mayForget(e, t), false, 'just in doubt');
  await assert.rejects(D.forgetInDoubt(app, doubtful.hash, { ethId, kv, now }), (x) => x.code === 'not_yet');
  t += 23 * HOUR;
  e = await look();
  assert.equal(D.doubtOf(e), 'unsure');
  assert.equal(D.mayForget(e, t), false, 'not a day yet');
  t += 2 * HOUR;
  assert.equal(D.mayForget(await stored(), t), false, 'a day has passed, but no look has failed since then');
  e = await look();
  assert.equal(D.mayForget(e, t), true, 'in doubt for a day, and the look a day on failed the same way');
  await assert.rejects(D.assertNothingInDoubt(app, { ethId, kv }), (x) => x.code === 'in_doubt');
  await D.forgetInDoubt(app, doubtful.hash, { ethId, kv, now });
  assert.deepEqual((await loadOutbox(app, { ethId, kv })).map((x) => x.hash), [older.hash], 'only that entry is gone');
  await D.assertNothingInDoubt(app, { ethId, kv });
  await assert.rejects(D.forgetInDoubt(app, older.hash, { ethId, kv, now }), (x) => x.code === 'not_in_doubt', 'a settled one is never forgotten');
  assert.equal(D.FORGET_WARNING, 'It may still go through. If it does and you send again, both go through.');
});

test('RE2-2: a doubt that cleared and came back starts its day again; "Not sent yet" a server keeps contradicting can be forgotten too', async () => {
  const D = await import('../../src/lib/eth/doubt.js');
  const { EthRpcError } = await import('../../src/lib/eth/rpc.js');
  const { app, kv, ethId } = await walletWithKey();
  let t = 50000;
  const now = () => t;
  // Unsure, then the server sees it again (pending: the doubt clears), then unsure again.
  const a = entry({ hash: F.h(0x4201), from: ME, nonce: '0', state: 'pending', sentAt: 1, createdAt: 2 });
  await addToOutbox(app, a, { ethId, kv });
  const stored = async (hash) => (await loadOutbox(app, { ethId, kv })).find((e) => e.hash === hash);
  await followOnce(app, stuckServer(EthRpcError), await stored(a.hash), { ethId, kv, now });
  t += 30 * HOUR;
  const seen = { ...stuckServer(EthRpcError, { count: 0n }), getTransactionByHash: async () => ({ hash: a.hash }) };
  assert.equal(D.doubtOf(await followOnce(app, seen, await stored(a.hash), { ethId, kv, now })), null, 'the server sees it again');
  t += HOUR;
  let e = await followOnce(app, stuckServer(EthRpcError), await stored(a.hash), { ethId, kv, now });
  assert.equal(D.doubtOf(e), 'unsure');
  assert.equal(D.mayForget(e, t), false, 'its day starts again');
  await updateOutbox(app, a.hash, { state: 'confirmed', unsureSince: null }, { ethId, kv });
  // Refused: the count says the nonce is free, yet the broadcast says "nonce too low": never decided.
  const b = entry({ hash: F.h(0x4202), from: ME, nonce: '0', state: 'signed', refusedAt: t, createdAt: 3 });
  await addToOutbox(app, b, { ethId, kv });
  const contradicts = stuckServer(EthRpcError, { count: 0n });
  e = await followOnce(app, contradicts, await stored(b.hash), { ethId, kv, now });
  assert.equal(D.doubtOf(e), 'refused');
  t += 25 * HOUR;
  e = await followOnce(app, contradicts, await stored(b.hash), { ethId, kv, now });
  assert.equal(D.doubtOf(e), 'refused');
  assert.equal(D.mayForget(e, t), true);
});

test('RE3-2: Forget needs a recent failing look, never marks left from days ago; the next look offers it again', async () => {
  const D = await import('../../src/lib/eth/doubt.js');
  const { EthRpcError } = await import('../../src/lib/eth/rpc.js');
  const { app, kv, ethId } = await walletWithKey();
  assert.equal(D.FORGET_LOOK_FRESH_MS, 5 * 60 * 1000);
  let t = 1_000_000;
  const now = () => t;
  // In doubt since t, and a failing look 30 hours later: it qualified then.
  const old = entry({ hash: F.h(0x4401), from: ME, nonce: '0', state: 'pending', sentAt: t, createdAt: t, unsureSince: t, doubtLookAt: t + 30 * HOUR });
  await addToOutbox(app, old, { ethId, kv });
  const stored = async () => (await loadOutbox(app, { ethId, kv })).find((e) => e.hash === old.hash);
  t += 30 * HOUR + 4 * 60000;
  assert.equal(D.mayForget(await stored(), t), true, 'a look 4 minutes ago');
  // The device was off for three days: those marks no longer offer it.
  t += 3 * 24 * HOUR;
  assert.equal(D.mayForget(await stored(), t), false, 'the last look is three days old');
  await assert.rejects(D.forgetInDoubt(app, old.hash, { ethId, kv, now }), (x) => x.code === 'not_lately' && /looks for it once more first/.test(x.message));
  assert.ok(await stored(), 'kept');
  // The screen looks again (still in doubt): offered again, and forgotten.
  const e = await followOnce(app, stuckServer(EthRpcError), await stored(), { ethId, kv, candidates: [], now });
  assert.equal(D.doubtOf(e), 'unsure');
  assert.equal(e.doubtLookAt, t);
  assert.equal(D.mayForget(e, t), true);
  await D.forgetInDoubt(app, old.hash, { ethId, kv, now });
  assert.equal(await stored(), undefined);
});

test('RE3-2: "Not sure yet" that a server now neither confirms nor clears (nonce free, payment unknown, bytes refused): each look counts', async () => {
  const D = await import('../../src/lib/eth/doubt.js');
  const { EthRpcError } = await import('../../src/lib/eth/rpc.js');
  const { app, kv, ethId } = await walletWithKey();
  let t = 5_000_000;
  const now = () => t;
  // "Not sure yet" since t, its last look an hour later; then another server, which says nonce 0 is
  // free, has never seen the payment and refuses its bytes for a reason that is not the nonce.
  const e0 = entry({ hash: F.h(0x4501), from: ME, nonce: '0', state: 'pending', sentAt: t, createdAt: t, unsureSince: t, doubtLookAt: t + HOUR });
  await addToOutbox(app, e0, { ethId, kv });
  const other = stuckServer(EthRpcError, { count: 0n, refuse: 'insufficient funds for gas * price + value' });
  t += 25 * HOUR;
  const e = await followOnce(app, other, (await loadOutbox(app, { ethId, kv })).find((x) => x.hash === e0.hash), { ethId, kv, candidates: [], now });
  assert.equal(D.doubtOf(e), 'unsure', 'still in doubt');
  assert.equal(e.doubtLookAt, t, 'this look is written down');
  assert.equal(D.mayForget(e, t), true, 'a day on, it can be forgotten (it could never be before)');
});

test('RE2-2: the way out names History from Stack Wallet when it is off', async () => {
  const D = await import('../../src/lib/eth/doubt.js');
  const pay = entry({ hash: F.h(0x4301), state: 'pending', unsureSince: 5 });
  const on = D.doubtMessage(pay);
  assert.ok(on.endsWith(D.DOUBT_WAY_OUT), 'History on (the default): as before');
  assert.ok(!/History/.test(on));
  const off = D.doubtMessage(pay, { history: false });
  assert.ok(off.endsWith(`${D.DOUBT_WAY_OUT} ${D.HISTORY_WAY_OUT}`), off);
  assert.equal(D.HISTORY_WAY_OUT, 'Or turn on History from Stack Wallet in Settings: it then finds what took its place, if anything did.');
  const { app, kv, ethId } = await walletWithKey();
  await addToOutbox(app, pay, { ethId, kv });
  await assert.rejects(D.assertNothingInDoubt({ ...app, prefs: { ethHistory: false } }, { ethId, kv }), (x) => x.code === 'in_doubt' && x.message.endsWith(D.HISTORY_WAY_OUT));
  await assert.rejects(D.assertNothingInDoubt(app, { ethId, kv }), (x) => x.code === 'in_doubt' && !/History/.test(x.message));
});

test('BM-1: a Uniswap swap or permission is refused while a transaction is in doubt, before the key is opened', async () => {
  const D = await import('../../src/lib/eth/doubt.js');
  const { signAndBroadcast } = await import('../../src/lib/eth/uniswap_app.js');
  const { app, kv, ethId } = await walletWithKey();
  const chain = fakeChain({ nonce: 3n });
  const w = { rpc: chain.rpc, ethId, kv, reloadOutbox: async () => [] };
  const tx = { to: F.BOB, data: '0x', value: 1n, gasLimit: 21000n, maxFeePerGas: 30n * GWEI, maxPriorityFeePerGas: GWEI };
  const doubtful = entry({ hash: F.h(77), from: ME, nonce: '3', state: 'pending', unsureSince: 10, createdAt: 5 });
  await addToOutbox(app, doubtful, { ethId, kv });
  const asked = chain.st.calls.length;
  await assert.rejects(signAndBroadcast(app, w, tx, { kind: 'swap', asset: ETH, amount: 1n }), (e) => e instanceof D.EthInDoubtError && e.entry.hash === doubtful.hash);
  await assert.rejects(signAndBroadcast({ ...app, dbPass: null }, w, tx, { kind: 'swap', asset: ETH, amount: 1n }), (e) => e.code === 'locked', 'locked: refused as before');
  assert.equal(chain.st.calls.length, asked, 'no nonce asked, nothing signed or sent');
  assert.equal((await loadOutbox(app, { ethId, kv })).length, 1);
  await updateOutbox(app, doubtful.hash, { state: 'confirmed', unsureSince: null }, { ethId, kv });
  const r = await signAndBroadcast(app, w, tx, { kind: 'swap', asset: ETH, amount: 1n });
  assert.equal(r.sent, true);
});

// ---------------------------------------------------------------- "Not sent" is not final for ever (BM-2)

test('BM-2: a payment the index shows mined is mined, whatever "rejected" or "replaced" said; the activity row and the entry follow it', async () => {
  const H = await import('../../src/lib/eth/history.js');
  const me = ME.toLowerCase();
  const hash = `0x${'ab'.repeat(32)}`;
  const rejected = entry({ hash, nonce: '7', state: 'rejected', refusedAt: 1, error: 'insufficient funds' });
  const minedTx = { hash, from: me, to: F.ALICE, value: 10n ** 16n, blockNumber: 123, timestamp: 1700000000, failed: false, fee: 21000n * GWEI, nonce: 7, contractCall: false };
  // The audit's PoC: index row mined in block 123, the screen said "Not sent ... Nothing was spent".
  let shown = H.mergeActivity({ address: ME, outbox: [rejected], txs: [minedTx], transfers: [] }).find((i) => i.hash === hash);
  assert.equal(shown.state, 'confirmed');
  assert.equal(shown.blockNumber, 123);
  assert.equal(shown.fee, 21000n * GWEI, "the index's fee");
  assert.equal(shown.local, true);
  // Mined but failed: the fee was spent, the amount stayed.
  shown = H.mergeActivity({ address: ME, outbox: [rejected], txs: [{ ...minedTx, failed: true }], transfers: [] }).find((i) => i.hash === hash);
  assert.equal(shown.state, 'failed');
  // "Replaced" was shown with evidence (the transaction that took its nonce, signed by this wallet,
  // with a receipt): an index row does not outrank it (re-audit RE2-5). It stays "Replaced", with
  // what the index says beside it, until the chosen server serves this hash's own receipt.
  const replaced = entry({ hash, state: 'replaced', replacedBy: F.h(9), replacedIn: 120, kind: 'swap' });
  const xfer = { hash, blockNumber: 124, timestamp: 1700000001, logIndex: 0, from: F.ME, to: F.BOB, amount: 5n, token: WBEAM };
  shown = H.mergeActivity({ address: ME, outbox: [replaced], txs: [], transfers: [xfer] }).find((i) => i.hash === hash);
  assert.equal(shown.state, 'replaced');
  assert.equal(shown.blockNumber, null);
  assert.equal(H.mergeActivity({ address: ME, outbox: [replaced], txs: [{ ...minedTx, fee: 21000n * GWEI }], transfers: [] }).find((i) => i.hash === hash).fee, null, "no fee from the index's word");
  assert.deepEqual(shown.indexSays, { state: 'confirmed', blockNumber: 124 });
  assert.deepEqual(H.minedInIndex({ outbox: [replaced], txs: [], transfers: [xfer] }), [], 'not written down from the index');
  assert.equal(H.mergeActivity({ address: ME, outbox: [rejected], txs: [minedTx], transfers: [] }).find((i) => i.hash === hash).indexSays, null);
  // Not in a block (the index's own pending row) or another hash: the entry's word stands.
  shown = H.mergeActivity({ address: ME, outbox: [rejected], txs: [{ ...minedTx, blockNumber: null }, { ...minedTx, hash: F.h(5) }], transfers: [] }).find((i) => i.hash === hash);
  assert.equal(shown.state, 'rejected');
  assert.deepEqual(H.minedInIndex({ outbox: [rejected, entry({ hash: F.h(6), state: 'confirmed' })], txs: [minedTx, { ...minedTx, hash: F.h(6) }], transfers: [] }), [{ hash, state: 'confirmed', blockNumber: 123 }]);

  // The wallet writes it down: the entry becomes confirmed (and stops being "Not sent").
  const { app, kv, ethId } = await walletWithKey();
  const w = await ethWallet(app, { kv });
  await addToOutbox(app, { ...rejected, from: ME }, { ethId, kv });
  await w.reloadOutbox();
  w.state.history = { txs: [minedTx], transfers: [], error: null, at: 1 };
  assert.equal(await w.settleFromIndex(), true);
  const e = (await loadOutbox(app, { ethId, kv }))[0];
  assert.equal(e.state, 'confirmed');
  assert.equal(e.receipt.blockNumber, 123);
  assert.equal(e.receipt.status, 1);
  assert.equal(e.refusedAt, null);
  assert.equal(w.state.outbox[0].state, 'confirmed');
  assert.equal(await w.settleFromIndex(), false, 'once');
  w.state.history = { txs: [], transfers: [], error: null, at: null };
  forgetEthWallet();
});

test('BM-2: "rejected" entries are looked at again (their receipt, once per look): a payment mined after all becomes confirmed', async () => {
  const { app, kv, ethId } = await walletWithKey();
  const chain = fakeChain();
  const p = await prepareSend(chain.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 1n, balances: { eth: ETHER } });
  chain.st.refuse = Object.assign(new Error('insufficient funds for gas * price + value'), { code: -32000 });
  chain.st.relayOnRefuse = true; // it passed them on before refusing
  let now = 1000;
  const r = await signAndSend(app, chain.rpc, p, { ethId, kv, now: () => now });
  now += REFUSAL_WATCH_MS;
  const gone = await followOnce(app, chain.rpc, r.entry, { ethId, kv, now: () => now });
  assert.equal(gone.state, 'rejected');
  const w = await ethWallet(app, { kv });
  w._rpc = chain.rpc;
  await w.reloadOutbox();
  // Nothing mined yet: one receipt asked, nothing changes.
  const before = chain.st.calls.length;
  assert.equal(await w.recheckRejected(), false);
  assert.deepEqual(chain.st.calls.slice(before), ['eth_getTransactionReceipt']);
  // Another node mined it after all.
  chain.mine(r.entry.hash);
  assert.equal(await w.recheckRejected(), true);
  const e = w.state.outbox.find((x) => x.hash === r.entry.hash);
  assert.equal(e.state, 'confirmed');
  assert.equal(e.receipt.gasUsed, '21000');
  assert.equal(e.refusedAt, null);
  assert.equal(entryFee(e).final, true);
  forgetEthWallet();
});

test('RE2-5: a verified "Replaced" the index contradicts flips only once the chosen server serves this hash\'s own receipt', async () => {
  const H = await import('../../src/lib/eth/history.js');
  const { app, kv, ethId } = await walletWithKey();
  const chain = fakeChain();
  const hash = F.h(0x5501);
  const replaced = entry({ hash, from: ME, nonce: '4', state: 'replaced', replacedBy: F.h(0x5502), replacedIn: 120, createdAt: 10 });
  await addToOutbox(app, replaced, { ethId, kv });
  const w = await ethWallet(app, { kv });
  w._rpc = chain.rpc;
  await w.reloadOutbox();
  const indexRow = { hash, from: ME.toLowerCase(), to: F.ALICE, value: 10n ** 16n, blockNumber: 130, timestamp: 1700000000, failed: false, fee: 21000n * GWEI, nonce: 4, contractCall: false };
  w.state.history = { txs: [indexRow], transfers: [], error: null, at: 1 };
  // The index alone writes nothing down: the evidence stays.
  assert.equal(await w.settleFromIndex(), false);
  let e = (await loadOutbox(app, { ethId, kv }))[0];
  assert.equal(e.state, 'replaced');
  assert.equal(e.replacedBy, F.h(0x5502));
  assert.deepEqual(w.indexSays(hash), { state: 'confirmed', blockNumber: 130 });
  // Each look asks the chosen server for this hash's receipt: none, so nothing changes.
  const before = chain.st.calls.length;
  assert.equal(await w.recheckRejected(), false);
  assert.deepEqual(chain.st.calls.slice(before), ['eth_getTransactionReceipt']);
  assert.equal((await loadOutbox(app, { ethId, kv }))[0].state, 'replaced');
  // A "Replaced" the index does not contradict is not asked about at all.
  w.state.history = { txs: [], transfers: [], error: null, at: 1 };
  const quiet = chain.st.calls.length;
  assert.equal(await w.recheckRejected(), false);
  assert.equal(chain.st.calls.length, quiet);
  // The server serves its receipt: then, and only then, it is mined.
  w.state.history = { txs: [indexRow], transfers: [], error: null, at: 1 };
  chain.st.mined.set(hash, { transactionHash: hash, status: '0x1', blockNumber: '0x82', blockHash: F.h(0xb082), from: ME.toLowerCase(), to: F.ALICE, gasUsed: '0x5208', effectiveGasPrice: '0x1', logs: [] });
  assert.equal(await w.recheckRejected(), true);
  e = (await loadOutbox(app, { ethId, kv }))[0];
  assert.equal(e.state, 'confirmed');
  assert.equal(e.receipt.blockNumber, 130);
  assert.equal(e.replacedBy, null);
  assert.equal(e.replacedIn, null);
  assert.equal(H.mergeActivity({ address: ME, outbox: [e], txs: [indexRow], transfers: [] }).find((i) => i.hash === hash).state, 'confirmed');
  w.state.history = { txs: [], transfers: [], error: null, at: null };
  forgetEthWallet();
});

test('BM-2: "Not sent" is said as the server\'s word, with Etherscan one tap away, never as certain', async () => {
  const { NOT_SENT_NOTE } = await import('../../src/screens/eth_ui.js');
  assert.match(NOT_SENT_NOTE, /^Your Ethereum server refused it for half an hour/);
  assert.match(NOT_SENT_NOTE, /most likely it never left/);
  assert.match(NOT_SENT_NOTE, /That is the server's word, not Ethereum's\./);
  assert.match(NOT_SENT_NOTE, /looks for it again each time you open your Ethereum wallet/);
  assert.ok(!/so it never left/.test(NOT_SENT_NOTE));
});

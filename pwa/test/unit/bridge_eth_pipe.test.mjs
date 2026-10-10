// The bridge's Ethereum side (lib/bridge/eth_pipe.js), offline: the bytes
// against values computed outside this code (the real lock of msgId 222 and
// Foundry's cast), the receipt reader against that lock's real receipt (the
// desktop's fixture, read from its own path: one fixture, two apps) changed one
// way at a time, and the service's own judgement over a fake JSON-RPC server -
// what it refuses, how long it trusts a freeze check, which steps a lock takes,
// what it lets the key sign. The cases are the desktop's eth_pipe_calls_test.dart
// and eth_pipe_service_test.dart.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { REPO_ROOT } from '../../tools/shader_check.mjs';
import { EthRpc, MULTICALL3 } from '../../src/lib/eth/rpc.js';
import { abiEncode, abiDecode, encodeCall, selectorHex, eventTopic } from '../../src/lib/eth/abi.js';
import { bytesToHex, hexToBytes } from '../../src/lib/eth/hex.js';
import { ethKeyFromMnemonic } from '../../src/lib/eth/crypto.js';
import { parseSignedTransaction } from '../../src/lib/eth/tx.js';
import { ROUTES, routeById, NEW_LOCAL_MESSAGE_TOPIC } from '../../src/lib/bridge/routes.js';
import { BridgeError } from '../../src/lib/bridge/beam_pipe.js';
import * as P from '../../src/lib/bridge/eth_pipe.js';

const { EthPipe, sendFundsCall, erc20ApproveCall, processedKey, decodePipeMessage, decodeLockReceipt, checkLockAmounts, checkBridgeTx, isBeamReceiverKey } = P;

const FIXTURE = join(REPO_ROOT, 'test', 'beam', 'bridge', 'eth', 'fixtures', 'receipt_0x8596_msg222.json');
const refReceipt = () => JSON.parse(readFileSync(FIXTURE, 'utf8'));
const refHash = '0x8596783918bb46a873b872405b102826f8619c659a54599ec5fdb8591c430684';
const refKey = hexToBytes('83324744834f22c9f113abed7abd2e9f69f339decec2e24aae2789dbd2fb307b01');
const refOwner = '0xf1e43ede41881fdfb7868ab506236dbd6ec63329';
const refValue = 10500000000n; // 105 WBEAM
const refFee = 2000000n; // 0.02 WBEAM
const JUNK = 'test test test test test test test test test test test junk';

const beam = routeById('beam');
const eth = routeById('eth');
const wbtc = routeById('wbtc');
const usdt = routeById('usdt');
const dai = routeById('dai');
const PERMIT2 = '0x000000000022d473030f116ddee9f6b43ac78ba3';

const word = (v) => abiEncode('uint256', [v]);
const code = (c) => (e) => e instanceof BridgeError && e.code === c;

// ---------------------------------------------------------------- bytes

test('calldata: sendFunds is the real lock of msgId 222, byte for byte; approve is exact', () => {
  // eth_getTransactionByHash(0x8596…0684).input, and cast calldata "sendFunds(uint256,uint256,bytes)" 10500000000 2000000 0x8332…01
  const input =
    '0x4d5dd2bc' +
    '0000000000000000000000000000000000000000000000000000000271d94900' +
    '00000000000000000000000000000000000000000000000000000000001e8480' +
    '0000000000000000000000000000000000000000000000000000000000000060' +
    '0000000000000000000000000000000000000000000000000000000000000021' +
    '83324744834f22c9f113abed7abd2e9f69f339decec2e24aae2789dbd2fb307b' +
    '0100000000000000000000000000000000000000000000000000000000000000';
  assert.equal(bytesToHex(sendFundsCall(refValue, refFee, refKey)), input);
  assert.equal(selectorHex('sendFunds(uint256,uint256,bytes)'), P.SEND_FUNDS_SELECTOR);
  // cast calldata "approve(address,uint256)" <USDT pipe> 100000000
  assert.equal(
    bytesToHex(erc20ApproveCall(usdt.ethPipe, 100000000n)),
    '0x095ea7b3' + '0000000000000000000000007c3fe09e86b0d8661d261a49bfa385536b7077f9' + '0000000000000000000000000000000000000000000000000000000005f5e100',
  );
  // cast sig
  assert.equal(selectorHex('isBlackListed(address)'), '0xe47d6060');
  assert.equal(selectorHex('basisPointsRate()'), '0xdd644f72');
  assert.equal(selectorHex('paused()'), '0x5c975abb');
  assert.equal(selectorHex('processRemoteMessage(uint64,uint256,uint256,address)'), '0x6efe7df5');
  assert.equal(eventTopic('NewLocalMessage(uint64,uint256,uint256,bytes)'), NEW_LOCAL_MESSAGE_TOPIC);
  assert.equal(eventTopic('Transfer(address,address,uint256)'), P.ERC20_TRANSFER_TOPIC);
});

test('paid flag: storage keys are what `cast index uint64 <id> <slot>` gives; each route reads its own slot', () => {
  // Computed once with Foundry cast 1.x on 2026-10-09 (the desktop's vectors).
  const cast = [
    [107, 1, '0xd70e245266dfd722d237312ada32b3921705992efb298b14480ba0acaaa0765a'],
    [108, 1, '0xd80c728dcb954e7539257f5b9090fa0c83e482d978be864c61ec2b155c05c252'],
    [108, 2, '0x5c02fad6158ba4ff0547bf3f852d51853ec7aacd92af6352c7a69490ade9671a'],
    [109, 2, '0xda4fbfd2174b26f2972ec2761ecc2e7a7d1eb0d5cc01aa04b334b35ee3251cc2'],
    [639, 2, '0xabf0a2a556cb3ca04d8ba0f52f0693e838ddbb50ab2a3ad1267171e912eee456'],
    [640, 2, '0x4b731f6157a6421eb979b42466aa68fb410b9338c286875652dec93423cb2e04'],
    [1, 1, '0xcc69885fda6bcc1a4ace058b4a62bf5e179ea78fd58a1ccd71c22cc9b688792f'],
    [0, 2, '0xac33ff75c19e70fe83507db0d683fd3465c996598dc972688b7ace676c89077b'],
    [222, 2, '0x66388a99db3d9747e46ce2fca9ca0912a710973e25f7899306b55ded62dc2dee'],
  ];
  for (const [id, slot, key] of cast) assert.equal(processedKey(id, slot), key, `id ${id} slot ${slot}`);
  assert.equal(processedKey(222n, 2), processedKey(222, 2));
  assert.throws(() => processedKey(-1, 2), RangeError);
  assert.throws(() => processedKey(1n << 64n, 2), RangeError);
  assert.throws(() => processedKey(1.5, 2), RangeError);
  for (const r of ROUTES) assert.equal(r.processedSlot, r.isNativeEth ? 1 : 2, r.id);
});

test('receiver key: a real key, the generator and x = 1 are claimable; nothing else is', () => {
  assert.ok(isBeamReceiverKey(refKey));
  const g = hexToBytes('79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798');
  assert.ok(isBeamReceiverKey(Uint8Array.from([...g, 0])));
  const one = new Uint8Array(33);
  one[31] = 1;
  assert.ok(isBeamReceiverKey(one));
  // The four WBEAM receivers that can never be claimed end in 23, b5, 22, f9.
  for (const parity of [0x02, 0x23, 0xb5, 0x22, 0xf9]) {
    const k = Uint8Array.from(refKey);
    k[32] = parity;
    assert.equal(isBeamReceiverKey(k), false, `parity ${parity}`);
  }
  assert.equal(isBeamReceiverKey(refKey.subarray(0, 32)), false);
  assert.equal(isBeamReceiverKey(new Uint8Array(34)), false);
  assert.equal(isBeamReceiverKey(new Uint8Array(33)), false); // x = 0
  const five = new Uint8Array(33);
  five[31] = 5;
  assert.equal(isBeamReceiverKey(five), false); // x³ + 7 not a square
  assert.equal(isBeamReceiverKey(Uint8Array.from([...new Array(32).fill(0xff), 0])), false); // x >= p
});

// ---------------------------------------------------------------- the lock receipt

const read = (receipt, { route = beam, owner = refOwner, value = refValue, fee = refFee, key = refKey } = {}) => decodeLockReceipt(route, receipt, { owner, value, fee, receiverKey: key });
const refused = (fn) => assert.throws(fn, code('unexpectedTransaction'));

test('the lock receipt: msgId 222 from the real receipt, and its message decodes to the spec', () => {
  const lock = read(refReceipt());
  assert.deepEqual({ ...lock }, { hash: refHash, success: true, blockNumber: 25868098, msgId: 222 });
  const m = decodePipeMessage(refReceipt().logs[1].data);
  assert.equal(m.msgId, 222);
  assert.equal(m.amount, refValue);
  assert.equal(m.relayerFee, refFee);
  assert.deepEqual(m.receiver, refKey);
});

test("the lock receipt: refuses another wallet's key, other amounts, another route, contract or sender", () => {
  const other = Uint8Array.from(refKey);
  other[0] ^= 1;
  refused(() => read(refReceipt(), { key: other }));
  refused(() => read(refReceipt(), { value: refValue + 1n }));
  refused(() => read(refReceipt(), { fee: refFee - 1n }));
  // The same total split differently is still another crossing.
  refused(() => read(refReceipt(), { value: refValue + 1n, fee: refFee - 1n }));
  const r = refReceipt();
  r.logs[1].address = usdt.ethPipe;
  refused(() => read(r));
  refused(() => read(refReceipt(), { route: usdt }));
  refused(() => read({ ...refReceipt(), to: dai.ethPipe }));
  refused(() => read(refReceipt(), { owner: eth.ethPipe }));
});

test('the lock receipt: refuses a token that did not move, moved short, elsewhere, or twice', () => {
  const none = refReceipt();
  none.logs.splice(0, 1);
  refused(() => read(none));
  const short = refReceipt();
  short.logs[0].data = bytesToHex(word(refValue + refFee - 1n));
  refused(() => read(short));
  const elsewhere = refReceipt();
  elsewhere.logs[0].topics[2] = `0x${'0'.repeat(24)}${beam.ethPipe.slice(2)}`;
  refused(() => read(elsewhere));
  const twice = refReceipt();
  twice.logs.unshift({ ...twice.logs[0] });
  refused(() => read(twice));
});

test('the lock receipt: refuses two messages, none, trailing bytes, no status; a reverted lock locked nothing', () => {
  const two = refReceipt();
  two.logs.push({ ...two.logs[1] });
  refused(() => read(two));
  const none = refReceipt();
  none.logs.splice(1, 1);
  refused(() => read(none));
  const trailing = refReceipt();
  trailing.logs[1].data += '00'.repeat(32);
  refused(() => read(trailing));
  const reverted = { ...refReceipt(), status: '0x0', logs: [] };
  assert.deepEqual({ ...read(reverted) }, { hash: refHash, success: false, blockNumber: 25868098, msgId: null });
  const noStatus = refReceipt();
  delete noStatus.status;
  refused(() => read(noStatus));
  refused(() => read({ ...refReceipt(), blockNumber: null }));
});

// ---------------------------------------------------------------- amounts and the transactions the key may sign

test('planLock refusals: nothing to move, a negative fee, off the 10^10 grid (ETH, DAI)', () => {
  const bad = (r, value, fee, c = 'badAmount', key = refKey) => assert.throws(() => checkLockAmounts(r, { value, fee, receiverKey: key }), code(c), `${r.id} ${value} ${fee}`);
  bad(beam, 0n, 2000000n);
  bad(beam, -1n, 2000000n);
  bad(beam, 100n, -1n);
  const step = 10n ** 10n;
  bad(eth, step + 1n, step * 7n);
  bad(eth, step, 63011920796n);
  bad(dai, 10n ** 18n - 1n, step);
  checkLockAmounts(eth, { value: step, fee: step * 7n, receiverKey: refKey });
  // A zero fee is allowed (the relayer delivers it).
  checkLockAmounts(wbtc, { value: 1000n, fee: 0n, receiverKey: refKey });
});

test('planLock refusals: a sum that wraps the pipe or that BEAM cannot hold; a key nobody can claim with', () => {
  const bad = (r, value, fee, c = 'badAmount', key = refKey) => assert.throws(() => checkLockAmounts(r, { value, fee, receiverKey: key }), code(c), `${r.id} ${value} ${fee}`);
  const max = (1n << 256n) - 1n;
  // Grid 1 (WBTC): the overflow messages of 2026-05-17.
  bad(wbtc, max, 1n);
  bad(usdt, max - 4471397801n, 4471397802n);
  bad(beam, 1n << 63n, 0n);
  bad(beam, 1n << 62n, 1n << 62n);
  // ETH: 2^63 groth is 2^63 × 10^10 wei.
  bad(eth, (1n << 63n) * 10n ** 10n, 0n);
  checkLockAmounts(beam, { value: (1n << 63n) - 2n, fee: 1n, receiverKey: refKey });
  const parity = Uint8Array.from(refKey);
  parity[32] = 0x23;
  for (const key of [new Uint8Array(33), refKey.subarray(0, 32), parity]) bad(beam, refValue, refFee, 'badPipe', key);
});

test('only bridge transactions are signed: exact approvals of a pipe, sendFunds as planned', () => {
  const tx = (to, data, value = 0n) => ({ to, data, value });
  const v = 1000n;
  const f = 10n;
  for (const r of ROUTES) {
    if (r.ethToken) assert.equal(checkBridgeTx(tx(r.ethToken, erc20ApproveCall(r.ethPipe, v))), r);
    assert.equal(checkBridgeTx(tx(r.ethPipe, sendFundsCall(v, f, refKey), r.isNativeEth ? v + f : 0n)), r);
  }
  const refusedTxs = [
    tx(usdt.ethToken, erc20ApproveCall(PERMIT2, v)), // approving someone else
    tx(usdt.ethToken, erc20ApproveCall(dai.ethPipe, v)), // the wrong pipe
    tx(usdt.ethToken, encodeCall('transfer(address,uint256)', [usdt.ethPipe, v])), // a transfer
    tx(usdt.ethToken, erc20ApproveCall(usdt.ethPipe, v), 1n), // an approval with ETH attached
    tx(eth.ethPipe, sendFundsCall(v, f, refKey), v), // ETH with the wrong msg.value
    tx(dai.ethPipe, sendFundsCall(v, f, refKey), v + f), // a token pipe with ETH attached
    tx(dai.ethPipe, sendFundsCall(v, f, new Uint8Array(33))), // an unclaimable receiver
    tx(wbtc.ethPipe, sendFundsCall((1n << 256n) - 1n, 1n, refKey)), // a sum that wraps
    tx(dai.ethToken, sendFundsCall(v, f, refKey)), // sendFunds to a token
    tx('0x0000000000000000000000000000000000000001', sendFundsCall(v, f, refKey)), // to an unknown contract
    tx(dai.ethPipe, Uint8Array.from([...sendFundsCall(v, f, refKey), 0])), // trailing bytes
    tx(dai.ethPipe, new Uint8Array(3)),
    tx('not an address', sendFundsCall(v, f, refKey)),
  ];
  refusedTxs.forEach((t, i) => assert.throws(() => checkBridgeTx(t), code('unexpectedTransaction'), `case ${i}`));
});

// ---------------------------------------------------------------- the service, over a fake server

/** A fake JSON-RPC server. contract(to, data, from) → [ok, bytes] or null (revert). */
function fakeChain() {
  const chain = {
    requests: [],
    down: false,
    contract: () => null,
    estimateGas: null,
    receipt: null,
    tx: null,
    storage: null,
    feeHistory: null,
    balance: '0x0',
    nonce: '0x7',
    chainId: '0x1',
    sent: [],
    sendError: null,
    count: (m) => chain.requests.filter((r) => r.method === m).length,
  };
  const revert = () => Object.assign(new Error('execution reverted'), { code: 3 });
  const answer = (method, params) => {
    switch (method) {
      case 'eth_chainId':
        return chain.chainId;
      case 'eth_call': {
        const { to, data, from } = params[0];
        const bytes = hexToBytes(data);
        if (to === MULTICALL3.toLowerCase()) {
          const [calls] = abiDecode('(address,bool,bytes)[]', bytes.subarray(4));
          const out = calls.map(([t, , d]) => {
            const a = chain.contract(t.toLowerCase(), d, null);
            return a ? [a[0], a[1]] : [false, new Uint8Array(0)];
          });
          return bytesToHex(abiEncode('(bool,bytes)[]', [out]));
        }
        const a = chain.contract(to, bytes, from || null);
        if (!a || !a[0]) throw revert();
        return bytesToHex(a[1]);
      }
      case 'eth_estimateGas': {
        const r = chain.estimateGas ? chain.estimateGas(params[0]) : null;
        if (r == null) throw revert();
        return r;
      }
      case 'eth_feeHistory':
        return chain.feeHistory ? chain.feeHistory(params) : { baseFeePerGas: ['0x3b9aca00', '0x3b9aca00'], reward: [['0x5f5e100']] };
      case 'eth_getBalance':
        return chain.balance;
      case 'eth_getTransactionCount':
        return chain.nonce;
      case 'eth_getTransactionReceipt':
        return chain.receipt ? chain.receipt(params) : null;
      case 'eth_getTransactionByHash':
        return chain.tx ? chain.tx(params) : null;
      case 'eth_getStorageAt':
        return chain.storage ? chain.storage(params) : `0x${'0'.repeat(64)}`;
      case 'eth_sendRawTransaction': {
        if (chain.sendError) throw chain.sendError;
        chain.sent.push(params[0]);
        return parseSignedTransaction(params[0]).hash;
      }
      default:
        throw new Error(`unexpected ${method}`);
    }
  };
  chain.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    chain.requests.push({ method: body.method, params: body.params });
    if (chain.down) throw new TypeError('down');
    let out;
    try {
      out = { jsonrpc: '2.0', id: body.id, result: answer(body.method, body.params) };
    } catch (e) {
      out = { jsonrpc: '2.0', id: body.id, error: { code: e.code ?? -32000, message: e.message } };
    }
    return new Response(JSON.stringify(out), { status: 200 });
  };
  chain.rpc = () => new EthRpc('stackwallet', { fetch: chain.fetch, timeoutMs: 2000 });
  return chain;
}

const OWNER = '0x00000000000000000000000000000000000000aa';

function service(chain, { now = { t: Date.UTC(2026, 9, 9, 12) }, owner = OWNER, withKey = null } = {}) {
  return new EthPipe({ rpc: chain.rpc(), owner, withKey, clock: () => now.t });
}

function tokens(chain, { wbeamPaused = false, wbtcPaused = false, usdtPaused = false, blacklisted = false, basisPoints = 0, extra = null } = {}) {
  chain.contract = (to, data, from) => {
    const sel = bytesToHex(data.subarray(0, 4));
    if (sel === '0x5c975abb') return [true, word({ [beam.ethToken]: wbeamPaused, [wbtc.ethToken]: wbtcPaused, [usdt.ethToken]: usdtPaused }[to] ? 1n : 0n)];
    if (sel === '0xe47d6060') {
      assert.equal(to, usdt.ethToken);
      assert.equal(abiDecode('address', data.subarray(4))[0].toLowerCase(), usdt.ethPipe);
      return [true, word(blacklisted ? 1n : 0n)];
    }
    if (sel === '0xdd644f72') return [true, word(BigInt(basisPoints))];
    return extra ? extra(to, data, from) : null;
  };
}

const reasons = (f) => f.map((x) => x.reason);

test('freezes: ETH and DAI have nothing to check; all clear is one multicall per route', async () => {
  const chain = fakeChain();
  const s = service(chain);
  assert.deepEqual(await s.freezes(eth), []);
  assert.deepEqual(await s.freezes(dai), []);
  assert.equal(chain.requests.length, 0);
  tokens(chain);
  for (const r of [beam, wbtc, usdt]) assert.deepEqual(await s.freezes(r), [], r.id);
  assert.equal(chain.count('eth_call'), 3);
});

test('freezes: each one in plain words', async () => {
  const chain = fakeChain();
  tokens(chain, { wbeamPaused: true });
  assert.deepEqual(reasons(await service(chain).freezes(beam)), ['WBEAM is paused by its issuer']);
  tokens(chain, { wbtcPaused: true });
  assert.deepEqual(reasons(await service(chain).freezes(wbtc)), ['WBTC is paused by its issuer']);
  tokens(chain, { usdtPaused: true, blacklisted: true, basisPoints: 10 });
  assert.deepEqual(reasons(await service(chain).freezes(usdt)), ['Tether has paused USDT', "Tether has frozen the bridge's USDT", 'USDT now charges a transfer fee']);
  tokens(chain, { blacklisted: true });
  assert.deepEqual(reasons(await service(chain).freezes(usdt)), ["Tether has frozen the bridge's USDT"]);
});

test('freezes: kept 10 minutes for quotes; then asked again', async () => {
  const chain = fakeChain();
  const now = { t: 0 };
  tokens(chain);
  const s = service(chain, { now });
  await s.freezes(usdt);
  now.t += 9 * 60000 + 59000;
  await s.freezes(usdt);
  assert.equal(chain.count('eth_call'), 1);
  tokens(chain, { blacklisted: true });
  now.t += 1000;
  assert.equal((await s.freezes(usdt)).length, 1);
  assert.equal(chain.count('eth_call'), 2);
});

test('freezes: server down - the last answer for up to an hour for a quote, then refused; nothing known: refused', async () => {
  const chain = fakeChain();
  const now = { t: 0 };
  tokens(chain);
  const s = service(chain, { now });
  await s.freezes(usdt);
  chain.down = true;
  now.t += 59 * 60000;
  assert.deepEqual(await s.freezes(usdt), []);
  now.t += 60000;
  await assert.rejects(s.freezes(usdt), code('network'));
  await assert.rejects(service(chain).freezes(beam), code('network'));
});

test('freezes: right before signing the check is fresh, and no answer means no signature (fail closed)', async () => {
  const chain = fakeChain();
  const now = { t: 0 };
  tokens(chain);
  const s = service(chain, { now });
  assert.deepEqual(await s.freezes(beam), []);
  // A minute later the issuer pauses WBEAM: a quote still sees the kept answer...
  tokens(chain, { wbeamPaused: true });
  now.t += 60000;
  assert.deepEqual(await s.freezes(beam), []);
  // ...the check before signing asks again.
  await assert.rejects(s.assertNotFrozen(beam), (e) => e.code === 'frozen' && /paused by its issuer/.test(e.message));
  tokens(chain);
  chain.down = true;
  await assert.rejects(s.assertNotFrozen(beam), code('network'));
  await assert.rejects(s.assertNotFrozen(usdt), code('network'));
  chain.down = false;
  await s.assertNotFrozen(beam);
  await s.assertNotFrozen(eth); // nothing can freeze ETH: no request
});

test('freezes: a check that fails or answers nonsense is refused', async () => {
  const chain = fakeChain();
  tokens(chain, { extra: null });
  const clear = chain.contract;
  chain.contract = (to, data, from) => (bytesToHex(data.subarray(0, 4)) === '0xe47d6060' ? null : clear(to, data, from));
  await assert.rejects(service(chain).freezes(usdt), code('frozen'));
  chain.contract = () => [true, word(2n)]; // paused() says 2
  await assert.rejects(service(chain).freezes(wbtc), code('frozen'));
  chain.contract = () => [true, new Uint8Array(31)]; // a short answer
  await assert.rejects(service(chain).freezes(beam), code('frozen'));
});

test('relayer gas: eth_feeHistory(0xa, latest, [50]); no answer or a useless one is no price', async () => {
  const chain = fakeChain();
  const now = { t: 12345 };
  chain.feeHistory = (p) => {
    assert.deepEqual(p, ['0xa', 'latest', [50]]);
    return { baseFeePerGas: ['0x29cf7a1b'], reward: [['0x1dcd6500']] };
  };
  const gas = await service(chain, { now }).relayerGas();
  assert.equal(gas.baseFee, 0x29cf7a1bn);
  assert.equal(gas.tip, 500000000n);
  assert.equal(gas.at, 12345);
  chain.feeHistory = () => ({ baseFeePerGas: [] });
  await assert.rejects(service(chain).relayerGas(), code('noPrice'));
  chain.down = true;
  await assert.rejects(service(chain).relayerGas(), code('noPrice'));
});

test('balances: ETH from eth_getBalance, a token from balanceOf; server down is network', async () => {
  const chain = fakeChain();
  chain.balance = '0xde0b6b3a7640000';
  chain.contract = (to, data) => {
    assert.equal(to, usdt.ethToken);
    assert.equal(bytesToHex(data), bytesToHex(encodeCall('balanceOf(address)', [OWNER])));
    return [true, word(4157110300n)];
  };
  const s = service(chain);
  assert.equal(await s.ethBalance(), 10n ** 18n);
  assert.equal(await s.balance(eth), 10n ** 18n);
  assert.equal(await s.balance(usdt), 4157110300n);
  chain.down = true;
  await assert.rejects(s.balance(dai), code('network'));
});

/**
 * planLock's view of a token: its allowance, whether it takes a non-zero change,
 * what each estimate says; and the freeze answers (chain.freeze).
 */
function lockChain({ allowance = 0n, takesChange = true, owner = OWNER } = {}) {
  const chain = fakeChain();
  chain.estimated = [];
  chain.allowance = allowance;
  chain.takesChange = takesChange;
  chain.freeze = {};
  chain.contract = (to, data, from) => {
    const sel = bytesToHex(data.subarray(0, 4));
    const f = chain.freeze;
    if (sel === '0x5c975abb') return [true, word({ [beam.ethToken]: f.wbeamPaused, [wbtc.ethToken]: f.wbtcPaused, [usdt.ethToken]: f.usdtPaused }[to] ? 1n : 0n)];
    if (sel === '0xe47d6060') return [true, word(f.blacklisted ? 1n : 0n)];
    if (sel === '0xdd644f72') return [true, word(BigInt(f.basisPoints || 0))];
    if (sel === selectorHex('allowance(address,address)')) {
      const [o, sp] = abiDecode('address,address', data.subarray(4));
      assert.equal(o.toLowerCase(), owner);
      assert.equal(sp.toLowerCase(), ROUTES.find((r) => r.ethToken === to).ethPipe);
      return [true, word(chain.allowance)];
    }
    if (sel === P.APPROVE_SELECTOR) {
      assert.equal(from, owner);
      return chain.takesChange ? [true, word(1n)] : null;
    }
    return null;
  };
  chain.estimateGas = (tx) => {
    const sel = tx.data.slice(0, 10);
    chain.estimated.push(sel);
    if (sel === P.SEND_FUNDS_SELECTOR) return tx.to === eth.ethPipe ? '0x7986' : '0xd365'; // 31110, 54117
    if (sel === P.APPROVE_SELECTOR) {
      const amount = abiDecode('address,uint256', hexToBytes(tx.data).subarray(4))[1];
      // USDT: non-zero to non-zero reverts while the allowance is set.
      if (!chain.takesChange && amount > 0n) return null;
      return '0xb3b0'; // 46000
    }
    return null;
  };
  return chain;
}

test('planLock ETH: one sendFunds carrying value + fee, gas measured, unsigned', async () => {
  const chain = lockChain();
  const value = 10n ** 17n;
  const fee = 70000000000n;
  const plan = await service(chain).planLock(eth, { value, fee, receiverKey: refKey });
  assert.equal(plan.steps.length, 1);
  const tx = plan.steps[0];
  assert.equal(tx.kind, 'lock');
  assert.equal(tx.to, eth.ethPipe);
  assert.equal(tx.value, value + fee);
  assert.equal(bytesToHex(tx.data), bytesToHex(sendFundsCall(value, fee, refKey)));
  assert.equal(tx.gasLimit, 31110n + 20000n);
  assert.equal(tx.note, 'Bridge: move 0.1 ETH to BEAM');
  assert.equal(plan.fees.baseFee, 1000000000n);
  assert.equal(tx.maxFeePerGas, plan.fees.maxFeePerGas);
  assert.equal(plan.maxGasCost, tx.gasLimit * plan.fees.maxFeePerGas);
  assert.equal(chain.count('eth_call'), 0, 'no allowance for ETH');
  assert.equal(chain.count('eth_sendRawTransaction'), 0);
  assert.ok(!('raw' in tx) && !('hash' in tx), 'nothing signed');
});

test('planLock token without allowance: exact approve, then sendFunds at the safe limit', async () => {
  const chain = lockChain();
  const plan = await service(chain).planLock(beam, { value: refValue, fee: refFee, receiverKey: refKey });
  assert.deepEqual(plan.steps.map((t) => t.kind), ['approve', 'lock']);
  const [approve, lock] = plan.steps;
  assert.equal(approve.to, beam.ethToken);
  assert.equal(approve.value, 0n);
  assert.equal(bytesToHex(approve.data), bytesToHex(erc20ApproveCall(beam.ethPipe, refValue + refFee)));
  assert.equal(approve.gasLimit, 46000n + 20000n);
  assert.equal(approve.note, 'Approve 105.02 WBEAM for the BEAM bridge');
  assert.equal(lock.value, 0n);
  assert.equal(lock.gasLimit, P.SEND_FUNDS_GAS_TOKEN);
  assert.equal(lock.note, 'Bridge: move 105 WBEAM to BEAM');
  assert.deepEqual(chain.estimated, [P.APPROVE_SELECTOR], 'sendFunds not measured');
});

test('planLock: never more than value + fee, never unlimited', async () => {
  const chain = lockChain({ allowance: 5n });
  for (const r of [beam, wbtc, dai]) {
    const value = r.ethGrid * 1000n;
    const plan = await service(chain).planLock(r, { value, fee: r.ethGrid, receiverKey: refKey });
    const approve = plan.steps.find((t) => t.kind === 'approve');
    assert.equal(abiDecode('address,uint256', approve.data.subarray(4))[1], value + r.ethGrid, r.id);
  }
});

test('planLock USDT with an allowance set: reset to 0, approve, sendFunds; DAI takes the change directly', async () => {
  const chain = lockChain({ allowance: 1n, takesChange: false });
  const plan = await service(chain).planLock(usdt, { value: 100000000n, fee: 157n, receiverKey: refKey });
  assert.deepEqual(plan.steps.map((t) => t.kind), ['approveReset', 'approve', 'lock']);
  assert.equal(bytesToHex(plan.steps[0].data), bytesToHex(erc20ApproveCall(usdt.ethPipe, 0n)));
  assert.equal(plan.steps[0].gasLimit, 66000n);
  assert.equal(plan.steps[0].note, 'Reset the USDT permission of the BEAM bridge to 0');
  assert.equal(plan.steps[1].gasLimit, P.APPROVE_GAS, 'its estimate reverts until the reset is mined');
  assert.equal(plan.steps[1].note, 'Approve 100.000157 USDT for the BEAM bridge');
  assert.equal(plan.steps[2].gasLimit, P.SEND_FUNDS_GAS_TOKEN);
  const d = lockChain({ allowance: 1n });
  const p2 = await service(d).planLock(dai, { value: 10n ** 18n, fee: 156740000000000n, receiverKey: refKey });
  assert.deepEqual(p2.steps.map((t) => t.kind), ['approve', 'lock']);
});

test('planLock: allowance already enough is sendFunds alone; a revert keeps the safe limit; server down plans nothing', async () => {
  const chain = lockChain({ allowance: refValue + refFee });
  const plan = await service(chain).planLock(beam, { value: refValue, fee: refFee, receiverKey: refKey });
  assert.equal(plan.steps.length, 1);
  assert.equal(plan.steps[0].gasLimit, 54117n + 20000n);
  chain.estimateGas = () => null;
  assert.equal((await service(chain).planLock(beam, { value: refValue, fee: refFee, receiverKey: refKey })).steps[0].gasLimit, P.SEND_FUNDS_GAS_TOKEN);
  assert.equal((await service(chain).planLock(eth, { value: 10n ** 17n, fee: 70000000000n, receiverKey: refKey })).steps[0].gasLimit, P.SEND_FUNDS_GAS_ETH);
  chain.down = true;
  await assert.rejects(service(chain).planLock(beam, { value: refValue, fee: refFee, receiverKey: refKey }), code('network'));
  // Refused before asking anything.
  const quiet = fakeChain();
  await assert.rejects(service(quiet).planLock(beam, { value: 0n, fee: refFee, receiverKey: refKey }), code('badAmount'));
  assert.equal(quiet.requests.length, 0);
});

test('sign: a fresh freeze check, mainnet, the next nonce, this key; each request once; nothing broadcast', async () => {
  const { sk, address } = await ethKeyFromMnemonic(JUNK);
  const owner = address.toLowerCase();
  const chain = lockChain({ owner });
  const keyUses = [];
  const withKey = async (fn) => {
    keyUses.push(1);
    return fn({ sk: Uint8Array.from(sk), address });
  };
  const s = service(chain, { owner, withKey });
  const plan = await s.planLock(beam, { value: refValue, fee: refFee, receiverKey: refKey });
  assert.deepEqual(await s.freezes(beam), []); // a quote's check, kept for 10 minutes
  const before = chain.count('eth_call');
  const signed = await s.sign(plan.steps[0]);
  assert.equal(chain.count('eth_call'), before + 1, 'a fresh freeze check');
  const parsed = parseSignedTransaction(signed.raw);
  assert.equal(parsed.from.toLowerCase(), owner);
  assert.equal(parsed.hash, signed.hash);
  assert.equal(parsed.tx.chainId, 1n);
  assert.equal(parsed.tx.nonce, 7n);
  assert.equal(signed.nonce, 7);
  assert.equal(parsed.tx.to.toLowerCase(), beam.ethToken);
  assert.equal(parsed.tx.data, bytesToHex(plan.steps[0].data));
  assert.equal(parsed.tx.gasLimit, plan.steps[0].gasLimit);
  assert.equal(parsed.tx.maxFeePerGas, plan.steps[0].maxFeePerGas);
  assert.equal(chain.count('eth_sendRawTransaction'), 0, 'signing broadcasts nothing');
  await assert.rejects(s.sign(plan.steps[0]), code('alreadySent'));
  assert.equal(keyUses.length, 1);

  // Frozen, no answer, or not mainnet: no signature, the key is never opened.
  chain.freeze = { wbeamPaused: true };
  await assert.rejects(s.sign(plan.steps[1]), code('frozen'));
  chain.freeze = {};
  const again = await s.planLock(beam, { value: refValue, fee: refFee, receiverKey: refKey });
  chain.down = true;
  await assert.rejects(s.sign(again.steps[0]), code('network'));
  chain.down = false;
  const plan2 = await s.planLock(eth, { value: 10n ** 16n, fee: 10n ** 12n, receiverKey: refKey });
  chain.chainId = '0x5';
  await assert.rejects(s.sign(plan2.steps[0]), code('network'));
  chain.chainId = '0x1';
  assert.equal(keyUses.length, 1);
  // Not a bridge transaction: refused before anything is asked.
  const asked = chain.requests.length;
  await assert.rejects(s.sign({ to: usdt.ethToken, data: erc20ApproveCall(PERMIT2, 1n), value: 0n, gasLimit: 70000n, maxFeePerGas: 2n, maxPriorityFeePerGas: 1n }), code('unexpectedTransaction'));
  assert.equal(chain.requests.length, asked);
  // A key that is not this wallet's: nothing signed.
  const other = service(lockChain(), { owner: OWNER, withKey });
  const plan3 = await other.planLock(eth, { value: 10n ** 16n, fee: 10n ** 12n, receiverKey: refKey });
  await assert.rejects(other.sign(plan3.steps[0]), code('unexpectedTransaction'));
});

test("broadcast: only this wallet's mainnet bridge bytes; the hash is keccak of the bytes; again is safe", async () => {
  const { sk, address } = await ethKeyFromMnemonic(JUNK);
  const owner = address.toLowerCase();
  const chain = lockChain({ owner });
  const s = service(chain, { owner, withKey: async (fn) => fn({ sk: Uint8Array.from(sk), address }) });
  const plan = await s.planLock(eth, { value: 10n ** 16n, fee: 10n ** 12n, receiverKey: refKey });
  const signed = await s.sign(plan.steps[0]);
  assert.equal(await s.broadcast(signed.raw), signed.hash);
  chain.sendError = Object.assign(new Error('already known'), { code: -32000 });
  assert.equal(await s.broadcast(signed.raw), signed.hash);
  assert.deepEqual(chain.sent, [signed.raw]);
  // Another wallet's bytes are not sent through this one.
  const other = service(chain, { owner: OWNER });
  await assert.rejects(other.broadcast(signed.raw), code('unexpectedTransaction'));
  await assert.rejects(s.broadcast('0x1234'), code('unexpectedTransaction'));
});

test('after sending: lockResult null while pending then the msgId; another wallet or hash refused; succeeded null/true/false', async () => {
  const chain = fakeChain();
  const s = service(chain, { owner: refOwner });
  chain.receipt = () => null;
  assert.equal(await s.lockResult(beam, refHash, { value: refValue, fee: refFee, receiverKey: refKey }), null);
  chain.receipt = (p) => {
    assert.deepEqual(p, [refHash]);
    return refReceipt();
  };
  const lock = await s.lockResult(beam, refHash, { value: refValue, fee: refFee, receiverKey: refKey });
  assert.equal(lock.msgId, 222);
  assert.equal(lock.success, true);
  assert.equal(await s.succeeded(refHash), true);
  chain.receipt = () => refReceipt();
  await assert.rejects(service(chain).lockResult(beam, refHash, { value: refValue, fee: refFee, receiverKey: refKey }), code('unexpectedTransaction'));
  await assert.rejects(s.lockResult(beam, `0x${'11'.repeat(32)}`, { value: refValue, fee: refFee, receiverKey: refKey }), code('unexpectedTransaction'));
  chain.receipt = () => ({ blockNumber: null });
  assert.equal(await s.succeeded(refHash), null);
  chain.receipt = () => ({ transactionHash: refHash, blockNumber: '0x1', status: '0x0' });
  assert.equal(await s.succeeded(refHash), false);
  chain.receipt = () => ({ transactionHash: refHash, blockNumber: '0x1', status: '0x1' });
  assert.equal(await s.succeeded(refHash), true);
  chain.tx = () => null;
  assert.equal(await s.known(refHash), false);
  chain.tx = () => ({ hash: refHash });
  assert.equal(await s.known(refHash), true);
});

test("isPaid reads the pipe's map at the route's slot; a value a bool never has is refused", async () => {
  const chain = fakeChain();
  chain.storage = ([pipe, key, block]) => {
    assert.equal(block, 'latest');
    if (pipe === eth.ethPipe && key === processedKey(107, 1)) return '0x1';
    if (pipe === usdt.ethPipe && key === processedKey(108, 2)) return `0x${'0'.repeat(63)}1`;
    return `0x${'0'.repeat(64)}`;
  };
  const s = service(chain);
  assert.equal(await s.isPaid(eth, 107), true);
  assert.equal(await s.isPaid(eth, 108), false);
  assert.equal(await s.isPaid(usdt, 108), true);
  assert.equal(await s.isPaid(usdt, 109), false);
  // Slot 1 of an ERC-20 pipe is its relayer, not the map.
  assert.equal(await s.isPaid(usdt, 107), false);
  chain.storage = () => '0x2';
  await assert.rejects(s.isPaid(beam, 639), code('badPipe'));
  chain.down = true;
  await assert.rejects(s.isPaid(beam, 639), code('network'));
});

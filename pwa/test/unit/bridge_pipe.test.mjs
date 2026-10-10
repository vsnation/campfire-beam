// The bridge's BEAM side (lib/bridge/beam_pipe.js), offline, through the real
// lib/contracts.js on a fake engine. The pipe answers are the desktop app's
// recordings from mainnet (test/beam/bridge/fixtures/pipe_views.json and
// pipe_builds.json, read from their own path: one fixture, two apps); see the
// _comment in each. The cases are the desktop's (pipe_args_test.dart,
// pipe_output_test.dart, real_pipe_raw_data_test.dart, beam_pipe_service_test.dart).
import test, { beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { REPO_ROOT } from '../../tools/shader_check.mjs';
import { fakeEngine, TXID } from './helpers/fake_engine.mjs';
import { invokeEntry, invokeData, FLAG_SAVE_APP_INVOKE } from './helpers/invoke_builder.mjs';
import { bindSession, unbindSession, setConsentPresenter, consentLog, contractsState, ContractError } from '../../src/lib/contracts.js';
import { SHADERS, verifyShader } from '../../src/lib/shaders.js';
import { ROUTES, routeById } from '../../src/lib/bridge/routes.js';
import * as pipe from '../../src/lib/bridge/beam_pipe.js';

const { BeamPipe, BridgeError } = pipe;
const FIX = join(REPO_ROOT, 'test', 'beam', 'bridge', 'fixtures');
const viewsFile = JSON.parse(readFileSync(join(FIX, 'pipe_views.json'), 'utf8'));
const buildsFile = JSON.parse(readFileSync(join(FIX, 'pipe_builds.json'), 'utf8'));
const VIEWS = viewsFile.views;
const BUILDS = buildsFile.builds;

const RECEIVER = '5a'.repeat(20);
const AMOUNT = 100000000n;
const FEE = 1000000n;
/** The recorded claims: route -> [msgId, amount]. */
const RECEIVES = { usdt: [78, 91049000n], eth: [67, 500000n], beam: [226, 2000000n] };
const OWNER = 'acefc4bed717cf94de3868e9979f72184aee00627bd3ebe1b8c0f086ab968b9f'; // bETH asset owner
const DEX = '729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae69b47bcfdeef9cbf';
const GX = '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
const P = 'fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f';

const beam = routeById('beam');
const eth = routeById('eth');
const usdt = routeById('usdt');
const hex = (b) => Buffer.from(b).toString('hex');
const bytes = (h) => [...Buffer.from(h, 'hex')];
const le = (v, n) => Array.from({ length: n }, (_, i) => Number((BigInt(v) >> BigInt(8 * i)) & 0xffn));
const keyHash = (cid) => createHash('sha256').update(Buffer.concat([Buffer.from('bvm.m.key'), Buffer.from([0]), Buffer.from(cid, 'hex')])).digest('hex');
const rawOf = (args) => [...Buffer.from(BUILDS[args].raw_data_base64, 'base64')];
const sendArgsOf = (r, amount = AMOUNT, fee = FEE) => pipe.sendArgs({ cid: r.beamPipeCid, amount, receiver: RECEIVER, relayerFee: fee });

const load = async (key) => verifyShader(key, new Uint8Array(readFileSync(join(REPO_ROOT, 'assets', 'beam', 'shaders', SHADERS[key].file))));
const shaderOf = (contract) => (contract.length === SHADERS.pipe.size ? 'forward' : contract.length === SHADERS.pipeReverse.size ? 'reverse' : null);

let engine;
let unset = () => {};
let svc;

/** Answers invoke_contract as the recorded wallet did, or from `overrides` (by exact args). */
function recorded({ overrides = {}, consent = null } = {}) {
  return (req, api) => {
    if (req.method === 'invoke_contract') {
      const shader = shaderOf(req.params.contract);
      assert.ok(shader, `a ${req.params.contract.length}-byte shader is not a pipe shader`);
      assert.equal(req.params.create_tx, false);
      const args = req.params.args;
      if (overrides[args]) return api.reply(req.id, overrides[args](shader));
      if (VIEWS[`${shader} ${args}`] !== undefined) return api.reply(req.id, { output: VIEWS[`${shader} ${args}`] });
      if (BUILDS[args]) return api.reply(req.id, { output: BUILDS[args].output, raw_data: rawOf(args) });
      return api.replyError(req.id, { code: -32000, message: `no recording for ${shader} ${args}` });
    }
    if (req.method === 'process_invoke_data') {
      assert.ok(consent, 'nothing should have reached process_invoke_data');
      return engine.askContract(api, req, consent.info, consent.amounts);
    }
    return api.replyError(req.id, { code: -32601, message: 'unexpected' });
  };
}

const sent = (method) => engine.apis.flatMap((a) => a.sent).filter((q) => q.method === method);
const isBridge = (code) => (e) => e instanceof BridgeError && e.code === code;
const isContract = (code) => (e) => e instanceof ContractError && e.code === code;

beforeEach(() => {
  engine = fakeEngine();
  engine.respond = recorded();
  bindSession(engine.session);
  svc = new BeamPipe({ load });
});
afterEach(() => {
  unset();
  unbindSession();
});

// ---------------------------------------------------------------- args

test('args: every action exactly as sent, no role', () => {
  const b = beam.beamPipeCid;
  const u = usdt.beamPipeCid;
  assert.equal(pipe.getPkArgs(b), `action=get_pk,cid=${b}`);
  assert.equal(pipe.localMsgCountArgs(u), `action=local_msg_count,cid=${u}`);
  assert.equal(pipe.localMsgArgs(b, 639), `action=local_msg,cid=${b},msgId=639`);
  assert.equal(pipe.remoteMsgArgs(u, 78), `action=remote_msg,cid=${u},msgId=78`);
  assert.equal(pipe.viewIncomingArgs(b), `action=view_incoming,cid=${b}`);
  assert.equal(pipe.viewIncomingArgs(b, 226), `action=view_incoming,cid=${b},startFrom=226`);
  assert.equal(pipe.sendArgs({ cid: u, amount: AMOUNT, receiver: RECEIVER, relayerFee: FEE }), `action=send,cid=${u},amount=100000000,receiver=${RECEIVER},relayerFee=1000000`);
  assert.equal(pipe.receiveArgs({ cid: u, msgId: 78 }), `action=receive,cid=${u},msgId=78`);
  // e2b ids start at 0 (the Ethereum pipe counts from 0).
  assert.equal(pipe.remoteMsgArgs(b, 0), `action=remote_msg,cid=${b},msgId=0`);
  assert.equal(pipe.receiveArgs({ cid: b, msgId: 0 }), `action=receive,cid=${b},msgId=0`);
  // The largest sum the core can hold: 2^63-1 in total.
  const max = (1n << 63n) - 1n;
  assert.match(pipe.sendArgs({ cid: b, amount: max - 1n, receiver: RECEIVER, relayerFee: 1n }), /amount=9223372036854775806,/);
  for (const r of ROUTES) assert.ok(pipe.getPkArgs(r.beamPipeCid).endsWith(r.beamPipeCid));
  assert.ok(!pipe.getPkArgs(b).includes('role'));
});

test('args: cids not in the registry are refused (the asset-owner trap)', () => {
  for (const cid of [OWNER, DEX, beam.beamPipeCid.toUpperCase(), '', 'x', undefined]) {
    assert.throws(() => pipe.getPkArgs(cid), isBridge('badArgs'), String(cid));
    assert.throws(() => pipe.receiveArgs({ cid, msgId: 1 }), isBridge('badArgs'));
    assert.throws(() => pipe.sendArgs({ cid, amount: 1n, receiver: RECEIVER, relayerFee: 1n }), isBridge('badArgs'));
  }
});

test('args: message ids - b2e from 1, e2b and startFrom from 0, whole numbers only', () => {
  const b = beam.beamPipeCid;
  for (const f of [() => pipe.localMsgArgs(b, 0), () => pipe.localMsgArgs(b, -1), () => pipe.remoteMsgArgs(b, -1), () => pipe.receiveArgs({ cid: b, msgId: -1 }), () => pipe.viewIncomingArgs(b, -1), () => pipe.remoteMsgArgs(b, 1.5), () => pipe.remoteMsgArgs(b, '7'), () => pipe.localMsgArgs(b, 2 ** 53)]) {
    assert.throws(f, isBridge('badArgs'));
  }
});

test('args: send amounts - non-positive, too large, a sum that overflows, not BigInt', () => {
  const max = (1n << 63n) - 1n;
  const send = (amount, relayerFee) => pipe.sendArgs({ cid: beam.beamPipeCid, amount, receiver: RECEIVER, relayerFee });
  for (const [a, f] of [[0n, 1n], [-1n, 1n], [1n, 0n], [1n, -1n], [max + 1n, 1n], [1n, max + 1n], [max, 1n], [1n << 62n, 1n << 62n], [18446744068709551617n, 5000000000n], [1, 1n], [1n, '1']]) {
    assert.throws(() => send(a, f), isBridge('badArgs'), `${a} ${f}`);
  }
});

test('args: receivers that are not 40 lowercase hex', () => {
  for (const r of [`0x${RECEIVER}`, RECEIVER.toUpperCase(), RECEIVER.slice(1), `${RECEIVER}5a`, `${RECEIVER.slice(2)}zz`, '', null]) {
    assert.throws(() => pipe.sendArgs({ cid: beam.beamPipeCid, amount: 1n, receiver: r, relayerFee: 1n }), isBridge('badArgs'), String(r));
  }
});

// ---------------------------------------------------------------- views (recorded)

test('views: each sends its exact args with the route\'s pinned shader, create_tx false', async () => {
  for (const r of ROUTES) {
    await svc.receiveKey(r);
    await svc.localMessageCount(r);
    await svc.incoming(r, { startFrom: 0 });
  }
  const calls = sent('invoke_contract');
  assert.equal(calls.length, 15);
  for (const [i, r] of ROUTES.entries()) {
    const mine = calls.slice(i * 3, i * 3 + 3);
    assert.deepEqual(
      mine.map((q) => q.params.args),
      [pipe.getPkArgs(r.beamPipeCid), pipe.localMsgCountArgs(r.beamPipeCid), pipe.viewIncomingArgs(r.beamPipeCid, 0)],
    );
    assert.ok(mine.every((q) => shaderOf(q.params.contract) === r.shader && q.params.create_tx === false));
  }
  assert.equal(sent('process_invoke_data').length, 0);
});

test('views: get_pk - pk (forward) and pubkey (reverse), checked as a secp256k1 point', async () => {
  for (const r of ROUTES) assert.equal(hex(await svc.receiveKey(r)), `${GX}00`, r.id);
});

test('views: recorded counts, a recorded message with exact amounts, absent ids are null', async () => {
  const counts = {};
  for (const r of ROUTES) counts[r.id] = await svc.localMessageCount(r);
  assert.deepEqual(counts, { beam: 639, eth: 107, wbtc: 19, usdt: 108, dai: 40 });
  const m = await svc.localMessage(beam, 639);
  assert.deepEqual({ ...m }, { receiver: `0x${'5b'.repeat(20)}`, amount: 23759052883550n, relayerFee: 2986536262n, height: 4072516 });
  assert.equal(await svc.localMessage(beam, 640), null);
  assert.equal(await svc.localMessage(eth, 108), null);
  const u = await svc.localMessage(usdt, 108);
  assert.equal(u.amount, 38720000000n);
});

test('views: remote_msg - unclaimed messages exact with their 33-byte key; claimed ones null', async () => {
  const m = await svc.remoteMessage(usdt, 78);
  assert.equal(m.amount, 91049000n); // 0.91049 USDT, ×100 into groth
  assert.equal(m.relayerFee, 59200n);
  assert.equal(hex(m.receiver), `${GX}00`);
  assert.equal((await svc.remoteMessage(beam, 226)).amount, 2000000n);
  assert.equal(await svc.remoteMessage(eth, 163), null);
});

test('views: view_incoming is empty on every pipe for a fresh key', async () => {
  for (const r of ROUTES) assert.deepEqual(await svc.incoming(r), []);
});

test("views: the asset-owner contract's view_incoming is not JSON at all: badPipe, not []", async () => {
  const owner = VIEWS[`forward action=view_incoming,cid=${OWNER}`];
  assert.equal(owner, '{"incoming": ["error": "no params"]}');
  engine.respond = recorded({ overrides: { [pipe.viewIncomingArgs(eth.beamPipeCid, 0)]: () => ({ output: owner }) } });
  await assert.rejects(svc.incoming(eth), isBridge('badPipe'));
});

/** The parsed outcome of a view whose output is `output`. */
async function viewing(route, args, output, fn) {
  engine.respond = recorded({ overrides: { [args]: () => ({ output }) } });
  return fn();
}

test('views: get_pk shapes that are not a key are badPipe', async () => {
  const args = pipe.getPkArgs(eth.beamPipeCid);
  let offCurve = null;
  for (let x = 1n; !offCurve; x++) {
    const p = BigInt('0x' + P);
    let r = 1n;
    let b = (x ** 3n + 7n) % p;
    for (let e = (p - 1n) >> 1n; e > 0n; e >>= 1n, b = (b * b) % p) if (e & 1n) r = (r * b) % p;
    if (r !== 1n) offCurve = x.toString(16).padStart(64, '0');
  }
  for (const out of [
    `{"pk": "${GX}"}`,
    `{"pk": "${GX}0000"}`,
    `{"pk": "${GX}02"}`,
    `{"pk": "${GX}ff"}`,
    `{"pk": "${'0'.repeat(64)}00"}`,
    `{"pk": "${P}00"}`,
    `{"pk": "${'f'.repeat(64)}01"}`,
    `{"pk": "${offCurve}00"}`,
    `{"pk": "${'zz'.repeat(33)}"}`,
    `{"pk": "${GX.toUpperCase()}00"}`,
    '{"pk": 5}',
    `{"pubkey": "${GX}00"}`, // the reverse shader's name on a forward pipe
    '{}',
    '{"error": "no params"}',
    'not json',
  ]) {
    await viewing(eth, args, out, () => assert.rejects(svc.receiveKey(eth), isBridge('badPipe'), out));
  }
  await viewing(beam, pipe.getPkArgs(beam.beamPipeCid), `{"pk": "${GX}00"}`, () => assert.rejects(svc.receiveKey(beam), isBridge('badPipe')));
  // Both parities of a real point.
  pipe.checkKey(Uint8Array.from(bytes(`${GX}00`)));
  pipe.checkKey(Uint8Array.from(bytes(`${GX}01`)));
  assert.throws(() => pipe.checkKey(Uint8Array.from(bytes(GX))), isBridge('badPipe'));
});

test('views: amounts past 2^63 stay exact; other shapes are badPipe', async () => {
  const args = pipe.localMsgArgs(beam.beamPipeCid, 563);
  const big = await viewing(beam, args, `{"amount": 18446744068709551617,"relayerFee": 5000000000,"receiver": "${'5b'.repeat(20)}","height": 3500000}`, () => svc.localMessage(beam, 563));
  assert.equal(big.amount, 18446744068709551617n);
  for (const out of [
    '{"error": "no params"}',
    '{"error": "invalid Action."}',
    `{"amount": 1,"relayerFee": 1,"receiver": "${'5b'.repeat(19)}","height": 1}`,
    `{"amount": 1,"relayerFee": 1,"receiver": "0x${'5b'.repeat(20)}","height": 1}`,
    `{"amount": -1,"relayerFee": 1,"receiver": "${'5b'.repeat(20)}","height": 1}`,
    `{"amount": 1.5,"relayerFee": 1,"receiver": "${'5b'.repeat(20)}","height": 1}`,
    `{"amount": 1,"relayerFee": 1,"receiver": "${'5b'.repeat(20)}"}`,
    `{"amount": "1","relayerFee": 1,"receiver": "${'5b'.repeat(20)}","height": 1}`,
    '',
  ]) {
    await viewing(beam, args, out, () => assert.rejects(svc.localMessage(beam, 563), isBridge('badPipe'), out));
  }
  const countArgs = pipe.localMsgCountArgs(beam.beamPipeCid);
  for (const out of ['{"count": -1}', '{"count": 1.5}', '{}', '{"count": "5"}']) {
    await viewing(beam, countArgs, out, () => assert.rejects(svc.localMessageCount(beam), isBridge('badPipe'), out));
  }
  const remote = pipe.remoteMsgArgs(usdt.beamPipeCid, 5);
  for (const out of ['{"error": "msg is processed"}', `{"amount": 1,"relayerFee": 1,"receiver": "${GX}"}`, '{"amount": 1,"relayerFee": 1}', 'nonsense']) {
    await viewing(usdt, remote, out, () => assert.rejects(svc.remoteMessage(usdt, 5), isBridge('badPipe'), out));
  }
});

test('views: view_incoming entries, with every spelling of the id; anything else badPipe', async () => {
  const args = pipe.viewIncomingArgs(beam.beamPipeCid, 0);
  const list = await viewing(beam, args, '{"incoming": [{"MsgId": 226,"amount": 2000000},{"msgId": 227,"amount": 9223372036854775809},{"id": 0,"amount": 1},{"MsgId": 5,"msgId": 5,"amount": 3}]}', () => svc.incoming(beam));
  assert.deepEqual(
    list.map((i) => [i.msgId, i.amount]),
    [
      [226, 2000000n],
      [227, 9223372036854775809n],
      [0, 1n],
      [5, 3n],
    ],
  );
  for (const out of ['{"error": "no params"}', '{"incoming": {}}', '{}', '{"incoming": [5]}', '{"incoming": [{"amount": 1}]}', '{"incoming": [{"MsgId": 1}]}', '{"incoming": [{"MsgId": -1,"amount": 1}]}', '{"incoming": [{"MsgId": 1,"msgId": 2,"amount": 1}]}', '{"incoming": [[1, 2]]}']) {
    await viewing(beam, args, out, () => assert.rejects(svc.incoming(beam), isBridge('badPipe'), out));
  }
});

test('views: a view that builds a transaction is badPipe; the wallet\'s own errors stay its own', async () => {
  const args = pipe.localMsgCountArgs(usdt.beamPipeCid);
  engine.respond = recorded({ overrides: { [args]: () => ({ output: '{"count": 1}', raw_data: [1, 2, 3] }) } });
  await assert.rejects(svc.localMessageCount(usdt), isBridge('badPipe'));
  engine.respond = (req, api) => api.replyError(req.id, { code: -32603, message: 'Internal JSON-RPC error.' });
  await assert.rejects(svc.localMessageCount(usdt), isContract('rpc'));
});

test('a route that is not the registry\'s is refused before any call', async () => {
  const fake = { ...usdt, beamPipeCid: OWNER };
  await assert.rejects(svc.receiveKey(fake), isBridge('badArgs'));
  await assert.rejects(svc.receiveKey({ ...usdt, sendMethod: 4 }), isBridge('badArgs'));
  await assert.rejects(svc.receiveKey({ id: 'btc' }), isBridge('badArgs'));
  await assert.rejects(svc.send({ ...beam, shader: 'forward' }, { ethReceiver: `0x${RECEIVER}`, amount: AMOUNT, fee: FEE }), isBridge('badArgs'));
  // A copy with every field equal is the registry's route.
  assert.equal(hex(await svc.receiveKey({ ...usdt })), `${GX}00`);
  assert.equal(sent('invoke_contract').length, 1);
});

// ---------------------------------------------------------------- inspect

test('the recorded raw_data is what this module expects: the writer reproduces it byte for byte', async () => {
  assert.equal(Object.keys(BUILDS).length, 8);
  for (const [args, b] of Object.entries(BUILDS)) assert.equal(createHash('sha256').update(Buffer.from(b.raw_data_base64, 'base64')).digest('hex'), b.raw_data_sha256, args);
  for (const r of ROUTES) assert.deepEqual(invokeData([sendEntry(r)]), rawOf(sendArgsOf(r)), r.id);
  for (const [id, [msgId, amount]] of Object.entries(RECEIVES)) {
    const r = routeById(id);
    assert.deepEqual(invokeData([receiveEntry(r, msgId, amount)]), rawOf(pipe.receiveArgs({ cid: r.beamPipeCid, msgId })), id);
  }
});

test('pipeKeyHash is SHA-256("bvm.m.key\\0" ‖ cid), the hash in the recorded claims', async () => {
  for (const r of ROUTES) assert.equal(await pipe.pipeKeyHash(r.beamPipeCid), keyHash(r.beamPipeCid));
  for (const [id, [msgId]] of Object.entries(RECEIVES)) {
    const r = routeById(id);
    assert.ok(hex(rawOf(pipe.receiveArgs({ cid: r.beamPipeCid, msgId }))).includes(keyHash(r.beamPipeCid)), id);
  }
});

function sendEntry(r, { cid = r.beamPipeCid, method = r.sendMethod, args = null, spend = null, sigs = [], charge = 0, flags = 0 } = {}) {
  return invokeEntry({ contractId: cid, method, flags, args: args || [...bytes(RECEIVER), ...le(AMOUNT, 8), ...le(FEE, 8)], sigs, charge, comment: 'Send funds', spend: spend || { [r.beamAssetId]: AMOUNT + FEE } });
}

function receiveEntry(r, msgId, amount, { cid = r.beamPipeCid, method = r.receiveMethod, args = null, spend = null, sigs = null, charge = 1200000, flags = 0 } = {}) {
  return invokeEntry({ contractId: cid, method, flags, args: args || le(msgId, 8), sigs: sigs || [keyHash(r.beamPipeCid)], charge, comment: 'Receive funds', spend: spend || { [r.beamAssetId]: -amount } });
}

const inspectSend = (r, raw) => pipe.sendInspector(r, { receiver: RECEIVER, amount: AMOUNT, fee: FEE })(Uint8Array.from(raw));
const inspectClaim = (r, msgId, amount, raw) => pipe.claimInspector(r, { msgId, amount })(Uint8Array.from(raw));
const refused = (problem) => problem && problem.code === 'unexpected' && /Nothing was sent/.test(problem.message);

test('inspect accepts the real raw_data of every recorded send and claim', async () => {
  for (const r of ROUTES) assert.equal(inspectSend(r, rawOf(sendArgsOf(r))), null, r.id);
  for (const [id, [msgId, amount]] of Object.entries(RECEIVES)) {
    const r = routeById(id);
    assert.equal(await inspectClaim(r, msgId, amount, rawOf(pipe.receiveArgs({ cid: r.beamPipeCid, msgId }))), null, id);
  }
});

test('inspect refuses a send whose cid, method, args, signatures or funds were changed', () => {
  const real = rawOf(sendArgsOf(usdt));
  const at = hex(real).indexOf(usdt.beamPipeCid) / 2;
  const flipped = real.slice();
  flipped[at + 31] ^= 1;
  const receiver = bytes(RECEIVER);
  const amount = le(AMOUNT, 8);
  const fee = le(FEE, 8);
  const total = AMOUNT + FEE;
  const cases = {
    'the cid, one bit': flipped,
    'another pipe': invokeData([sendEntry(usdt, { cid: eth.beamPipeCid })]),
    'the asset owner': invokeData([sendEntry(usdt, { cid: OWNER })]),
    'the receive method': invokeData([sendEntry(usdt, { method: usdt.receiveMethod })]),
    "the reverse pipe's send method": invokeData([sendEntry(usdt, { method: 4 })]),
    'amount + 1': invokeData([sendEntry(usdt, { args: [...receiver, ...le(AMOUNT + 1n, 8), ...fee] })]),
    'amount and fee swapped': invokeData([sendEntry(usdt, { args: [...receiver, ...fee, ...amount] })]),
    'another receiver': invokeData([sendEntry(usdt, { args: [...bytes('5b'.repeat(20)), ...amount, ...fee] })]),
    'a big-endian amount': invokeData([sendEntry(usdt, { args: [...receiver, ...amount.slice().reverse(), ...fee] })]),
    'a trailing byte': invokeData([sendEntry(usdt, { args: [...receiver, ...amount, ...fee, 0] })]),
    'a missing byte': invokeData([sendEntry(usdt, { args: [...receiver, ...amount, ...fee.slice(1)] })]),
    'a signature': invokeData([sendEntry(usdt, { sigs: [keyHash(usdt.beamPipeCid)] })]),
    'the amount only': invokeData([sendEntry(usdt, { spend: { 37: AMOUNT } })]),
    'one groth more': invokeData([sendEntry(usdt, { spend: { 37: total + 1n } })]),
    'another asset': invokeData([sendEntry(usdt, { spend: { 36: total } })]),
    'an extra asset': invokeData([sendEntry(usdt, { spend: { 37: total, 0: 1n } })]),
    'receiving instead': invokeData([sendEntry(usdt, { spend: { 37: -total } })]),
    'no funds': invokeData([sendEntry(usdt, { spend: {} })]),
    'a second entry': invokeData([sendEntry(usdt), sendEntry(usdt)]),
    'no entry': invokeData([]),
    unreadable: [1, 2, 3],
    'a trailing byte after the data': [...real, 0],
  };
  for (const [name, raw] of Object.entries(cases)) assert.ok(refused(inspectSend(usdt, raw)), name);
});

test('inspect refuses a claim whose cid, message, method, signatures or funds were changed', async () => {
  const [msgId, amount] = RECEIVES.usdt;
  const key = keyHash(usdt.beamPipeCid);
  const cases = {
    'another pipe': invokeData([receiveEntry(usdt, msgId, amount, { cid: eth.beamPipeCid })]),
    'another message': invokeData([receiveEntry(usdt, msgId, amount, { args: le(79, 8) })]),
    'a 4-byte id': invokeData([receiveEntry(usdt, msgId, amount, { args: le(78, 4) })]),
    'the send method': invokeData([receiveEntry(usdt, msgId, amount, { method: 3 })]),
    "the reverse pipe's receive method": invokeData([receiveEntry(usdt, msgId, amount, { method: 6 })]),
    'no signature': invokeData([receiveEntry(usdt, msgId, amount, { sigs: [] })]),
    'two signatures': invokeData([receiveEntry(usdt, msgId, amount, { sigs: [key, key] })]),
    "another pipe's key": invokeData([receiveEntry(usdt, msgId, amount, { sigs: [keyHash(eth.beamPipeCid)] })]),
    "the asset owner's key": invokeData([receiveEntry(usdt, msgId, amount, { sigs: [keyHash(OWNER)] })]),
    'one groth more': invokeData([receiveEntry(usdt, msgId, amount + 1n)]),
    'one groth less': invokeData([receiveEntry(usdt, msgId, amount - 1n)]),
    'paying instead': invokeData([receiveEntry(usdt, msgId, amount, { spend: { 37: amount } })]),
    'another asset': invokeData([receiveEntry(usdt, msgId, amount, { spend: { 0: -amount } })]),
    'a second entry': invokeData([receiveEntry(usdt, msgId, amount), receiveEntry(usdt, msgId, amount)]),
  };
  for (const [name, raw] of Object.entries(cases)) assert.ok(refused(await inspectClaim(usdt, msgId, amount, raw)), name);
  // The beam route's reverse methods: 6 passes, the forward 4 does not.
  const [bId, bAmount] = RECEIVES.beam;
  assert.equal(await inspectClaim(beam, bId, bAmount, invokeData([receiveEntry(beam, bId, bAmount)])), null);
  assert.ok(refused(await inspectClaim(beam, bId, bAmount, invokeData([receiveEntry(beam, bId, bAmount, { method: 4 })]))));
});

test('inspect: stored shader args - equal to the request passes; different, extra or privileged is refused', async () => {
  const args = sendArgsOf(usdt);
  const asked = Object.fromEntries(args.split(',').map((kv) => [kv.slice(0, kv.indexOf('=')), kv.slice(kv.indexOf('=') + 1)]));
  const stored = (appArgs, privilege = 0) => invokeData([sendEntry(usdt, { flags: FLAG_SAVE_APP_INVOKE })], { firstFlags: FLAG_SAVE_APP_INVOKE, appArgs, privilege });
  assert.equal(inspectSend(usdt, stored(asked)), null);
  assert.ok(refused(inspectSend(usdt, stored({ ...asked, receiver: '5b'.repeat(20) }))));
  assert.ok(refused(inspectSend(usdt, stored({ ...asked, extra: '1' }))));
  const { relayerFee, ...fewer } = asked;
  assert.ok(relayerFee && refused(inspectSend(usdt, stored(fewer))));
  assert.ok(refused(inspectSend(usdt, stored(asked, 1))));
  const [msgId, amount] = RECEIVES.usdt;
  const claimAsked = { action: 'receive', cid: usdt.beamPipeCid, msgId: String(msgId) };
  const claimStored = (appArgs, privilege = 0) => invokeData([receiveEntry(usdt, msgId, amount, { flags: FLAG_SAVE_APP_INVOKE })], { firstFlags: FLAG_SAVE_APP_INVOKE, appArgs, privilege });
  assert.equal(await inspectClaim(usdt, msgId, amount, claimStored(claimAsked)), null);
  assert.ok(refused(await inspectClaim(usdt, msgId, amount, claimStored({ ...claimAsked, msgId: '79' }))));
  assert.ok(refused(await inspectClaim(usdt, msgId, amount, claimStored(claimAsked, 2))));
});

// ---------------------------------------------------------------- expect

const req = (o) => ({ kind: 'contract', spends: [], receives: [], fee: 1100000n, ...o });
const a = (assetId, amount) => ({ assetId, amount, amountText: '' });

test('expect: a send is amount + fee of its asset leaving, nothing arriving, and exactly 0.011 BEAM', () => {
  const check = pipe.sendExpectation(usdt, { amount: AMOUNT, fee: FEE });
  assert.equal(check(req({ spends: [a(37, 101000000n)] })), null);
  for (const [name, r] of Object.entries({
    'the amount only': req({ spends: [a(37, AMOUNT)] }),
    'one groth more': req({ spends: [a(37, 101000001n)] }),
    'another asset': req({ spends: [a(36, 101000000n)] }),
    'an extra spend': req({ spends: [a(37, 101000000n), a(0, 1n)] }),
    'something arriving': req({ spends: [a(37, 101000000n)], receives: [a(0, 1n)] }),
    'nothing': req({}),
    'a higher fee': req({ spends: [a(37, 101000000n)], fee: 1100001n }),
    "the claim's fee": req({ spends: [a(37, 101000000n)], fee: 12100000n }),
    'a plain send': req({ kind: 'send', spends: [a(37, 101000000n)] }),
  })) {
    assert.ok(refused(check(r)), name);
  }
  // BEAM itself: the engine reports the network fee apart from the spend.
  assert.equal(pipe.sendExpectation(beam, { amount: AMOUNT, fee: FEE })(req({ spends: [a(0, 101000000n)] })), null);
});

test('expect: a claim is the message amount arriving, nothing leaving, and exactly 0.121 BEAM', () => {
  const check = pipe.claimExpectation(usdt, { amount: 91049000n });
  assert.equal(check(req({ receives: [a(37, 91049000n)], fee: 12100000n })), null);
  for (const [name, r] of Object.entries({
    'one groth less': req({ receives: [a(37, 91048999n)], fee: 12100000n }),
    'another asset': req({ receives: [a(0, 91049000n)], fee: 12100000n }),
    'something leaving': req({ receives: [a(37, 91049000n)], spends: [a(0, 1n)], fee: 12100000n }),
    "the send's fee": req({ receives: [a(37, 91049000n)], fee: 1100000n }),
    'a plain send': req({ kind: 'send', receives: [a(37, 91049000n)], fee: 12100000n }),
  })) {
    assert.ok(refused(check(r)), name);
  }
});

// ---------------------------------------------------------------- send and claim, end to end

/** What the engine reports to the consent handler for a send of AMOUNT + FEE of `r`. */
const sendConsent = (r, { fee = '0.011', amount = '1.01', isEnough = false } = {}) => ({ info: { comment: 'Send funds', fee, isEnough, isSpend: true }, amounts: [{ amount, assetID: r.beamAssetId, spend: true }] });

test('send: built, inspected, checked against the engine, then shown on the consent sheet - "no" sends nothing', async () => {
  let seen = null;
  unset = setConsentPresenter(async (r) => {
    seen = r;
    return false;
  });
  engine.respond = recorded({ consent: sendConsent(usdt) });
  await assert.rejects(svc.send(usdt, { ethReceiver: `0x${RECEIVER.toUpperCase()}`, amount: AMOUNT, fee: FEE }), isContract('rejected'));
  assert.equal(seen.native, true);
  assert.deepEqual(seen.spends, [{ assetId: 37, amount: 101000000n, amountText: '1.01' }]);
  assert.equal(seen.fee, 1100000n);
  assert.equal(seen.isEnough, false);
  assert.deepEqual(seen.intent, { action: 'bridge', direction: 'toEthereum', route: 'usdt', amount: AMOUNT, fee: FEE, receiver: `0x${RECEIVER}` });
  assert.deepEqual(sent('invoke_contract').map((q) => q.params.args), [sendArgsOf(usdt)], 'the receiver is sent lower case, without 0x');
  const pid = sent('process_invoke_data');
  assert.equal(pid.length, 1);
  assert.deepEqual(pid[0].params.data, rawOf(sendArgsOf(usdt)), 'the inspected bytes are the bytes sent');
  assert.deepEqual(engine.answers, ['rejected']);
});

test('send: a yes gives the tx id', async () => {
  unset = setConsentPresenter(async () => true);
  engine.respond = recorded({ consent: sendConsent(beam, { isEnough: true }) });
  assert.equal(await svc.send(beam, { ethReceiver: RECEIVER, amount: AMOUNT, fee: FEE }), TXID);
});

test('send: a build that is not the request never reaches process_invoke_data', async () => {
  let shown = 0;
  unset = setConsentPresenter(async () => {
    shown++;
    return true;
  });
  const args = sendArgsOf(usdt);
  for (const raw of [invokeData([sendEntry(usdt, { cid: eth.beamPipeCid })]), invokeData([sendEntry(usdt, { args: [...bytes('5b'.repeat(20)), ...le(AMOUNT, 8), ...le(FEE, 8)] })]), invokeData([sendEntry(usdt, { spend: { 37: AMOUNT + FEE + 1n } })])]) {
    engine.respond = recorded({ overrides: { [args]: () => ({ output: '{}', raw_data: raw }) } });
    await assert.rejects(svc.send(usdt, { ethReceiver: RECEIVER, amount: AMOUNT, fee: FEE }), (e) => isContract('unexpected')(e) && /Nothing was sent/.test(e.message));
  }
  assert.equal(sent('process_invoke_data').length, 0);
  assert.equal(shown, 0);
  assert.deepEqual(engine.answers, []);
});

test('send: an engine report of other amounts or another fee is refused without being shown', async () => {
  let shown = 0;
  unset = setConsentPresenter(async () => {
    shown++;
    return true;
  });
  for (const consent of [sendConsent(usdt, { fee: '0.012' }), sendConsent(usdt, { amount: '1.00' }), sendConsent(eth)]) {
    engine.respond = recorded({ consent });
    await assert.rejects(svc.send(usdt, { ethReceiver: RECEIVER, amount: AMOUNT, fee: FEE }), isContract('unexpected'));
  }
  assert.equal(shown, 0);
  assert.deepEqual(engine.answers, ['rejected', 'rejected', 'rejected']);
  assert.ok(consentLog().slice(-3).every((o) => o.decision === 'refused'));
  assert.equal(contractsState().inflight, 0);
});

test('send: what the bridge cannot carry is refused before any call', async () => {
  const max = (1n << 63n) - 1n;
  const cap = beam.maxGroth;
  const cases = [
    [usdt, 0n, 100n],
    [usdt, -100n, 100n],
    [usdt, 100n, 0n],
    [beam, max, 1n],
    [beam, 1n << 62n, 1n << 62n],
    [beam, cap + 1n, 1000000n], // 3,000,000 BEAM per crossing, amount and fee each
    [beam, AMOUNT, cap + 1n],
    [usdt, 100000001n, 1000000n], // USDT moves in 100-groth steps (6 decimals on Ethereum)
    [usdt, AMOUNT, 1000050n],
    [usdt, 1, 100n],
  ];
  for (const [r, amount, fee] of cases) await assert.rejects(svc.send(r, { ethReceiver: RECEIVER, amount, fee }), isBridge('badAmount'), `${r.id} ${amount} ${fee}`);
  for (const to of [`0x${'0'.repeat(40)}`, `0x${RECEIVER.slice(2)}`, `0x${RECEIVER}5a`, `0X${RECEIVER}`, `0x${'g'.repeat(40)}`, null]) {
    await assert.rejects(svc.send(usdt, { ethReceiver: to, amount: AMOUNT, fee: FEE }), isBridge('badArgs'), String(to));
  }
  assert.equal(sent('invoke_contract').length, 0);
});

test('send: at the cap and on the grid is fine', async () => {
  const cap = beam.maxGroth;
  const args = pipe.sendArgs({ cid: beam.beamPipeCid, amount: cap, receiver: RECEIVER, relayerFee: cap });
  const raw = invokeData([sendEntry(beam, { args: [...bytes(RECEIVER), ...le(cap, 8), ...le(cap, 8)], spend: { 0: cap + cap } })]);
  unset = setConsentPresenter(async (r) => r.spends[0].amount === cap + cap);
  engine.respond = recorded({ overrides: { [args]: () => ({ output: '{}', raw_data: raw }) }, consent: sendConsent(beam, { amount: '6000000', isEnough: true }) });
  assert.equal(await svc.send(beam, { ethReceiver: RECEIVER, amount: cap, fee: cap }), TXID);
});

/** What the engine reports for a claim of `amount` groth of `r`. */
const claimConsent = (r, amount, { fee = '0.121' } = {}) => ({ info: { comment: 'Receive funds', fee, isEnough: true, isSpend: false }, amounts: [{ amount: (Number(amount) / 1e8).toFixed(8).replace(/\.?0+$/, ''), assetID: r.beamAssetId, spend: false }] });

test('claim: the recorded builds pass, forward and reverse, and are shown as arriving', async () => {
  const seen = [];
  unset = setConsentPresenter(async (r) => {
    seen.push(r);
    return true;
  });
  for (const [id, [msgId, amount]] of Object.entries(RECEIVES)) {
    const r = routeById(id);
    engine.respond = recorded({ consent: claimConsent(r, amount) });
    assert.equal(await svc.claim(r, { msgId, amount }), TXID, id);
    assert.deepEqual(seen.at(-1).receives.map((x) => [x.assetId, x.amount]), [[r.beamAssetId, amount]]);
    assert.equal(seen.at(-1).fee, 12100000n);
    assert.deepEqual(seen.at(-1).intent, { action: 'bridge', direction: 'toBeam', route: id, amount, msgId });
  }
  assert.deepEqual(engine.answers, ['approved', 'approved', 'approved']);
});

test('claim: another amount than the message pays, or the send fee, is refused', async () => {
  let shown = 0;
  unset = setConsentPresenter(async () => {
    shown++;
    return true;
  });
  const [msgId, amount] = RECEIVES.usdt;
  engine.respond = recorded({ consent: claimConsent(usdt, amount) });
  await assert.rejects(svc.claim(usdt, { msgId, amount: amount + 1n }), isContract('unexpected'));
  assert.equal(sent('process_invoke_data').length, 0, 'the built claim pays another amount: refused before the engine sees it again');
  engine.respond = recorded({ consent: claimConsent(usdt, amount, { fee: '0.011' }) });
  await assert.rejects(svc.claim(usdt, { msgId, amount }), isContract('unexpected'));
  assert.equal(shown, 0);
});

test('claim: a message claimed meanwhile - the pipe says so (badPipe); impossible amounts never build', async () => {
  const args = pipe.receiveArgs({ cid: usdt.beamPipeCid, msgId: 78 });
  engine.respond = recorded({ overrides: { [args]: () => ({ output: '{"error": "msg with current id is absent"}' }) } });
  await assert.rejects(svc.claim(usdt, { msgId: 78, amount: 91049000n }), (e) => isBridge('badPipe')(e) && /absent/.test(e.message));
  const before = sent('invoke_contract').length;
  for (const amount of [0n, -1n, 1n << 63n, 5]) await assert.rejects(svc.claim(usdt, { msgId: 78, amount }), isBridge('badAmount'));
  await assert.rejects(svc.claim(usdt, { msgId: -1, amount: 1n }), isBridge('badArgs'));
  assert.equal(sent('invoke_contract').length, before);
});

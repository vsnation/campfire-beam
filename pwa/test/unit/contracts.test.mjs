import test, { beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fakeEngine, TXID } from './helpers/fake_engine.mjs';
import { bindSession, unbindSession, openApp, nativeApp, setConsentPresenter, consentLog, contractsState, ContractError, consentRequest, decimalToGroth, parseShaderJson, NATIVE_APP_NAME, ENGINE_PRIVILEGE_REFUSAL, readsAsWallet } from '../../src/lib/contracts.js';

const tick = () => new Promise((r) => setImmediate(r));
const pwa = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

let engine;
let unset = () => {};
beforeEach(() => {
  engine = fakeEngine();
  bindSession(engine.session);
});
afterEach(() => {
  unset();
  unbindSession();
});

test('approve handlers are registered once per session', async () => {
  bindSession(engine.session);
  bindSession(engine.session);
  assert.deepEqual(engine.handlerSets, { contract: 1, send: 1 });
});

test('ids are unique across apps and every answer reaches the app that asked', async () => {
  const replies = [];
  engine.respond = (req, api) => replies.push({ req, api });
  const a = await openApp({ appName: 'Alpha', appUrl: 'https://a.example' });
  const b = await openApp({ appName: 'Beta', appUrl: 'https://b.example' });
  assert.equal(a.appId, 'appid:Alpha|https://a.example');
  const pa = a.call('wallet_status');
  const pb = b.call('wallet_status');
  const pa2 = a.call('get_asset_info', { asset_id: 1 });
  await tick();
  const ids = replies.map((r) => r.req.id);
  assert.equal(new Set(ids).size, 3, `ids must be unique: ${ids}`);
  // Answer in reverse order.
  for (const r of replies.reverse()) r.api.reply(r.req.id, { who: r.api.appName, method: r.req.method });
  assert.deepEqual(await pa, { who: 'Alpha', method: 'wallet_status' });
  assert.deepEqual(await pb, { who: 'Beta', method: 'wallet_status' });
  assert.deepEqual(await pa2, { who: 'Alpha', method: 'get_asset_info' });
  assert.equal(contractsState().inflight, 0);
});

test('a call nobody answers times out and is forgotten', async () => {
  engine.respond = () => {};
  const a = await openApp({ appName: 'Slow' });
  await assert.rejects(a.call('wallet_status', {}, { timeoutMs: 20 }), (e) => e instanceof ContractError && e.code === 'timeout');
  assert.equal(contractsState().inflight, 0);
});

test('engine errors carry the engine error object', async () => {
  engine.respond = (req, api) => api.replyError(req.id, { code: -32005, message: 'Feature is not supported' });
  const a = await openApp({ appName: 'X' });
  await assert.rejects(a.call('create_address', {}), (e) => e.code === 'rpc' && e.rpc.code === -32005);
});

test("the engine's refusal of raised app privilege (wasm patch 0112) reaches the caller as 'privileged', the engine's error kept", async () => {
  const data = `${ENGINE_PRIVILEGE_REFUSAL} (it asks for privilege 1, this app runs at 0)`;
  engine.respond = (req, api) => {
    if (req.method === 'invoke_contract') return api.reply(req.id, { output: '', raw_data: [1, 2, 3] });
    if (req.method === 'process_invoke_data') return api.replyError(req.id, { code: -32019, message: 'Contract call failed', data });
    return api.reply(req.id, {});
  };
  const app = await openApp({ appName: 'Some dApp' });
  await assert.rejects(app.call('process_invoke_data', { data: [1, 2, 3] }), (e) => e instanceof ContractError && e.code === 'privileged' && /extra privileges\. Nothing was sent\.$/.test(e.message) && e.rpc.code === -32019 && e.rpc.data === data);
  // Any other contract error stays an rpc error.
  engine.respond = (req, api) => api.replyError(req.id, { code: -32019, message: 'Contract call failed', data: 'failed to deserialize invoke data' });
  await assert.rejects(app.call('process_invoke_data', { data: [1, 2, 3] }), (e) => e.code === 'rpc' && e.rpc.data === 'failed to deserialize invoke data');
});

test('engine patch 0112: in the lock, and it sends the text this module matches (the one core patch 0002 sends)', () => {
  const lock = JSON.parse(readFileSync(join(pwa, 'engine.lock.json'), 'utf8'));
  const p = 'scripts/beam/wasm/patches/0112-wasm-refuse-raised-app-privilege.patch';
  assert.ok(lock.patches.includes(p));
  const patch = readFileSync(join(pwa, '..', p), 'utf8');
  const core = readFileSync(join(pwa, '..', 'scripts/beam/core/patches/0002-privileged-shader-allowlist.patch'), 'utf8');
  assert.ok(patch.includes(`+                    throw std::runtime_error("${ENGINE_PRIVILEGE_REFUSAL} (" + why + ")");`));
  assert.ok(core.includes(`std::string("${ENGINE_PRIVILEGE_REFUSAL}")`));
  // Refused above the manager's own privilege, and for a body the manager did not compile.
  assert.match(patch, /\+\s+if \(nAsked > m_Privilege\)/);
  assert.match(patch, /\+\s+else if \(!_privilegedBodies\.count\(hv\)\)/);
});

test('no presenter: every spending request is rejected', async () => {
  const app = await nativeApp();
  await assert.rejects(app.transact('action=pool_trade,bPredictOnly=0', [0]), (e) => e.code === 'rejected' && e.rpc.code === -32021);
  assert.deepEqual(engine.answers, ['rejected']);
  const last = consentLog().at(-1);
  assert.equal(last.decision, 'rejected');
  assert.equal(last.why, 'no_presenter');
});

test('a presenter that throws, or answers anything but true, rejects', async () => {
  const app = await nativeApp();
  unset = setConsentPresenter(async () => {
    throw new Error('screen broke');
  });
  await assert.rejects(app.transact('action=pool_trade,bPredictOnly=0', [0]), (e) => e.code === 'rejected');
  unset = setConsentPresenter(async () => 'yes');
  await assert.rejects(app.transact('action=pool_trade,bPredictOnly=0', [0]), (e) => e.code === 'rejected');
  unset = setConsentPresenter(async () => 1);
  await assert.rejects(app.transact('action=pool_trade,bPredictOnly=0', [0]), (e) => e.code === 'rejected');
  assert.deepEqual(engine.answers, ['rejected', 'rejected', 'rejected']);
});

test('the presenter sees what the engine reported, for the app that asked; true approves', async () => {
  const seen = [];
  unset = setConsentPresenter(async (req) => {
    seen.push(req);
    return true;
  });
  const dapp = await openApp({ appName: 'Some DEX', appUrl: 'https://dex.example' });
  const native = await nativeApp();
  const t1 = await dapp.transact('action=pool_trade,bPredictOnly=0', new Uint8Array([1, 2]), { intent: { action: 'swap' } });
  const t2 = await native.transact('action=pool_trade,bPredictOnly=0', [1, 2], { intent: { action: 'swap' } });
  assert.equal(t1, TXID);
  assert.equal(t2, TXID);
  assert.equal(seen[0].appName, 'Some DEX');
  assert.equal(seen[0].native, false);
  assert.equal(seen[0].intent, null, 'only the wallet itself may describe its request');
  assert.equal(seen[1].appName, NATIVE_APP_NAME);
  assert.equal(seen[1].native, true);
  assert.deepEqual(seen[1].intent, { action: 'swap' });
  const r = seen[1];
  assert.equal(r.kind, 'contract');
  assert.equal(r.fee, 1100000n);
  assert.equal(r.isEnough, true);
  assert.deepEqual(r.spends, [{ assetId: 0, amount: 1000000n, amountText: '0.01' }]);
  assert.deepEqual(r.receives, [{ assetId: 174, amount: 37176133894n, amountText: '371.76133894' }]);
  assert.ok(r.signal && r.signal.aborted === false);
  assert.deepEqual(engine.answers, ['approved', 'approved']);
  // create_tx is always false through the app API.
  const invokes = engine.apis.flatMap((a) => a.sent).filter((q) => q.method === 'invoke_contract');
  assert.ok(invokes.every((q) => q.params.create_tx === false));
  assert.deepEqual(invokes[0].params.contract, [1, 2], 'shader bytes travel as a plain array');
});

test('one consent at a time', async () => {
  let open = 0;
  let maxOpen = 0;
  unset = setConsentPresenter(async () => {
    open++;
    maxOpen = Math.max(maxOpen, open);
    await new Promise((r) => setTimeout(r, 10));
    open--;
    return false;
  });
  const a = await openApp({ appName: 'A' });
  const b = await openApp({ appName: 'B' });
  const r = await Promise.allSettled([a.transact('x=1,bPredictOnly=0', [0]), b.transact('x=2,bPredictOnly=0', [0])]);
  assert.equal(maxOpen, 1);
  assert.ok(r.every((x) => x.status === 'rejected' && x.reason.code === 'rejected'));
});

test('expect() refuses a request that is not what was asked, without showing it', async () => {
  let shown = 0;
  unset = setConsentPresenter(async () => {
    shown++;
    return true;
  });
  const app = await nativeApp();
  await assert.rejects(
    app.transact('action=pool_trade,bPredictOnly=0', [0], { expect: (req) => (req.receives[0].amount < 40000000000n ? { code: 'priceMoved', message: 'moved' } : null) }),
    (e) => e.code === 'priceMoved' && e.message === 'moved',
  );
  assert.equal(shown, 0);
  assert.deepEqual(engine.answers, ['rejected']);
  assert.equal(consentLog().at(-1).decision, 'refused');
});

test('locking withdraws a pending consent: the screen is told, the engine hears No, calls end', async () => {
  let signal = null;
  unset = setConsentPresenter((req) => {
    signal = req.signal;
    return new Promise(() => {}); // the person never answers
  });
  const app = await openApp({ appName: 'Pending' });
  const p = app.transact('action=pool_trade,bPredictOnly=0', [0]);
  while (!signal) await tick();
  unbindSession();
  assert.equal(signal.aborted, true);
  assert.deepEqual(engine.answers, ['rejected']);
  await assert.rejects(p, (e) => e.code === 'locked');
  assert.equal(app.closed, true);
  assert.ok(engine.deleted >= 1, 'the app API handle is released');
  await assert.rejects(openApp({ appName: 'After' }), (e) => e.code === 'no_wallet');
});

test('closing an app withdraws its consent and rejects its calls', async () => {
  let signal = null;
  unset = setConsentPresenter((req) => {
    signal = req.signal;
    return new Promise((resolve) => req.signal.addEventListener('abort', () => resolve(true))); // a late yes must not count
  });
  const app = await openApp({ appName: 'Closer' });
  const p = app.transact('action=pool_trade,bPredictOnly=0', [0]);
  while (!signal) await tick();
  app.close();
  await assert.rejects(p, (e) => e.code === 'closed');
  await tick();
  assert.deepEqual(engine.answers, ['rejected']);
});

test('a consent for a request this module did not send is rejected', async () => {
  unset = setConsentPresenter(async () => true);
  const cb = engine.callback({ reply() {}, replyError() {} }, JSON.stringify({ jsonrpc: '2.0', id: 'stranger', method: 'process_invoke_data' }));
  engine.contractHandler(JSON.stringify({ jsonrpc: '2.0', id: 'stranger', method: 'process_invoke_data' }), JSON.stringify({ fee: '0.011', isEnough: true }), '[]', cb);
  await tick();
  assert.deepEqual(engine.answers, ['rejected']);
});

test('tx_send through an app asks as a send, with the address', async () => {
  let seen = null;
  unset = setConsentPresenter(async (req) => {
    seen = req;
    return false;
  });
  const app = await openApp({ appName: 'Payer' });
  await assert.rejects(app.call('tx_send', { address: 'x', value: 150000000 }), (e) => e.code === 'rejected');
  assert.equal(seen.kind, 'send');
  assert.equal(seen.address, 'f'.repeat(66));
  assert.deepEqual(seen.spends, [{ assetId: 0, amount: 150000000n, amountText: '1.5' }]);
  assert.equal(seen.fee, 100000n);
});

test('view: parsed output, exact big numbers, shader errors and stray transactions refused', async () => {
  const a = await openApp({ appName: 'Viewer' });
  engine.respond = (req, api) => api.reply(req.id, { output: '{"res": [{"tok1": 123456789012345678901, "k": "0.5"}]}' });
  assert.deepEqual(await a.view('action=pools_view', [0]), { res: [{ tok1: '123456789012345678901', k: '0.5' }] });
  engine.respond = (req, api) => api.reply(req.id, { output: '{"error": "no such pool"}' });
  await assert.rejects(a.view('action=pool_view', [0]), (e) => e.code === 'shader' && e.message === 'no such pool');
  engine.respond = (req, api) => api.reply(req.id, { output: '{}', raw_data: [9] });
  await assert.rejects(a.view('action=pool_trade', [0]), (e) => e.code === 'unexpected');
});

test('events reach the app that subscribed', async () => {
  const a = await openApp({ appName: 'Evented' });
  const got = [];
  a.onEvent((id, r) => got.push([id, r]));
  engine.apis.at(-1).event('ev_system_state', { current_height: 5 });
  assert.deepEqual(got, [['ev_system_state', { current_height: 5 }]]);
});

test("an app may not borrow the wallet's own name", async () => {
  await assert.rejects(openApp({ appName: 'BEAM  campfire' }), (e) => e.code === 'reserved_name');
  await assert.rejects(openApp({ appName: '‮' }), (e) => e.code === 'open');
});

test("an app or its publisher may not use a name that reads as the wallet's own", async () => {
  const pub = (name) => ({ key: '02' + 'ab'.repeat(32), name });
  // Accents, Cyrillic and Greek letters, digits for letters, other spacing, extra words.
  for (const appName of ['BEAM Campf\u00edre', '\u0412\u0415\u0410\u041c Campfire', 'BEAM C\u0430mpfire', '8EAM Campf1re', 'BEAM-Campfire', 'BEAMCAMPFIRE', 'BEAM Campfire Security', 'Official BEAM Campfire', 'Beam PWA Security', 'Official Beam PWA', 'B\u0435am P.W.A', 'BEAMPWA']) {
    await assert.rejects(openApp({ appName }), (e) => e.code === 'reserved_name', appName);
  }
  for (const name of ['BEAM Campf\u00edre', 'B\u0395AM Campfire', 'BEAM Campfire Team', 'Beam PWA Team']) {
    await assert.rejects(openApp({ appName: 'Some dApp', publisher: pub(name) }), (e) => e.code === 'reserved_name', name);
  }
  // Names that only share a word still open.
  for (const appName of ['Campfire Games', 'Beam DEX', 'BEAM NFT Gallery']) assert.equal((await openApp({ appName, publisher: pub('Campfire Studio') })).appName, appName);
  assert.equal(readsAsWallet(NATIVE_APP_NAME), true);
  assert.equal(readsAsWallet(''), false);
});

// Audit BC-5: the florin (U+0192) and the small digamma (U+03DD) read as "f" but were dropped by
// skeleton(), so "BEAM Campƒire" opened as a dApp. Both map to F now; and any spelling within one
// edit of the wallet's own (a letter added, dropped, changed or two swapped, as "ſ" folds to S)
// is refused for an app or publisher name, also inside a longer name.
test("BC-5: look-alikes of f, and names one edit from the wallet's, are refused; unrelated names still open", async () => {
  const { skeleton } = await import('../../src/lib/lookalike.js');
  assert.equal(skeleton('\u0192'), 'F');
  assert.equal(skeleton('\u03dd'), 'F');
  const near = ['BEAM Camp\u0192ire', 'BEAM Camp\u03ddire', 'BEAM Camp\u017fire', 'BEAM Campfie', 'BEAM Camppfire', 'BEAM Cmapfire', 'BEAM Canpfire', 'BEAM Campsire Security', 'Official BEAM Campfir', 'BEAN Campfire'];
  for (const appName of near) {
    assert.equal(readsAsWallet(appName), true, appName);
    await assert.rejects(openApp({ appName }), (e) => e.code === 'reserved_name', appName);
  }
  await assert.rejects(openApp({ appName: 'Some dApp', publisher: { key: '02' + 'ab'.repeat(32), name: 'BEAM Camp\u0192ire' } }), (e) => e.code === 'reserved_name');
  // The name people see (Beam PWA) is matched as it reads, not within one edit: at seven letters that
  // would take in other names.
  for (const appName of ['Campfire Games', 'Beam DEX', 'BEAM NFT Gallery', 'BEAM Camp', 'Beam Campaign', 'Campfire Studio', 'BEAM Fire', 'BeamSwap', 'Beam PWR', 'Beam Pay']) {
    assert.equal(readsAsWallet(appName), false, appName);
  }
});

test('engine amounts: decimal text to groth, nothing else accepted', () => {
  assert.equal(decimalToGroth('0.011'), 1100000n);
  assert.equal(decimalToGroth('371.76133894'), 37176133894n);
  assert.equal(decimalToGroth('5'), 500000000n);
  assert.throws(() => decimalToGroth('1e5'));
  assert.throws(() => decimalToGroth('-1'));
  assert.throws(() => decimalToGroth('0.123456789'));
  assert.deepEqual(parseShaderJson('{"a": 9007199254740993, "b": 12}'), { a: '9007199254740993', b: 12 });
});

test('consentRequest refuses unreadable engine reports', () => {
  const app = { appId: 'a', appName: 'A', native: false };
  assert.throws(() => consentRequest('contract', app, 1, '{"fee":"x"}', '[]'));
  assert.throws(() => consentRequest('contract', app, 1, '{"fee":"0.011"}', '[{"amount":"1","assetID":-1,"spend":true}]'));
  assert.throws(() => consentRequest('contract', app, 1, '{"fee":"0.011"}', '{}'));
  const ok = consentRequest('contract', app, 1, '{"fee":"0.011","isEnough":false}', '[]');
  assert.equal(ok.isEnough, false);
});

test('a closed app keeps its engine handle until the engine has answered what was sent through it', async () => {
  const held = [];
  engine.respond = (req, api) => held.push({ req, api });
  const app = await openApp({ appName: 'Busy' });
  const p = app.call('invoke_contract', { args: 'role=manager,action=view', create_tx: false });
  await tick();
  app.close();
  await assert.rejects(p, (e) => e.code === 'closed');
  assert.equal(engine.deleted, 0, 'not released while the engine still runs its request');
  held[0].api.reply(held[0].req.id, { output: '{}' });
  await tick();
  assert.equal(engine.deleted, 1, 'released once the engine answered');
  // Nothing outstanding: released at once.
  engine.respond = (req, api) => api.reply(req.id, { ok: 1 });
  const idle = await openApp({ appName: 'Idle' });
  await idle.call('get_version');
  idle.close();
  assert.equal(engine.deleted, 2);
});

test('a session that ends releases closed apps still waiting on the engine', async () => {
  engine.respond = () => {};
  const app = await openApp({ appName: 'Stuck' });
  app.call('invoke_contract', { args: 'a=b', create_tx: false }).catch(() => {});
  await tick();
  app.close();
  assert.equal(engine.deleted, 0);
  unbindSession();
  assert.equal(engine.deleted, 1);
});

test('inspect reads the built bytes before the engine sees them again; null lets the request on to consent', async () => {
  const seen = [];
  let shown = 0;
  unset = setConsentPresenter(async () => {
    shown++;
    return true;
  });
  const app = await nativeApp();
  const txId = await app.transact('action=pool_trade,bPredictOnly=0', [0], {
    inspect: (bytes) => {
      seen.push({ bytes, sentYet: engine.apis.flatMap((a) => a.sent).some((q) => q.method === 'process_invoke_data') });
      bytes[0] = 99; // a copy: what is sent is what the engine built
      return null;
    },
  });
  assert.equal(txId, TXID);
  assert.equal(seen.length, 1);
  assert.ok(seen[0].bytes instanceof Uint8Array);
  assert.equal(seen[0].sentYet, false, 'inspect runs before process_invoke_data');
  assert.equal(shown, 1);
  const pid = engine.apis.flatMap((a) => a.sent).filter((q) => q.method === 'process_invoke_data');
  assert.deepEqual(pid.map((q) => q.params.data), [[1, 2, 3]]);
});

test("inspect also gets the shader's parsed answer, large integers kept exact", async () => {
  const fallback = engine.respond;
  engine.respond = (req, api) => (req.method === 'invoke_contract' ? api.reply(req.id, { output: '{"res": {"batch": 18446744073709551615, "n": 2}}', raw_data: [4, 5] }) : fallback(req, api));
  unset = setConsentPresenter(async () => true);
  const app = await nativeApp();
  const got = [];
  await app.transact('action=create', [0], {
    inspect: (bytes, output) => {
      got.push({ bytes: [...bytes], output });
    },
  });
  assert.deepEqual(got, [{ bytes: [4, 5], output: { res: { batch: '18446744073709551615', n: 2 } } }]);
});

test('an inspect refusal (returned or thrown) sends nothing and shows nothing', async () => {
  let shown = 0;
  unset = setConsentPresenter(async () => {
    shown++;
    return true;
  });
  const app = await nativeApp();
  await assert.rejects(
    app.transact('action=pool_trade,bPredictOnly=0', [0], { inspect: () => ({ code: 'unexpected', message: 'Not what you asked for. Nothing was sent.' }) }),
    (e) => e instanceof ContractError && e.code === 'unexpected' && e.message === 'Not what you asked for. Nothing was sent.',
  );
  await assert.rejects(
    app.transact('action=pool_trade,bPredictOnly=0', [0], {
      inspect: async () => {
        throw new Error('cannot read it');
      },
    }),
    (e) => e.code === 'unexpected' && e.message === 'cannot read it',
  );
  await assert.rejects(app.transact('action=pool_trade,bPredictOnly=0', [0], { inspect: () => 'no' }), (e) => e.code === 'refused' && e.message === 'no');
  assert.equal(engine.apis.flatMap((a) => a.sent).filter((q) => q.method === 'process_invoke_data').length, 0);
  assert.equal(shown, 0);
  assert.deepEqual(engine.answers, []);
  assert.equal(contractsState().inflight, 0);
});

test('with inspect, raw_data that is not all bytes is refused before inspect runs', async () => {
  engine.respond = (req, api) => api.reply(req.id, { output: '', raw_data: [1, 256, 3] });
  const app = await nativeApp();
  let ran = false;
  await assert.rejects(
    app.transact('x=1', [0], {
      inspect: () => {
        ran = true;
        return null;
      },
    }),
    (e) => e.code === 'unexpected',
  );
  assert.equal(ran, false);
  assert.equal(engine.apis.flatMap((a) => a.sent).filter((q) => q.method === 'process_invoke_data').length, 0);
});

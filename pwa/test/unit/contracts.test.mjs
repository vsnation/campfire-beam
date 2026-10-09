import test, { beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { bindSession, unbindSession, openApp, nativeApp, setConsentPresenter, consentLog, contractsState, ContractError, consentRequest, decimalToGroth, parseShaderJson, NATIVE_APP_NAME } from '../../src/lib/contracts.js';

const TXID = 'ab'.repeat(16);
const tick = () => new Promise((r) => setImmediate(r));

/**
 * A stand-in for the engine's WasmWalletClient and its app API, shaped like
 * wasmclient.cpp: createAppAPI(id, name, cb(err, api)); api.callWalletApi(json);
 * api.setHandler(fn); approve handlers get (request, info, amounts, cb).
 */
function fakeEngine({ respond } = {}) {
  const engine = { apis: [], handlerSets: { contract: 0, send: 0 }, contractHandler: null, sendHandler: null, deleted: 0, answers: [] };
  engine.respond =
    respond ||
    ((req, api) => {
      if (req.method === 'invoke_contract') {
        if (req.params.args.includes('bPredictOnly=0') || req.params.args.includes('action=tx')) return api.reply(req.id, { output: '', raw_data: [1, 2, 3] });
        return api.reply(req.id, { output: '{"res": {"ok": 1}}' });
      }
      if (req.method === 'process_invoke_data') return engine.askContract(api, req, { comment: 'Amm trade', fee: '0.011', isEnough: true, isSpend: true }, [{ amount: '0.01', assetID: 0, spend: true }, { amount: '371.76133894', assetID: 174, spend: false }]);
      if (req.method === 'tx_send') return engine.askSend(api, req, { comment: '', fee: '0.001', token: 'f'.repeat(66), isOnline: true, isSpend: true, isEnough: true, amount: '1.5', assetID: 0 });
      return api.reply(req.id, { echo: req.method });
    });
  engine.askContract = (api, req, info, amounts) => {
    const text = JSON.stringify(req);
    setImmediate(() => engine.contractHandler(text, JSON.stringify(info), JSON.stringify(amounts), engine.callback(api, text)));
  };
  engine.askSend = (api, req, info) => {
    const text = JSON.stringify(req);
    setImmediate(() => engine.sendHandler(text, JSON.stringify(info), engine.callback(api, text)));
  };
  engine.callback = (api, original) => {
    const answer = (approved) => (request) => {
      assert.equal(request, original, 'the engine gets back the request it sent');
      engine.answers.push(approved ? 'approved' : 'rejected');
      const id = JSON.parse(request).id;
      if (approved) api.reply(id, { txid: TXID });
      else api.replyError(id, { code: -32021, message: 'Call is rejected by user' });
    };
    return { contractInfoApproved: answer(true), contractInfoRejected: answer(false), sendApproved: answer(true), sendRejected: answer(false), delete() {} };
  };
  engine.client = {
    setApproveContractInfoHandler(fn) {
      engine.handlerSets.contract++;
      engine.contractHandler = fn;
    },
    setApproveSendHandler(fn) {
      engine.handlerSets.send++;
      engine.sendHandler = fn;
    },
    createAppAPI(appId, appName, cb) {
      const api = {
        appId,
        appName,
        handler: null,
        sent: [],
        setHandler(fn) {
          this.handler = fn;
        },
        callWalletApi(s) {
          const req = JSON.parse(s);
          this.sent.push(req);
          engine.respond(req, this);
        },
        reply(id, result) {
          setImmediate(() => this.handler && this.handler(JSON.stringify({ jsonrpc: '2.0', id, result })));
        },
        replyError(id, error) {
          setImmediate(() => this.handler && this.handler(JSON.stringify({ jsonrpc: '2.0', id, error })));
        },
        event(id, result) {
          this.handler && this.handler(JSON.stringify({ jsonrpc: '2.0', id, result }));
        },
        delete() {
          engine.deleted++;
        },
      };
      engine.apis.push(api);
      setImmediate(() => cb(undefined, api));
    },
  };
  engine.session = { client: engine.client, M: { WasmWalletClient: { GenerateAppID: (n, u) => `appid:${n}|${u}` } } };
  return engine;
}

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
  await assert.rejects(openApp({ appName: 'BEAM  campfire' }), (e) => e.code === 'open');
  await assert.rejects(openApp({ appName: '‮' }), (e) => e.code === 'open');
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

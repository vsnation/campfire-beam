// Release audit RE3-3: the engine runs one shader call (invoke_contract) at a time per app API and
// refuses a second while the first runs (wallet/api/v6_0/v6_api_handle.cpp: jsonrpc_exception
// UnexpectedError, "Previous shader call is still in progress"). The app's own screens used to send
// two at once (the bridge list beside its timer, a claim beside a poll), and the second came back as
// "Unexpected call". Now an app's shader calls wait their turn, and a refusal that still happens is
// said in plain words.
import test, { beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { fakeEngine } from './helpers/fake_engine.mjs';
import { bindSession, unbindSession, openApp, ContractError, ENGINE_SHADER_BUSY, SHADER_BUSY_TEXT } from '../../src/lib/contracts.js';

const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));
const SHADER = Uint8Array.from([0, 97, 115, 109]);

let engine;
let log;
/** Like the engine: one invoke_contract per app at a time, answered after `ms`; a second one is refused. */
function oneAtATime(ms = 5) {
  const busy = new Map();
  return (req, api) => {
    log.push(`sent ${api.appName} ${req.method} ${req.params && req.params.args ? req.params.args : ''}`.trim());
    if (req.method !== 'invoke_contract') return api.reply(req.id, { echo: req.method });
    if (busy.get(api)) return api.replyError(req.id, { code: -32017, message: 'Unexpected call', data: ENGINE_SHADER_BUSY });
    busy.set(api, true);
    setTimeout(() => {
      busy.set(api, false);
      log.push(`answered ${api.appName} ${req.params.args}`);
      api.reply(req.id, { output: JSON.stringify({ args: req.params.args }) });
    }, ms);
  };
}

beforeEach(() => {
  engine = fakeEngine();
  log = [];
  engine.respond = oneAtATime();
  bindSession(engine.session);
});
afterEach(() => unbindSession());

test("two views of one app at once: the second waits for the first, both answer; nothing is refused", async () => {
  const app = await openApp({ appName: 'Wallet views' });
  const [a, b, c] = await Promise.all([app.view('action=a', SHADER), app.view('action=b', SHADER), app.view('action=c', SHADER)]);
  assert.deepEqual([a.args, b.args, c.args], ['action=a', 'action=b', 'action=c']);
  assert.deepEqual(log, [
    'sent Wallet views invoke_contract action=a',
    'answered Wallet views action=a',
    'sent Wallet views invoke_contract action=b',
    'answered Wallet views action=b',
    'sent Wallet views invoke_contract action=c',
    'answered Wallet views action=c',
  ]);
});

test('other methods, and other apps, never wait for a shader call', async () => {
  const one = await openApp({ appName: 'One' });
  const two = await openApp({ appName: 'Two' });
  const v1 = one.view('action=slow', SHADER);
  const status = one.call('wallet_status');
  const v2 = two.view('action=other', SHADER);
  await tick();
  assert.deepEqual(log.slice().sort(), ['sent One invoke_contract action=slow', 'sent One wallet_status', 'sent Two invoke_contract action=other'], 'all three sent before any shader call was answered');
  await Promise.all([v1, status, v2]);
});

test('a refusal the engine still sends (a call that timed out here but runs on there) is "busy", in plain words', async () => {
  engine.respond = oneAtATime(60);
  const app = await openApp({ appName: 'Slow' });
  await assert.rejects(app.view('action=first', SHADER, { timeoutMs: 15 }), (e) => e.code === 'timeout');
  await assert.rejects(app.view('action=second', SHADER), (e) => e instanceof ContractError && e.code === 'busy' && e.message === SHADER_BUSY_TEXT && e.rpc.code === -32017 && e.rpc.data === ENGINE_SHADER_BUSY);
  assert.equal(SHADER_BUSY_TEXT, 'Beam PWA is busy with another check. Try again in a moment.');
  // ...and once the engine is done, the next one goes through.
  await tick(80);
  assert.deepEqual(await app.view('action=third', SHADER), { args: 'action=third' });
});

test('a call whose time runs out while it waits behind another rejects then, and is never sent', async () => {
  engine.respond = (req, api) => {
    log.push(`sent ${req.params.args}`);
    if (req.params.args === 'action=hangs') return; // deferred by the engine (a wallet not in sync)
    api.reply(req.id, { output: '{}' });
  };
  const app = await openApp({ appName: 'Deferred' });
  const t0 = Date.now();
  const first = app.view('action=hangs', SHADER, { timeoutMs: 60 });
  await assert.rejects(app.view('action=behind', SHADER, { timeoutMs: 20 }), (e) => e.code === 'timeout');
  assert.ok(Date.now() - t0 < 55, 'at its own time, not after the call ahead of it');
  await assert.rejects(first, (e) => e.code === 'timeout');
  await tick(5);
  assert.deepEqual(log, ['sent action=hangs'], 'the one behind was never sent');
});

test('a call that fails frees the turn; a call waiting when the app closes is refused and never sent', async () => {
  const app = await openApp({ appName: 'Closing' });
  engine.respond = (req, api) => {
    log.push(`sent ${req.params.args}`);
    if (req.params.args === 'action=bad') return api.replyError(req.id, { code: -32019, message: 'Contract call failed', data: 'bad args' });
    return oneAtATime()(req, api);
  };
  const bad = app.view('action=bad', SHADER);
  const good = app.view('action=good', SHADER);
  await assert.rejects(bad, (e) => e.code === 'rpc');
  assert.equal((await good).args, 'action=good');
  const held = app.view('action=held', SHADER);
  const waiting = app.view('action=waiting', SHADER);
  app.close();
  await assert.rejects(held, (e) => e.code === 'closed');
  await assert.rejects(waiting, (e) => e.code === 'closed');
  assert.ok(!log.some((l) => /action=waiting/.test(l)), 'never reached the engine');
});

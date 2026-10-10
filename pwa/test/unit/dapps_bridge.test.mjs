// The bridge between a dApp frame and the wallet: the frame's policy, the
// messages accepted from a frame, the session's rules, and that nothing
// but the frame's own port reaches the runner.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { frameCsp, frameHeaders, frameDocument, frameRouteFor, parsePolicySegment, policySegment, remoteMaskFor, REMOTE_ORIGINS, FRAME_ROUTE, newNonce } from '../../src/lib/dapps/frame_policy.js';
import { validateFrameMessage } from '../../src/lib/dapps/messages.js';
import { DappSession } from '../../src/lib/dapps/session.js';
import { invokeData, invokeEntry } from './helpers/invoke_builder.mjs';
import { BANS_CID } from '../../src/lib/dapps/policy.js';

const pwa = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const req = (id, method, params) => JSON.stringify({ jsonrpc: '2.0', id, method, params });
const parse = (s) => JSON.parse(s);

// ------------------------------------------------------------ frame policy
test('frame policy: a sandboxed, opaque document that can reach nothing of the wallet', () => {
  const nonce = newNonce();
  const csp = frameCsp({ evalAllowed: false, remoteOrigins: [], nonce });
  assert.match(csp, /^sandbox allow-scripts;/);
  assert.ok(!/allow-same-origin|allow-popups|allow-top-navigation|allow-forms|allow-modals/.test(csp));
  const fetchDirectives = csp.split('; ').filter((d) => !d.startsWith('frame-ancestors'));
  assert.ok(!fetchDirectives.join(';').includes("'self'"), "no 'self' to load from: the wallet origin is not the frame's to reach (only frame-ancestors names it: only the wallet may embed a frame)");
  assert.ok(!csp.includes('unsafe-eval'));
  assert.ok(csp.includes(`script-src 'nonce-${nonce}' blob:`));
  assert.ok(csp.includes("connect-src blob: data:;"));
  assert.ok(csp.includes("frame-ancestors 'self'"));
  for (const d of ["frame-src 'none'", "worker-src 'none'", "object-src 'none'", "base-uri 'none'", "form-action 'none'"]) assert.ok(csp.includes(d), d);
  const wide = frameCsp({ evalAllowed: true, remoteOrigins: REMOTE_ORIGINS, nonce });
  assert.ok(wide.includes("'unsafe-eval'"));
  assert.ok(wide.includes(`connect-src blob: data: ${REMOTE_ORIGINS.join(' ')}`));
  const h = frameHeaders({ evalAllowed: false, remoteOrigins: [] }, nonce);
  assert.equal(h['Cross-Origin-Embedder-Policy'], 'require-corp');
  assert.equal(h['Cache-Control'], 'no-store');
  assert.throws(() => frameCsp({ evalAllowed: false, remoteOrigins: [], nonce: "x' 'unsafe-inline" }));
});

test('frame policy: only well-formed policy segments, only known remote origins', () => {
  assert.equal(policySegment({ evalAllowed: true, remoteMask: 3 }), 'e1r3');
  assert.deepEqual(parsePolicySegment('e0r2'), { evalAllowed: false, remoteMask: 2, remoteOrigins: [REMOTE_ORIGINS[1]] });
  for (const bad of ['e2r0', 'e1r4', 'e1r01', 'e1', 'E1r0', 'e1r0x', '', 'e1r-1']) assert.equal(parsePolicySegment(bad), null, bad);
  assert.equal(remoteMaskFor(REMOTE_ORIGINS), 3);
  assert.throws(() => remoteMaskFor(['https://evil.example']));
  assert.deepEqual(frameRouteFor(`${FRAME_ROUTE}e1r1/app/index.html`), { evalAllowed: true, remoteMask: 1, remoteOrigins: [REMOTE_ORIGINS[0]] });
  for (const bad of ['index.html', `${FRAME_ROUTE}e1r1/`, `${FRAME_ROUTE}e1r1`, `${FRAME_ROUTE}e9r1/app/index.html`, `${FRAME_ROUTE}/app/index.html`]) assert.equal(frameRouteFor(bad), null, bad);
});

test('frame document: the bootstrap only, under the nonce', () => {
  const script = readFileSync(join(pwa, 'src', 'dapp-frame.js'), 'utf8');
  assert.ok(!/<\/script/i.test(script));
  assert.ok(/^[\x09\x0a\x0d\x20-\x7e]*$/.test(script), 'ASCII only');
  const doc = frameDocument(script, 'abcdefghijklmnop0123');
  assert.ok(doc.includes('<script nonce="abcdefghijklmnop0123">'));
  assert.throws(() => frameDocument('x</script><script>alert(1)', 'abcdefghijklmnop0123'));
});

// ------------------------------------------------------------ messages
test('frame messages: known types with bounded, typed fields; everything else is dropped', () => {
  assert.deepEqual(validateFrameMessage({ t: 'rpc', json: '{}' }), { t: 'rpc', json: '{}' });
  assert.deepEqual(validateFrameMessage({ t: 'ready', extra: 1 }), { t: 'ready' });
  assert.deepEqual(validateFrameMessage({ t: 'hello', apiver: '7.0', apivermin: 7, appname: 'x'.repeat(65) }), { t: 'hello', apiver: '7.0', apivermin: null, appname: null });
  assert.deepEqual(validateFrameMessage({ t: 'open-link', url: 'https://explorer.beam.mw/block?h=1' }), { t: 'open-link', url: 'https://explorer.beam.mw/block?h=1' });
  assert.deepEqual(validateFrameMessage({ t: 'layout', width: 860, viewport: 390, x: 1 }), { t: 'layout', width: 860, viewport: 390 });
  assert.equal(validateFrameMessage({ t: 'layout', width: '860', viewport: 390 }), null);
  for (const bad of [null, 'rpc', [], {}, { t: 'nope' }, { t: 'rpc' }, { t: 'rpc', json: '' }, { t: 'rpc', json: 5 }, { t: 'rpc', json: 'x'.repeat(8 * 1024 * 1024 + 1) }, { t: 'pong', n: 1.5 }, { t: 'open-link', url: 'javascript:alert(1)' }, { t: 'open-link', url: 'http://plain.example' }, { t: 'open-link', url: 'https://user:pw@x.example' }, { t: 'open-link', url: 'not a url' }, { t: 'campfire-port' }, { t: 'start', files: [] }]) {
    assert.equal(validateFrameMessage(bad), null, JSON.stringify(bad)?.slice(0, 60));
  }
});

// ------------------------------------------------------------ session
function fakeApp() {
  const calls = [];
  return {
    calls,
    async call(method, params) {
      calls.push({ method, params });
      if (method === 'invoke_contract') return { output: '{"res":[]}' };
      if (method === 'process_invoke_data') {
        const e = new Error('rejected');
        e.rpc = { code: -32021, message: 'Call is rejected by user' };
        throw e;
      }
      return { ok: method };
    },
  };
}

test('session: create_tx true, blocked and unknown methods never reach the wallet', async () => {
  const app = fakeApp();
  const s = new DappSession({ appName: 'Beam DEX', app, confirmSign: async () => true, apiVersion: '7.0' });
  assert.equal(parse(await s.handle(req(1, 'invoke_contract', { args: 'a=b', create_tx: true }))).error.code, -32020);
  assert.equal(parse(await s.handle(req(2, 'get_utxo', {}))).error.code, -32020);
  assert.equal(parse(await s.handle(req(3, 'export_owner_key', {}))).error.code, -32601);
  assert.equal(parse(await s.handle('not json')).error.code, -32600);
  assert.equal(app.calls.length, 0);
  const r = parse(await s.handle(req('call-4', 'invoke_contract', { args: 'action=view', contract: [1, 2, 3], contract_file: '/etc/passwd' })));
  assert.equal(r.id, 'call-4');
  assert.deepEqual(app.calls[0], { method: 'invoke_contract', params: { args: 'action=view', contract: [1, 2, 3], create_tx: false } });
});

test("session: a call without the shader gets this dApp's own last shader, never another's", async () => {
  const app = fakeApp();
  const s = new DappSession({ appName: 'x', app, confirmSign: async () => true });
  assert.equal(parse(await s.handle(req(1, 'invoke_contract', { args: 'a=b' }))).error.code, -32602);
  await s.handle(req(2, 'invoke_contract', { args: 'a=b', contract: [9, 9] }));
  await s.handle(req(3, 'invoke_contract', { args: 'c=d' }));
  assert.deepEqual(app.calls[1].params.contract, [9, 9]);
});

test('session: contract data the policy refuses is answered -32020 and never forwarded; the rest goes to the wallet, which asks', async () => {
  const app = fakeApp();
  const refusedWhy = [];
  const s = new DappSession({ appName: 'x', app, confirmSign: async () => true, onRefused: (w) => refusedWhy.push(w) });
  const bad = invokeData([invokeEntry({ contractId: BANS_CID })]);
  const r1 = parse(await s.handle(req(1, 'process_invoke_data', { data: bad })));
  assert.equal(r1.error.code, -32020);
  assert.match(r1.error.data, /names/);
  assert.equal(app.calls.length, 0);
  assert.equal(refusedWhy.length, 1);
  const ok = invokeData([invokeEntry({ contractId: '729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae69b47bcfdeef9cbf', spend: { 0: 1000 } })]);
  const r2 = parse(await s.handle(req(2, 'process_invoke_data', { data: ok })));
  assert.equal(app.calls.length, 1);
  assert.equal(r2.error.code, -32021, "the engine's own rejection reaches the dApp unchanged");
});

test('session: sign_message is put to the person first; a reserved key is refused without asking', async () => {
  const app = fakeApp();
  const asked = [];
  let answer = false;
  const s = new DappSession({ appName: 'Beam DEX', app, confirmSign: async (q) => (asked.push(q), answer) });
  assert.equal(parse(await s.handle(req(1, 'sign_message', { message: 'hello', key_material: 'aa' }))).error.code, -32021);
  assert.deepEqual(asked, [{ appName: 'Beam DEX', message: 'hello' }]);
  answer = true;
  assert.equal(parse(await s.handle(req(2, 'sign_message', { message: 'hello', key_material: 'aa' }))).result.ok, 'sign_message');
  assert.equal(parse(await s.handle(req(3, 'sign_message', { message: 'hello', key_material: BANS_CID }))).error.code, -32020);
  assert.equal(asked.length, 2);
});

test('session: handshake negotiates like the core; events only when subscribed', async () => {
  const s = new DappSession({ appName: 'x', app: fakeApp(), confirmSign: async () => true });
  assert.equal(s.handshake({ apiver: '9.9', apivermin: '9.0' }), false);
  assert.equal(s.handshake({ apiver: 'current', apivermin: '' }), true);
  assert.equal(s.version, '7.4');
  assert.equal(s.handshake({ apiver: '6.0' }), true);
  assert.equal(parse(await s.handle(req(1, 'wallet_status', {}))).error.code, -32020);
  assert.equal(s.event('ev_txs_changed', { txs: [] }), null);
  s.handshake({ apiver: '7.0' });
  await s.handle(req(2, 'ev_subunsub', { ev_txs_changed: true }));
  assert.equal(parse(s.event('ev_txs_changed', { txs: [] })).id, 'ev_txs_changed');
  assert.equal(s.event('ev_system_state', {}), null);
});

test('session: no more than maxInFlight requests at once', async () => {
  let release;
  const gate = new Promise((r) => (release = r));
  const app = { calls: 0, async call() { this.calls++; await gate; return 1; } };
  const s = new DappSession({ appName: 'x', app, confirmSign: async () => true, limits: { ...(await import('../../src/lib/dapps/sanitizer.js')).DEFAULT_REQUEST_LIMITS, maxInFlight: 2 } });
  const a = s.handle(req(1, 'tx_status', { txId: 'ab'.repeat(16) }));
  const b = s.handle(req(2, 'tx_status', { txId: 'ab'.repeat(16) }));
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(parse(await s.handle(req(3, 'tx_status', { txId: 'ab'.repeat(16) }))).error.code, -32014);
  release();
  await Promise.all([a, b]);
});

// ------------------------------------------------------------ runner: only the port is heard
test('runner: messages posted to the wallet window, or malformed ones on the port, reach no wallet call', async () => {
  const wallet = new EventTarget();
  globalThis.window = wallet;
  globalThis.document = { baseURI: 'http://localhost/', createElement: () => fakeFrame };
  globalThis.fetch = async () => ({ ok: true, text: async () => '/* shim */' });
  let framePort = null;
  const listeners = {};
  const fakeFrame = {
    attrs: {},
    setAttribute(k, v) { this.attrs[k] = v; },
    addEventListener(t, fn) { listeners[t] = fn; },
    remove() {},
    contentWindow: { postMessage(msg, origin, transfer) { if (msg.t === 'campfire-port') framePort = transfer[0]; } },
  };
  const { DappRunner } = await import('../../src/lib/dapps/runner.js');
  const app = fakeApp();
  const r = new DappRunner({ entry: { guid: 'db851322f6674a6da3e84e9953db2ffd', needsEval: true }, manifest: { name: 'Beam DEX', startPath: 'app/index.html', apiVersion: '7.0' }, files: new Map([['app/index.html', new Uint8Array([60])]]), appApi: { ...app, close() {} }, confirmSign: async () => false });
  r.mount({ clientWidth: 390, appendChild() {} });
  assert.ok(fakeFrame.src.endsWith('/src/dapp-run/e1r0/app/index.html'), fakeFrame.src);
  assert.equal(fakeFrame.attrs.sandbox, undefined, 'no sandbox attribute before the first load (the service worker must serve it)');
  listeners.load();
  assert.equal(fakeFrame.attrs.sandbox, 'allow-scripts', 'sandboxed from the first load on');
  assert.ok(framePort, 'the frame got a port on its first load');
  const got = [];
  framePort.onmessage = (e) => got.push(e.data);
  // Forged: a message to the wallet window, as another frame or the dApp could post it.
  wallet.dispatchEvent(Object.assign(new Event('message'), { data: { t: 'rpc', json: req(1, 'invoke_contract', { args: 'a=b', contract: [1] }) } }));
  // Malformed on the port.
  framePort.postMessage({ t: 'rpc', json: 7 });
  framePort.postMessage('rpc');
  await new Promise((x) => setTimeout(x, 30));
  assert.equal(app.calls.length, 0);
  assert.equal(r.session.stats.requests, 0);
  assert.equal(r.dropped, 2);
  // The real thing, on the port.
  framePort.postMessage({ t: 'rpc', json: req('call-1', 'invoke_contract', { args: 'a=b', contract: [1] }) });
  await new Promise((x) => setTimeout(x, 30));
  assert.equal(app.calls.length, 1);
  assert.equal(parse(got.find((m) => m.t === 'deliver').json).id, 'call-1');
  // A second load is pinged; a frame that cannot answer is closed.
  r.close();
  framePort.close();
  delete globalThis.window;
  delete globalThis.document;
});


// Parameter rules and request parsing: ported from the desktop's dapp_request_sanitizer_test.dart.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { RequestSanitizer, DEFAULT_REQUEST_LIMITS } from '../../src/lib/dapps/sanitizer.js';
import { RpcError, RpcFailure, parseRequest } from '../../src/lib/dapps/rpc.js';

const s = new RequestSanitizer();
const run = (method, params) => s.sanitize(method, params);
const rpcError = (code, data) => (e) => e instanceof RpcError && e.code === code && (data === undefined || (data instanceof RegExp ? data.test(String(e.data)) : e.data === data));
const ch = (n) => String.fromCharCode(n);

test('invoke_contract: contract_file and unknown keys are stripped', async () => {
  const out = await run('invoke_contract', { contract_file: '/etc/passwd', contract: [1, 2, 3], args: 'role=manager,action=view', create_tx: false, priority: 1, surprise: true });
  assert.deepEqual(out, { contract: [1, 2, 3], args: 'role=manager,action=view', create_tx: false, priority: 1 });
});

test('invoke_contract: create_tx is forced false when absent', async () => {
  assert.equal((await run('invoke_contract', { args: 'a=b' })).create_tx, false);
});

test('invoke_contract: create_tx true is refused with the core error', async () => {
  await assert.rejects(run('invoke_contract', { args: 'a=b', create_tx: true }), rpcError(-32020, 'Applications must set create_tx to false and use process_contract_data'));
  await assert.rejects(run('invoke_contract', { create_tx: 'false' }), rpcError(-32602));
});

test('invoke_contract: contract must be bytes within the size limit', async () => {
  for (const bad of ['AAEC', [1, 256], [-1], [1.5], null, { 0: 1 }]) await assert.rejects(run('invoke_contract', { contract: bad }), rpcError(-32602), JSON.stringify(bad));
  const small = new RequestSanitizer({ ...DEFAULT_REQUEST_LIMITS, maxShaderBytes: 4, maxArgsLength: 3 });
  await assert.rejects(small.sanitize('invoke_contract', { contract: [1, 2, 3, 4, 5] }), RpcError);
  await assert.rejects(small.sanitize('invoke_contract', { args: 'a=bc' }), RpcError);
});

test('contract_file is stripped from any other method too', async () => {
  assert.deepEqual(await run('tx_status', { txId: 'ab'.repeat(16), contract_file: '/x' }), { txId: 'ab'.repeat(16) });
});

test('privileged shaders: the listed hash is refused, one byte different is just another shader', async () => {
  const shader = [1, 2, 3];
  const custom = new RequestSanitizer(DEFAULT_REQUEST_LIMITS, [createHash('sha256').update(Buffer.from(shader)).digest('hex')]);
  await assert.rejects(custom.sanitize('invoke_contract', { contract: shader }), rpcError(-32020, /reserves for its own name service/));
  assert.deepEqual((await custom.sanitize('invoke_contract', { contract: [1, 2, 4], args: 'a=b' })).contract, [1, 2, 4]);
});

const ok = { address: 'abc', value: 5 };
test('tx_send: accepts the shown keys only', async () => {
  const out = await run('tx_send', { ...ok, asset_id: 7, fee: 100000, comment: 'c', confirm_comment: 'cc', from: 'def', txId: '0123456789abcdef0123456789abcdef', offline: true });
  assert.equal(Object.keys(out).length, 9);
  for (const extra of ['coins', 'contract_file', 'key', 'session']) await assert.rejects(run('tx_send', { ...ok, [extra]: 1 }), rpcError(-32602), extra);
});

test('tx_send: checks types and ranges', async () => {
  for (const bad of [{ value: 5 }, { address: '', value: 5 }, { address: 'abc', value: 0 }, { address: 'abc', value: -5 }, { address: 'abc', value: 5.5 }, { address: 'abc', value: '5' }, { address: 'abc', value: 2 ** 60 }, { ...ok, fee: 0 }, { ...ok, asset_id: -1 }, { ...ok, asset_id: 0x100000000 }, { ...ok, txId: 'xyz' }, { ...ok, offline: 'yes' }, { ...ok, confirm_comment: 'x'.repeat(1025) }, { ...ok, comment: 7 }]) {
    await assert.rejects(run('tx_send', bad), rpcError(-32602), JSON.stringify(bad));
  }
});

test('process_invoke_data: needs data bytes, allows confirm_comment, nothing else', async () => {
  assert.deepEqual(await run('process_invoke_data', { data: [1, 2] }), { data: [1, 2] });
  assert.deepEqual(await run('process_invoke_data', { data: [1], confirm_comment: 'Swap' }), { data: [1], confirm_comment: 'Swap' });
  for (const bad of [{}, { data: [] }, { data: 'AQI=' }, { data: [1], create_tx: true }, { data: [1], confirm_comment: 'x'.repeat(1025) }]) {
    await assert.rejects(run('process_invoke_data', bad), rpcError(-32602), JSON.stringify(bad));
  }
});

test('ev_subunsub: apps may not subscribe to utxo or asset events; unknown, empty or non-bool is invalid', async () => {
  for (const e of ['ev_utxos_changed', 'ev_assets_changed']) await assert.rejects(run('ev_subunsub', { ev_txs_changed: true, [e]: true }), rpcError(-32020));
  assert.deepEqual(await run('ev_subunsub', { ev_txs_changed: true, ev_sync_progress: false }), { ev_txs_changed: true, ev_sync_progress: false });
  await assert.rejects(run('ev_subunsub', { ev_nope: true }), rpcError(-32602, "The event 'ev_nope' is unknown."));
  await assert.rejects(run('ev_subunsub', {}), rpcError(-32602));
  await assert.rejects(run('ev_subunsub', { ev_txs_changed: 1 }), rpcError(-32602));
});

test('sign_message: only message and key_material, as even-length hex', async () => {
  assert.deepEqual(await run('sign_message', { message: 'hi', key_material: 'aB01' }), { message: 'hi', key_material: 'aB01' });
  await assert.rejects(run('sign_message', { message: 'hi', key_material: 'aa', extra: 1 }), rpcError(-32602));
  for (const bad of ['', 'a', 'abc', 'zz', 'aa zz', '0xaa', `aa${ch(0)}`]) await assert.rejects(run('sign_message', { message: 'hi', key_material: bad }), rpcError(-32602), bad);
});

test('sign_message: a message with hidden characters is refused, line breaks are fine', async () => {
  for (const bad of [`pay ${ch(0x202e)}01 BEAM`, `a${ch(0)}b`, `x${ch(0x200b)}y`, `a${ch(0x2028)}b`, '']) await assert.rejects(run('sign_message', { message: bad, key_material: 'aa' }), rpcError(-32602), JSON.stringify(bad));
  assert.equal((await run('sign_message', { message: 'line 1\nline 2', key_material: 'aa' })).message, 'line 1\nline 2');
});

test('request parsing as the core parses it', () => {
  const r = parseRequest('{"jsonrpc":"2.0","id":"call-1","method":"get_version"}', { maxLength: 100 });
  assert.equal(r.id, 'call-1');
  assert.deepEqual(r.params, {});
  for (const bad of ['', 'nope', '[]', '{"jsonrpc":"2.0","id":1.5,"method":"x"}', '{"jsonrpc":"2.0","id":null,"method":"x"}', '{"jsonrpc":"1.0","id":1,"method":"x"}', '{"jsonrpc":"2.0","id":1}', `{"jsonrpc":"2.0","id":1,"method":"${'x'.repeat(100)}"}`]) {
    assert.throws(() => parseRequest(bad, { maxLength: 100 }), RpcFailure, bad);
  }
  for (const odd of ['[1]', 'false', '"a=1"', '7']) assert.deepEqual(parseRequest(`{"jsonrpc":"2.0","id":1,"method":"x","params":${odd}}`, { maxLength: 100 }).params, {}, odd);
});

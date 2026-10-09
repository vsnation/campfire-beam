// The method gate and API versions: ported from the desktop's dapp_method_gate_test.dart,
// plus a check of the table against the desktop's generated one.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { MethodGate, METHOD_TABLE, API_VERSIONS, parseApiVersion, negotiateApiVersion } from '../../src/lib/dapps/gate.js';
import { RpcError } from '../../src/lib/dapps/rpc.js';

const pwa = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const rpcError = (code) => (e) => e instanceof RpcError && e.code === code;

test('parse and negotiate like the core and beam-ui', () => {
  assert.equal(parseApiVersion('current'), '7.4');
  assert.equal(parseApiVersion('6.2'), '6.2');
  for (const bad of ['7.5', '7', ' 7.0', '7.0.0', '', null, undefined, 7]) assert.equal(parseApiVersion(bad), null, String(bad));
  assert.equal(negotiateApiVersion(), '7.4');
  assert.equal(negotiateApiVersion({ wanted: '9.9', minimum: '6.0' }), '6.0');
  assert.equal(negotiateApiVersion({ wanted: '9.9', minimum: '9.0' }), null);
  assert.equal(negotiateApiVersion({ wanted: '9.9' }), null);
  assert.equal(negotiateApiVersion({ wanted: '7.0', minimum: '7.0' }), '7.0');
});

test('allowed methods pass in every version that has them', () => {
  for (const v of API_VERSIONS) {
    const g = new MethodGate(v);
    for (const m of ['tx_send', 'process_invoke_data', 'invoke_contract', 'tx_status', 'addr_list', 'validate_address', 'calc_change']) g.check(m);
  }
});

test('blocked methods are -32020', () => {
  for (const v of API_VERSIONS) {
    const g = new MethodGate(v);
    for (const m of ['get_utxo', 'tx_split', 'tx_asset_issue', 'tx_asset_consume', 'change_password', 'set_confirmations_count', 'swap_create_offer']) {
      assert.throws(() => g.check(m), rpcError(-32020), `${m} in ${v}`);
    }
  }
});

test('unknown methods are -32601', () => {
  const g = new MethodGate('7.4');
  for (const m of ['foo', 'tx_send ', 'TX_SEND', '', 'export_owner_key', '__proto__', 'constructor', 'toString']) assert.throws(() => g.check(m), rpcError(-32601), m);
});

test('version differences follow the core', () => {
  assert.throws(() => new MethodGate('6.0').check('wallet_status'), rpcError(-32020));
  new MethodGate('6.1').check('wallet_status');
  assert.throws(() => new MethodGate('6.0').check('ev_subunsub'), rpcError(-32601));
  assert.throws(() => new MethodGate('7.2').check('assets_list'), rpcError(-32601));
  new MethodGate('7.3').check('assets_list');
  assert.throws(() => new MethodGate('7.3').check('send_message'), rpcError(-32601));
  new MethodGate('7.4').check('send_message');
  assert.deepEqual(new MethodGate('6.2').allowedMethods, new MethodGate('6.1').allowedMethods);
});

test('the 7.4 allowlist is exactly the core one', () => {
  assert.deepEqual(new MethodGate('7.4').allowedMethods, ['addr_list', 'assets_list', 'block_details', 'calc_change', 'create_address', 'delete_address', 'derive_id', 'edit_address', 'ev_subunsub', 'export_payment_proof', 'generate_tx_id', 'get_asset_info', 'get_confirmations_count', 'get_version', 'invoke_contract', 'ipfs_add', 'ipfs_gc', 'ipfs_get', 'ipfs_hash', 'ipfs_pin', 'ipfs_unpin', 'process_invoke_data', 'read_messages', 'send_message', 'sign_message', 'tx_asset_info', 'tx_cancel', 'tx_delete', 'tx_list', 'tx_send', 'tx_status', 'validate_address', 'verify_payment_proof', 'verify_signature', 'wallet_status']);
});

test('the table is the desktop generated table, version by version, method by method', (t) => {
  const dart = join(pwa, '..', 'lib', 'wallets', 'beam', 'dapps', 'dapp_method_table.dart');
  if (!existsSync(dart)) return t.skip('desktop sources not next to the PWA');
  const src = readFileSync(dart, 'utf8');
  const parsed = {};
  for (const m of src.matchAll(/'(\d\.\d)': \{([^}]*)\}/g)) {
    parsed[m[1]] = Object.fromEntries([...m[2].matchAll(/'([a-z_0-9]+)': (true|false)/g)].map((x) => [x[1], x[2] === 'true']));
  }
  assert.deepEqual(Object.keys(parsed), API_VERSIONS);
  for (const v of API_VERSIONS) assert.deepEqual({ ...METHOD_TABLE[v] }, parsed[v], v);
});

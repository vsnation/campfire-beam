// What a dApp may submit through process_invoke_data and sign through sign_message.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { decodeInvokeData, InvokeDataError, FLAG_DEPENDENT, FLAG_SAVE_APP_INVOKE } from '../../src/lib/dapps/invoke_data.js';
import { checkContractData, PolicyRefusal, RESERVED_KEYS, BANS_CID, VAULT_ANON_CID, AIRDROP_CID, keyHashOf, reservedUseOfKeyMaterial } from '../../src/lib/dapps/policy.js';
import { invokeData, invokeEntry, cid } from './helpers/invoke_builder.mjs';

const pwa = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const DEX = '729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae69b47bcfdeef9cbf';
const refused = (reason) => (e) => e instanceof PolicyRefusal && e.reason === reason;
const someKey = 'ab'.repeat(32);

test("the Beam DEX dApp's own swap (recorded on mainnet) decodes and is allowed", (t) => {
  const f = join(pwa, '..', 'test', 'beam', 'dapps', 'fixtures', 'dex_dapp_swap_raw_data.json');
  if (!existsSync(f)) return t.skip('desktop fixtures not next to the PWA');
  const raw = Buffer.from(JSON.parse(readFileSync(f, 'utf8')).result.raw_data_base64, 'base64');
  const d = checkContractData(new Uint8Array(raw));
  assert.equal(d.entries.length, 1);
  const e = d.entries[0];
  assert.equal(e.contractId, DEX);
  assert.equal(e.comment, 'Amm trade');
  assert.ok(e.flags & FLAG_DEPENDENT);
  assert.ok(e.flags & FLAG_SAVE_APP_INVOKE);
  assert.equal(d.appPrivilege, 0);
  assert.equal(e.signatureKeyHashes.length, 0);
});

test('a plain call to an unknown contract is allowed; the decoded funds are as built', () => {
  const d = checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xa1), spend: { 0: 100000000, 174: -5 }, comment: 'x' })])));
  assert.equal(d.entries[0].spend.get(0), 100000000n);
  assert.equal(d.entries[0].spend.get(174), -5n);
});

test('privilege above 0 is refused', () => {
  const raw = invokeData([invokeEntry({ contractId: cid(0xa1), flags: FLAG_SAVE_APP_INVOKE })], { firstFlags: FLAG_SAVE_APP_INVOKE, privilege: 1 });
  assert.throws(() => checkContractData(new Uint8Array(raw)), refused('privileged'));
  const ok = invokeData([invokeEntry({ contractId: cid(0xa1), flags: FLAG_SAVE_APP_INVOKE })], { firstFlags: FLAG_SAVE_APP_INVOKE, privilege: 0 });
  checkContractData(new Uint8Array(ok));
});

test('calls to BEAM names or their vault are refused, also as the second call', () => {
  for (const c of [BANS_CID, VAULT_ANON_CID]) {
    assert.throws(() => checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: c })]))), refused('forbidden_contract'));
    assert.throws(() => checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xa1) }), invokeEntry({ contractId: c })]))), refused('forbidden_contract'));
  }
});

test('a call signed with a key BEAM Campfire uses is refused', () => {
  for (const k of Object.keys(RESERVED_KEYS)) {
    assert.throws(() => checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xa1), sigs: [someKey, k] })]))), refused('reserved_key'));
  }
  checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xa1), sigs: [someKey] })])));
});

test('data that cannot be read in full is refused: trailing bytes, truncation, unknown or advanced flags', () => {
  const good = invokeData([invokeEntry({ contractId: cid(0xa1) })]);
  assert.throws(() => checkContractData(new Uint8Array([...good, 0])), refused('unreadable'));
  assert.throws(() => checkContractData(new Uint8Array(good.slice(0, -3))), refused('unreadable'));
  assert.throws(() => checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xa1), flags: 0x01 })]))), refused('unreadable'));
  assert.throws(() => checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xa1), flags: 0x80 })]))), refused('unreadable'));
  assert.throws(() => decodeInvokeData(new Uint8Array([0x85])), InvokeDataError);
});

test('the reserved key hashes are SHA-256("bvm.m.key\\0" || id) of the BANS, airdrop and owner ids', async () => {
  const h = (id) => createHash('sha256').update(Buffer.concat([Buffer.from('bvm.m.key'), Buffer.from([0]), Buffer.from(id)])).digest('hex');
  const expect = {
    [h(Buffer.from(BANS_CID, 'hex'))]: 'your BEAM names',
    [h(Buffer.concat([Buffer.from(AIRDROP_CID, 'hex'), Buffer.from([0])]))]: 'your airdrops',
    [h(Buffer.from([0xad, 42]))]: 'the airdrop contract',
  };
  assert.deepEqual({ ...RESERVED_KEYS }, expect);
  assert.equal(await keyHashOf(BANS_CID), h(Buffer.from(BANS_CID, 'hex')));
  assert.equal(await reservedUseOfKeyMaterial(BANS_CID), 'your BEAM names');
  assert.equal(await reservedUseOfKeyMaterial('ad2a'), 'the airdrop contract');
  assert.equal(await reservedUseOfKeyMaterial('00'), null);
});

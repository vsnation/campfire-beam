// What Activity calls a contract transaction: BEAM Campfire's titles (BeamTxText.contractLabel),
// not "Done". invoke_data amounts are from the contract's side: positive left the wallet.
import test from 'node:test';
import assert from 'node:assert/strict';
import { contractLabel, contractKind, contractStatusText } from '../../src/lib/wallet.js';

const DEX = '729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae69b47bcfdeef9cbf';
const AIRDROP = '8737e0d39575d7015fdea259fa091e41fc293e6c3d54e80d529033c349b5b18e';
const NAMES = 'af4550f1f8a6051ffeffea06e0cb978f8076fdfc2101d2273d4e62c86540bc5e';
const MINTER = '295fe749dc12c55213d1bd16ced174dc8780c020f59cb17749e900bb0c15d868';
const BURN = '5ab408982b148210e88f180114f10222a2235eafeede0a3a224fda0e523e17b7';
const tx = (cid, amounts, extra = {}) => ({ tx_type: 12, status: 3, invoke_data: [{ contract_id: cid, amounts: amounts.map(([asset_id, amount]) => ({ asset_id, amount })) }], ...extra });

test('DEX: a swap, adding to a pool, taking from a pool', () => {
  assert.equal(contractLabel(tx(DEX, [[0, 100], [174, -50]])), 'DEX swap');
  assert.equal(contractLabel(tx(DEX, [[0, 100], [174, 50], [175, -10]])), 'Added to a DEX pool');
  assert.equal(contractLabel(tx(DEX, [[175, 10], [0, -100], [174, -50]])), 'Taken from a DEX pool');
  assert.equal(contractLabel(tx(DEX, [])), 'DEX');
  assert.equal(contractKind(tx(DEX, [])), 'dex');
});

test('airdrop, names, minter, burn', () => {
  assert.equal(contractLabel(tx(AIRDROP, [[174, -500]])), 'Airdrop claim');
  assert.equal(contractLabel(tx(AIRDROP, [[0, 1000]])), 'Airdrop created');
  assert.equal(contractLabel(tx(AIRDROP, [])), 'Airdrop');
  assert.equal(contractLabel(tx(NAMES, [[0, 1000]])), 'Name payment');
  assert.equal(contractLabel(tx(MINTER, [[0, 1000]])), 'Token minter');
  assert.equal(contractLabel(tx(BURN, [[0, 1000]])), 'Burn');
});

test('an unknown contract: the dApp that made it, else "Contract call"; never "Done"', () => {
  const cid = 'ab'.repeat(32);
  assert.equal(contractLabel(tx(cid, [[0, 1]], { appname: 'BeamX DAO' })), 'BeamX DAO');
  assert.equal(contractLabel(tx(cid, [[0, 1]], { appname: 'BEAM Campfire' })), 'Contract call');
  assert.equal(contractLabel(tx(cid, [[0, 1]])), 'Contract call');
  assert.equal(contractLabel({ tx_type: 12, status: 3 }), 'Contract call');
  assert.equal(contractStatusText(tx(cid, [])), 'Completed');
  assert.notEqual(contractStatusText({ ...tx(cid, []), status: 1 }), 'Completed');
});

test('the bridge: a move to Ethereum and one from it', () => {
  const PIPE = 'e63bd26ca5b226558686dd191122a8e5d6861a97597db9f40bda48aef6dbe835';
  assert.equal(contractKind(tx(PIPE, [])), 'bridge');
  assert.equal(contractLabel(tx(PIPE, [[0, 100000000]])), 'Moved to Ethereum');
  assert.equal(contractLabel(tx(PIPE, [[0, -100000000]])), 'Moved from Ethereum');
});

test('the bridge pipes named in Activity are exactly the bridge routes', async () => {
  const { ROUTES } = await import('../../src/lib/bridge/routes.js');
  const { BRIDGE_PIPES } = await import('../../src/lib/wallet.js');
  assert.deepEqual([...BRIDGE_PIPES].sort(), ROUTES.map((r) => r.beamPipeCid).sort());
});

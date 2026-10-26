// Own addresses (lib/addresses.js): active and expired, which one Receive shows,
// labels, lifetimes and deleting only what no payment is waiting on.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as A from '../../src/lib/addresses.js';

const DAY = 86400;
const a = (address, patch = {}) => ({ address, own: true, expired: false, type: 'regular', comment: 'BEAM Campfire', create_time: 1000, duration: 0, ...patch });

test('active and expired, newest first; peer addresses left out', () => {
  const list = [a('x1', { create_time: 10 }), a('x2', { create_time: 30 }), a('x3', { expired: true, create_time: 20 }), a('p1', { own: false })];
  const { active, expired } = A.splitAddresses(list);
  assert.deepEqual(active.map((x) => x.address), ['x2', 'x1']);
  assert.deepEqual(expired.map((x) => x.address), ['x3']);
  assert.deepEqual(A.splitAddresses(null), { active: [], expired: [] });
});

test('Receive shows the chosen address while it can be paid, else the newest one it made', () => {
  const list = [a('old', { create_time: 10 }), a('new', { create_time: 20 }), a('mine', { create_time: 5, comment: 'From Alex' }), a('off', { type: 'offline', create_time: 40 }), a('gone', { expired: true, create_time: 50 })];
  assert.equal(A.pickReceiveAddress(list, { label: 'BEAM Campfire' }), 'new');
  assert.equal(A.pickReceiveAddress(list, { preferred: 'mine', label: 'BEAM Campfire' }), 'mine', 'renamed and chosen: still shown');
  assert.equal(A.pickReceiveAddress(list, { preferred: 'gone', label: 'BEAM Campfire' }), 'new', 'an expired choice is not shown');
  assert.equal(A.pickReceiveAddress(list, { preferred: 'off', label: 'BEAM Campfire' }), 'new', 'offline addresses are for one payment');
  assert.equal(A.pickReceiveAddress(list, { preferred: 'deleted', label: 'BEAM Campfire' }), 'new');
  assert.equal(A.pickReceiveAddress([], { label: 'BEAM Campfire' }), null);
  assert.equal(A.canBeCurrent(a('r', { type: 'regular_new' })), true);
  assert.equal(A.canBeCurrent(a('r', { expired: true })), false);
});

test('labels, types and lifetimes in words', () => {
  assert.equal(A.cleanLabel('  From\nAlex '), 'From Alex');
  assert.equal([...A.cleanLabel('y'.repeat(100))].length, A.LABEL_MAX);
  assert.equal(A.typeLabel('max_privacy'), 'Max privacy');
  assert.equal(A.typeLabel('???'), 'Other');
  const day = (s) => `d${s}`;
  assert.equal(A.lifetime(a('x'), { day }), 'Created d1000 · Never expires');
  assert.equal(A.lifetime(a('x', { duration: 61 * DAY }), { day }), `Created d1000 · Expires d${1000 + 61 * DAY}`);
  assert.equal(A.lifetime(a('x', { duration: 5, expired: true }), { day }), 'Created d1000 · Expired d1005');
  assert.match(A.lifetime(a('x', { create_time: 1719014400 })), /^Created 22 Jun 2024 · Never expires$/);
  assert.equal(A.shortAddress('1234567890abcdefghijklmnopqrstuv'), '1234567890…mnopqrstuv');
});

test('an address a payment is still waiting on is not deleted', () => {
  const txs = [{ status: 0, receiver: 'busy' }, { status: 3, receiver: 'done' }, { status: 5, sender: 'reg' }];
  assert.equal(A.busyWith('busy', txs), true);
  assert.equal(A.busyWith('reg', txs), true);
  assert.equal(A.busyWith('done', txs), false);
  assert.equal(A.busyWith('free', []), false);
});

test('the wallet calls send the label cleaned', async () => {
  const calls = [];
  const s = { call: async (m, p) => (calls.push([m, p]), m === 'addr_list' ? [a('x')] : 'done') };
  assert.equal((await A.listOwn(s)).length, 1);
  await A.renameAddress(s, 'x', ' From  Alex\n');
  await A.deleteAddress(s, 'x');
  assert.deepEqual(calls, [['addr_list', { own: true }], ['edit_address', { address: 'x', comment: 'From Alex' }], ['delete_address', { address: 'x' }]]);
});

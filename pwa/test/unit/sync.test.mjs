import test from 'node:test';
import assert from 'node:assert/strict';
import { assessSync, HF6_HEIGHT } from '../../src/lib/sync.js';

const now = 1_800_000_000;
const st = (h, age, inSync = true) => ({ current_height: h, current_state_timestamp: now - age, is_in_sync: inSync });
const ex = (h, age = 30) => ({ height: h, timestamp: now - age, fetchedAt: now - 5 });
const base = { nodeConnected: true, everConnected: true, now };

test('synced and verified: in sync, fresh tip, explorer agrees within 5 blocks', () => {
  const r = assessSync({ ...base, status: st(4_000_000, 40), explorer: ex(4_000_003) });
  assert.equal(r.state, 'synced');
  assert.equal(r.verified, true);
  assert.equal(r.canSend, true);
});

test('explorer unavailable: still synced, but says it could not double-check', () => {
  const r = assessSync({ ...base, status: st(4_000_000, 40), explorer: null });
  assert.equal(r.state, 'synced');
  assert.equal(r.verified, false);
  assert.equal(r.canSend, true);
  assert.match(r.detail, /Can't double-check/);
});

test('explorer 6+ blocks ahead: behind, sending refused, says how far', () => {
  const r = assessSync({ ...base, status: st(4_000_000, 40), explorer: ex(4_000_006) });
  assert.equal(r.state, 'behind');
  assert.equal(r.canSend, false);
  assert.equal(r.behindBlocks, 6);
  assert.match(r.title, /6 blocks behind/);
});

test('is_in_sync false: catching up, sending refused, blocks behind named', () => {
  const r = assessSync({ ...base, status: st(3_999_880, 7200, false), explorer: ex(4_000_000) });
  assert.equal(r.state, 'syncing');
  assert.equal(r.canSend, false);
  assert.equal(r.behindBlocks, 120);
  assert.match(r.title, /120 blocks behind/);
});

test('is_in_sync true but the tip is 11 minutes old: not synced', () => {
  const r = assessSync({ ...base, status: st(4_000_000, 660, true), explorer: null });
  assert.equal(r.state, 'syncing');
  assert.equal(r.canSend, false);
});

test('a tip from the future (clock skew > 2 min) is not trusted', () => {
  const r = assessSync({ ...base, status: st(4_000_000, -600, true), explorer: null });
  assert.equal(r.canSend, false);
});

test('not connected to a node this session: never synced, whatever the stored tip says', () => {
  const r = assessSync({ ...base, everConnected: false, nodeConnected: false, status: st(4_000_000, 30), explorer: ex(4_000_000) });
  assert.equal(r.state, 'connecting');
  assert.equal(r.canSend, false);
  const r2 = assessSync({ ...base, nodeConnected: false, status: st(4_000_000, 30), explorer: ex(4_000_000) });
  assert.equal(r2.state, 'offline');
  assert.equal(r2.canSend, false);
});

test('connection failed: an honest offline state', () => {
  const r = assessSync({ ...base, everConnected: false, nodeConnected: false, connectFailed: true, status: null, explorer: null });
  assert.equal(r.state, 'offline');
  assert.match(r.title, /Can't reach the BEAM network/);
});

test('below the HF6 fork while the network is past it: stalled on an old chain', () => {
  const r = assessSync({ ...base, status: st(HF6_HEIGHT - 1, 30), explorer: ex(HF6_HEIGHT + 100000) });
  assert.equal(r.state, 'stalled');
  assert.equal(r.canSend, false);
});

test('a stale explorer (old tip or old fetch) is not used as a check', () => {
  const r = assessSync({ ...base, status: st(4_000_000, 30), explorer: { height: 4_000_100, timestamp: now - 3600, fetchedAt: now } });
  assert.equal(r.state, 'synced');
  assert.equal(r.verified, false);
  const r2 = assessSync({ ...base, status: st(4_000_000, 30), explorer: { height: 4_000_100, timestamp: now - 10, fetchedAt: now - 3600 } });
  assert.equal(r2.verified, false);
});

test('an explorer far behind the wallet cannot vouch for it', () => {
  const r = assessSync({ ...base, status: st(4_000_000, 30), explorer: ex(3_999_000) });
  assert.equal(r.state, 'synced');
  assert.equal(r.verified, false);
});

test('no height constant grants synced: a high height with is_in_sync false stays unsynced', () => {
  const r = assessSync({ ...base, status: st(9_999_999, 30, false), explorer: null });
  assert.equal(r.canSend, false);
});

test('importing the snapshot is its own state', () => {
  const r = assessSync({ ...base, importing: true, status: null, explorer: null });
  assert.equal(r.state, 'importing');
  assert.equal(r.canSend, false);
});

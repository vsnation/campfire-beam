// Random node: the pool order and when the wallet moves to the next node.
import test from 'node:test';
import assert from 'node:assert/strict';
import { POOL, NODES, poolOrder, nextInOrder, isPoolNode } from '../../src/lib/nodes.js';
import { assessNodeHealth, hopAllowed, HEALTH } from '../../src/lib/node_health.js';

const FULL = ['eu-node02.mainnet.beam.mw:8200', 'eu-node03.mainnet.beam.mw:8200', 'eu-node04.mainnet.beam.mw:8200'];
const seq = (...xs) => {
  let i = 0;
  return () => xs[i++ % xs.length];
};

test('pool order: a random full-chain node first, then the others, eu-nodes, and eu-node01 last', () => {
  const firsts = new Set();
  for (let k = 0; k < 300; k++) {
    const o = poolOrder();
    assert.equal(o.length, 5);
    assert.deepEqual([...o].sort(), [...NODES].sort());
    assert.deepEqual([...o.slice(0, 3)].sort(), [...FULL].sort());
    assert.equal(o[3], 'eu-nodes.mainnet.beam.mw:8200');
    assert.equal(o[4], 'eu-node01.mainnet.beam.mw:8200');
    firsts.add(o[0]);
  }
  assert.deepEqual([...firsts].sort(), [...FULL].sort(), 'each full-chain node starts sometimes');
  assert.deepEqual(poolOrder(seq(0, 0)), ['eu-node03.mainnet.beam.mw:8200', 'eu-node04.mainnet.beam.mw:8200', 'eu-node02.mainnet.beam.mw:8200', 'eu-nodes.mainnet.beam.mw:8200', 'eu-node01.mainnet.beam.mw:8200']);
  assert.deepEqual(poolOrder(seq(0.99, 0.99)), [...FULL, 'eu-nodes.mainnet.beam.mw:8200', 'eu-node01.mainnet.beam.mw:8200']);
  assert.equal(POOL.find((n) => n.address.startsWith('eu-node01')).fullChain, false);
});

test('next node wraps round the order', () => {
  const o = ['a', 'b', 'c'];
  assert.equal(nextInOrder(o, 'a'), 'b');
  assert.equal(nextInOrder(o, 'c'), 'a');
  assert.equal(nextInOrder(o, 'x'), 'a');
  assert.ok(isPoolNode('eu-node04.mainnet.beam.mw:8200') && !isPoolNode('127.0.0.1:9443'));
});

const T0 = 1_000_000;
const g = (o = {}) => ({ attempts: 1, failures: 0, open: 0, everOpen: false, firstOpenAt: null, lastCloseAt: null, ...o });
const at = (ms, p) => assessNodeHealth({ now: T0 + ms, startedAt: T0, ...p });
const STAY = { switch: false, reason: null };

test('unreachable: no socket within 15 s, or two failed attempts', () => {
  assert.deepEqual(at(5000, { guard: g() }), STAY);
  assert.equal(at(HEALTH.connectTimeoutMs - 1, { guard: g() }).switch, false);
  assert.deepEqual(at(HEALTH.connectTimeoutMs, { guard: g() }), { switch: true, reason: 'unreachable' });
  assert.deepEqual(at(5200, { guard: g({ attempts: 2, failures: 2 }) }), { switch: true, reason: 'unreachable' });
  assert.equal(at(1000, { guard: g({ failures: 1 }) }).switch, false);
});

test('silent: sockets open but no BEAM handshake for 45 s, whether the socket stays open or keeps closing', () => {
  const open = g({ everOpen: true, open: 1, firstOpenAt: T0 + 2000 });
  assert.equal(at(2000 + HEALTH.silentMs - 1, { guard: open }).switch, false);
  assert.deepEqual(at(2000 + HEALTH.silentMs, { guard: open }), { switch: true, reason: 'silent' });
  const flapping = g({ everOpen: true, open: 0, firstOpenAt: T0 + 2000, lastCloseAt: T0 + 44000 });
  assert.deepEqual(at(2000 + HEALTH.silentMs, { guard: flapping }), { switch: true, reason: 'silent' });
  assert.equal(at(2000 + HEALTH.silentMs, { guard: open, answered: true, answeredAt: T0 + 3000, connected: true }).switch, false, 'a node that answered is not silent');
});

test('dropped: it answered, then the connection was lost and not back for 20 s', () => {
  const p = { guard: g({ everOpen: true, open: 0, firstOpenAt: T0 + 1000 }), answered: true, answeredAt: T0 + 1500, connected: false, lostAt: T0 + 60000 };
  assert.equal(at(60000 + HEALTH.dropMs - 1, p).switch, false);
  assert.deepEqual(at(60000 + HEALTH.dropMs, p), { switch: true, reason: 'dropped' });
  // Sockets that reopen without the handshake do not reset it: only the node answering again does.
  assert.deepEqual(at(60000 + HEALTH.dropMs, { ...p, guard: g({ everOpen: true, open: 1, firstOpenAt: T0 + 1000 }) }), { switch: true, reason: 'dropped' });
  assert.equal(at(60000 + HEALTH.dropMs, { ...p, connected: true, lostAt: null, lastProgressAt: T0 + 70000 }).switch, false);
});

test('stalled: connected, then no new block or sync progress for 10 minutes; any progress resets it', () => {
  const base = { guard: g({ everOpen: true, open: 1, firstOpenAt: T0 + 2000 }), answered: true, answeredAt: T0 + 3000, connected: true };
  const last = T0 + 120000;
  assert.equal(at(120000 + HEALTH.stallMs - 1, { ...base, lastProgressAt: last }).switch, false);
  assert.deepEqual(at(120000 + HEALTH.stallMs, { ...base, lastProgressAt: last }), { switch: true, reason: 'stalled' });
  // An ordinary gap between blocks (several minutes) is not a stall.
  assert.equal(at(120000 + 5 * 60000, { ...base, lastProgressAt: last }).switch, false);
  // Answered but never a block: counted from the answer.
  assert.deepEqual(at(3000 + HEALTH.stallMs, base), { switch: true, reason: 'stalled' });
  // It needs no clock: only how long since the node last gave something.
  assert.equal(HEALTH.stallMs, 600000);
});

test('nothing moves during a recovery import', () => {
  assert.equal(at(10 * 60000, { guard: g(), importing: true }).switch, false);
});

test('hops: a whole round with nothing from any node slows to one a minute; a round of stalls stops stall hops', () => {
  const now = T0 + 100000;
  assert.equal(hopAllowed({ reason: 'unreachable', now, poolSize: 5, emptyHops: 4, lastHopAt: now - 1000 }), true);
  assert.equal(hopAllowed({ reason: 'unreachable', now, poolSize: 5, emptyHops: 5, lastHopAt: now - 1000 }), false);
  assert.equal(hopAllowed({ reason: 'silent', now, poolSize: 5, emptyHops: 5, lastHopAt: now - HEALTH.roundCooldownMs }), true);
  assert.equal(hopAllowed({ reason: 'stalled', now, poolSize: 5, staleHops: 4 }), true);
  assert.equal(hopAllowed({ reason: 'stalled', now, poolSize: 5, staleHops: 5 }), false);
});

// Auto-lock also fires while the app is out of sight (audit item ported from the Firo wallet,
// 5ee127b30). On "hidden" the app only noted the time, and the 15-second check ran only while
// visible: the lock came on the way back. A Beam PWA tab left in the background on a computer
// stayed unlocked for hours or days, with the database password and the running engine in memory,
// while Settings said "Auto-lock: Also in the background".
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { installAutoLock, CHECK_EVERY_MS } from '../../src/lib/auto_lock.js';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src');

function page({ minutes = 5, allowed = true } = {}) {
  let clock = 1_000_000;
  const timers = new Map();
  let nextId = 1;
  const intervals = [];
  const listeners = new Map();
  const target = () => ({ addEventListener: (t, f) => listeners.set(t, [...(listeners.get(t) || []), f]) });
  const doc = { visibilityState: 'visible', ...target() };
  const win = target();
  const locks = [];
  const app = {
    lastActivity: clock,
    hiddenAt: null,
    autoLockMs: () => minutes * 60000,
    lockAllowedNow: () => allowed && locks.length === 0,
    lock: (reason) => locks.push(reason),
    touch() {
      this.lastActivity = clock;
    },
  };
  installAutoLock(app, {
    doc,
    win,
    now: () => clock,
    setTimer: (f, ms) => (timers.set(nextId, { f, at: clock + ms }), nextId++),
    clearTimer: (id) => timers.delete(id),
    every: (f, ms) => intervals.push({ f, ms }),
  });
  return {
    app,
    locks,
    fire: (t) => (listeners.get(t) || []).forEach((f) => f({})),
    setVisible(v) {
      doc.visibilityState = v ? 'visible' : 'hidden';
      this.fire('visibilitychange');
    },
    /** Time passes; due one-shot timers run (a frozen page: pass runTimers false). */
    advance(ms, { runTimers = true, ticks = true } = {}) {
      clock += ms;
      if (runTimers) for (const [id, t] of [...timers]) if (t.at <= clock) (timers.delete(id), t.f());
      if (ticks) intervals.forEach((i) => i.f());
    },
    intervals,
  };
}

test('out of sight: it locks there, at the auto-lock time, without coming back', () => {
  const p = page({ minutes: 5 });
  p.setVisible(false);
  p.advance(4 * 60000);
  assert.deepEqual(p.locks, [], 'not before its time');
  p.advance(60000 + 100);
  assert.deepEqual(p.locks, ['timeout'], 'locked while still hidden');
});

test('out of sight with background timers slowed: the periodic check counts from when it went out of sight', () => {
  const p = page({ minutes: 1 });
  p.setVisible(false);
  // The one-shot timer is throttled away; only the periodic check gets to run.
  p.advance(61000, { runTimers: false });
  assert.deepEqual(p.locks, ['timeout']);
  assert.equal(p.intervals[0].ms, CHECK_EVERY_MS);
});

test('a frozen page (a phone) locks the moment it comes back; a short absence does not', () => {
  const p = page({ minutes: 5 });
  p.setVisible(false);
  p.advance(30000, { runTimers: false, ticks: false });
  p.setVisible(true);
  assert.deepEqual(p.locks, [], 'back within the time: coming back is use');
  p.setVisible(false);
  p.advance(6 * 60000, { runTimers: false, ticks: false });
  p.setVisible(true);
  assert.deepEqual(p.locks, ['timeout']);
});

test('on screen: after the minutes without use; use resets it; never while a lock is not allowed (first download)', () => {
  const p = page({ minutes: 5 });
  p.advance(4 * 60000);
  p.fire('pointerdown');
  p.advance(4 * 60000);
  assert.deepEqual(p.locks, []);
  p.advance(60000 + 1);
  assert.deepEqual(p.locks, ['timeout']);
  const q = page({ minutes: 1, allowed: false });
  q.setVisible(false);
  q.advance(5 * 60000);
  assert.deepEqual(q.locks, []);
});

test('app.js uses it, and nothing else decides the auto-lock', () => {
  const t = readFileSync(join(src, 'app.js'), 'utf8');
  assert.match(t, /installAutoLock\(app\);/);
  assert.ok(!/setInterval\(/.test(t), 'no second timer in app.js');
});

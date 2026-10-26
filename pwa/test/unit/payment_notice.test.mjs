// Which payments are news (lib/payment_notice.js, Beam PWA's BeamWallet._announceIncoming),
// when a run's news starts, and the browser's notification states. What is told: notify_rules.test.mjs.
import test from 'node:test';
import assert from 'node:assert/strict';
import { isNews, catchUp, settled, CATCH_UP_GRACE_MS, notificationPermission, isIos, isStandalone } from '../../src/lib/payment_notice.js';

const tx = (txId, extra = {}) => ({ txId, tx_type: 0, income: true, status: 3, value: 50000000, asset_id: 0, sender: 'a', receiver: 'b', ...extra });

test('news: a completed incoming payment; never a send, change, a split or a contract call', () => {
  assert.equal(isNews(tx('1')), true);
  assert.equal(isNews(tx('2', { tx_type: 7, address_type: 'max_privacy' })), true, 'offline / max privacy');
  assert.equal(isNews(tx('3', { income: false })), false, 'a send');
  assert.equal(isNews(tx('4', { income: false, sender: '', receiver: '' })), false, 'a split');
  assert.equal(isNews(tx('5', { tx_type: 12 })), false, 'a contract call');
  assert.equal(isNews(tx('6', { status: 1 })), false, 'not finished');
  assert.equal(isNews(tx('7', { status: 4 })), false, 'failed');
  assert.equal(isNews(tx('8', { value: 0 })), false);
  assert.equal(isNews(null), false);
});

test('news starts once the run has caught up (Synced, no block requests left) for 20 s, then stays on', () => {
  const synced = { running: true, importing: false, sync: { state: 'synced' }, progress: { done: 40, total: 40 } };
  assert.equal(settled(synced), true);
  assert.equal(settled({ ...synced, progress: { done: 12, total: 40 } }), false, 'block bodies still being read');
  assert.equal(settled({ ...synced, progress: null }), true);
  assert.equal(settled({ ...synced, sync: { state: 'syncing' } }), false);
  assert.equal(settled({ ...synced, importing: true }), false);
  assert.equal(CATCH_UP_GRACE_MS, 20000);
  const run = catchUp();
  assert.equal(run.live({ ...synced, progress: { done: 1, total: 9 } }, 0), false);
  assert.equal(run.live(synced, 1000), false, 'just caught up');
  assert.equal(run.live(synced, 20999), false);
  assert.equal(run.live(synced, 21000), true);
  assert.equal(run.live({ ...synced, progress: { done: 3, total: 4 } }, 22000), true, "a new block's requests do not turn it off");
  run.reset();
  assert.equal(run.live(synced, 30000), false, 'a new run catches up again');
});

test("the browser's notifications: unsupported, asked, allowed, blocked", () => {
  const N = (permission) => Object.assign(function Notification() {}, { permission, requestPermission: () => Promise.resolve(permission) });
  assert.equal(notificationPermission({}), 'unsupported');
  assert.equal(notificationPermission({ Notification: N('default') }), 'default');
  assert.equal(notificationPermission({ Notification: N('granted') }), 'granted');
  assert.equal(notificationPermission({ Notification: N('denied') }), 'denied');
  assert.equal(isIos({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)' }), true);
  assert.equal(isIos({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', maxTouchPoints: 5 }), true, 'iPadOS');
  assert.equal(isIos({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', maxTouchPoints: 0 }), false);
  assert.equal(isStandalone({ navigator: { standalone: true } }), true);
  assert.equal(isStandalone({ navigator: {}, matchMedia: () => ({ matches: false }) }), false);
});

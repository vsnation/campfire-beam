// What Beam PWA tells the person about, worked out on the device (lib/notify_rules.js), and
// where a tap on a notification may open the app (lib/notify.js parseOpen).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { txWatcher, wordsFor, settingsOf, leavingEvents, remindersFor, dueReminders, awaySummary, snapshotOf, awayLine, KINDS, KIND_WORDS, REMIND_AFTER_MS, DAY_MS } from '../../src/lib/notify_rules.js';

const tx = (txId, extra = {}) => ({ txId, tx_type: 0, income: true, status: 3, value: 50000000, asset_id: 0, sender: 'a', receiver: 'b', create_time: 1000, ...extra });
const types = (evs) => evs.map((e) => `${e.type}:${e.tx ? e.tx.txId : ''}`);

test('the watcher: first read is history; then money in, money out, failures and contract calls, each once', () => {
  const w = txWatcher();
  assert.deepEqual(w.update([tx('old')], false), [], 'not read yet');
  assert.equal(w.started, false);
  const sending = tx('s1', { income: false, status: 1 });
  const call = tx('c1', { tx_type: 12, income: false, status: 1 });
  const incoming = tx('i1', { status: 5 });
  assert.deepEqual(w.update([tx('old'), sending, call, incoming]), [], 'the first read is history');
  assert.equal(w.started, true);
  const next = w.update([tx('new'), tx('old'), { ...sending, status: 3 }, { ...call, status: 4 }, { ...incoming, status: 4 }, tx('mine', { income: false, status: 3 })]);
  assert.deepEqual(types(next), ['received:new', 'sent:s1', 'contractFailed:c1', 'failed:i1'], 'a send never seen under way is not news');
  assert.deepEqual(next.map((e) => e.kind), ['in', 'out', 'contracts', 'out']);
  assert.deepEqual(w.update([tx('new'), { ...sending, status: 3 }]), [], 'once');
  // Caught up later: payments found while catching up are history, then never news.
  const c = txWatcher();
  c.update([]);
  assert.deepEqual(c.update([tx('found')], true, false), []);
  assert.deepEqual(c.update([tx('found'), tx('live')], true, true).map((e) => e.tx.txId), ['live']);
  // A contract call this run never saw under way: not news (it may be days old).
  const d = txWatcher();
  d.update([]);
  assert.deepEqual(d.update([tx('c2', { tx_type: 12, income: false, status: 3 })]), []);
  w.reset();
  assert.deepEqual(w.update([tx('x'), tx('y')]), [], 'after a stop the first read is history again');
});

test('the words: amounts only when allowed; verified tickers only; a tap opens the payment', () => {
  const label = (id) => (id === 174 ? { verified: true, symbol: 'FOMO' } : id === 779 ? { verified: false, symbol: 'BEAM' } : null);
  const r = wordsFor({ type: 'received', tx: tx('ab12') }, { label });
  assert.equal(r.title, 'Received 0.5 BEAM');
  assert.equal(r.url, '#open=activity&tx=ab12');
  assert.equal(wordsFor({ type: 'received', tx: tx('1', { asset_id: 174, value: 56812970000 }) }, { label }).title, 'Received 568.1297 FOMO');
  assert.equal(wordsFor({ type: 'received', tx: tx('1', { asset_id: 779, value: 300000000 }) }, { label }).title, 'Received 3 of token #779', 'anyone can mint a token called BEAM');
  assert.equal(wordsFor({ type: 'received', tx: tx('1') }, { amounts: false }).title, 'Payment received', 'no amount on a lock screen');
  assert.equal(wordsFor({ type: 'sent', tx: tx('1', { income: false }) }).title, 'Sent 0.5 BEAM');
  assert.match(wordsFor({ type: 'failed', tx: tx('1', { income: false }) }).body, /Nothing left your wallet/);
  assert.match(wordsFor({ type: 'failed', tx: tx('1') }).title, /to you did not go through/);
  assert.equal(wordsFor({ type: 'contractDone', tx: tx('1', { tx_type: 12 }) }, { contractTitle: () => 'Swap on Beam DEX' }).title, 'Swap on Beam DEX: done');
  // A dApp names itself: its name is framed as the app's, never read as the wallet speaking.
  const dapp = tx('1', { tx_type: 12, appname: 'Re-verify your wallet now' });
  assert.equal(wordsFor({ type: 'contractDone', tx: dapp }, { contractTitle: (t) => t.appname }).title, 'A call by \u201cRe-verify your wallet now\u201d: done');
  assert.equal(wordsFor({ type: 'contractFailed', tx: dapp }, { contractTitle: (t) => t.appname }).title, 'A call by \u201cRe-verify your wallet now\u201d: did not go through');
  assert.equal(wordsFor({ type: 'contractDone', tx: dapp }, { contractTitle: () => 'DEX swap' }).title, 'DEX swap: done', "the wallet's own label is not framed");
  assert.match(wordsFor({ type: 'arriving', tx: tx('1', { status: 1 }) }).body, /finishes only while Beam PWA is open/);
  assert.equal(wordsFor({ type: 'received', tx: tx('1') }, { walletName: 'Savings' }).body, 'Tap to see it in Activity. In Savings.');
});

test('settings: off until turned on; every kind on by default; the old payment switch counts as on', () => {
  assert.equal(settingsOf(null).on, false);
  assert.equal(settingsOf({ paymentNotifications: true }).on, true, '0.2.8 switch carried over');
  assert.equal(settingsOf({ paymentNotifications: true, notify: { on: false } }).on, false);
  const s = settingsOf({ notify: { on: true, kinds: { out: false } } });
  assert.deepEqual(KINDS.filter((k) => s.kinds[k]), ['in', 'underway', 'contracts', 'moves']);
  // A lock screen is read by whoever holds the phone: amounts only when the person asks.
  assert.equal(s.amounts, false, 'no amounts by default');
  assert.equal(settingsOf({ notify: { on: true } }).amounts, false);
  assert.equal(settingsOf({ notify: { on: true, amounts: true } }).amounts, true);
  assert.equal(settingsOf({ notify: { on: true, amounts: false } }).amounts, false);
  for (const k of KINDS) assert.ok(KIND_WORDS[k].title && KIND_WORDS[k].sub);
});

test('leaving the app: a regular payment still under way is said at once; nothing else is', () => {
  const evs = leavingEvents([tx('a', { status: 1 }), tx('b', { status: 0, income: false }), tx('c', { status: 1, tx_type: 7 }), tx('d', { status: 3 }), tx('e', { status: 1, tx_type: 12 })]);
  assert.deepEqual(types(evs), ['arriving:a', 'leaving:b'], 'offline / max-privacy payments need no one online');
  assert.ok(evs.every((e) => e.kind === 'underway'));
});

test('reminders for later: payments still waiting, private coin ready, name expiring, NEAR deposit deadline', () => {
  const now = 1_700_000_000_000;
  const list = remindersFor({
    now,
    txs: [tx('a', { status: 1 }), tx('b', { status: 0, income: false })],
    privateCoins: [{ id: 'p1', spendableAt: now + 3600_000 }, { id: 'p0', spendableAt: now - 1 }],
    names: [{ name: 'alice', expiresAt: now + 10 * DAY_MS }, { name: 'bob', expiresAt: now + 3 * DAY_MS }],
    nearSwaps: [{ id: 'dep1', symbol: 'BTC', sendBefore: now + 3600_000 }],
  });
  assert.deepEqual(list.map((r) => r.id.replace(/\d+$/, 'T')), ['rem-arr-T', 'rem-priv-T', 'rem-name-T', 'rem-name-T', 'rem-name-T', 'rem-near-T']);
  assert.equal(list[0].at, now + REMIND_AFTER_MS);
  assert.equal(list[0].id, `rem-arr-${now + REMIND_AFTER_MS}`, 'its id is its time');
  assert.equal(list[0].title, 'Payments are still waiting', 'one reminder for both');
  assert.equal(list[2].at, now + 3 * DAY_MS);
  assert.equal(list[2].title, 'A BEAM name of yours expires in 7 days');
  assert.equal(list[4].title, 'A BEAM name of yours expires in 1 day');
  assert.equal(list[5].title, 'A deposit address closes soon');
  assert.deepEqual(list.map((r) => r.url), ['#open=activity', '#open=coins', '#open=names', '#open=names', '#open=names', '#open=nearIntents']);
  assert.ok(list.every((r) => !/\d+(\.\d+)? BEAM/.test(`${r.title} ${r.body}`)), 'no amounts in a stored reminder');
  const { due, keep } = dueReminders(list, now + REMIND_AFTER_MS);
  assert.deepEqual(due.map((r) => r.id), [`rem-arr-${now + REMIND_AFTER_MS}`]);
  assert.equal(keep.length, 5);
});

test('a stored reminder names nothing (audit A-4): no payment id, coin, name, address, label, deposit address, symbol, wallet', () => {
  const now = 1_700_000_000_000;
  const secrets = ['a'.repeat(32), 'coin-77', 'alice', 'dep1addressxyz', 'BTC', 'From Alex', 'w1', 'Savings', '0011ab'];
  const list = remindersFor({
    now,
    wallet: 'w1',
    walletName: 'Savings',
    labels: true,
    txs: [tx('a'.repeat(32), { status: 1 })],
    privateCoins: [{ id: 'coin-77', spendableAt: now + 3600_000 }],
    names: [{ name: 'alice', expiresAt: now + 10 * DAY_MS }],
    nearSwaps: [{ id: 'dep1addressxyz', symbol: 'BTC', sendBefore: now + 3600_000 }],
    addresses: [{ address: `0011ab${'cd'.repeat(30)}`, expiresAt: now + 10 * DAY_MS, label: 'From Alex' }],
  });
  assert.equal(list.length, 6);
  const stored = JSON.stringify(list);
  for (const s of secrets) assert.ok(!stored.includes(s), `"${s}" is in a stored reminder`);
  assert.ok(list.every((r) => Object.keys(r).sort().join() === 'at,body,id,kind,title,url'), 'no wallet field');
  assert.ok(list.every((r) => /^rem-(arr|priv|name|addr|near)-\d+$/.test(r.id)));
});

test('reminders an earlier version stored are rewritten to name nothing, at the same times', async () => {
  const { plainReminders } = await import('../../src/lib/notify_rules.js');
  const now = 1_700_000_000_000;
  const old = [
    { id: `rem-arr-${'b1'.repeat(16)}`, wallet: 'w1', kind: 'underway', at: now + 1, title: 'Your payment is still waiting', body: 'It finishes only while Beam PWA is open. Open it to finish. In Savings.', url: `#open=activity&tx=${'b1'.repeat(16)}` },
    { id: 'rem-priv-coin-77', wallet: 'w1', kind: 'in', at: now + 2, title: 'A private payment can now be spent', body: 'Open Beam PWA to use it.', url: '#open=coins' },
    { id: 'rem-name-alice-1', wallet: 'w1', kind: 'contracts', at: now + 3, title: 'alice.beam expires in 1 day', body: 'Renew it in BEAM names so it stays yours.', url: '#open=names' },
    { id: 'rem-name-alice-7', wallet: 'w1', kind: 'contracts', at: now + 4, title: 'alice.beam expires in 7 days', body: 'Renew it in BEAM names so it stays yours.', url: '#open=names' },
    { id: `rem-addr-0011ab${'cd'.repeat(5)}`, wallet: 'w1', kind: 'in', at: now + 5, title: 'An address of yours (From Alex) expires in 3 days', body: 'x', url: '#open=addresses' },
    { id: 'rem-addr-ffff', wallet: null, kind: 'in', at: now + 6, title: '3 of your addresses expire in 3 days', body: 'x', url: '#open=addresses' },
    { id: 'rem-near-dep1addressxyz', wallet: 'w1', kind: 'moves', at: now + 7, title: 'Send your BTC in the next 30 minutes', body: 'x In Savings.', url: '#open=nearIntents' },
    { id: 'rem-test-odd', at: now, title: 'odd' },
  ];
  const got = plainReminders(old);
  assert.deepEqual(got.map((r) => [r.id, r.at]), [1, 2, 3, 4, 5, 6, 7].map((d, i) => [`rem-${['arr', 'priv', 'name', 'name', 'addr', 'addr', 'near'][i]}-${now + d}`, now + d]));
  assert.equal(got[2].title, 'A BEAM name of yours expires in 1 day');
  assert.equal(got[3].title, 'A BEAM name of yours expires in 7 days');
  assert.equal(got[5].title, '3 of your addresses expire in 3 days');
  for (const s of ['b1b1', 'coin-77', 'alice', 'From Alex', 'dep1', 'BTC', 'Savings', 'w1', '0011ab']) assert.ok(!JSON.stringify(got).includes(s), s);
  assert.deepEqual(plainReminders(got), got, 'already plain: kept as they are');
});

test('while you were away: from the statuses saved on leaving, never older history', () => {
  const left = { at: 2_000_000, txs: snapshotOf([tx('s1', { income: false, status: 1 }), tx('c1', { tx_type: 12, status: 1, income: false }), tx('old')]) };
  const now = [
    tx('new1', { create_time: 2100 }),
    tx('new2', { create_time: 2200, value: 25000000 }),
    tx('s1', { income: false, status: 3 }),
    tx('c1', { tx_type: 12, income: false, status: 3 }),
    tx('f1', { create_time: 2300, income: false, status: 4 }),
    tx('ancient', { create_time: 100 }),
    tx('old'),
  ];
  const sum = awaySummary(left, now);
  assert.deepEqual(sum.received.map((t) => t.txId), ['new1', 'new2'], 'a payment older than the 200 saved is not news');
  assert.deepEqual(sum.sent.map((t) => t.txId), ['s1']);
  assert.deepEqual(sum.contracts.map((t) => t.txId), ['c1']);
  assert.deepEqual(sum.failed.map((t) => t.txId), []);
  assert.equal(awayLine(sum), 'While you were away: received 2 payments (0.75 BEAM) · a payment you sent finished · a swap or app call finished.');
  assert.equal(awayLine(sum, { amounts: false }), 'While you were away: received 2 payments · a payment you sent finished · a swap or app call finished.');
  assert.equal(awayLine(awaySummary(left, [tx('old')])), null, 'nothing happened: no line');
  assert.equal(Object.keys(snapshotOf(Array.from({ length: 300 }, (_, i) => tx(`t${i}`)))).length, 200);
});

test('a tap opens only the app own screens (lib/notify.js parseOpen; sw.js accepts the same links)', async () => {
  // notify.js imports the wallet; its parseOpen is checked through its source, the rule sw.js shares.
  const src = readFileSync(new URL('../../src/lib/notify.js', import.meta.url), 'utf8');
  const sw = readFileSync(new URL('../../src/sw.js', import.meta.url), 'utf8');
  const pageRule = /\/\^#open=\(\[a-zA-Z\]\+\)\(\?:&tx=\(\[0-9a-f\]\{1,128\}\)\)\?\$\//;
  assert.match(src, pageRule);
  assert.match(sw, /const OPEN_LINK = \/\^#open=\[a-zA-Z\]\+\(&tx=\[0-9a-f\]\{1,128\}\)\?\$\/;/);
  const OPEN_LINK = /^#open=[a-zA-Z]+(&tx=[0-9a-f]{1,128})?$/;
  assert.equal(OPEN_LINK.test('#open=activity&tx=ab12'), true);
  for (const bad of ['https://evil.example/#open=home', '#open=home&x=1', 'javascript:alert(1)', '#open=activity&tx=AB', '#open=../x']) assert.equal(OPEN_LINK.test(bad), false, bad);
  // No server is asked for anything: no push subscription, no fetch.
  for (const s of [src, readFileSync(new URL('../../src/lib/notify_rules.js', import.meta.url), 'utf8')]) {
    assert.doesNotMatch(s, /pushManager|subscribe\(|fetch\(|XMLHttpRequest|WebSocket/);
  }
  assert.doesNotMatch(sw.slice(sw.indexOf('// ---------------------------------------------------------------- notifications')), /pushManager|addEventListener\('push'|fetch\(/);
});

test('other parts of the app: their own words, without amounts when the person said so', () => {
  const ev = { type: 'free', title: 'Money was paid to your BEAM name', body: 'Sent to your name alice.beam: 2 BEAM. Claim it on Home.', plainBody: 'Claim it on Home.', tag: 'names-inbox', url: '#open=home' };
  assert.equal(wordsFor(ev).body, 'Sent to your name alice.beam: 2 BEAM. Claim it on Home.');
  assert.equal(wordsFor(ev, { amounts: false }).body, 'Claim it on Home.');
  assert.equal(wordsFor({ type: 'free', title: 'Your coins reached your Ethereum wallet', body: 'The bridge paid them.', url: '#open=bridgeList' }, { walletName: 'Savings' }).body, 'The bridge paid them. In Savings.');
});

test('an address about to expire: 3 days before, the nearest few, one reminder a day, never its label', async () => {
  const { ADDRESS_REMINDERS } = await import('../../src/lib/notify_rules.js');
  const now = 1_700_000_000_000;
  const addr = (n, days, label = '') => ({ address: `${String(n).padStart(2, '0')}${'ab'.repeat(30)}`, expiresAt: now + days * DAY_MS, label });
  const list = remindersFor({ now, addresses: [addr(1, 10, 'From Alex'), addr(2, 2), addr(3, 20), addr(4, 20.2), { ...addr(5, 30), expired: true }] });
  assert.deepEqual(list.map((r) => [r.id, Math.round((r.at - now) / DAY_MS)]), [[`rem-addr-${now + 7 * DAY_MS}`, 7], [`rem-addr-${now + 17 * DAY_MS}`, 17]], 'expiring in 2 days is too late for a 3-day notice; 20 and 20.2 share a day');
  assert.equal(list[0].title, 'An address of yours expires in 3 days', 'no label');
  assert.equal(list[1].title, '2 of your addresses expire in 3 days');
  assert.equal(list[0].url, '#open=addresses');
  assert.equal(list[0].kind, 'in');
  assert.equal(remindersFor({ now, addresses: [addr(1, 10, 'From Alex')], labels: true })[0].title, 'An address of yours expires in 3 days', 'a label is a private note: never in a stored reminder');
  const many = remindersFor({ now, addresses: Array.from({ length: 12 }, (_, i) => addr(i, 5 + i)) });
  assert.equal(many.length, ADDRESS_REMINDERS, 'the nearest few only');
});

// Notifications, end to end, all on the device: the installed Google Chrome (headless), its own
// build and port, BEAM mainnet, a throwaway wallet that holds nothing and spends nothing.
//
//   npm run e2e:notify   (own build folder and port 8826)
//
// Payments that "arrive", "leave" or "fail" are put in the page's payment list (the engine is not
// told); the app's switch, banner, system notifications, badge, reminders, the summary after an
// unlock and the service worker's reminders are the real code. The page's system notifications
// are recorded (registration.showNotification stubbed in the page); the service worker's are real.
// "Out of front" is the page hidden (visibilitychange) or its window without focus.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen, shot, sleep, foreignHosts, PWA, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced, unlockWithPassword, lock } from './flows.mjs';

const PORT = 8826;
const tid = (id) => `[data-testid="${id}"]`;
const PASSWORD = `notify-${Math.random().toString(36).slice(2, 10)}`;

let tmp, srv, browser, ctx, page, rec;

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-notify-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  await ctx.grantPermissions(['notifications'], { origin: srv.url });
  await ctx.addInitScript(() => {
    window.__shown = [];
    ServiceWorkerRegistration.prototype.showNotification = function (title, opts) {
      window.__shown.push({ title, body: opts && opts.body, url: opts && opts.data && opts.data.url, tag: opts && opts.tag });
      return Promise.resolve();
    };
    window.__badge = null;
    Object.defineProperty(navigator, 'setAppBadge', { configurable: true, value: (n) => ((window.__badge = n), Promise.resolve()) });
    Object.defineProperty(navigator, 'clearAppBadge', { configurable: true, value: () => ((window.__badge = 0), Promise.resolve()) });
    window.__front = true;
    document.hasFocus = () => window.__front;
    window.__setHidden = (hidden) => {
      Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => (hidden ? 'hidden' : 'visible') });
      Object.defineProperty(document, 'hidden', { configurable: true, get: () => hidden });
      document.dispatchEvent(new Event('visibilitychange'));
    };
  });
  ({ page, rec } = await recordedPage(ctx, { label: 'notify' }));
  console.log(`# screenshots: ${SHOTS}`);
});

test.afterEach(async () => {
  if (page) await page.evaluate(() => {
    window.__front = true;
    if (document.visibilityState !== 'visible') window.__setHidden(false);
  }).catch(() => {});
});

test.after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

async function both(name) {
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(250);
    await shot(page, `${name}-${scheme}`);
  }
  await page.emulateMedia({ colorScheme: 'light' });
}

/** Payments shown to the page only (the engine is never told), kept across reads, locks and unlocks of this page. */
async function fakeTxs() {
  await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    window.__fake = window.__fake || new Map();
    if (wallet.__fakePatched) return;
    wallet.__fakePatched = true;
    const orig = wallet.refreshTxs.bind(wallet);
    wallet.refreshTxs = async function () {
      await orig();
      const fake = [...window.__fake.values()];
      const have = new Set(fake.map((t) => t.txId));
      this.state.txs = [...fake, ...this.state.txs.filter((t) => !have.has(t.txId))].sort((a, b) => b.create_time - a.create_time);
      this.emit();
    };
  });
}

/** Put (or change) payments in the page's list and read it. */
async function put(...txs) {
  await page.evaluate(async (list) => {
    const { wallet } = await import('./lib/wallet.js');
    const now = Math.floor(Date.now() / 1000);
    for (const t of list) window.__fake.set(t.txId, { tx_type: 0, fee: 100000, asset_id: 0, sender: 'ab', receiver: 'cd', create_time: now, ...(window.__fake.get(t.txId) || {}), ...t });
    await wallet.refreshTxs();
  }, txs);
  await sleep(400);
}

const shown = () => page.evaluate(() => window.__shown.map((n) => n.title));

/** Polls fn in the page until it returns true (page.waitForFunction takes an async function's promise as a yes). */
async function until(fn, arg = null, { timeout = 20000, label = 'condition' } = {}) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (await page.evaluate(fn, arg)) return;
    await sleep(300);
  }
  throw new Error(`timed out waiting for ${label}`);
}
const hex = (c) => c.repeat(16);

async function reminders() {
  return page.evaluate(async () => {
    const { rawStore } = await import('./lib/store.js');
    const keys = (await rawStore.keys('w:')).filter((k) => k.endsWith(':notify-reminders'));
    const out = [];
    for (const k of keys) out.push(...((await rawStore.get(k)) || []));
    return out;
  });
}

test('a new wallet, synced; Settings → Notifications: off, asked only from the switch, then on', { timeout: 15 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  await waitSynced(page);
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  assert.equal(await page.textContent(tid('notify-row-sub')), 'Off');
  await page.click(tid('notify-row'));
  await waitScreen(page, 'notifications');
  assert.match(await page.textContent(tid('notify-sub')), /^Off/);
  assert.match(await page.textContent(tid('notify-note')), /in the background until it locks itself/);
  assert.equal(await page.isVisible(tid('notify-kinds')), false, 'what to be told about shows once they are on');
  assert.equal(await page.isVisible(tid('notify-test')), false);
  // The switch is on screen on a 375 x 667 phone without scrolling.
  await page.setViewportSize({ width: 375, height: 667 });
  const box = await page.locator(tid('notify-switch')).boundingBox();
  assert.ok(box && box.y + box.height <= 667, 'the switch fits a small phone');
  await page.setViewportSize({ width: 390, height: 844 });
  await page.click(tid('notify-switch'));
  await page.waitForFunction(() => /^On/.test(document.querySelector('[data-testid="notify-sub"]').textContent));
  for (const k of ['in', 'out', 'underway', 'contracts', 'moves']) assert.equal(await page.isChecked(tid(`notify-kind-${k}`)), true, k);
  // Reminders while the app is closed (Chrome's Periodic Background Sync): off unless turned on.
  assert.equal(await page.isVisible(tid('notify-wakeups')), true, 'offered in Chrome');
  assert.equal(await page.isChecked(tid('notify-wakeups')), false, 'off by default');
  assert.match(await page.textContent(tid('notify-wakeups-sub')), /with no Beam PWA screen open to warn you/);
  // No amounts on the lock screen unless asked for; this suite turns them on to read them.
  assert.equal(await page.isChecked(tid('notify-amounts')), false, 'off by default');
  await page.click(tid('notify-amounts'));
  await until(async () => {
    const { getPrefs } = await import('./lib/store.js');
    return (await getPrefs()).notify.amounts === true;
  }, null, { label: 'amounts on' });
  await page.click(tid('notify-test'));
  await page.waitForFunction(() => window.__shown.length === 1);
  assert.deepEqual(await page.evaluate(() => window.__shown[0]), { title: 'Beam PWA notifications are on', body: 'A payment will be told like this.', url: '#open=notifications', tag: 'campfire-test' });
  await both('notify-01-settings');
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  assert.equal(await page.textContent(tid('notify-row-sub')), 'On');
});

test('in front: a banner for money in, nothing on the lock screen; out of front: a notification and the badge', { timeout: 5 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await fakeTxs();
  // The run counts as caught up 20 s after it settled; what turns up before is history.
  await sleep(25000);
  await page.evaluate(() => (window.__shown = []));
  await put({ txId: hex('a1'), income: true, status: 3, value: 50000000 }, { txId: hex('b1'), income: false, status: 1, value: 20000000 }, { txId: hex('c1'), income: true, status: 5, value: 30000000 }, { txId: hex('d1'), tx_type: 12, income: false, status: 1, value: 0 });
  await page.waitForSelector(tid('pay-banner'));
  assert.equal(await page.textContent(tid('pay-banner-title')), 'Received 0.5 BEAM');
  assert.deepEqual(await shown(), [], 'in front: the banner says it');
  await both('notify-02-banner');
  await page.click(tid('pay-banner-close'));

  // Another window in front (a computer): the page is visible but not focused.
  await page.evaluate(() => (window.__front = false));
  await put({ txId: hex('a2'), income: true, status: 3, value: 25000000 });
  await page.waitForFunction(() => window.__shown.length === 1);
  assert.deepEqual(await shown(), ['Received 0.25 BEAM']);
  assert.equal(await page.evaluate(() => window.__shown[0].url), `#open=activity&tx=${hex('a2')}`);
  assert.equal(await page.evaluate(() => window.__badge), 1);
  await page.evaluate(() => (window.__front = true));
});

test('leaving the app: payments under way said at once, reminders stored; changes while away notified; back: badge cleared', { timeout: 5 * 60000 }, async () => {
  await page.evaluate(() => {
    window.__shown = [];
    window.__front = false;
    window.__setHidden(true);
  });
  await page.waitForFunction(() => window.__shown.length >= 2, null, { timeout: 15000 });
  assert.deepEqual((await shown()).sort(), ['A payment to you is arriving', 'Your payment is still on its way']);
  // Back and away again: said once per payment.
  await page.evaluate(() => window.__setHidden(false));
  await sleep(300);
  await page.evaluate(() => window.__setHidden(true));
  await sleep(1000);
  assert.equal((await shown()).length, 2, 'not said again');
  // Stored once the private coins are read (a moment after leaving).
  await until(async () => {
    const { rawStore } = await import('./lib/store.js');
    const keys = (await rawStore.keys('w:')).filter((k) => k.endsWith(':notify-reminders'));
    let n = 0;
    for (const k of keys) n += ((await rawStore.get(k)) || []).length;
    return n >= 1;
  }, null, { label: 'the reminder stored' });
  const rem = await reminders();
  // One reminder for both payments, naming nothing (audit A-4): its id is its time, no payment id on disk.
  assert.equal(rem.length, 1, JSON.stringify(rem.map((r) => r.id)));
  assert.match(rem[0].id, /^rem-arr-\d+$/);
  assert.equal(rem[0].title, 'Payments are still waiting');
  assert.equal(rem[0].url, '#open=activity');
  assert.ok(!JSON.stringify(rem).includes(hex('b1')) && !JSON.stringify(rem).includes(hex('c1')), 'no payment id kept on disk');
  assert.ok(rem.every((r) => r.at > Date.now() + 15 * 60000 && !/BEAM\b.*\d|\d.*BEAM/.test(r.title)), 'later, and no amounts kept on disk');
  // While away: the send finishes, the contract call fails, the incoming payment fails, more money arrives.
  // Two at a time: four or more at once are one notification ("4 changes in your wallet").
  await put({ txId: hex('b1'), status: 3 }, { txId: hex('d1'), status: 4 });
  await put({ txId: hex('c1'), status: 4 }, { txId: hex('a3'), income: true, status: 3, value: 100000000 });
  await page.waitForFunction(() => window.__shown.length >= 6, null, { timeout: 15000 });
  // Both payments ended while away: their "still waiting" reminders are gone before the person is back.
  await until(async () => {
    const { rawStore } = await import('./lib/store.js');
    const keys = (await rawStore.keys('w:')).filter((k) => k.endsWith(':notify-reminders'));
    let n = 0;
    for (const k of keys) n += ((await rawStore.get(k)) || []).filter((r) => r.id.startsWith('rem-arr-')).length;
    return n === 0;
  }, null, { label: 'the reminders of payments that ended dropped' });
  const titles = (await shown()).slice(2);
  assert.ok(titles.includes('Sent 0.2 BEAM'), titles.join(' | '));
  assert.ok(titles.includes('Received 1 BEAM'), titles.join(' | '));
  assert.ok(titles.some((t) => /: did not go through$/.test(t)), 'the contract call');
  assert.ok(titles.includes('A payment of 0.3 BEAM to you did not go through'), titles.join(' | '));
  assert.equal(await page.evaluate(() => window.__badge), 4, 'the four changes since the person last came back (coming back clears it)');
  // Back: the badge is cleared, reminders about payments under way go.
  await page.evaluate(() => {
    window.__front = true;
    window.__setHidden(false);
  });
  await page.waitForFunction(() => window.__badge === 0);
  await sleep(500);
  assert.deepEqual(await reminders(), []);
});

test('the person chooses: no amounts on the lock screen; a kind turned off is not told', { timeout: 3 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('notifications'));
  await waitScreen(page, 'notifications');
  await page.click(tid('notify-amounts'));
  await page.click(tid('notify-kind-out'));
  await until(async () => {
    const { getPrefs } = await import('./lib/store.js');
    const p = await getPrefs();
    return Boolean(p.notify && p.notify.amounts === false && p.notify.kinds.out === false);
  }, null, { label: 'the choices saved' });
  await page.evaluate(() => {
    window.__shown = [];
    window.__front = false;
  });
  await put({ txId: hex('a4'), income: true, status: 3, value: 70000000 }, { txId: hex('b4'), income: false, status: 1, value: 1000000 });
  await page.waitForFunction(() => window.__shown.length >= 1);
  await put({ txId: hex('b4'), status: 3 });
  await sleep(1500);
  assert.deepEqual(await shown(), ['Payment received'], 'no amount; the finished send (Money out, off) not told');
  await page.click(tid('notify-amounts'));
  await page.click(tid('notify-kind-out'));
  await page.evaluate(() => (window.__front = true));
});

test('back after a lock: Home says what happened meanwhile, once', { timeout: 10 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  // Leaving saves what the wallet looked like; then the app locks.
  await page.evaluate(() => window.__setHidden(true));
  await until(async () => {
    const { rawStore } = await import('./lib/store.js');
    return (await rawStore.keys('w:')).some((k) => k.endsWith(':notify-snapshot'));
  }, null, { label: 'the statuses saved on leaving' });
  // Sealed (audit A-4): no payment id of this wallet in the clear.
  const stored = await page.evaluate(async () => {
    const { rawStore } = await import('./lib/store.js');
    const k = (await rawStore.keys('w:')).find((x) => x.endsWith(':notify-snapshot'));
    return JSON.stringify(await rawStore.get(k));
  });
  assert.ok(!/"txs"/.test(stored) && !stored.includes(hex('b1')) && !stored.includes(hex('a3')), 'the snapshot is sealed');
  await page.evaluate(() => window.__setHidden(false));
  await lock(page);
  // Found after the unlock: money in while the app was locked, and the sent payment that finished.
  await page.evaluate(() => {
    const now = Math.floor(Date.now() / 1000);
    window.__fake.set('e5'.repeat(16), { txId: 'e5'.repeat(16), tx_type: 0, fee: 100000, asset_id: 0, sender: 'ab', receiver: 'cd', create_time: now, income: true, status: 3, value: 12000000 });
  });
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 120000);
  await page.waitForSelector(tid('home-away'), { timeout: 120000 });
  assert.equal(await page.textContent(tid('home-away-text')), 'While you were away: received a payment (0.12 BEAM).');
  await both('notify-03-away');
  await page.click(tid('home-away-close'));
  assert.equal(await page.isVisible(tid('home-away')), false);
  await page.evaluate(() => window.__campfire.go('activity'));
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await sleep(500);
  assert.equal(await page.isVisible(tid('home-away')), false, 'once');
});

test('a tap on a notification opens what it was about; a link to anything else is ignored', { timeout: 3 * 60000 }, async () => {
  const tap = (url) => page.evaluate((u) => navigator.serviceWorker.dispatchEvent(new MessageEvent('message', { data: { type: 'campfire-open', url: u } })), url);
  await tap(`#open=activity&tx=${hex('a3')}`);
  await waitScreen(page, 'activity');
  await page.waitForFunction(() => document.querySelector('[data-testid="tx-detail-title"]')?.textContent === 'Received');
  await page.click('.sheet button:text-is("Close")');
  await tap('https://evil.example/#open=home');
  await tap('#open=../../x');
  await sleep(500);
  assert.equal(await page.evaluate(() => window.__campfire.screen()), 'activity');
  // Locked: it opens right after the unlock, and the unlock screen says so.
  await page.evaluate(() => window.__campfire.go('home'));
  await lock(page);
  await tap('#open=coins');
  await page.waitForSelector(tid('unlock-follow'));
  assert.match(await page.textContent(tid('unlock-follow')), /Unlock to see what the notification was about/);
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'coins', 120000);
});

test('other parts tell through the same notifier: on screen a banner that opens its screen; out of front a notification', { timeout: 2 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await page.evaluate(() => (window.__shown = []));
  // Through the app object the screens use.
  const tellVia = (opts) => page.evaluate(async (o) => {
    const { tellOther, notifyApp } = await import('./lib/notify.js');
    return tellOther(notifyApp(), o);
  }, opts);
  await tellVia({ kind: 'in', title: 'Money was paid to your BEAM name', body: 'Sent to your name alice.beam: 2 BEAM. Claim it on Home.', plainBody: 'Claim it on Home.', tag: 'names-inbox', url: '#open=names', banner: true });
  await page.waitForSelector(tid('pay-banner'));
  assert.equal(await page.textContent(tid('pay-banner-title')), 'Money was paid to your BEAM name');
  assert.deepEqual(await shown(), [], 'in front');
  await page.click(tid('pay-banner-open'));
  await waitScreen(page, 'names');
  await page.evaluate(() => (window.__front = false));
  await tellVia({ kind: 'moves', title: 'Your coins reached your Ethereum wallet', body: 'The bridge paid them.', tag: 'bridge-1', url: '#open=bridgeList' });
  assert.deepEqual(await page.evaluate(() => window.__shown.map((n) => [n.title, n.url])), [['Your coins reached your Ethereum wallet', '#open=bridgeList']]);
  await page.evaluate(() => window.__campfire.go('home'));
});

test('an address that expires: Extend in Your addresses, and a reminder 3 days before it expires', { timeout: 3 * 60000 }, async () => {
  const address = await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const a = await wallet.session.call('create_address', { type: 'regular', expiration: '24h', comment: 'From Alex' }, { timeoutMs: 20000 });
    await wallet.persistNow();
    return a;
  });
  await page.evaluate(() => window.__campfire.go('addresses'));
  await waitScreen(page, 'addresses');
  const tile = page.locator(`[data-address="${address}"]`);
  await tile.waitFor();
  const day = (ms) => new Date(ms).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
  assert.match(await tile.locator(tid('address-life')).textContent(), new RegExp(`Expires ${day(Date.now() + 86400000)}`));
  await tile.locator(tid('address-extend')).click();
  await page.waitForFunction(([a, d]) => document.querySelector(`[data-address="${a}"] [data-testid="address-life"]`)?.textContent.includes(`Expires ${d}`), [address, day(Date.now() + 61 * 86400000)], { timeout: 20000 });
  await shot(page, 'notify-04-address-extended');
  // Leaving: a reminder 3 days before it now expires, naming neither the address nor its label (audit A-4).
  await page.evaluate(() => window.__setHidden(true));
  await until(async () => {
    const { rawStore } = await import('./lib/store.js');
    const keys = (await rawStore.keys('w:')).filter((k) => k.endsWith(':notify-reminders'));
    for (const k of keys) if (((await rawStore.get(k)) || []).some((r) => r.id.startsWith('rem-addr-') && r.at > Date.now() + 50 * 86400000)) return true;
    return false;
  }, null, { label: 'the address reminder stored' });
  const r = (await reminders()).find((x) => x.id.startsWith('rem-addr-') && x.at > Date.now() + 50 * 86400000);
  assert.equal(r.title, 'An address of yours expires in 3 days');
  assert.ok(!JSON.stringify(await reminders()).includes(address.slice(0, 16)) && !JSON.stringify(await reminders()).includes('From Alex'), 'neither the address nor its label on disk');
  assert.equal(r.url, '#open=addresses');
  const days = (r.at - Date.now()) / 86400000;
  assert.ok(days > 57.9 && days < 58.1, `58 days from now (${days.toFixed(2)})`);
  await page.evaluate(() => window.__setHidden(false));
});

test('app closed: a wake-up shows nothing until "Reminders when Beam PWA is closed" is on; then the due reminders', { timeout: 3 * 60000 }, async () => {
  // Two reminders left for later: one due now, one not.
  await page.evaluate(async () => {
    const { rawStore } = await import('./lib/store.js');
    const { walletKey } = await import('./lib/wallet_scope.js');
    const { listWallets } = await import('./lib/wallets.js');
    const w = (await listWallets())[0];
    const now = Date.now();
    await rawStore.set(walletKey({ record: w }, 'notify-reminders'), [
      { id: 'rem-test-due', wallet: w.id, kind: 'in', at: now - 1000, title: 'A private payment can now be spent', body: 'Open Beam PWA to use it.', url: '#open=coins' },
      { id: 'rem-test-later', wallet: w.id, kind: 'in', at: now + 86400000, title: 'Later', body: 'Later', url: 'https://evil.example/' },
    ]);
  });
  const cdp = await ctx.newCDPSession(page);
  const regs = new Map();
  cdp.on('ServiceWorker.workerRegistrationUpdated', ({ registrations }) => registrations.forEach((r) => regs.set(r.registrationId, r)));
  await cdp.send('ServiceWorker.enable');
  await sleep(1000);
  const reg = [...regs.values()].find((r) => r.scopeURL.startsWith(srv.url) && !r.isDeleted);
  assert.ok(reg, 'the app has a service worker');
  const wake = () => cdp.send('ServiceWorker.dispatchPeriodicSyncEvent', { origin: new URL(srv.url).origin, registrationId: reg.registrationId, tag: 'campfire-reminders' });
  const swShown = () => page.evaluate(async () => (await (await navigator.serviceWorker.getRegistration()).getNotifications()).map((n) => n.title));
  // Off (the default): the wake-up shows nothing, keeps the reminders, and asks for no more wake-ups.
  await wake();
  await sleep(3000);
  assert.deepEqual((await reminders()).map((r) => r.id).sort(), ['rem-test-due', 'rem-test-later']);
  assert.ok(!(await swShown()).includes('A private payment can now be spent'), 'nothing shown while the switch is off');
  assert.deepEqual(await page.evaluate(async () => (await (await navigator.serviceWorker.getRegistration()).periodicSync.getTags())), [], 'no wake-ups asked for');
  // Turned on in Settings -> Notifications.
  await page.evaluate(() => window.__campfire.go('notifications'));
  await waitScreen(page, 'notifications');
  await page.click(tid('notify-wakeups'));
  await until(async () => (await (await import('./lib/store.js')).rawStore.get('prefs')).notify.wakeUps === true, null, { label: 'the switch saved' });
  await page.evaluate(() => document.querySelector('[data-testid="notify-wakeups"]').scrollIntoView({ block: 'center' }));
  await both('notify-05-wakeups-on');
  await page.evaluate(() => window.__campfire.go('home'));
  await wake();
  await until(async () => {
    const { rawStore } = await import('./lib/store.js');
    const keys = (await rawStore.keys('w:')).filter((k) => k.endsWith(':notify-reminders'));
    const all = [];
    for (const k of keys) all.push(...((await rawStore.get(k)) || []));
    return all.length === 1 && all[0].id === 'rem-test-later';
  }, null, { timeout: 30000, label: 'the due reminder shown and forgotten' });
  const real = await page.evaluate(async () => (await (await navigator.serviceWorker.getRegistration()).getNotifications()).map((n) => ({ title: n.title, url: n.data && n.data.url })));
  console.log(`# service worker notifications: ${JSON.stringify(real)}`);
  assert.deepEqual(real.filter((n) => n.title === 'A private payment can now be spent'), [{ title: 'A private payment can now be spent', url: '#open=coins' }]);
  await cdp.detach();
});

test('privacy: nothing leaves the device for notifications; no host but the origin and BEAM nodes; no CSP violation; no page error', async () => {
  assert.deepEqual(foreignHosts(rec, srv.url), []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
});

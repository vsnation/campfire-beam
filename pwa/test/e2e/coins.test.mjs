// Coins and Split coins, More ways to receive, and the payment notice, end to end: the installed
// Google Chrome (headless), its own build and port, BEAM mainnet. Spends nothing: a throwaway
// wallet that holds nothing.
//
//   npm run e2e:coins   (own build folder and port 8970, so it can run beside the other suites)
//
// The wallet is empty, so to see a split up to its approval the page is shown coins it does not
// have (the page's answers to get_utxo and wallet_status only): one coin of 1 BEAM, a change coin
// and a private coin BEAM still holds back. The engine still knows the truth; the test stops at
// the password sheet and checks that nothing reached the engine. Payments that "arrive" are put in
// the page's payment list the same way; the engine's own answers (-32005 for a max-privacy address
// on a wallet that does not scan) are real.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen, shot, sleep, foreignHosts, PWA, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';

const PORT = 8970;
const tid = (id) => `[data-testid="${id}"]`;
const PASSWORD = `coins-${Math.random().toString(36).slice(2, 10)}`;
const BEAM = 100000000;

let tmp, srv, browser, ctx, page, rec;

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-coins-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  // The system notifications the page makes, recorded (titles only); permission "granted".
  await ctx.addInitScript(() => {
    // In front the whole time: the banner tells, no system notification (out of front: e2e:notify).
    document.hasFocus = () => true;
    window.__notified = [];
    window.__asked = 0;
    function FakeNotification(title, opts) {
      window.__notified.push({ title, body: opts && opts.body });
      this.close = () => {};
      this.addEventListener = () => {};
    }
    FakeNotification.permission = 'default';
    FakeNotification.requestPermission = () => {
      window.__asked++;
      FakeNotification.permission = 'granted';
      return Promise.resolve('granted');
    };
    Object.defineProperty(window, 'Notification', { value: FakeNotification, configurable: true, writable: true });
  });
  ({ page, rec } = await recordedPage(ctx, { label: 'coins' }));
  console.log(`# screenshots: ${SHOTS}`);
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

/** The primary button is on screen without scrolling on a 375 x 667 phone. */
async function ctaFits(selector) {
  const vp = page.viewportSize();
  await page.setViewportSize({ width: 375, height: 667 });
  await sleep(300);
  await page.evaluate(() => window.scrollTo(0, 0));
  const box = await page.locator(selector).boundingBox();
  await page.setViewportSize(vp);
  assert.ok(box && box.y + box.height <= 667, `${selector} visible without scrolling at 375x667 (bottom ${box && Math.round(box.y + box.height)})`);
}

test('a new wallet, synced; Home has Coins one tap away', { timeout: 15 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  await waitSynced(page);
  assert.equal(await page.isVisible(tid('open-coins')), true);
  assert.equal(await page.isVisible(tid('private-maturing')), false, 'no private balance on an empty wallet');
  await page.click(tid('open-coins'));
  await waitScreen(page, 'coins');
  await page.waitForSelector(tid('coin-list-empty'));
  assert.match(await page.textContent(tid('split-funds')), /no BEAM it can spend/);
  assert.equal(await page.isDisabled(tid('split-cta')), true);
  assert.equal(await page.isVisible(tid('split-receive')), true, 'never a dead end: Receive BEAM');
  await both('coins-01-empty');
});

test('coins (shown to the page): the advice, the plan, each coin, a private one with its wait', { timeout: 5 * 60000 }, async () => {
  const height = await page.evaluate(() => window.__campfire.height());
  await page.evaluate(
    async ({ height, BEAM }) => {
      const { wallet } = await import('./lib/wallet.js');
      window.__engineCalls = [];
      const coins = [
        { id: 'aa01', asset_id: 0, amount: BEAM, type: 'norm', status: 1, status_string: 'available', maturity: height - 500, createTxId: '', spentTxId: '' },
        { id: 'aa02', asset_id: 0, amount: 4000000, type: 'chng', status: 1, status_string: 'available', maturity: height - 400, createTxId: '', spentTxId: '' },
        // A max-privacy coin that arrived 11 hours ago: BEAM releases it 72 hours after it arrived.
        { id: '7123', asset_id: 0, amount: 1000000, type: 'shld', status: 2, status_string: 'maturing', maturity: height - 660, createTxId: '', spentTxId: '' },
      ];
      const wrap = (session) => {
        if (!session || session.__coinsStub) return;
        const orig = session.call.bind(session);
        session.call = (method, params, opts) => {
          window.__engineCalls.push(method);
          if (method === 'get_utxo') return Promise.resolve((params && params.skip) ? [] : coins);
          return orig(method, params, opts);
        };
        session.__coinsStub = true;
      };
      wrap(wallet.session);
      const origStatus = wallet.refreshStatus.bind(wallet);
      wallet.refreshStatus = async function () {
        await origStatus();
        wrap(this.session);
        this.state.totals.set(0, { available: BigInt(BEAM + 4000000), receiving: 0n, sending: 0n, maturing: 1000000n, maturingMp: 1000000n });
        this.emit();
      };
      await wallet.refreshStatus();
    },
    { height, BEAM },
  );
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await page.waitForSelector(tid('private-maturing'));
  assert.match(await page.textContent(tid('private-maturing')), /0\.01 BEAM arrived privately: spendable in about (61|62) hours/);
  assert.doesNotMatch(await page.textContent('.balance .pending').catch(() => ''), /maturing/, 'the private coin is not also "maturing"');
  await both('coins-02-home-private');

  await page.click(tid('private-maturing'));
  await waitScreen(page, 'coins');
  await page.waitForSelector(tid('split-cta'));
  // 1.04 BEAM in two coins, the large one 96%: worth splitting, 4 coins by default (BEAM Light Wallet's rule).
  assert.match(await page.textContent(tid('split-now')), /^1\.04 BEAM in 2 coins; the largest holds 96%$/);
  assert.equal(await page.textContent(tid('split-cta')), 'Split into 4 coins');
  assert.equal(await page.getAttribute(tid('split-count-4'), 'aria-checked'), 'true');
  await page.click(tid('split-count-5'));
  assert.equal(await page.textContent(tid('split-cta')), 'Split into 5 coins');
  assert.equal(await page.textContent(tid('split-new-coins')), '5 coins of 0.18 BEAM');
  assert.equal(await page.textContent(tid('split-fee')), '0.00118 BEAM');
  assert.equal(await page.isDisabled(tid('split-cta')), false);
  const rows = await page.$$eval(tid('coin-row'), (els) => els.map((e) => ({ type: e.dataset.type, status: e.dataset.status, text: e.textContent })));
  assert.equal(rows.length, 3);
  const priv = rows.find((r) => r.type === 'shld');
  assert.match(priv.text, /0\.01 BEAMPrivateSpendable in about (61|62) hours/);
  assert.match(rows.find((r) => r.type === 'chng').text, /Change/);
  assert.equal(await page.isVisible(tid('coin-private-note')), true);
  await ctaFits(tid('split-cta'));
  await both('coins-03-split');
  await page.locator(tid('coin-list')).scrollIntoViewIfNeeded();
  await both('coins-04-coin-list');
});

test('the review: what stays, what leaves; the password sheet; cancel sends nothing', { timeout: 5 * 60000 }, async () => {
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.click(tid('split-cta'));
  await waitScreen(page, 'splitReview');
  await page.waitForSelector(tid('split-confirm-cta'));
  assert.match(await page.textContent(tid('split-review-note')), /Nothing leaves your wallet/);
  assert.equal(await page.textContent(tid('split-review-now')), '1.04 BEAM in 2 coins');
  assert.equal(await page.textContent(tid('split-review-new')), '5 coins of 0.18 BEAM');
  assert.equal(await page.textContent(tid('split-review-leaves')), '0.00118 BEAM');
  assert.equal(await page.textContent(tid('split-confirm-cta')), 'Split into 5 coins');
  await ctaFits(tid('split-confirm-cta'));
  await both('coins-05-review');
  await page.click(tid('split-confirm-cta'));
  await page.waitForSelector(tid('auth-pw'));
  assert.match(await page.textContent('.sheet'), /Split 0\.9 BEAM into 5 coins/);
  await shot(page, 'coins-06-approve');
  await page.click(tid('auth-cancel'));
  await page.waitForSelector('.sheet', { state: 'detached' });
  const calls = await page.evaluate(() => window.__engineCalls);
  assert.equal(calls.includes('tx_split'), false, 'nothing reached the engine');
  assert.equal(calls.includes('generate_tx_id'), false);
  assert.equal(await page.isDisabled(tid('split-confirm-cta')), false, 'it can still be approved');
  // "Change" goes back to the coins as they were.
  await page.click(tid('split-review-change-btn'));
  await waitScreen(page, 'coins');
});

test('More ways to receive: off on a wallet that does not scan, with what turns them on; the engine agrees', { timeout: 5 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('receive'));
  await waitScreen(page, 'receive');
  await page.waitForSelector(tid('receive-address'));
  await page.click(tid('more-ways-toggle'));
  await page.waitForSelector(tid('more-ways-blocked'));
  assert.equal(await page.getAttribute(tid('more-ways-blocked'), 'data-block'), 'noScan');
  assert.match(await page.textContent(tid('more-ways-blocked')), /Rescan/);
  for (const t of ['offline', 'max_privacy', 'public_offline']) assert.equal(await page.isDisabled(tid(`receive-type-${t}`)), true, `${t} off`);
  assert.equal(await page.isVisible(tid('more-ways-rescan')), true);
  assert.equal(await page.isVisible(tid('more-ways-ownNode')), true);
  // Measured 2026-10-11: the engine refuses these addresses without block scanning (-32005).
  const r = await page.evaluate(() => window.__campfire.createAddress('max_privacy'));
  assert.equal(r.ok, false);
  assert.equal(r.code, -32005);
  await page.locator(tid('more-ways')).scrollIntoViewIfNeeded();
  await both('coins-07-more-ways-off');
  // Share stays the first thing on Receive at 375 x 667.
  await page.click(tid('more-ways-toggle'));
  await ctaFits(tid('share'));

  // Were the page to believe it scans, the engine's refusal is said plainly, never as a crash.
  await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    wallet.state.scanning = true;
    wallet.emit();
  });
  await page.click(tid('more-ways-toggle'));
  await page.waitForFunction(() => !document.querySelector('[data-testid="receive-type-max_privacy"]').disabled);
  await page.locator(tid('more-ways')).scrollIntoViewIfNeeded();
  await both('coins-08-more-ways-on');
  await page.click(tid('receive-type-max_privacy'));
  await page.waitForSelector(tid('more-ways-error'));
  assert.match(await page.textContent(tid('more-ways-error')), /Rescan turns that on/);
  await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    wallet.state.scanning = false;
    wallet.emit();
  });
});

test('payment notifications: asked once from the switch; in front, a banner for money in, never for money out', { timeout: 5 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.locator(tid('notify-row')).scrollIntoViewIfNeeded();
  assert.equal(await page.textContent(tid('notify-row-sub')), 'Off');
  await page.click(tid('notify-row'));
  await waitScreen(page, 'notifications');
  assert.match(await page.textContent(tid('notify-sub')), /^Off/);
  assert.match(await page.textContent(tid('notify-note')), /until it locks itself/);
  assert.equal(await page.evaluate(() => window.__asked), 0, 'never asked by itself');
  await page.click(tid('notify-switch'));
  await page.waitForFunction(() => /^On/.test(document.querySelector('[data-testid="notify-sub"]').textContent));
  assert.equal(await page.evaluate(() => window.__asked), 1);
  await both('coins-09-settings');

  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  assert.equal(await page.isVisible(tid('pay-banner')), false, 'the first read was history: nothing announced');
  // Money arrives, and the wallet sends and splits: only the first is news.
  await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const now = Math.floor(Date.now() / 1000);
    const fake = [
      { txId: 'f1'.repeat(16), tx_type: 0, income: true, status: 3, value: 50000000, fee: 100000, asset_id: 0, sender: 'ab', receiver: 'cd', create_time: now },
      { txId: 'f2'.repeat(16), tx_type: 0, income: false, status: 3, value: 20000000, fee: 100000, asset_id: 0, sender: 'cd', receiver: 'ef', create_time: now - 1 },
      { txId: 'f3'.repeat(16), tx_type: 0, income: false, status: 3, value: 90000000, fee: 118000, asset_id: 0, sender: '', receiver: '', create_time: now - 2 },
    ];
    const orig = wallet.refreshTxs.bind(wallet);
    wallet.refreshTxs = async function () {
      await orig();
      const have = new Set(this.state.txs.map((t) => t.txId));
      this.state.txs = [...fake.filter((t) => !have.has(t.txId)), ...this.state.txs];
      this.emit();
    };
    await wallet.refreshTxs();
  });
  await page.waitForSelector(tid('pay-banner'));
  assert.equal(await page.textContent(tid('pay-banner-title')), 'Received 0.5 BEAM');
  const notified = await page.evaluate(() => window.__notified);
  assert.deepEqual(notified.map((n) => n.title), [], 'in front: the banner says it, no system notification');
  await both('coins-10-banner');
  // The split is named as Beam PWA names it, and only its fee left.
  const split = page.locator('[data-split="1"]').first();
  assert.match(await split.textContent(), /Split into coins.*0\.9 BEAM.*−0\.00118 BEAM/);
  await page.click(tid('pay-banner-open'));
  await waitScreen(page, 'activity');
  await page.waitForSelector(tid('tx-detail-title'));
  assert.equal(await page.textContent(tid('tx-detail-title')), 'Received');
  await page.click('.sheet button:text-is("Close")');
  await page.waitForSelector('.sheet', { state: 'detached' });
  await page.locator('[data-split="1"]').first().click();
  await page.waitForFunction(() => document.querySelector('[data-testid="tx-detail-title"]')?.textContent === 'Split into coins');
  await both('coins-11-split-detail');
  // Still once: another read announces nothing new.
  await page.evaluate(async () => (await import('./lib/wallet.js')).wallet.refreshTxs());
  await sleep(500);
  assert.equal((await page.evaluate(() => window.__notified)).length, 0);
  assert.equal(await page.locator(tid('pay-banner')).count(), 0, 'no second banner');
});

test('privacy: no host but the origin and BEAM nodes; no CSP violation; no page error', async () => {
  assert.deepEqual(foreignHosts(rec, srv.url), []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
});

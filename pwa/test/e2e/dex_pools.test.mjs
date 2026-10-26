// DEX pools end to end: the installed Google Chrome (headless), the dev server on its own
// port and build, BEAM mainnet. Spends nothing: a throwaway wallet that holds nothing.
//
//   npm run e2e:dex-pools
//
// The pools list, a pool, adding and withdrawing up to the approve sheet, creating a pool up
// to the approve sheet: each sheet is cancelled and the engine is checked to have sent nothing.
// As in the swap test, the screens are shown balances the wallet does not have (the page's
// state only) so their buttons work; the engine still knows the truth, and the approve sheet
// must show what the engine reports - "Not enough", no approve button - not what the screen believed.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, shot, waitScreen, foreignHosts, sleep, SHOTS, PWA } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';

const PORT = Number(process.env.CAMPFIRE_DEX_POOLS_PORT || 8900);
const PASSWORD = `pools-${Math.random().toString(36).slice(2, 10)}`;
const FOMO = 174;
const LP = 175; // BEAM/FOMO 1%
const tid = (id) => `[data-testid="${id}"]`;
const groth = (text) => {
  const m = /([\d,]+(?:\.\d+)?)/.exec(text);
  const [w, f = ''] = m[1].replace(/,/g, '').split('.');
  return BigInt(w) * 100000000n + BigInt((f + '00000000').slice(0, 8));
};

let tmp, srv, browser, ctx, page, rec;

before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-dex-pools-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  ({ page, rec } = await recordedPage(ctx, { label: 'pools' }));
  console.log(`# screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

/** Light and dark, at 390x844. */
async function shots(name) {
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(250);
    await shot(page, `${name}-${scheme}`);
  }
  await page.emulateMedia({ colorScheme: 'light' });
}

/** The primary button is on screen without scrolling on a 375x667 phone. */
async function ctaVisibleOnSmallPhone(selector, name) {
  await page.setViewportSize({ width: 375, height: 667 });
  await page.evaluate(() => window.scrollTo(0, 0));
  await sleep(300);
  const box = await page.locator(selector).boundingBox();
  await shot(page, `${name}-375x667`);
  await page.setViewportSize({ width: 390, height: 844 });
  assert.ok(box && box.y >= 0 && box.y + box.height <= 667, `${selector} visible without scrolling on 375x667 (${JSON.stringify(box)})`);
}

async function engineTruth() {
  return page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const txs = await wallet.session.call('tx_list', { count: 100, skip: 0 });
    const st = await wallet.session.call('wallet_status', { nz_totals: true });
    return { contractTxs: txs.filter((t) => Number(t.tx_type) === 12).length, allTxs: txs.length, available: String(st.available) };
  });
}

test('a new wallet, synced', { timeout: 15 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  await waitSynced(page);
  const loads = await page.evaluate(() => performance.getEntriesByType('resource').filter((e) => /\/screens\/pool|dex_liquidity/.test(e.name)).length);
  assert.equal(loads, 0, 'the pool screens load only when one is opened');
});

test('Home: a pool share is a row that opens its page, which leads to its pool', { timeout: 5 * 60000 }, async () => {
  // The screen is shown 12 BEAM, 100,000 FOMO and 1 BEAM/FOMO LP; the engine holds nothing.
  await page.evaluate(async ([fomo, lp]) => {
    const { wallet } = await import('./lib/wallet.js');
    const orig = wallet.refreshStatus.bind(wallet);
    const t = (v) => ({ available: v, receiving: 0n, sending: 0n, maturing: 0n });
    wallet.refreshStatus = async function () {
      await orig();
      this.state.totals.set(0, t(1200000000n));
      this.state.totals.set(fomo, t(10000000000000n));
      this.state.totals.set(lp, t(100000000n));
      this.emit();
    };
    await wallet.refreshStatus();
  }, [FOMO, LP]);
  const row = page.locator(`[data-testid="token-row"][data-asset-id="${LP}"]`);
  await row.waitFor({ timeout: 30000 });
  // Every token row opens its token page (screens/token.js); an LP token's page has Pool.
  assert.equal(await row.evaluate((el) => el.tagName), 'BUTTON');
  assert.match(await row.locator(tid('token-name')).textContent(), /^BEAM\/FOMO LP$/);
  await row.scrollIntoViewIfNeeded();
  await shots('pools-00-home-lp-row');
});

test('Swap -> Pools: yours first, then all; sizes, shares, a price that flips, search', { timeout: 5 * 60000 }, async () => {
  await page.click(tid('swap'));
  await waitScreen(page, 'swap');
  await page.click(tid('swap-pools'));
  await waitScreen(page, 'pools');
  await page.waitForSelector(tid('pools-loading'), { timeout: 10000 }).catch(() => {});
  await page.waitForSelector(tid('pool-card'), { timeout: 120000 });
  const loads = await page.evaluate(() => performance.getEntriesByType('resource').filter((e) => e.name.endsWith('/shaders/amm_app.wasm')).length);
  assert.equal(loads, 1, 'the DEX shader loads once');
  assert.equal(await page.textContent(tid('pools-mine-title')), 'Your pools');
  const first = page.locator(tid('pool-card')).first();
  assert.equal(await first.getAttribute('data-pool'), '0-174-2', 'the pool this wallet holds a share of comes first');
  assert.match(await first.locator(tid('pool-share')).textContent(), /^Your share of the pool: (< 0\.01|\d+(\.\d+)?)%$/);
  assert.match(await first.locator(tid('pool-name')).textContent(), /^BEAM \/ FOMO$/);
  assert.match(await first.locator(tid('pool-reserves')).textContent(), /^[\d,.]+ BEAM · [\d,.]+ FOMO$/);
  assert.match(await first.locator(tid('pool-size')).textContent(), /^Pool size ≈ [\d,.]+ BEAM$/);
  const all = await page.textContent(tid('pools-all-title'));
  const n = Number(/· (\d+)/.exec(all)[1]);
  console.log(`# ${all}`);
  assert.ok(n >= 20, 'every pool with liquidity is listed');
  // The price flips, and back.
  const rate = first.locator(tid('pool-rate'));
  const r0 = await rate.textContent();
  assert.match(r0, /^1 BEAM ≈ [\d,.]+ FOMO$/);
  await rate.click();
  const r1 = await rate.textContent();
  assert.match(r1, /^1 FOMO ≈ [\d,.]+ BEAM$/);
  await rate.click();
  assert.equal(await rate.textContent(), r0);
  console.log(`# ${r0} / ${r1}`);
  await page.evaluate(() => window.scrollTo(0, 0));
  await shots('pools-01-list');
  // Search by ticker, by number, and nothing.
  await page.fill(tid('pools-search'), 'fomo');
  await sleep(200);
  const names = await page.$$eval('[data-testid="pool-name"]', (els) => els.map((e) => e.textContent));
  assert.ok(names.length >= 1 && names.every((t) => /FOMO/.test(t)), names.join('|'));
  await page.fill(tid('pools-search'), '#174');
  await sleep(200);
  assert.ok((await page.$$eval('[data-testid="pool-name"]', (els) => els.map((e) => e.textContent))).every((t) => /FOMO/.test(t)));
  await page.fill(tid('pools-search'), 'qqzzxx');
  await page.waitForSelector(tid('pools-no-match'));
  assert.equal(await page.locator(tid('pool-card')).count(), 0);
  await shots('pools-02-no-match');
  await page.fill(tid('pools-search'), '');
  await page.waitForSelector(tid('pool-card'));
  await ctaVisibleOnSmallPhone(tid('pools-create'), 'pools-01b-list');
});

test('a pool: price, reserves, your share; add up to the approve sheet, Cancel sends nothing', { timeout: 8 * 60000 }, async () => {
  await page.locator(tid('pool-card')).first().locator(tid('pool-open')).click();
  await waitScreen(page, 'pool');
  await page.waitForSelector(tid('pool-head'), { timeout: 60000 });
  assert.match(await page.textContent(tid('pool-name')), /^BEAM \/ FOMO$/);
  assert.equal(await page.textContent(tid('pool-fee')), '1% fee');
  assert.match(await page.textContent(`${tid('pool-price')} span`), /^1 BEAM ≈ [\d,.]+ FOMO$/);
  await page.click(tid('pool-price'));
  assert.match(await page.textContent(`${tid('pool-price')} span`), /^1 FOMO ≈ [\d.]+ BEAM$/);
  await page.click(tid('pool-price'));
  assert.match(await page.textContent(tid('pool-reserves')), /[\d,.]+ BEAM[\d,.]+ FOMOPool size ≈ [\d,.]+ BEAM/);
  assert.equal(await page.textContent('.topbar h1'), 'BEAM/FOMO pool');
  assert.match(await page.textContent(tid('pool-my-share')), /%$/);
  assert.match(await page.textContent(tid('pool-my-value')), /BEAM$/);
  assert.match(await page.textContent(tid('pool-my-value-note')), /^[\d,.]+ BEAM \+[\d,.]+ FOMO$/);
  assert.equal(await page.getAttribute(tid('pool-mode-add'), 'aria-pressed'), 'true');

  // Type BEAM: the pool fills in the FOMO.
  await page.fill(tid('pool-add-1'), '0.01');
  await page.waitForSelector(tid('pool-get-lp'), { timeout: 60000 });
  const fomo = await page.inputValue(tid('pool-add-2'));
  assert.ok(Number(fomo) > 0, `matching FOMO filled in: ${fomo}`);
  assert.equal(await page.textContent(`${tid('pool-side-2')} .swap-label`), 'Matching amount');
  assert.match(await page.textContent(tid('pool-get-lp')), /^≈ [\d,.]+ BEAM\/FOMO LP$/);
  assert.match(await page.textContent(tid('pool-share-after')), /%$/);
  assert.equal(await page.textContent(tid('pool-fee-network')), '0.011 BEAM');
  assert.equal(await page.textContent(tid('pool-total-beam')), '0.021 BEAM');
  await page.waitForFunction(() => !document.querySelector('[data-testid="pool-cta"]').disabled, null, { timeout: 30000 });
  const cta = await page.textContent(tid('pool-cta'));
  assert.match(cta, /^Add 0\.01 BEAM \+ [\d,.]+ FOMO$/);
  console.log(`# add: 0.01 BEAM + ${fomo} FOMO -> ${await page.textContent(tid('pool-get-lp'))}, share after ${await page.textContent(tid('pool-share-after'))}`);
  await page.evaluate(() => window.scrollTo(0, 0));
  await shots('pools-03-pool-add');
  await ctaVisibleOnSmallPhone(tid('pool-cta'), 'pools-03b-pool-add');

  await page.click(tid('pool-cta'));
  await page.waitForSelector(tid('consent'), { timeout: 90000 });
  assert.equal(await page.textContent('.consent h2'), 'Confirm your deposit');
  assert.equal(await page.textContent(tid('consent-pay-0')), '0.01 BEAM');
  const payFomo = await page.textContent(tid('consent-pay-1'));
  assert.match(payFomo, / FOMO$/);
  assert.equal(groth(payFomo), groth(fomo), 'the sheet pays the FOMO the screen showed');
  assert.match(await page.textContent(tid('consent-get-0')), / BEAM\/FOMO LP$/);
  assert.equal(await page.textContent(tid('consent-fee')), '0.011 BEAM');
  assert.equal(await page.textContent(tid('consent-total')), '0.021 BEAM');
  assert.equal(await page.textContent(tid('consent-extra-0')), 'BEAM/FOMO · 1% fee');
  assert.match(await page.textContent(tid('consent-not-enough')), /^Not enough /);
  assert.equal(await page.isVisible(tid('consent-approve')), false, 'the engine says it is not enough: no approve button');
  await shots('pools-04-add-sheet');
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(tid('pool-result'), { timeout: 30000 });
  const r = await page.$eval(tid('pool-result'), (el) => ({ code: el.dataset.code, rpc: el.dataset.rpc, text: el.textContent }));
  assert.equal(r.code, 'rejected');
  assert.equal(r.rpc, '-32021');
  assert.match(r.text, /Nothing was sent/);
  const last = (await page.evaluate(() => window.__campfire.consents())).at(-1);
  assert.equal(last.decision, 'rejected');
  assert.deepEqual(last.spends.map((s) => s.assetId).sort((a, b) => a - b), [0, FOMO]);
  assert.deepEqual(last.receives.map((s) => s.assetId), [LP]);
  assert.equal(last.fee, '0.011');

  // Type FOMO instead: the pool fills in the BEAM.
  await page.fill(tid('pool-add-2'), '100');
  await page.waitForFunction(() => Number(document.querySelector('[data-testid="pool-add-1"]').value) > 0, null, { timeout: 60000 });
  assert.equal(await page.textContent(`${tid('pool-side-1')} .swap-label`), 'Matching amount');
  // Max: as much as both balances allow.
  await page.click(tid('pool-max-1'));
  await page.waitForSelector(tid('pool-get-lp'), { timeout: 60000 });
  const maxBeam = groth(await page.inputValue(tid('pool-add-1')));
  assert.ok(maxBeam > 0n && maxBeam <= 1200000000n - 1100000n, `Max leaves the network fee: ${maxBeam}`);
});

test('withdraw: a share by percent or exactly, up to the approve sheet, Cancel sends nothing', { timeout: 6 * 60000 }, async () => {
  await page.click(tid('pool-mode-withdraw'));
  await page.waitForSelector(tid('pool-get-back'), { timeout: 60000 });
  assert.equal(await page.getAttribute(tid('pool-pct-100'), 'aria-pressed'), 'true', 'all of it unless chosen otherwise');
  assert.equal(await page.textContent(tid('pool-return-lp')), '1 LP');
  await page.click(tid('pool-pct-50'));
  await page.waitForFunction(() => document.querySelector('[data-testid="pool-return-lp"]')?.textContent === '0.5 LP', null, { timeout: 60000 });
  await page.fill(tid('pool-withdraw-exact'), '0.25');
  await page.waitForFunction(() => document.querySelector('[data-testid="pool-return-lp"]')?.textContent === '0.25 LP', null, { timeout: 60000 });
  assert.equal(await page.getAttribute(tid('pool-pct-50'), 'aria-pressed'), 'false');
  const back = await page.textContent(tid('pool-get-back'));
  assert.match(back, /^[\d,.]+ BEAM \+[\d,.]+ FOMO$/);
  assert.match(await page.textContent(tid('pool-get-back-note')), /BEAM$/);
  await page.waitForFunction(() => !document.querySelector('[data-testid="pool-cta"]').disabled, null, { timeout: 30000 });
  assert.match(await page.textContent(tid('pool-cta')), /^Withdraw [\d,.]+ BEAM \+ [\d,.]+ FOMO$/);
  console.log(`# withdraw 0.25 LP -> ${back}`);
  await page.evaluate(() => window.scrollTo(0, 0));
  await shots('pools-05-pool-withdraw');
  await ctaVisibleOnSmallPhone(tid('pool-cta'), 'pools-05b-pool-withdraw');
  // More than held: said, button off.
  await page.fill(tid('pool-withdraw-exact'), '2');
  await page.waitForFunction(() => /You hold 1 LP/.test(document.querySelector('[data-testid="pool-reason"]').textContent));
  await page.fill(tid('pool-withdraw-exact'), '0.25');
  await page.waitForFunction(() => !document.querySelector('[data-testid="pool-cta"]').disabled, null, { timeout: 60000 });

  await page.click(tid('pool-cta'));
  await page.waitForSelector(tid('consent'), { timeout: 90000 });
  assert.equal(await page.textContent('.consent h2'), 'Confirm your withdrawal');
  assert.equal(await page.textContent(tid('consent-pay-0')), '0.25 BEAM/FOMO LP');
  const gets = [await page.textContent(tid('consent-get-0')), await page.textContent(tid('consent-get-1'))].join(' | ');
  assert.match(gets, /BEAM/);
  assert.match(gets, /FOMO/);
  assert.equal(await page.textContent(tid('consent-fee')), '0.011 BEAM');
  assert.match(await page.textContent('.consent'), /You return/);
  assert.match(await page.textContent('.consent'), /You get back/);
  await shots('pools-06-withdraw-sheet');
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(tid('pool-result'), { timeout: 30000 });
  assert.equal(await page.getAttribute(tid('pool-result'), 'data-code'), 'rejected');
});

test('create a pool: deposit stated first, an existing pool named, the approve sheet, Cancel sends nothing', { timeout: 6 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('pools'));
  await waitScreen(page, 'pools');
  await page.waitForSelector(tid('pool-card'), { timeout: 60000 });
  await page.click(tid('pools-create'));
  await waitScreen(page, 'poolCreate');
  await page.waitForSelector(tid('create-deposit-note'));
  assert.match(await page.textContent(tid('create-deposit-note')), /locks a 10 BEAM deposit/);
  assert.match(await page.textContent(tid('create-asset-a')), /BEAM/);
  assert.equal(await page.getAttribute(tid('create-kind-2'), 'aria-checked'), 'true', '1% pre-selected');
  await page.waitForFunction(() => /Choose the second asset/.test(document.querySelector('[data-testid="create-reason"]').textContent), null, { timeout: 60000 });
  await shots('pools-07-create-empty');
  await page.click(tid('create-asset-b'));
  await page.waitForSelector(`.sheet [data-asset-id="${FOMO}"]`);
  await page.click(`.sheet [data-asset-id="${FOMO}"]`);
  // BEAM/FOMO 1% exists: said, with a way there; the button stays off.
  await page.waitForSelector(tid('create-exists'));
  assert.match(await page.textContent(tid('create-exists')), /BEAM\/FOMO pool with a 1% fee already exists/);
  assert.equal(await page.isDisabled(tid('create-cta')), true);
  await shots('pools-08-create-exists');
  // A fee tier that has no BEAM/FOMO pool yet.
  const free = await page.evaluate(async () => {
    const { loadPools } = await import('./lib/dex_pools.js');
    const pools = await loadPools();
    return [1, 0].find((k) => !pools.some((p) => p.aid1 === 0 && p.aid2 === 174 && p.kind === k));
  });
  assert.ok(free != null, 'a BEAM/FOMO fee tier without a pool');
  await page.click(tid(`create-kind-${free}`));
  await page.waitForFunction(() => !document.querySelector('[data-testid="create-cta"]').disabled, null, { timeout: 30000 });
  assert.equal(await page.textContent(tid('create-cta')), 'Create the BEAM/FOMO pool');
  assert.equal(await page.textContent(tid('create-total')), '10.01471 BEAM');
  await shots('pools-09-create-ready');
  await ctaVisibleOnSmallPhone(tid('create-cta'), 'pools-09b-create');

  await page.click(tid('create-cta'));
  await page.waitForSelector(tid('consent'), { timeout: 90000 });
  assert.equal(await page.textContent('.consent h2'), 'Confirm the new pool');
  assert.equal(await page.textContent(tid('consent-pay-0')), '10 BEAM');
  assert.equal(await page.textContent(tid('consent-fee')), '0.01471 BEAM', 'the fee the screen stated');
  assert.equal(await page.textContent(tid('consent-total')), '10.01471 BEAM');
  assert.match(await page.textContent(tid('consent-extra-0')), /^BEAM\/FOMO · 0\.(05|3)% fee$/);
  assert.match(await page.textContent(tid('consent-warn')), /stays locked/);
  assert.match(await page.textContent(tid('consent-not-enough')), /^Not enough BEAM/);
  await shots('pools-10-create-sheet');
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(tid('create-result'), { timeout: 30000 });
  assert.equal(await page.getAttribute(tid('create-result'), 'data-code'), 'rejected');
  const truth = await engineTruth();
  console.log(`# engine after three cancelled sheets: ${JSON.stringify(truth)}`);
  assert.deepEqual(truth, { contractTxs: 0, allTxs: 0, available: '0' });
});

test('the new-pool sheet with enough BEAM: approving needs the tick first', { timeout: 2 * 60000 }, async () => {
  // The sheet as a wallet holding 11 BEAM would see it (built from a request, not sent anywhere).
  const shown = page.evaluate(async () => {
    const { presentConsent } = await import('./screens/consent.js');
    const { wallet } = await import('./lib/wallet.js');
    const req = {
      id: 'x', kind: 'contract', appId: 'x', appName: 'BEAM Campfire', native: true, unchecked: false, comment: '', fee: 1471000n, feeText: '0.01471', isEnough: true,
      spends: [{ assetId: 0, amount: 1000000000n, amountText: '10' }], receives: [], address: null, isOnline: null,
      intent: { action: 'poolCreate', rows: [['New pool', 'BEAM/FOMO · 0.05% fee']], warn: 'The 10 BEAM deposit stays locked in the DEX until the pool is empty and you, its creator, close it.', ack: 'I understand the 10 BEAM stays locked until the pool is empty' },
    };
    return presentConsent({ wallet, go() {} }, req);
  });
  await page.waitForSelector(tid('consent-ack'));
  assert.equal(await page.isDisabled(tid('consent-approve')), true, 'no approving before the tick');
  assert.equal(await page.textContent(tid('consent-approve')), 'Lock 10 BEAM and create the pool');
  await shots('pools-11-create-sheet-tick');
  await page.click(tid('consent-ack-box'));
  assert.equal(await page.isDisabled(tid('consent-approve')), false);
  await page.click(tid('consent-cancel'));
  assert.equal(await shown, false);
});

test('Home: the LP row opens its page, and Pool opens the pool on the Withdraw tab', { timeout: 2 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await page.click(`[data-testid="token-row"][data-asset-id="${LP}"]`);
  await waitScreen(page, 'token');
  await page.click(tid('token-pool'));
  await waitScreen(page, 'pool');
  await page.waitForSelector(tid('pool-withdraw-form'), { state: 'visible', timeout: 60000 });
  assert.equal(await page.getAttribute(tid('pool-mode-withdraw'), 'aria-pressed'), 'true');
  assert.equal(await page.evaluate(() => window.__campfire.backStack()).then((s) => s.at(-1)), 'token', 'Back returns to the token page');
});

test('lock closes every app; nothing pending', { timeout: 120000 }, async () => {
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await page.click(tid('lock'));
  await waitScreen(page, 'unlock');
  assert.deepEqual(await page.evaluate(() => window.__campfire.contracts()), { bound: false, apps: 0, inflight: 0, consents: 0, presenter: true });
});

test('IP privacy and a clean console: only this origin and the chosen node', async () => {
  assert.deepEqual(foreignHosts(rec, srv.url), []);
  assert.deepEqual(rec.csp, []);
  assert.deepEqual(rec.errors, []);
});

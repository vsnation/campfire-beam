// Swap and consent end-to-end: the installed Google Chrome (headless), the dev
// server, BEAM mainnet. Spends nothing: a throwaway wallet that holds nothing.
//
//   npm run e2e:swap   (stages the engine, builds dist/, runs this file)
//
// The wallet is empty, so the swap screen would rightly keep its button off.
// To reach the consent sheet the test shows the screen a balance it does not
// have (the page's wallet state only). The engine still knows the truth, and
// that is the point: the consent sheet must show what the engine reports -
// "Not enough BEAM", no approve button - not what the screen believed.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startServer, launch, recordedPage, shot, waitScreen, foreignHosts, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';

const PORT = 8793;
const PASSWORD = `swap-${Math.random().toString(36).slice(2, 10)}`;
const NODE = 'eu-nodes.mainnet.beam.mw:8200';
const FOMO = 174;
const tid = (id) => `[data-testid="${id}"]`;
const groth = (text) => {
  const m = /([\d,]+(?:\.\d+)?)/.exec(text);
  const [w, f = ''] = m[1].replace(/,/g, '').split('.');
  return BigInt(w) * 100000000n + BigInt((f + '00000000').slice(0, 8));
};

let srv, browser, ctx, page, rec;

before(async () => {
  srv = await startServer({ root: 'dist', port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  ({ page, rec } = await recordedPage(ctx, { label: 'swap' }));
  console.log(`# screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
});

test('a new wallet, synced', { timeout: 15 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  await waitSynced(page);
  const shaderLoads = await page.evaluate(() => performance.getEntriesByType('resource').filter((e) => e.name.includes('/shaders/')).length);
  assert.equal(shaderLoads, 0, 'no shader is loaded before a feature needs it');
});

test('swap BEAM -> FOMO: live quote, the consent sheet shows what the engine reported, Cancel sends nothing', { timeout: 10 * 60000 }, async () => {
  // The screen is shown 1 BEAM; the engine holds 0.
  await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const orig = wallet.refreshStatus.bind(wallet);
    wallet.refreshStatus = async function () {
      await orig();
      this.state.totals.set(0, { available: 100000000n, receiving: 0n, sending: 0n, maturing: 0n });
      this.emit();
    };
    await wallet.refreshStatus();
  });
  await page.click(tid('swap'));
  await waitScreen(page, 'swap');
  await page.waitForFunction(() => !/Loading prices/.test(document.querySelector('[data-testid="swap-reason"]').textContent), null, { timeout: 60000 });
  await page.click(tid('swap-get-asset'));
  await page.waitForSelector(`.sheet [data-asset-id="${FOMO}"]`);
  await page.click(`.sheet [data-asset-id="${FOMO}"]`);
  assert.match(await page.textContent(tid('swap-get-asset')), /FOMO/);
  await page.fill(tid('swap-pay-amount'), '0.01');
  await page.waitForSelector(tid('swap-rate'), { timeout: 60000 });
  await page.waitForFunction(() => !document.querySelector('[data-testid="swap-cta"]').disabled, null, { timeout: 30000 });
  const quoted = await page.textContent(tid('swap-get-exact'));
  const quote = groth(quoted);
  console.log(`# quote: 0.01 BEAM -> ${quoted}; ${await page.textContent(tid('swap-rate'))}; pool fee ${await page.textContent(tid('swap-pool-fee'))}`);
  assert.ok(quote > 0n);
  assert.equal(await page.textContent(tid('swap-fee')), '0.011 BEAM');
  assert.equal(await page.textContent(tid('swap-cta')), 'Swap 0.01 BEAM');
  const shaderLoads = await page.evaluate(() => performance.getEntriesByType('resource').filter((e) => e.name.endsWith('/shaders/amm_app.wasm')).length);
  assert.equal(shaderLoads, 1, 'the DEX shader loads once, when the swap screen needs it');
  await shot(page, 'swap-01-quote');

  await page.click(tid('swap-cta'));
  await page.waitForSelector(tid('consent'), { timeout: 60000 });
  await shot(page, 'swap-02-consent-not-enough');
  const pay = await page.textContent(tid('consent-pay-0'));
  const get = await page.textContent(tid('consent-get-0'));
  const fee = await page.textContent(tid('consent-fee'));
  const short = await page.textContent(tid('consent-not-enough'));
  console.log(`# consent: pay "${pay}", get "${get}", fee "${fee}", "${short.trim()}"`);
  assert.equal(pay, '0.01 BEAM');
  assert.match(get, / FOMO$/);
  const got = groth(get);
  assert.ok(got * 100n >= quote * 99n && got <= quote + quote / 100n, `consent ${got} within 1% of the quote ${quote}`);
  assert.equal(fee, '0.011 BEAM');
  assert.match(await page.textContent(tid('consent-total')), /^0\.021 BEAM$/);
  assert.match(short, /^Not enough BEAM\./);
  assert.equal(await page.isVisible(tid('consent-approve')), false, 'no approve button when the engine says it is not enough');
  assert.match(await page.textContent(tid('consent-app')), /BEAM Campfire/);

  await page.click(tid('consent-cancel'));
  await page.waitForSelector(tid('swap-result'), { timeout: 30000 });
  const result = await page.$eval(tid('swap-result'), (el) => ({ code: el.dataset.code, rpc: el.dataset.rpc, text: el.textContent }));
  console.log(`# after Cancel: ${JSON.stringify(result)}`);
  assert.equal(result.code, 'rejected');
  assert.equal(result.rpc, '-32021', 'the engine answered "Call is rejected by user"');
  assert.match(result.text, /Nothing was sent/);
  await shot(page, 'swap-03-cancelled');

  const log = await page.evaluate(() => window.__campfire.consents());
  const last = log.at(-1);
  console.log(`# consent log: ${JSON.stringify(last)}`);
  assert.equal(last.decision, 'rejected');
  assert.equal(last.kind, 'contract');
  assert.equal(last.appName, 'BEAM Campfire');
  assert.equal(last.isEnough, false);
  assert.equal(last.fee, '0.011');
  assert.deepEqual(last.spends, [{ assetId: 0, amount: '0.01' }]);
  assert.equal(last.receives.length, 1);
  assert.equal(last.receives[0].assetId, FOMO);

  // Nothing was sent: no contract transaction, and the engine's balance is still empty.
  const truth = await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const txs = await wallet.session.call('tx_list', { count: 100, skip: 0 });
    const st = await wallet.session.call('wallet_status', { nz_totals: true });
    return { contractTxs: txs.filter((t) => Number(t.tx_type) === 12).length, allTxs: txs.length, available: String(st.available) };
  });
  console.log(`# engine after Cancel: ${JSON.stringify(truth)}`);
  assert.equal(truth.contractTxs, 0);
  assert.equal(truth.allTxs, 0);
  assert.equal(truth.available, '0');
  const state = await page.evaluate(() => window.__campfire.contracts());
  assert.equal(state.consents, 0, 'no consent left pending');
  assert.equal(state.inflight, 0, 'no call left waiting');
});

test('lock closes every app; the next session starts clean', { timeout: 120000 }, async () => {
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await page.click(tid('lock'));
  await waitScreen(page, 'unlock');
  assert.deepEqual(await page.evaluate(() => window.__campfire.contracts()), { bound: false, apps: 0, inflight: 0, consents: 0, presenter: true });
});

test('IP privacy: only this origin and the chosen node', async () => {
  assert.deepEqual(foreignHosts(rec, srv.url, [NODE]), []);
  assert.deepEqual(rec.csp, []);
  assert.deepEqual(rec.errors, []);
});

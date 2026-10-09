// LIVE MONEY TEST on BEAM mainnet, tiny amounts only.
//
//   npm run e2e:live:swap
//
// Test wallet FUNDER2, restored through the real Restore screen, swaps
// 0.01 BEAM for FOMO on BEAM's DEX through the Swap screen and the approve
// sheet, exactly as a user would: quote, "Swap 0.01 BEAM", read the sheet,
// approve, password. The swap must complete on chain, and the balances must
// move by what the sheet said: BEAM down by the amount paid plus the 0.011
// BEAM network fee, FOMO up by at least the 1%-protected amount.
//
// Hard limits: pays 0.01 BEAM; refuses a sheet that pays more than 0.02 BEAM
// or charges another fee; refuses to start under 0.03 BEAM available.
import { startServer, launch, recordedPage, shot, waitScreen, sleep, foreignHosts } from './harness.mjs';
import { waitHome, waitSynced } from './flows.mjs';
import { tid, log, funderWords, restoreFunder, total, waitTx } from './live_common.mjs';

const FOMO = 174;
const PAY_GROTH = 1000000n; // 0.01 BEAM
const MAX_PAY_GROTH = 2000000n; // 0.02 BEAM
const FEE_GROTH = 1100000n; // 0.011 BEAM, one contract call
const PORT = Number(process.env.LIVE_PORT || 8797);
const password = `live-s-${Math.random().toString(36).slice(2, 10)}`;
const groth = (text) => {
  const m = /^([0-9]+)(?:\.([0-9]{1,8}))?\b/.exec(String(text).replace(/,/g, '').trim());
  if (!m) throw new Error(`not an amount: ${text}`);
  return BigInt(m[1]) * 100000000n + BigInt((m[2] || '').padEnd(8, '0'));
};

const extra = process.env.BEAM_RECOVERY_FILE ? ['--recovery-file', process.env.BEAM_RECOVERY_FILE] : [];
const srv = await startServer({ port: PORT, extra });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
const { page, rec } = await recordedPage(ctx, { label: 'S' });
let exit = 0;
try {
  log('restoring FUNDER2 through the Restore screen + recovery snapshot');
  await page.goto(srv.url);
  await restoreFunder(page, funderWords(), password, 'live-swap');
  await waitHome(page, { timeout: 20 * 60000 });
  await waitSynced(page, 15 * 60000);
  await page.waitForFunction(() => window.__campfire.sync().canSend, null, { timeout: 300000 });
  await sleep(8000);
  const beam0 = await total(page, 0);
  const fomo0 = await total(page, FOMO);
  log('before: BEAM', JSON.stringify(beam0), 'FOMO', JSON.stringify(fomo0));
  if (BigInt(beam0.available) < 3000000n) throw new Error(`FUNDER2 has ${beam0.available} groth available; need at least 0.03 BEAM`);
  const txs0 = new Set((await page.evaluate(() => window.__campfire.txs())).map((t) => t.txId));

  // ---- the Swap screen, as a user
  await page.click(tid('swap'));
  await waitScreen(page, 'swap');
  await page.waitForFunction(() => !/Loading prices/.test(document.querySelector('[data-testid="swap-reason"]').textContent), null, { timeout: 120000 });
  await page.click(tid('swap-get-asset'));
  await page.waitForSelector(`.sheet [data-asset-id="${FOMO}"]`);
  await page.click(`.sheet [data-asset-id="${FOMO}"]`);
  await page.fill(tid('swap-pay-amount'), '0.01');
  await page.waitForSelector(tid('swap-rate'), { timeout: 60000 });
  await page.waitForFunction(() => !document.querySelector('[data-testid="swap-cta"]').disabled, null, { timeout: 60000 });
  const quote = {
    get: await page.textContent(tid('swap-get-exact')),
    rate: await page.textContent(tid('swap-rate')),
    poolFee: await page.textContent(tid('swap-pool-fee')),
    fee: await page.textContent(tid('swap-fee')),
    cta: await page.textContent(tid('swap-cta')),
  };
  log('quote:', JSON.stringify(quote));
  await shot(page, 'live-swap-03-quote');

  // ---- the approve sheet: check what it says before approving
  await page.click(tid('swap-cta'));
  await page.waitForSelector(tid('consent'), { timeout: 90000 });
  const sheet = {
    app: await page.textContent(tid('consent-app')),
    pay: await page.textContent(tid('consent-pay-0')),
    get: await page.textContent(tid('consent-get-0')),
    fee: await page.textContent(tid('consent-fee')),
    total: await page.textContent(tid('consent-total')),
    button: await page.textContent(tid('consent-approve')),
  };
  log('sheet:', JSON.stringify(sheet));
  await shot(page, 'live-swap-04-sheet');
  if (!/BEAM Campfire/.test(sheet.app)) throw new Error('the sheet does not name this wallet');
  if (!/BEAM/.test(sheet.pay) || groth(sheet.pay) > MAX_PAY_GROTH) throw new Error(`refusing: the sheet pays ${sheet.pay}`);
  if (groth(sheet.fee) !== FEE_GROTH) throw new Error(`refusing: the sheet charges ${sheet.fee}`);
  if (!/FOMO/.test(sheet.get)) throw new Error(`refusing: the sheet gives ${sheet.get}`);
  const payGroth = groth(sheet.pay);
  const getGroth = groth(sheet.get);

  await page.click(tid('consent-approve'));
  await page.waitForSelector(tid('auth-pw'), { timeout: 20000 });
  await page.fill(tid('auth-pw'), password);
  await page.click(tid('auth-submit'));
  await waitScreen(page, 'txStatus', 120000);
  await shot(page, 'live-swap-05-status-pending');

  // ---- on chain
  const tx = await waitTx(page, (t) => !txs0.has(t.txId), 'swap', 25 * 60000);
  log('swap completed:', JSON.stringify(tx));
  await shot(page, 'live-swap-06-status-done');
  await page.waitForFunction(
    ([id, before]) => BigInt((window.__campfire.totals()[id] || { available: '0' }).available) > BigInt(before),
    [FOMO, fomo0.available],
    { timeout: 300000, polling: 3000 },
  );
  await sleep(5000);
  const beam1 = await total(page, 0);
  const fomo1 = await total(page, FOMO);
  const beamOut = BigInt(beam0.available) - BigInt(beam1.available);
  const fomoIn = BigInt(fomo1.available) - BigInt(fomo0.available);
  log('after: BEAM', JSON.stringify(beam1), 'FOMO', JSON.stringify(fomo1));
  log(`BEAM out ${beamOut} groth (sheet: ${payGroth} + fee ${FEE_GROTH}); FOMO in ${fomoIn} (sheet: ${getGroth})`);
  if (beamOut !== payGroth + FEE_GROTH) throw new Error('BEAM did not move by the sheet\'s pay + fee');
  if (fomoIn < (getGroth * 99n) / 100n) throw new Error('FOMO received is below the 1%-protected amount');
  if (PAY_GROTH !== payGroth) log('note: the DEX paid', payGroth, 'groth, a few groth under 0.01 (expected)');
  await page.evaluate(() => window.__campfire.go('activity'));
  await sleep(1500);
  await shot(page, 'live-swap-07-activity');
  log('foreign hosts', JSON.stringify(foreignHosts(rec, srv.url)));
} catch (e) {
  exit = 1;
  log('LIVE SWAP FAILED:', e.message);
  await shot(page, 'live-swap-failure').catch(() => {});
} finally {
  await browser.close();
  srv.stop();
}
process.exit(exit);

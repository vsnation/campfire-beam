// LIVE MONEY TEST on BEAM mainnet: a BEAM name and an airdrop, small amounts only.
//
//   npm run e2e:live:names-airdrop      (needs the owner's go-ahead: it spends real BEAM)
//
// Test wallet FUNDER2, restored through the real Restore screen, uses the new
// screens exactly as a person would, reading every approve sheet before
// approving it:
//   1. Names: registers a random 12-character name for 1 year (the $10 tier,
//      paid in BEAM at the oracle's rate), then sees it under My names.
//   2. Airdrop: creates a batch of 2 codes x 0.001 BEAM, claims one of them back
//      into the same wallet, then takes the batch back to recover the other.
// At the end BEAM must have moved by exactly what the sheets said.
//
// Hard limits (any sheet outside them is cancelled and the test stops):
//   - name: pays BEAM only, at most the screen's own estimate + 2% and at most
//     LIVE_NAME_MAX_BEAM (default 1500 BEAM); network fee exactly 0.011 BEAM;
//   - batch: pays exactly 0.00202 BEAM (2 x 0.001 + 1%); fee exactly 0.121 BEAM;
//   - claim: receives exactly 0.001 BEAM, pays nothing; fee exactly 0.121 BEAM;
//   - take back: receives exactly 0.001 BEAM, pays nothing; fee exactly 0.181 BEAM.
// The codes are never printed or written anywhere but the wallet itself.
import { startServer, launch, recordedPage, shot, waitScreen, sleep, foreignHosts } from './harness.mjs';
import { waitHome, waitSynced } from './flows.mjs';
import { tid, log, funderWords, restoreFunder, total, waitTx } from './live_common.mjs';

const PORT = Number(process.env.LIVE_PORT || 8822);
const NAME = `cf${Math.random().toString(36).slice(2, 8)}${Math.random().toString(36).slice(2, 6)}`.padEnd(12, 'x').slice(0, 12);
const NAME_FEE = 1100000n; // 0.011 BEAM
const MAX_NAME_GROTH = BigInt(Math.round(Number(process.env.LIVE_NAME_MAX_BEAM || 1500) * 1e8));
const DROP_VALUE = 100000n; // 0.001 BEAM per code
const DROP_LOCK = 202000n; // 2 x 0.001 + 1%
const DROP_FEE = 12100000n; // 0.121 BEAM
const CANCEL_FEE = 18100000n; // 0.181 BEAM
const password = `live-n-${Math.random().toString(36).slice(2, 10)}`;
const groth = (text) => {
  const m = /^\s*([0-9][0-9,]*)(?:\.([0-9]{1,8}))?\b/.exec(String(text));
  if (!m) throw new Error(`not an amount: ${text}`);
  return BigInt(m[1].replace(/,/g, '')) * 100000000n + BigInt((m[2] || '').padEnd(8, '0'));
};

const extra = process.env.BEAM_RECOVERY_FILE ? ['--recovery-file', process.env.BEAM_RECOVERY_FILE] : [];
const srv = await startServer({ port: PORT, extra });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, locale: 'en-GB' });
const { page, rec } = await recordedPage(ctx, { label: 'N' });

/** Reads the open approve sheet. */
async function readSheet() {
  await page.waitForSelector(tid('consent'), { timeout: 120000 });
  const text = async (id) => ((await page.$(tid(id))) ? (await page.textContent(tid(id))).trim() : null);
  return {
    title: (await page.textContent('.consent h2')).trim(),
    app: await text('consent-app'),
    pay: await text('consent-pay-0'),
    pay2: await text('consent-pay-1'),
    get: await text('consent-get-0'),
    get2: await text('consent-get-1'),
    fee: await text('consent-fee'),
    notEnough: await text('consent-not-enough'),
    button: await text('consent-approve'),
  };
}

/** Approves the sheet only if `problem(sheet)` finds nothing; otherwise cancels it and stops. */
async function approveIf(label, problem) {
  const sheet = await readSheet();
  log(`${label} sheet:`, JSON.stringify(sheet));
  await shot(page, `live-na-${label}-sheet`);
  const why = !/BEAM Campfire/.test(sheet.app || '') ? 'the sheet does not name this wallet' : sheet.notEnough ? `the wallet says: ${sheet.notEnough}` : !sheet.button ? 'no approve button' : problem(sheet);
  if (why) {
    await page.click(tid('consent-cancel')).catch(() => {});
    throw new Error(`refusing the ${label} sheet: ${why}`);
  }
  await page.click(tid('consent-approve'));
  await page.waitForSelector(tid('auth-pw'), { timeout: 20000 });
  await page.fill(tid('auth-pw'), password);
  await page.click(tid('auth-submit'));
  return sheet;
}

const newTx = (seen) => (t) => !seen.has(t.txId);
const txIds = async () => new Set((await page.evaluate(() => window.__campfire.txs())).map((t) => t.txId));

let exit = 0;
try {
  log('restoring FUNDER2 through the Restore screen + recovery snapshot');
  await page.goto(srv.url);
  await restoreFunder(page, funderWords(), password, 'live-na');
  await waitHome(page, { timeout: 20 * 60000 });
  await waitSynced(page, 15 * 60000);
  await page.waitForFunction(() => window.__campfire.sync().canSend, null, { timeout: 300000 });
  await sleep(8000);
  const beam0 = BigInt((await total(page, 0)).available);
  log('before: BEAM available', String(beam0));

  // ---------------------------------------------------------------- 1. a name
  await page.click(tid('names'));
  await waitScreen(page, 'names');
  await page.fill(tid('names-input'), NAME);
  await page.waitForSelector(`${tid('names-result')}[data-state="available"]`, { timeout: 120000 });
  await page.waitForFunction(() => /≈ [\d,]+ BEAM/.test(document.querySelector('[data-testid="names-beam"]')?.textContent || ''), null, { timeout: 60000 });
  const usd = await page.textContent(tid('names-usd'));
  const estimate = groth((await page.textContent(tid('names-beam'))).replace('≈', ''));
  log(`name ${NAME}: ${usd} for 1 year, about ${estimate} groth`);
  if (NAME.length < 10) throw new Error('refusing: the test name must have 10 or more characters');
  if ((await page.textContent(tid('names-years'))) !== '1 year') throw new Error('refusing: the test registers for the shortest period, 1 year');
  if (usd !== '$10') throw new Error(`refusing: a 12-character name should cost $10 a year, the screen says ${usd}`);
  const need = estimate + (estimate * 2n) / 100n + NAME_FEE + DROP_LOCK + DROP_FEE * 2n + CANCEL_FEE + 1000000n;
  if (beam0 < need) throw new Error(`FUNDER2 has ${beam0} groth available; this test needs at least ${need}`);
  if (estimate > MAX_NAME_GROTH) throw new Error(`refusing: the name costs about ${estimate} groth, above LIVE_NAME_MAX_BEAM`);
  await page.waitForFunction(() => !document.querySelector('[data-testid="names-cta"]').disabled, null, { timeout: 60000 });
  if ((await page.textContent(tid('names-cta'))) !== `Register ${NAME} for 1 year`) throw new Error('the button does not say what it does');
  await shot(page, 'live-na-01-name-ready');
  let seen = await txIds();
  await page.click(tid('names-cta'));
  const nameSheet = await approveIf('name', (s) => {
    if (s.pay2 || s.get) return 'it moves more than one amount';
    if (!/ BEAM$/.test(s.pay || '')) return `it pays ${s.pay}`;
    const p = groth(s.pay);
    if (p > estimate + (estimate * 2n) / 100n) return `it pays ${s.pay}, more than the screen's estimate + 2%`;
    if (p > MAX_NAME_GROTH) return `it pays ${s.pay}, above LIVE_NAME_MAX_BEAM`;
    if (groth(s.fee) !== NAME_FEE) return `it charges ${s.fee}`;
    if (!/^Pay [\d,.]+ BEAM and register /.test(s.button) || !s.button.endsWith(`register ${NAME}`)) return `the button says ${s.button}`;
    return null;
  });
  const namePaid = groth(nameSheet.pay);
  await page.waitForSelector(`${tid('names-notice')}[data-code="sent"]`, { timeout: 120000 });
  await shot(page, 'live-na-02-name-sent');
  const nameTx = await waitTx(page, newTx(seen), 'name registration', 25 * 60000);
  log('name registered:', JSON.stringify(nameTx));
  await page.evaluate(() => window.__campfire.go('names'));
  await page.waitForSelector(`[data-testid="names-mine-row"][data-name="${NAME}"]`, { timeout: 300000 });
  await shot(page, 'live-na-03-my-names');

  // ---------------------------------------------------------------- 2. an airdrop
  await page.evaluate(() => window.__campfire.go('airdropCreate'));
  await waitScreen(page, 'airdropCreate');
  await page.fill(tid('drop-amount'), '0.001');
  await page.fill(tid('drop-count'), '2');
  await page.waitForFunction(() => !document.querySelector('[data-testid="drop-cta"]').disabled, null, { timeout: 60000 });
  if ((await page.textContent(tid('drop-total'))) !== '0.12302 BEAM') throw new Error('refusing: the create screen does not add up to 0.12302 BEAM');
  seen = await txIds();
  await page.click(tid('drop-cta'));
  await approveIf('batch', (s) => (s.pay2 || s.get ? 'it moves more than one amount' : s.pay !== '0.00202 BEAM' ? `it pays ${s.pay}` : groth(s.fee) !== DROP_FEE ? `it charges ${s.fee}` : null));
  await waitScreen(page, 'airdropCodes', 120000);
  await page.waitForSelector(tid('code'));
  const codes = await page.$$eval(tid('code'), (els) => els.map((e) => e.textContent));
  if (codes.length !== 2) throw new Error(`expected 2 codes, the screen shows ${codes.length}`);
  log('batch sent; 2 codes saved in the wallet (not printed)');
  await shot(page, 'live-na-04-codes');
  await waitTx(page, newTx(seen), 'batch', 25 * 60000);
  log('batch confirmed');

  // Claim one code back into this wallet.
  await page.evaluate(() => window.__campfire.go('airdrop'));
  await waitScreen(page, 'airdrop');
  await page.fill(tid('airdrop-code'), codes[0]);
  await page.waitForSelector(`${tid('airdrop-result')}[data-state="found"]`, { timeout: 180000 });
  if ((await page.textContent(tid('airdrop-gets'))) !== '0.001 BEAM') throw new Error('refusing: the code does not give 0.001 BEAM');
  await page.waitForFunction(() => !document.querySelector('[data-testid="airdrop-cta"]').disabled, null, { timeout: 60000 });
  await shot(page, 'live-na-05-claim-found');
  seen = await txIds();
  await page.click(tid('airdrop-cta'));
  await approveIf('claim', (s) => (s.pay || s.get2 ? 'it moves something other than the code' : s.get !== '0.001 BEAM' ? `it gives ${s.get}` : groth(s.fee) !== DROP_FEE ? `it charges ${s.fee}` : null));
  await page.waitForSelector(tid('airdrop-done'), { timeout: 120000 });
  await shot(page, 'live-na-06-claimed');
  await waitTx(page, newTx(seen), 'claim', 25 * 60000);
  log('claim confirmed');

  // Take the batch back: the other code.
  await page.evaluate(() => window.__campfire.go('airdropBatches'));
  await waitScreen(page, 'airdropBatches');
  await page.waitForFunction(() => [...document.querySelectorAll('[data-testid="batch-counts"]')].some((e) => /1 claimed · 1 not claimed/.test(e.textContent)), null, { timeout: 300000, polling: 3000 });
  await shot(page, 'live-na-07-batches');
  const cancelBtn = page.locator('[data-testid="batch"]', { has: page.locator('[data-testid="batch-counts"]', { hasText: '1 claimed · 1 not claimed' }) }).locator(tid('batch-cancel'));
  if ((await cancelBtn.textContent()) !== 'Take back 0.001 BEAM') throw new Error(`refusing: the button says ${await cancelBtn.textContent()}`);
  seen = await txIds();
  await cancelBtn.click();
  await approveIf('takeback', (s) => (s.pay || s.get2 ? 'it moves something other than the unclaimed code' : s.get !== '0.001 BEAM' ? `it gives ${s.get}` : groth(s.fee) !== CANCEL_FEE ? `it charges ${s.fee}` : null));
  await page.waitForSelector(`${tid('batches-result')}[data-code="sent"]`, { timeout: 120000 });
  await waitTx(page, newTx(seen), 'take back', 25 * 60000);
  log('take back confirmed');
  await sleep(10000);

  // ---------------------------------------------------------------- the balance
  const beam1 = BigInt((await total(page, 0)).available);
  const moved = beam0 - beam1;
  const want = namePaid + NAME_FEE + (DROP_LOCK + DROP_FEE) + (DROP_FEE - DROP_VALUE) + (CANCEL_FEE - DROP_VALUE);
  log(`after: BEAM available ${beam1}; out ${moved} groth; the sheets said ${want}`);
  if (moved !== want) throw new Error('BEAM did not move by exactly what the sheets said');
  await page.evaluate(() => window.__campfire.go('activity'));
  await sleep(1500);
  await shot(page, 'live-na-08-activity');
  log('foreign hosts', JSON.stringify(foreignHosts(rec, srv.url)));
} catch (e) {
  exit = 1;
  log('LIVE NAMES/AIRDROP FAILED:', e.message);
  await shot(page, 'live-na-failure').catch(() => {});
} finally {
  await browser.close();
  srv.stop();
}
process.exit(exit);

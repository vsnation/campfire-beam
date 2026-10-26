// LIVE MONEY TEST on BEAM mainnet: Airdrop v3 from the web wallet, small amounts only.
//
//   npm run e2e:live:airdrop-v3      (spends real BEAM: about 0.05 BEAM)
//
// Wallet A is the test wallet FUNDER2, restored through the real Restore screen. Wallet B is a new wallet
// made for the run, holding nothing. Both use the screens exactly as a person would, and every approve
// sheet is read before it is approved:
//   1. A creates 2 codes x 0.001 BEAM with "pay the claim fee for each code" on, and waits for the check
//      (3 confirmations, then every code looked up) before the codes show as ready.
//   2. B, with 0 BEAM, claims one code: "No BEAM needed", the code's prepaid fee pays the claim.
//   3. A takes the batch back, which recovers the other code and its prepaid fee.
// At the end BEAM must have moved by exactly what the sheets said, on both wallets.
//
// Hard limits (any sheet outside them is cancelled and the test stops):
//   - create: pays 0.04602 BEAM (0.002 + 1% + 2 x 0.022 prepaid), network fee exactly 0.0185 BEAM;
//   - claim: pays nothing, receives 0.023 BEAM (0.001 + the 0.022 prepaid fee), fee exactly 0.021 BEAM;
//   - take back: pays nothing, receives 0.023 BEAM, fee exactly 0.011 BEAM.
// Codes are never printed. BEAM's node certificates lapsed on 2026-10-13: run with CAMPFIRE_IGNORE_NODE_CERTS=1.
import { startServer, launch, recordedPage, shot, waitScreen, sleep } from './harness.mjs';
import { waitHome, waitSynced, createWallet, unlockWithPassword } from './flows.mjs';
import { tid, log, funderWords, restoreFunder, total, waitTx } from './live_common.mjs';

const PORT = Number(process.env.LIVE_PORT || 8861);
const CREATE_PAYS = 4602000n; // 0.002 + 0.00002 + 0.044 BEAM
const CREATE_FEE = 1850000n; // 0.0185 BEAM
const CLAIM_GETS = 2300000n; // 0.001 + 0.022 BEAM
const CLAIM_FEE = 2100000n; // 0.021 BEAM
const BACK_GETS = 2300000n;
const BACK_FEE = 1100000n; // 0.011 BEAM
const pwA = `live-v3a-${Math.random().toString(36).slice(2, 10)}`;
const pwB = `live-v3b-${Math.random().toString(36).slice(2, 10)}`;
const groth = (text) => {
  const m = /^\s*([0-9][0-9,]*)(?:\.([0-9]{1,8}))?\s*BEAM\s*$/.exec(String(text || ''));
  if (!m) throw new Error(`not a BEAM amount: ${text}`);
  return BigInt(m[1].replace(/,/g, '')) * 100000000n + BigInt((m[2] || '').padEnd(8, '0'));
};
const sumBeam = (...xs) => xs.filter(Boolean).reduce((s, x) => s + groth(x), 0n);

const srv = await startServer({ port: PORT });
const browser = await launch();
const ctxA = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, locale: 'en-GB' });
const ctxB = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, locale: 'en-GB' });
const { page: A } = await recordedPage(ctxA, { label: 'A' });
const { page: B } = await recordedPage(ctxB, { label: 'B' });

async function passKeptHere(p) {
  const go = await p.waitForSelector('[data-testid="kept-here-go"]', { timeout: 5000 }).catch(() => null);
  if (go) await go.click();
}

async function readSheet(p) {
  await p.waitForSelector(tid('consent'), { timeout: 120000 });
  const text = async (id) => ((await p.$(tid(id))) ? (await p.textContent(tid(id))).trim() : null);
  return {
    title: (await p.textContent('.consent h2')).trim(),
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
async function approveIf(p, password, label, problem) {
  const sheet = await readSheet(p);
  log(`${label} sheet:`, JSON.stringify(sheet));
  await shot(p, `live-v3-${label}-sheet`);
  const why = !/Beam PWA/.test(sheet.app || '') ? 'the sheet does not name this wallet' : sheet.notEnough ? `the wallet says: ${sheet.notEnough}` : !sheet.button ? 'no approve button' : problem(sheet);
  if (why) {
    await p.click(tid('consent-cancel')).catch(() => {});
    throw new Error(`refusing the ${label} sheet: ${why}`);
  }
  await p.click(tid('consent-approve'));
  await p.waitForSelector(tid('auth-pw'), { timeout: 20000 });
  await p.fill(tid('auth-pw'), password);
  await p.click(tid('auth-submit'));
  return sheet;
}

/** A wallet left idle locks itself after a few minutes, as it should: unlock it before using it again. */
async function awake(p, password) {
  const screen = await p.evaluate(() => document.getElementById('app') && document.getElementById('app').dataset.screen);
  if (screen === 'unlock') {
    await unlockWithPassword(p, password);
    await waitHome(p, { timeout: 120000 });
  }
}

const txIds = async (p) => new Set((await p.evaluate(() => window.__campfire.txs())).map((t) => t.txId));
const newTx = (seen) => (t) => !seen.has(t.txId);

let exit = 0;
try {
  log('A: restoring FUNDER2 through the Restore screen + recovery snapshot; B: a new empty wallet');
  await A.goto(srv.url);
  await B.goto(srv.url);
  await Promise.all([
    (async () => {
      await restoreFunder(A, funderWords(), pwA, 'live-v3a');
      await waitHome(A, { timeout: 20 * 60000 });
      await waitSynced(A, 15 * 60000);
      await A.waitForFunction(() => window.__campfire.sync().canSend, null, { timeout: 300000 });
    })(),
    (async () => {
      await createWallet(B, { password: pwB });
      await waitHome(B, { timeout: 10 * 60000 });
      await waitSynced(B, 15 * 60000);
    })(),
  ]);
  await sleep(8000);
  const a0 = BigInt((await total(A, 0)).available);
  const b0 = BigInt((await total(B, 0)).available);
  log('before: A BEAM available', String(a0), '| B BEAM available', String(b0));
  if (b0 !== 0n) throw new Error('B must start with exactly 0 BEAM');

  // ---------------------------------------------------------------- 0. a batch left by an earlier run
  // Its codes lived only in that run's browser; a v3 batch is taken back by its creator without them.
  await A.evaluate(() => window.__campfire.go('airdropBatches'));
  await waitScreen(A, 'airdropBatches');
  await sleep(15000);
  const left = A.locator('[data-testid="batch"]', { has: A.locator('[data-testid="batch-counts"]', { hasText: '0 claimed · 2 not claimed' }) }).locator(tid('batch-cancel'));
  if (await left.count()) {
    log('an earlier run left a batch: taking it back first;', await left.first().textContent());
    const seen0 = await txIds(A);
    await left.first().click();
    await approveIf(A, pwA, 'takeback-earlier', (s) => (s.pay || s.pay2 ? `it pays ${s.pay}` : sumBeam(s.get, s.get2) !== 2n * BACK_GETS ? `it gives ${s.get} ${s.get2 || ''}` : groth(s.fee) !== BACK_FEE ? `it charges ${s.fee}` : null));
    const t0 = await waitTx(A, newTx(seen0), 'take back (earlier)', 25 * 60000);
    log('earlier batch taken back:', JSON.stringify({ txId: t0.txId, kernel: t0.kernel }));
    await sleep(15000);
  }
  const a0x = BigInt((await total(A, 0)).available);

  // ---------------------------------------------------------------- 1. A creates 2 codes, fees paid
  await awake(A, pwA);
  await A.evaluate(() => window.__campfire.go('airdropCreate'));
  await waitScreen(A, 'airdropCreate');
  await A.fill(tid('drop-amount'), '0.001');
  await A.fill(tid('drop-count'), '2');
  if (!(await A.isChecked(tid('drop-gas')))) throw new Error('refusing: "pay the claim fee" is not on by default');
  await A.waitForFunction(() => !document.querySelector('[data-testid="drop-cta"]').disabled, null, { timeout: 60000 });
  let seen = await txIds(A);
  await A.click(tid('drop-cta'));
  await passKeptHere(A);
  await approveIf(A, pwA, 'create', (s) => (s.get ? 'it receives something' : sumBeam(s.pay, s.pay2) !== CREATE_PAYS ? `it pays ${s.pay} ${s.pay2 || ''}` : groth(s.fee) !== CREATE_FEE ? `it charges ${s.fee}` : null));
  await waitScreen(A, 'airdropCodes', 120000);
  const createTx = await waitTx(A, newTx(seen), 'create', 25 * 60000);
  log('create confirmed:', JSON.stringify({ txId: createTx.txId, kernel: createTx.kernel }));
  // The codes show only once the check has passed (3 confirmations, every code found in this batch).
  await A.waitForSelector(tid('codes-ready'), { timeout: 20 * 60000 });
  const codes = await A.$$eval(tid('code'), (els) => els.map((e) => e.textContent.trim()));
  if (codes.length !== 2) throw new Error(`expected 2 codes, the screen shows ${codes.length}`);
  log('check passed: "Ready to share"; 2 codes (not printed)');
  await shot(A, 'live-v3-01-ready');

  // ---------------------------------------------------------------- 2. B (0 BEAM) claims one, gasless
  await awake(B, pwB);
  await B.evaluate(() => window.__campfire.go('airdrop'));
  await waitScreen(B, 'airdrop');
  await B.fill(tid('airdrop-code'), codes[0]);
  await B.waitForSelector(`${tid('airdrop-result')}[data-state="found"]`, { timeout: 180000 });
  // A BEAM code says it in the fee row ("Paid by the code") and in a positive balance change; the separate
  // "No BEAM needed" note is for token codes (screens/airdrop.js).
  const found = (await B.textContent(tid('airdrop-result'))).replace(/\s+/g, ' ');
  if (!/Network fee\s*Paid by the code/.test(found)) throw new Error('refusing: the claim does not say its fee is paid by the code');
  if (!/Balance change\s*\+0\.002 BEAM/.test(found)) throw new Error('refusing: the balance change is not +0.002 BEAM');
  if ((await B.textContent(tid('airdrop-gets'))) !== '0.001 BEAM') throw new Error('refusing: the code does not give 0.001 BEAM');
  if ((await B.textContent(tid('airdrop-fee'))) !== '0.021 BEAM') throw new Error('refusing: the claim fee is not 0.021 BEAM');
  await B.waitForFunction(() => !document.querySelector('[data-testid="airdrop-cta"]').disabled, null, { timeout: 60000 });
  await shot(B, 'live-v3-02-claim-found');
  const seenB = await txIds(B);
  await B.click(tid('airdrop-cta'));
  await approveIf(B, pwB, 'claim', (s) => (s.pay || s.pay2 ? `it pays ${s.pay}` : sumBeam(s.get, s.get2) !== CLAIM_GETS ? `it gives ${s.get} ${s.get2 || ''}` : groth(s.fee) !== CLAIM_FEE ? `it charges ${s.fee}` : null));
  await B.waitForSelector(tid('airdrop-done'), { timeout: 120000 });
  const claimTx = await waitTx(B, newTx(seenB), 'claim', 25 * 60000);
  log('claim confirmed from the empty wallet:', JSON.stringify({ txId: claimTx.txId, kernel: claimTx.kernel }));
  await shot(B, 'live-v3-03-claimed');

  // A's codes screen now shows where the codes stand (release audit 0.2.16).
  await awake(A, pwA);
  await A.evaluate(() => window.__campfire.go('airdropBatches'));
  await waitScreen(A, 'airdropBatches');
  await A.waitForFunction(() => [...document.querySelectorAll('[data-testid="batch-counts"]')].some((e) => /1 claimed · 1 not claimed/.test(e.textContent)), null, { timeout: 300000, polling: 3000 });

  // ---------------------------------------------------------------- 3. A takes the batch back
  const back = A.locator('[data-testid="batch"]', { has: A.locator('[data-testid="batch-counts"]', { hasText: '1 claimed · 1 not claimed' }) }).locator(tid('batch-cancel'));
  log('take-back button:', await back.textContent());
  seen = await txIds(A);
  await back.click();
  await approveIf(A, pwA, 'takeback', (s) => (s.pay || s.pay2 ? `it pays ${s.pay}` : sumBeam(s.get, s.get2) !== BACK_GETS ? `it gives ${s.get} ${s.get2 || ''}` : groth(s.fee) !== BACK_FEE ? `it charges ${s.fee}` : null));
  const backTx = await waitTx(A, newTx(seen), 'take back', 25 * 60000);
  log('take back confirmed:', JSON.stringify({ txId: backTx.txId, kernel: backTx.kernel }));
  await sleep(15000);

  // ---------------------------------------------------------------- the balances
  const a1 = BigInt((await total(A, 0)).available);
  const b1 = BigInt((await total(B, 0)).available);
  const wantA = a0x - CREATE_PAYS - CREATE_FEE + BACK_GETS - BACK_FEE;
  const wantB = b0 + CLAIM_GETS - CLAIM_FEE;
  log('after: A', String(a1), 'want', String(wantA), '| B', String(b1), 'want', String(wantB));
  if (a1 !== wantA || b1 !== wantB) throw new Error('BEAM did not move by exactly what the sheets said');
  log('LIVE OK: create, check, gasless claim from an empty wallet, take back; every amount exact');
} catch (e) {
  exit = 1;
  log('LIVE FAILED:', e.message);
  await shot(A, 'live-v3-fail-A').catch(() => {});
  await shot(B, 'live-v3-fail-B').catch(() => {});
} finally {
  await browser.close();
  await srv.stop();
  process.exit(exit);
}

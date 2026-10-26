// LIVE MONEY TEST on BEAM mainnet, tiny amounts only.
//
//   BEAM_RECOVERY_FILE=<a local mainnet_recovery.bin> npm run e2e:live:dex
//
// Test wallet FUNDER2, restored through the real Restore screen, adds liquidity to the
// BEAM/FOMO pool (1%) through the Pools screens and the approve sheet, exactly as a user
// would, checks the LP balance and the Activity entry, then takes all of it out again, so the
// coins come back to FUNDER2. Creating a pool is taken only as far as its approve sheet
// (FUNDER2 holds less than the 10 BEAM deposit: the screen is shown 11 BEAM, the engine knows
// better) and cancelled; nothing may be sent. If FUNDER2 holds too little FOMO, a small swap
// through the Swap screen comes first.
//
// Hard limits: a deposit of ADD_BEAM (0.02 BEAM) and its matching FOMO; refuses any sheet that
// pays more than MAX_BEAM_OUT (0.05 BEAM) of BEAM or charges a fee other than 0.011 BEAM, a swap
// of more than 0.05 BEAM, and starting under 0.2 BEAM available. Logs every tx id and kernel.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, shot, waitScreen, sleep, foreignHosts, PWA } from './harness.mjs';
import { waitHome, waitSynced } from './flows.mjs';
import { tid, log, funderWords, restoreFunder, total, waitTx } from './live_common.mjs';

const FOMO = 174;
const LP = 175;
const ADD_BEAM = '0.02';
const MAX_BEAM_OUT = 5000000n; // 0.05 BEAM in any one sheet
const FEE = 1100000n; // 0.011 BEAM
const MIN_START = 20000000n; // 0.2 BEAM
const PORT = Number(process.env.LIVE_PORT || 8901);
const password = `live-d-${Math.random().toString(36).slice(2, 10)}`;
const groth = (text) => {
  const m = /([0-9][0-9,]*)(?:\.([0-9]{1,8}))?/.exec(String(text));
  if (!m) throw new Error(`not an amount: ${text}`);
  return BigInt(m[1].replace(/,/g, '')) * 100000000n + BigInt((m[2] || '').padEnd(8, '0'));
};
const B = (g) => `${g / 100000000n}.${String(g % 100000000n).padStart(8, '0')}`;

const tmp = mkdtempSync(join(tmpdir(), 'campfire-live-dex-'));
execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
const extra = process.env.BEAM_RECOVERY_FILE ? ['--recovery-file', process.env.BEAM_RECOVERY_FILE] : [];
const srv = await startServer({ root: join(tmp, 'dist'), port: PORT, extra });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
const { page, rec } = await recordedPage(ctx, { label: 'D' });
const record = [];
let exit = 0;

const balances = async () => ({ beam: BigInt((await total(page, 0)).available), fomo: BigInt((await total(page, FOMO)).available), lp: BigInt((await total(page, LP)).available) });
const showB = (b) => `BEAM ${B(b.beam)}, FOMO ${B(b.fomo)}, LP ${B(b.lp)}`;

async function approve(prefix) {
  await page.click(tid('consent-approve'));
  await page.waitForSelector(tid('auth-pw'), { timeout: 20000 });
  await page.fill(tid('auth-pw'), password);
  await page.click(tid('auth-submit'));
  await shot(page, `${prefix}-after-approve`);
}

async function sheet() {
  const text = async (id) => ((await page.$(tid(id))) ? (await page.textContent(tid(id))).trim() : null);
  return {
    title: await page.textContent('.consent h2'),
    app: await text('consent-app'),
    pay: [await text('consent-pay-0'), await text('consent-pay-1')].filter(Boolean),
    get: [await text('consent-get-0'), await text('consent-get-1')].filter(Boolean),
    fee: await text('consent-fee'),
    total: await text('consent-total'),
    button: await text('consent-approve'),
    short: await text('consent-not-enough'),
  };
}

function refuseUnlessSafe(s, what) {
  if (!/Beam PWA/.test(s.app || '')) throw new Error(`${what}: the sheet does not name this wallet`);
  if (groth(s.fee) !== FEE) throw new Error(`${what}: refusing, the sheet charges ${s.fee}`);
  for (const p of s.pay) if (/ BEAM$/.test(p) && groth(p) > MAX_BEAM_OUT) throw new Error(`${what}: refusing, the sheet pays ${p}`);
}

/** Waits until a new contract tx completes, and returns it with the pool status screen's kernel. */
async function waitNewTx(before, label) {
  const tx = await waitTx(page, (t) => !before.has(t.txId), label, 25 * 60000);
  return tx;
}

try {
  log('restoring FUNDER2 through the Restore screen + recovery snapshot');
  await page.goto(srv.url);
  await restoreFunder(page, funderWords(), password, 'live-dex');
  await waitHome(page, { timeout: 20 * 60000 });
  await waitSynced(page, 15 * 60000);
  await page.waitForFunction(() => window.__campfire.sync().canSend, null, { timeout: 300000 });
  await sleep(8000);
  const b0 = await balances();
  log('before:', showB(b0));
  record.push({ step: 'before', ...Object.fromEntries(Object.entries(b0).map(([k, v]) => [k, B(v)])) });
  if (b0.beam < MIN_START) throw new Error(`FUNDER2 has ${B(b0.beam)} BEAM available; need at least ${B(MIN_START)}`);
  await shot(page, 'live-dex-01-home');

  // ---- the pool, to know how much FOMO a 0.02 BEAM deposit needs
  await page.click(tid('swap'));
  await waitScreen(page, 'swap');
  await page.click(tid('swap-pools'));
  await waitScreen(page, 'pools');
  await page.waitForSelector(`[data-testid="pool-card"][data-pool="0-174-2"]`, { timeout: 120000 });
  await shot(page, 'live-dex-02-pools');
  await page.locator(`[data-testid="pool-card"][data-pool="0-174-2"] [data-testid="pool-open"]`).click();
  await waitScreen(page, 'pool');
  await page.waitForSelector(tid('pool-head'), { timeout: 60000 });
  if (await page.$(tid('pool-mode-add'))) await page.click(tid('pool-mode-add'));
  await page.fill(tid('pool-add-1'), ADD_BEAM);
  await page.waitForSelector(tid('pool-get-lp'), { timeout: 90000 });
  let needFomo = groth(await page.inputValue(tid('pool-add-2')));
  log(`a ${ADD_BEAM} BEAM deposit needs ${B(needFomo)} FOMO; FUNDER2 has ${B(b0.fomo)}`);

  // ---- not enough FOMO: swap a little BEAM for it first (the Swap screen)
  if (b0.fomo < needFomo) {
    const perBeam = (needFomo * 100000000n) / groth(ADD_BEAM); // FOMO per BEAM
    const want = needFomo - b0.fomo;
    let payBeam = (want * 100000000n) / perBeam;
    payBeam = (payBeam * 110n) / 100n + 100000n; // the pool fee and some room
    if (payBeam > MAX_BEAM_OUT) throw new Error(`refusing: the FOMO top-up would need a ${B(payBeam)} BEAM swap`);
    log(`swapping ${B(payBeam)} BEAM for FOMO first`);
    const txs0 = new Set((await page.evaluate(() => window.__campfire.txs())).map((t) => t.txId));
    await page.evaluate(() => window.__campfire.go('swap'));
    await waitScreen(page, 'swap');
    await page.waitForFunction(() => !/Loading prices/.test(document.querySelector('[data-testid="swap-reason"]').textContent), null, { timeout: 120000 });
    if (!/FOMO/.test(await page.textContent(tid('swap-get-asset')))) {
      await page.click(tid('swap-get-asset'));
      await page.waitForSelector(`.sheet [data-asset-id="${FOMO}"]`);
      await page.click(`.sheet [data-asset-id="${FOMO}"]`);
    }
    await page.fill(tid('swap-pay-amount'), B(payBeam));
    await page.waitForFunction(() => !document.querySelector('[data-testid="swap-cta"]').disabled, null, { timeout: 90000 });
    await page.click(tid('swap-cta'));
    await page.waitForSelector(tid('consent'), { timeout: 90000 });
    const s = await sheet();
    log('swap sheet:', JSON.stringify(s));
    refuseUnlessSafe(s, 'swap');
    await approve('live-dex-03-swap');
    await waitScreen(page, 'txStatus', 120000);
    const tx = await waitNewTx(txs0, 'swap');
    log('swap completed:', JSON.stringify(tx));
    record.push({ step: 'swap', txId: tx.txId, kernel: tx.kernel, sheet: s });
    await page.waitForFunction(([id, need]) => BigInt((window.__campfire.totals()[id] || { available: '0' }).available) >= BigInt(need), [FOMO, String(needFomo)], { timeout: 300000, polling: 3000 });
    await sleep(5000);
    await page.evaluate(() => window.__campfire.go('pool', { aid1: 0, aid2: 174, kind: 2, mode: 'add' }));
    await waitScreen(page, 'pool');
    await page.waitForSelector(tid('pool-head'), { timeout: 60000 });
    await page.fill(tid('pool-add-1'), ADD_BEAM);
    await page.waitForSelector(tid('pool-get-lp'), { timeout: 90000 });
  }

  // ---- add liquidity through the pool screen and the approve sheet
  const bA = await balances();
  log('before the deposit:', showB(bA));
  const screenAdd = { fomo: await page.inputValue(tid('pool-add-2')), lp: await page.textContent(tid('pool-get-lp')), shareAfter: await page.textContent(tid('pool-share-after')) };
  await page.waitForFunction(() => !document.querySelector('[data-testid="pool-cta"]').disabled, null, { timeout: 60000 });
  log('pool screen:', JSON.stringify(screenAdd), await page.textContent(tid('pool-cta')));
  await shot(page, 'live-dex-04-add');
  const txsA = new Set((await page.evaluate(() => window.__campfire.txs())).map((t) => t.txId));
  await page.click(tid('pool-cta'));
  await page.waitForSelector(tid('consent'), { timeout: 90000 });
  const sA = await sheet();
  log('deposit sheet:', JSON.stringify(sA));
  await shot(page, 'live-dex-05-add-sheet');
  refuseUnlessSafe(sA, 'deposit');
  if (sA.title !== 'Confirm your deposit' || sA.pay.length !== 2 || sA.get.length !== 1 || !/BEAM\/FOMO LP$/.test(sA.get[0])) throw new Error('refusing: the deposit sheet is not a BEAM + FOMO -> LP deposit');
  if (groth(sA.pay[0]) !== groth(ADD_BEAM)) throw new Error(`refusing: the sheet deposits ${sA.pay[0]}`);
  const addFomo = groth(sA.pay[1]);
  const addLp = groth(sA.get[0]);
  await approve('live-dex-06-add');
  await waitScreen(page, 'poolTx', 120000);
  await shot(page, 'live-dex-07-add-pending');
  const txAdd = await waitNewTx(txsA, 'deposit');
  await page.waitForFunction(() => /^Added to the pool$/.test(document.querySelector('[data-testid="pool-tx-title"]')?.textContent || ''), null, { timeout: 120000 });
  await page.waitForSelector(tid('pool-tx-kernel'), { timeout: 60000 });
  await shot(page, 'live-dex-08-add-done');
  log('deposit completed:', JSON.stringify(txAdd));
  await page.waitForFunction(([id, want]) => BigInt((window.__campfire.totals()[id] || { available: '0' }).available) >= BigInt(want), [LP, String(bA.lp + addLp)], { timeout: 300000, polling: 3000 });
  await sleep(5000);
  const bB = await balances();
  log('after the deposit:', showB(bB));
  const addOk = bA.beam - bB.beam === groth(ADD_BEAM) + FEE && bA.fomo - bB.fomo === addFomo && bB.lp - bA.lp === addLp;
  record.push({ step: 'add', txId: txAdd.txId, kernel: txAdd.kernel, sheet: sA, before: showB(bA), after: showB(bB), exact: addOk });
  if (!addOk) throw new Error('the deposit did not move the balances by what the sheet said');

  // Activity names it.
  await page.evaluate(() => window.__campfire.go('activity'));
  await page.waitForSelector(`[data-txid="${txAdd.txId}"]`, { timeout: 60000 });
  const actAdd = await page.textContent(`[data-txid="${txAdd.txId}"] .t`);
  log('Activity:', actAdd);
  await shot(page, 'live-dex-09-activity-add');
  if (actAdd !== 'Added to a DEX pool') throw new Error(`Activity calls the deposit "${actAdd}"`);

  // Home shows the LP row; it opens the pool on Withdraw.
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  const lpRow = page.locator(`[data-testid="token-row"][data-asset-id="${LP}"]`);
  await lpRow.waitFor({ timeout: 60000 });
  log('Home LP row:', (await lpRow.textContent()).replace(/\s+/g, ' '));
  await lpRow.scrollIntoViewIfNeeded();
  await shot(page, 'live-dex-10-home-lp');
  await lpRow.click();
  await waitScreen(page, 'pool');
  await page.waitForSelector(tid('pool-position'), { timeout: 60000 });
  log('position:', await page.textContent(tid('pool-my-share')), await page.textContent(tid('pool-my-value')), await page.textContent(tid('pool-my-value-note')));

  // ---- withdraw what was added through the pool screen and the approve sheet
  await page.waitForSelector(tid('pool-withdraw-form'), { state: 'visible', timeout: 60000 });
  if (bA.lp === 0n) await page.click(tid('pool-pct-100'));
  else await page.fill(tid('pool-withdraw-exact'), B(addLp));
  await page.waitForFunction((want) => document.querySelector('[data-testid="pool-return-lp"]')?.textContent === `${want} LP`, B(addLp).replace(/\.?0+$/, ''), { timeout: 90000 });
  await page.waitForFunction(() => !document.querySelector('[data-testid="pool-cta"]').disabled, null, { timeout: 60000 });
  const screenWd = { back: await page.textContent(tid('pool-get-back')), cta: await page.textContent(tid('pool-cta')) };
  log('withdraw screen:', JSON.stringify(screenWd));
  await shot(page, 'live-dex-11-withdraw');
  const txsW = new Set((await page.evaluate(() => window.__campfire.txs())).map((t) => t.txId));
  await page.click(tid('pool-cta'));
  await page.waitForSelector(tid('consent'), { timeout: 90000 });
  const sW = await sheet();
  log('withdrawal sheet:', JSON.stringify(sW));
  await shot(page, 'live-dex-12-withdraw-sheet');
  refuseUnlessSafe(sW, 'withdrawal');
  if (sW.title !== 'Confirm your withdrawal' || sW.pay.length !== 1 || groth(sW.pay[0]) !== addLp) throw new Error(`refusing: the withdrawal returns ${sW.pay[0]}, not the ${B(addLp)} LP added`);
  const backBeam = groth(sW.get.find((x) => / BEAM$/.test(x)));
  const backFomo = groth(sW.get.find((x) => / FOMO$/.test(x)));
  await approve('live-dex-13-withdraw');
  await waitScreen(page, 'poolTx', 120000);
  const txWd = await waitNewTx(txsW, 'withdrawal');
  await page.waitForFunction(() => /^Taken out of the pool$/.test(document.querySelector('[data-testid="pool-tx-title"]')?.textContent || ''), null, { timeout: 120000 });
  await page.waitForSelector(tid('pool-tx-kernel'), { timeout: 60000 });
  await shot(page, 'live-dex-14-withdraw-done');
  log('withdrawal completed:', JSON.stringify(txWd));
  await page.waitForFunction(([id, want]) => BigInt((window.__campfire.totals()[id] || { available: '0' }).available) <= BigInt(want), [LP, String(bA.lp)], { timeout: 300000, polling: 3000 });
  await page.waitForFunction(([id, want]) => BigInt((window.__campfire.totals()[id] || { available: '0' }).available) >= BigInt(want), [FOMO, String(bB.fomo + backFomo)], { timeout: 300000, polling: 3000 });
  await sleep(5000);
  const bC = await balances();
  log('after the withdrawal:', showB(bC));
  const wdOk = bC.lp === bA.lp && bC.beam - bB.beam === backBeam - FEE && bC.fomo - bB.fomo === backFomo;
  record.push({ step: 'withdraw', txId: txWd.txId, kernel: txWd.kernel, sheet: sW, before: showB(bB), after: showB(bC), exact: wdOk });
  if (!wdOk) throw new Error('the withdrawal did not move the balances by what the sheet said');
  await page.evaluate(() => window.__campfire.go('activity'));
  await page.waitForSelector(`[data-txid="${txWd.txId}"]`, { timeout: 60000 });
  const actWd = await page.textContent(`[data-txid="${txWd.txId}"] .t`);
  log('Activity:', actWd);
  await shot(page, 'live-dex-15-activity-withdraw');
  if (actWd !== 'Taken from a DEX pool') throw new Error(`Activity calls the withdrawal "${actWd}"`);

  // ---- create a pool: only as far as the approve sheet, then Cancel
  const txsC = (await page.evaluate(() => window.__campfire.txs())).length;
  await page.evaluate(async () => {
    // The screen is shown 11 BEAM so its button works; the engine knows FUNDER2's real balance.
    const { wallet } = await import('./lib/wallet.js');
    const orig = wallet.refreshStatus.bind(wallet);
    wallet.refreshStatus = async function () {
      await orig();
      const t = this.state.totals.get(0) || { available: 0n, receiving: 0n, sending: 0n, maturing: 0n };
      this.state.totals.set(0, { ...t, available: 1100000000n });
      this.emit();
    };
    await wallet.refreshStatus();
  });
  await page.evaluate(() => window.__campfire.go('poolCreate', { aidA: 0, aidB: 174 }));
  await waitScreen(page, 'poolCreate');
  const free = await page.evaluate(async () => {
    const { loadPools } = await import('./lib/dex_pools.js');
    const pools = await loadPools();
    return [1, 0].find((k) => !pools.some((p) => p.aid1 === 0 && p.aid2 === 174 && p.kind === k));
  });
  await page.click(tid(`create-kind-${free}`));
  await page.waitForFunction(() => !document.querySelector('[data-testid="create-cta"]').disabled, null, { timeout: 60000 });
  await shot(page, 'live-dex-16-create');
  await page.click(tid('create-cta'));
  await page.waitForSelector(tid('consent'), { timeout: 90000 });
  const sC = await sheet();
  log('new pool sheet:', JSON.stringify(sC));
  await shot(page, 'live-dex-17-create-sheet');
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(tid('create-result'), { timeout: 30000 });
  const createResult = await page.getAttribute(tid('create-result'), 'data-code');
  await sleep(5000);
  const txsAfter = await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    return (await wallet.session.call('tx_list', { count: 100, skip: 0 })).length;
  });
  const bD = await balances();
  record.push({ step: 'create (cancelled)', sheet: sC, result: createResult, txsBefore: txsC, txsAfter });
  log(`create: ${createResult}; transactions ${txsC} -> ${txsAfter}`);
  if (createResult !== 'rejected' || txsAfter !== txsC) throw new Error('the cancelled pool creation left a transaction');
  log('final:', showB({ ...bD, beam: bC.beam }), `(BEAM as the engine has it: ${B(bC.beam)}); spent ${B(b0.beam - bC.beam)} BEAM in all`);
  log('foreign hosts', JSON.stringify(foreignHosts(rec, srv.url)));
} catch (e) {
  exit = 1;
  log('LIVE DEX FAILED:', e.message);
  await shot(page, 'live-dex-failure').catch(() => {});
} finally {
  console.log('RECORD', JSON.stringify(record, (k, v) => (typeof v === 'bigint' ? String(v) : v)));
  await browser.close();
  srv.stop();
  rmSync(tmp, { recursive: true, force: true });
}
process.exit(exit);

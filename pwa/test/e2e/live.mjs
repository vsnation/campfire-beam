// LIVE MONEY TEST on BEAM mainnet, tiny amounts only.
//
//   npm run e2e:live
//
// Two BEAM Campfire wallets in two browser contexts, open at the same time
// (BEAM regular payments are interactive: both wallets must be online):
//   A = the owner's test wallet FUNDER2, restored from its 12 words through the
//       real Restore screen and the recovery snapshot. The words are read from
//       ~/.config/campfire-beam/test_wallets.env (FUNDER2_WALLET_SEED) at run
//       time and are never printed or screenshotted.
//   B = a fresh throwaway wallet.
// A sends 0.01 BEAM to B; then B sends everything it can (0.01 - fee) back to A,
// so nothing is stranded in the throwaway wallet. Both payments must complete
// in both wallets; the script prints txIds and kernel ids.
//
// Hard limits: refuses any payment above 0.02 BEAM; refuses to start if A
// has less than 0.012 BEAM.
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, shot, waitScreen, sleep, foreignHosts } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';

const MAX_GROTH = 2000000n; // 0.02 BEAM, per payment
const SEND_GROTH = 1000000n; // 0.01 BEAM
const tid = (id) => `[data-testid="${id}"]`;
const PORT = 8792;

function readEnv(path) {
  const out = {};
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#') || !t.includes('=')) continue;
    const i = t.indexOf('=');
    out[t.slice(0, i)] = t.slice(i + 1).trim().replace(/^["']|["']$/g, '');
  }
  return out;
}

const env = readEnv(join(homedir(), '.config', 'campfire-beam', 'test_wallets.env'));
const funderWords = (env.FUNDER2_WALLET_SEED || '').split(/[\s;]+/).filter(Boolean);
if (funderWords.length !== 12) throw new Error('FUNDER2_WALLET_SEED is missing or not 12 words (not printed)');

const pwA = `live-a-${Math.random().toString(36).slice(2, 10)}`;
const pwB = `live-b-${Math.random().toString(36).slice(2, 10)}`;
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

async function restoreFunder(page) {
  await waitScreen(page, 'welcome', 60000);
  await page.click(tid('restore'));
  await waitScreen(page, 'restore');
  await shot(page, 'live-A-01-restore-empty'); // before any word is typed
  await page.fill(tid('word-1'), funderWords.join(' '));
  await page.waitForFunction(() => !document.querySelector('[data-testid="restore-submit"]').disabled, null, { timeout: 30000 });
  await page.click(tid('restore-submit'));
  await waitScreen(page, 'setPassword');
  await page.fill(tid('pw1'), pwA);
  await page.fill(tid('pw2'), pwA);
  await page.click(tid('save-password'));
  await page.waitForFunction(() => ['passkeySetup', 'ipNotice'].includes(document.getElementById('app').dataset.screen), null, { timeout: 30000 });
  if ((await page.evaluate(() => document.getElementById('app').dataset.screen)) === 'passkeySetup') await page.click(tid('passkey-skip'));
  await waitScreen(page, 'ipNotice');
  await page.click(tid('ip-connect'));
  await waitScreen(page, 'fastStart');
  await shot(page, 'live-A-02-fast-start-restore');
  await page.click(tid('fast-download'));
}

const beam = (page) => page.evaluate(() => window.__campfire.totals()[0] || { available: '0', receiving: '0', sending: '0' });

async function pay(page, who, address, amountText, password) {
  await page.evaluate(() => window.__campfire.go('send'));
  await waitScreen(page, 'send');
  await page.fill(tid('send-address'), address);
  await page.waitForFunction(() => /Regular address/.test(document.querySelector('[data-testid="address-hint"]').textContent), null, { timeout: 30000 });
  if (amountText === 'max') await page.click(tid('max'));
  else await page.fill(tid('send-amount'), amountText);
  const typed = await page.inputValue(tid('send-amount'));
  const groth = BigInt(Math.round(Number(typed) * 1e8));
  if (groth > MAX_GROTH) throw new Error(`refusing to send ${typed} BEAM (limit 0.02)`);
  await page.waitForFunction(() => !document.querySelector('[data-testid="review"]').disabled, null, { timeout: 60000 });
  await shot(page, `live-${who}-send`);
  await page.click(tid('review'));
  await waitScreen(page, 'review');
  const summary = {
    amount: await page.textContent(tid('review-amount')),
    to: await page.textContent(tid('review-to')),
    fee: await page.textContent(tid('review-fee')),
    total: await page.textContent(tid('review-total')),
  };
  log(`${who} review:`, JSON.stringify(summary));
  await shot(page, `live-${who}-review`);
  await page.click(tid('confirm-send'));
  await page.waitForSelector(tid('auth-pw'), { timeout: 20000 });
  await page.fill(tid('auth-pw'), password);
  await shot(page, `live-${who}-confirm-auth`);
  await page.click(tid('auth-submit'));
  await waitScreen(page, 'txStatus', 60000);
  await shot(page, `live-${who}-status-pending`);
  return summary;
}

async function waitTx(page, pred, label, timeoutMs = 20 * 60000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    const txs = await page.evaluate(() => window.__campfire.txs());
    const t = txs.find(pred);
    if (t && Number(t.status) === 3) return t;
    if (t && (Number(t.status) === 4 || Number(t.status) === 2)) throw new Error(`${label}: status ${t.status}`);
    await sleep(5000);
  }
  throw new Error(`${label}: not completed in time`);
}

const extra = process.env.BEAM_RECOVERY_FILE ? ['--recovery-file', process.env.BEAM_RECOVERY_FILE] : [];
const srv = await startServer({ port: PORT, extra });
const browser = await launch();
const ctxA = await browser.newContext({ viewport: { width: 375, height: 667 }, deviceScaleFactor: 2 });
const ctxB = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
const A = await recordedPage(ctxA, { label: 'A' });
const B = await recordedPage(ctxB, { label: 'B' });
let exit = 0;
try {
  log('A: restoring FUNDER2 through the Restore screen + recovery snapshot');
  await A.page.goto(srv.url);
  await restoreFunder(A.page);
  await waitHome(A.page, { timeout: 20 * 60000 });
  await waitSynced(A.page, 15 * 60000);
  await sleep(8000);
  let a = await beam(A.page);
  log('A synced; BEAM available (groth):', a.available, 'receiving:', a.receiving);
  await shot(A.page, 'live-A-03-home-restored');
  if (BigInt(a.available) < 1200000n) throw new Error(`A has ${a.available} groth available; need at least 0.012 BEAM. Ask the coordinator to fund FUNDER2.`);

  log('B: creating a throwaway wallet');
  await B.page.goto(srv.url);
  await createWallet(B.page, { password: pwB, passkey: false });
  await waitHome(B.page, { timeout: 20 * 60000 });
  await waitSynced(B.page, 15 * 60000);
  await B.page.click(tid('receive'));
  await waitScreen(B.page, 'receive');
  await B.page.waitForFunction(() => document.querySelector('[data-testid="receive-address"]').textContent.length > 20, null, { timeout: 60000 });
  const addrB = await B.page.textContent(tid('receive-address'));
  await shot(B.page, 'live-B-receive');
  log('B address (public receive address):', addrB);
  await B.page.evaluate(() => window.__campfire.go('home'));

  // ---- A -> B, 0.01 BEAM
  await A.page.waitForFunction(() => window.__campfire.sync().canSend, null, { timeout: 300000 });
  await pay(A.page, 'A', addrB, '0.01', pwA);
  const t1 = await waitTx(A.page, (t) => !t.income && String(t.value) === String(SEND_GROTH), 'A->B (sender)');
  log('A->B completed in A:', JSON.stringify(t1));
  await shot(A.page, 'live-A-status-completed');
  const r1 = await waitTx(B.page, (t) => t.income && String(t.value) === String(SEND_GROTH), 'A->B (receiver)');
  log('A->B completed in B:', JSON.stringify(r1));
  await B.page.evaluate(() => window.__campfire.go('activity'));
  await sleep(1000);
  await shot(B.page, 'live-B-activity-received');

  // ---- B -> A, everything B can send (0.01 - 0.001 fee = 0.009), so nothing is stranded
  const addrA = await (async () => {
    await A.page.evaluate(() => window.__campfire.go('receive'));
    await waitScreen(A.page, 'receive');
    await A.page.waitForFunction(() => document.querySelector('[data-testid="receive-address"]').textContent.length > 20, null, { timeout: 60000 });
    const x = await A.page.textContent(tid('receive-address'));
    await A.page.evaluate(() => window.__campfire.go('home'));
    return x;
  })();
  await B.page.evaluate(() => window.__campfire.go('home'));
  await B.page.waitForFunction(() => window.__campfire.sync().canSend && BigInt(window.__campfire.totals()[0].available) >= 1000000n, null, { timeout: 600000, polling: 2000 });
  await pay(B.page, 'B', addrA, 'max', pwB);
  const t2 = await waitTx(B.page, (t) => !t.income && String(t.value) === '900000', 'B->A (sender)');
  log('B->A completed in B:', JSON.stringify(t2));
  await shot(B.page, 'live-B-status-completed');
  const r2 = await waitTx(A.page, (t) => t.income && String(t.value) === '900000', 'B->A (receiver)');
  log('B->A completed in A:', JSON.stringify(r2));
  await A.page.evaluate(() => window.__campfire.go('activity'));
  await sleep(1000);
  await shot(A.page, 'live-A-activity');
  a = await beam(A.page);
  const b = await beam(B.page);
  log('final A:', JSON.stringify(a), 'final B:', JSON.stringify(b));
  for (const [n, r] of [['A', A], ['B', B]]) {
    const f = foreignHosts(r.rec, srv.url);
    log(`${n}: foreign hosts ${JSON.stringify(f)}, websockets ${JSON.stringify([...new Set(r.rec.websockets.map((u) => new URL(u).host))])}`);
    if (f.length) exit = 1;
  }
} catch (e) {
  exit = 1;
  log('LIVE TEST FAILED:', e.message);
  await shot(A.page, 'live-A-failure').catch(() => {});
  await shot(B.page, 'live-B-failure').catch(() => {});
} finally {
  await browser.close();
  srv.stop();
}
process.exit(exit);

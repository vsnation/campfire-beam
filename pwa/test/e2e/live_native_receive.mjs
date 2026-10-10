// LIVE MONEY TEST on BEAM mainnet, tiny amounts only: the web wallet receives
// from a wallet that is not a web wallet - BEAM's own wallet-api, on a plain TCP
// connection to a BEAM node, as the desktop and mobile apps connect.
//
//   NATIVE=<label> node test/e2e/live_native_receive.mjs
//
// <label> is a wallet in ~/.config/campfire-beam/test_wallets.env already
// running under scripts/beam/live/wapi.py (start + wait-sync).
// A = FUNDER2 restored in the web wallet (words read at run time, never printed).
//   1. A pays the native wallet 0.015 BEAM (web -> native).
//   2. A is closed and opened again, so its address is one from an earlier session.
//   3. The native wallet pays A 0.01 BEAM (native -> web), the direction reported failing.
// Each step prints both sides' status changes and the time taken.
//
// Hard limits: no payment above 0.02 BEAM.
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { startServer, launch, recordedPage, shot, waitScreen, sleep, PWA } from './harness.mjs';
import { waitHome, waitSynced, unlockWithPassword } from './flows.mjs';
import { tid, log, funderWords as readFunderWords, restoreFunder as restore, total } from './live_common.mjs';

const NATIVE = process.env.NATIVE;
if (!NATIVE) throw new Error('set NATIVE=<label> (a wallet running under wapi.py)');
const PORT = 8799;
const WAPI = join(PWA, '..', 'scripts', 'beam', 'live', 'wapi.py');
const STATUS = { 0: 'pending', 1: 'in progress', 2: 'canceled', 3: 'completed', 4: 'failed', 5: 'registering' };
const pwA = `native-a-${Math.random().toString(36).slice(2, 10)}`;

/** One JSON-RPC call to the native wallet-api through wapi.py. */
function rpc(method, params = {}) {
  const out = execFileSync('python3', ['-I', WAPI, 'call', NATIVE, method, JSON.stringify(params)], { encoding: 'utf8', timeout: 90000 });
  const j = JSON.parse(out);
  if (j.error) throw new Error(`${method}: ${JSON.stringify(j.error)}`);
  return j.result !== undefined ? j.result : j;
}

const webTx = async (page, txId) => (await page.evaluate(() => window.__campfire.txs())).find((t) => t.txId === txId) || null;
const nativeTx = (txId) => (rpc('tx_list', { count: 50 }) || []).find((t) => t.txId === txId) || null;

/** Follows [txId] on both sides until both say completed; logs every change. */
async function follow(label, txId, page, pw, timeoutMs = 15 * 60000) {
  const t0 = Date.now();
  const last = { web: '', native: '' };
  const done = {};
  while (Date.now() - t0 < timeoutMs) {
    if ((await page.evaluate(() => window.__campfire.screen())) === 'unlock') {
      await unlockWithPassword(page, pw);
      await waitHome(page, { timeout: 5 * 60000 });
      log(`  web: unlocked`);
    }
    const sides = { web: await webTx(page, txId), native: nativeTx(txId) };
    for (const [k, t] of Object.entries(sides)) {
      const s = t ? STATUS[t.status] || String(t.status) : 'not listed';
      if (s !== last[k]) {
        log(`  ${label} ${k}: ${s}${t && t.failure_reason ? ` (${t.failure_reason})` : ''} (+${Math.round((Date.now() - t0) / 1000)} s)`);
        last[k] = s;
      }
      if (t && Number(t.status) === 3 && !done[k]) done[k] = Date.now() - t0;
      if (t && [2, 4].includes(Number(t.status))) throw new Error(`${label} ${k}: ${s}`);
    }
    if (done.web != null && done.native != null) return { ms: Math.max(done.web, done.native), kernel: (sides.web && sides.web.kernel) || (sides.native && sides.native.kernel) };
    await sleep(3000);
  }
  throw new Error(`${label}: not completed in ${timeoutMs / 60000} min (web ${last.web}, native ${last.native})`);
}

const results = [];
const srv = await startServer({ port: PORT });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
let A = await recordedPage(ctx, { label: 'A' });
let exit = 0;
try {
  const st = rpc('wallet_status');
  log(`native ${NATIVE}: height ${st.current_height}, available ${st.available} groth`);

  log('A: restoring FUNDER2 in the web wallet');
  await A.page.goto(srv.url);
  await restore(A.page, readFunderWords(), pwA, 'native-A');
  await waitHome(A.page, { timeout: 20 * 60000 });
  await waitSynced(A.page, 15 * 60000);
  await sleep(8000);
  log('A synced; BEAM available (groth):', (await total(A.page, 0)).available, 'node:', await A.page.evaluate(() => window.__campfire.node()));
  await A.page.click(tid('receive'));
  await waitScreen(A.page, 'receive');
  await A.page.waitForFunction(() => document.querySelector('[data-testid="receive-address"]').textContent.length > 20, null, { timeout: 60000 });
  const addrA = await A.page.textContent(tid('receive-address'));
  await A.page.evaluate(() => window.__campfire.go('home'));

  // ---- 1. web -> native, 0.015 BEAM (only when the native wallet has less than 0.011)
  if (BigInt(st.available) < 1100000n) {
    const addrN = rpc('create_address', { type: 'regular', expiration: 'never', comment: 'web receive test' });
    log('1. A pays the native wallet 0.015 BEAM');
    await A.page.waitForFunction(() => window.__campfire.sync().canSend, null, { timeout: 300000 });
    await A.page.evaluate(() => window.__campfire.go('send'));
    await waitScreen(A.page, 'send');
    await A.page.fill(tid('send-address'), addrN);
    await A.page.waitForFunction(() => /Regular address/.test(document.querySelector('[data-testid="address-hint"]').textContent), null, { timeout: 30000 });
    await A.page.fill(tid('send-amount'), '0.015');
    await A.page.waitForFunction(() => !document.querySelector('[data-testid="review"]').disabled, null, { timeout: 60000 });
    const before = new Set((await A.page.evaluate(() => window.__campfire.txs())).map((t) => t.txId));
    await A.page.click(tid('review'));
    await waitScreen(A.page, 'review');
    await A.page.click(tid('confirm-send'));
    await A.page.waitForSelector(tid('auth-pw'), { timeout: 20000 });
    await A.page.fill(tid('auth-pw'), pwA);
    await A.page.click(tid('auth-submit'));
    await waitScreen(A.page, 'txStatus', 60000);
    const id1 = (await A.page.evaluate(() => window.__campfire.txs())).find((t) => !before.has(t.txId) && !t.income).txId;
    const r1 = await follow('web->native', id1, A.page, pwA);
    results.push({ step: 'web -> native', txId: id1, ...r1 });
  } else log('1. skipped: the native wallet already has funds');

  // ---- 2. A closed and opened again
  log('2. A closed and opened again (its address now comes from an earlier session)');
  await A.page.close();
  await sleep(5000);
  A = await recordedPage(ctx, { label: 'A' });
  await A.page.goto(srv.url);
  await unlockWithPassword(A.page, pwA);
  await waitHome(A.page, { timeout: 5 * 60000 });
  await waitSynced(A.page, 5 * 60000);
  log('A open again; node:', await A.page.evaluate(() => window.__campfire.node()));

  // ---- 3. native -> web, 0.01 BEAM
  log('3. the native wallet pays A 0.01 BEAM');
  const sent = rpc('tx_send', { address: addrA, value: 1000000, fee: 100000 });
  const id3 = sent.txId;
  log(`  native tx ${id3}`);
  const r3 = await follow('native->web', id3, A.page, pwA);
  results.push({ step: 'native -> web (address from an earlier session)', txId: id3, ...r3 });
  await A.page.evaluate(() => window.__campfire.go('activity'));
  await sleep(1500);
  await shot(A.page, 'native-A-activity');
} catch (e) {
  exit = 1;
  log('LIVE TEST FAILED:', e.message);
  if (!A.page.isClosed()) await shot(A.page, 'native-A-failure').catch(() => {});
  if (!A.page.isClosed()) console.log(A.rec.console.slice(-30).map((c) => `[A] ${c.text.slice(0, 200)}`).join('\n'));
} finally {
  log('RESULTS', JSON.stringify(results, null, 1));
  await browser.close();
  srv.stop();
}
process.exit(exit);

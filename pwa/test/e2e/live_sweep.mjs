// LIVE: sends what is left in the receive tests' throwaway web wallets to a
// native test wallet, so no test money is stranded. Tiny amounts only.
//
//   NATIVE=<label> SWEEP=<label> node test/e2e/live_sweep.mjs
//
// Every <SWEEP>_WALLET_SEED entry in ~/.config/campfire-beam/test_wallets.env is
// restored in the web wallet (words never printed) and sends everything it can
// to <NATIVE>, a wallet running under scripts/beam/live/wapi.py.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen, sleep, PWA } from './harness.mjs';
import { waitHome, waitSynced } from './flows.mjs';
import { tid, log, restoreFunder as restore, total } from './live_common.mjs';

const { NATIVE, SWEEP } = process.env;
if (!NATIVE || !SWEEP) throw new Error('set NATIVE=<label> SWEEP=<label>');
const WAPI = join(PWA, '..', 'scripts', 'beam', 'live', 'wapi.py');
const MAX_GROTH = 3000000n; // 0.03 BEAM

function rpc(method, params = {}) {
  const j = JSON.parse(execFileSync('python3', ['-I', WAPI, 'call', NATIVE, method, JSON.stringify(params)], { encoding: 'utf8', timeout: 90000 }));
  if (j.error) throw new Error(`${method}: ${JSON.stringify(j.error)}`);
  return j.result;
}

const seeds = readFileSync(join(homedir(), '.config', 'campfire-beam', 'test_wallets.env'), 'utf8')
  .split('\n')
  .filter((l) => l.startsWith(`${SWEEP}_WALLET_SEED=`))
  .map((l) => l.slice(l.indexOf('=') + 1).trim().split(/[\s;]+/));
if (!seeds.length || seeds.some((w) => w.length !== 12)) throw new Error(`no 12-word ${SWEEP}_WALLET_SEED entries (not printed)`);
log(`${seeds.length} wallet(s) to sweep into ${NATIVE}`);

const srv = await startServer({ port: 8802 });
const browser = await launch();
let exit = 0;
try {
  for (const [n, words] of seeds.entries()) {
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const { page } = await recordedPage(ctx, { label: `sweep${n}` });
    const pw = `sweep-${Math.random().toString(36).slice(2, 10)}`;
    await page.goto(srv.url);
    await restore(page, words, pw, `sweep-${n}`);
    await waitHome(page, { timeout: 20 * 60000 });
    await waitSynced(page, 15 * 60000);
    await sleep(8000);
    const have = BigInt((await total(page, 0)).available);
    log(`wallet ${n + 1}: ${have} groth available`);
    if (have <= 100000n) {
      await ctx.close();
      continue;
    }
    const to = rpc('create_address', { type: 'regular', expiration: 'never', comment: 'sweep' });
    await page.waitForFunction(() => window.__campfire.sync().canSend, null, { timeout: 300000 });
    await page.evaluate(() => window.__campfire.go('send'));
    await waitScreen(page, 'send');
    await page.fill(tid('send-address'), to);
    await page.waitForFunction(() => /Regular address/.test(document.querySelector('[data-testid="address-hint"]').textContent), null, { timeout: 30000 });
    await page.click(tid('max'));
    const typed = await page.inputValue(tid('send-amount'));
    if (BigInt(Math.round(Number(typed) * 1e8)) > MAX_GROTH) throw new Error(`refusing to sweep ${typed} BEAM`);
    await page.waitForFunction(() => !document.querySelector('[data-testid="review"]').disabled, null, { timeout: 60000 });
    const before = new Set((await page.evaluate(() => window.__campfire.txs())).map((t) => t.txId));
    await page.click(tid('review'));
    await waitScreen(page, 'review');
    await page.click(tid('confirm-send'));
    await page.waitForSelector(tid('auth-pw'), { timeout: 20000 });
    await page.fill(tid('auth-pw'), pw);
    await page.click(tid('auth-submit'));
    await waitScreen(page, 'txStatus', 60000);
    const id = (await page.evaluate(() => window.__campfire.txs())).find((t) => !before.has(t.txId) && !t.income).txId;
    log(`wallet ${n + 1}: sweeping ${typed} BEAM, tx ${id}`);
    const t0 = Date.now();
    for (;;) {
      const web = (await page.evaluate(() => window.__campfire.txs())).find((t) => t.txId === id);
      const nat = (rpc('tx_list', { count: 50 }) || []).find((t) => t.txId === id);
      if (web && nat && Number(web.status) === 3 && Number(nat.status) === 3) {
        log(`wallet ${n + 1}: swept, kernel ${web.kernel} (${Math.round((Date.now() - t0) / 1000)} s)`);
        break;
      }
      if ((web && [2, 4].includes(Number(web.status))) || Date.now() - t0 > 15 * 60000) throw new Error(`wallet ${n + 1}: sweep did not complete (web ${web && web.status}, native ${nat && nat.status})`);
      await sleep(4000);
    }
    await ctx.close();
  }
  log(`native ${NATIVE} available now: ${rpc('wallet_status').available} groth`);
} catch (e) {
  exit = 1;
  log('SWEEP FAILED:', e.message);
} finally {
  await browser.close();
  srv.stop();
}
process.exit(exit);

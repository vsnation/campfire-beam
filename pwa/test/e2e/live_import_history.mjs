// LIVE, read-only: a wallet.db with a long history (many addresses, long expired) imports, starts
// and syncs. Before engine patch 0108 BEAM's NotificationCenter re-entered its address-expiry
// check once per expired address and the wallet thread ran out of stack at start
// ("Maximum call stack size exceeded"): nothing answered and the app moved between nodes forever.
//
//   node test/e2e/live_import_history.mjs
//
// The wallet is a COPY of LWTEST's wallet.db (path and password read from
// ~/.config/campfire-beam/test_wallets.env at run time, never printed). Nothing is sent or signed.
import { copyFileSync, chmodSync, mkdtempSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen } from './harness.mjs';
import { readEnv, tid, log } from './live_common.mjs';

const PORT = 8804;
const env = readEnv(join(homedir(), '.config', 'campfire-beam', 'test_wallets.env'));
if (!env.LWTEST_WALLET_DB || !env.LWTEST_WALLET_PASS) throw new Error('LWTEST_WALLET_DB / LWTEST_WALLET_PASS missing (not printed)');
const tmp = mkdtempSync(join(tmpdir(), 'campfire-history-'));
const db = join(tmp, 'wallet.db');
copyFileSync(env.LWTEST_WALLET_DB, db);
chmodSync(db, 0o600);

const srv = await startServer({ port: PORT });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
const { page, rec } = await recordedPage(ctx, { label: 'history' });
let exit = 0;
try {
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 60000);
  await page.click(tid('import'));
  await waitScreen(page, 'importWallet');
  await page.setInputFiles(tid('import-file'), db);
  await page.fill(tid('import-pw'), env.LWTEST_WALLET_PASS);
  const t0 = Date.now();
  await page.click(tid('import-submit'));
  await page.waitForFunction(() => ['passkeySetup', 'fastStart', 'home'].includes(window.__campfire.screen()), null, { timeout: 180000 });
  if ((await page.evaluate(() => window.__campfire.screen())) === 'passkeySetup') await page.click(tid('passkey-skip'));
  await page.waitForFunction(() => window.__campfire.screen() === 'home' && window.__campfire.sync().state === 'synced', null, { timeout: 180000 });
  log(`imported and synced in ${Math.round((Date.now() - t0) / 1000)} s; ${(await page.evaluate(() => Object.keys(window.__campfire.totals()).length))} asset(s) held`);
  const overflow = rec.console.filter((c) => /Maximum call stack|sent an error|Aborted\(/.test(c.text));
  if (overflow.length) throw new Error(`engine trouble: ${overflow[0].text.slice(0, 200)}`);
  if (rec.errors.length) throw new Error(`page error: ${rec.errors[0].slice(0, 200)}`);
  log('PASS');
} catch (e) {
  exit = 1;
  log('LIVE IMPORT FAILED:', e.message);
  console.log(rec.console.filter((c) => !/Password field/.test(c.text) && !c.text.includes(env.LWTEST_WALLET_PASS)).slice(-30).map((c) => `[console] ${c.text.slice(0, 200)}`).join('\n'));
} finally {
  await browser.close();
  srv.stop();
  rmSync(tmp, { recursive: true, force: true });
}
process.exit(exit);

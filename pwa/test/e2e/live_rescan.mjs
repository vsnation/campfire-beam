// LIVE on BEAM mainnet, no money moves: Settings -> Rescan on a funded wallet.
//
//   BEAM_RECOVERY_FILE=<mainnet_recovery.bin> RESCAN_BROKEN_FILE=<a truncated copy> \
//     node test/e2e/live_rescan.mjs
//
// FUNDER2 (words read at run time, never printed) is restored with the snapshot
// skipped, as a restore that found nothing looks: it scans from genesis and shows
// no coins yet. Then:
//   1. Rescan finds the coins from the snapshot.
//   2. A second Rescan shows the same balance (nothing counted twice), and the
//      wallet keeps its addresses.
//   3. A Rescan from a broken snapshot fails and changes nothing: after "Not now"
//      the wallet runs again with the same balance.
// Both recovery files are optional: without them the server proxies BEAM's file
// (330 MB per Rescan) and step 3 is skipped.
import { existsSync } from 'node:fs';
import { startServer, launch, recordedPage, shot, waitScreen, sleep } from './harness.mjs';
import { waitHome, waitSynced } from './flows.mjs';
import { tid, log, funderWords, total } from './live_common.mjs';

const PORT = 8803;
const RECOVERY = process.env.BEAM_RECOVERY_FILE || null;
const BROKEN = process.env.RESCAN_BROKEN_FILE || null;
const password = `rescan-${Math.random().toString(36).slice(2, 10)}`;

const beam = async (page) => BigInt((await total(page, 0)).available);
const coinsTotal = async (page) => {
  const t = await total(page, 0);
  return BigInt(t.available) + BigInt(t.receiving || 0) + BigInt(t.maturing || 0);
};

/** Waits until the BEAM total has not changed for [quietMs] (the blocks after the snapshot are read). */
async function settled(page, quietMs = 20000, maxMs = 10 * 60000) {
  const t0 = Date.now();
  let last = await coinsTotal(page);
  let since = Date.now();
  while (Date.now() - t0 < maxMs) {
    await sleep(2000);
    const now = await coinsTotal(page);
    if (now !== last) {
      last = now;
      since = Date.now();
    } else if (Date.now() - since >= quietMs) return now;
  }
  return last;
}

async function rescan(page, label) {
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.click(tid('rescan-row'));
  await waitScreen(page, 'fastStart');
  await page.waitForSelector(tid('fast-download'));
  // A restored wallet's Rescan offers no "Skip and scan instead": that belongs to a fresh restore.
  if (await page.isVisible(tid('fast-skip'))) throw new Error('Rescan offers "Skip and scan instead"');
  await shot(page, `${label}-choose`);
  const t0 = Date.now();
  await page.click(tid('fast-download'));
  await waitHome(page, { timeout: 15 * 60000 });
  await waitSynced(page, 10 * 60000);
  const got = await settled(page);
  log(`${label}: ${got} groth after ${Math.round((Date.now() - t0) / 1000)} s`);
  return got;
}

const srv = await startServer({ port: PORT, extra: RECOVERY ? ['--recovery-file', RECOVERY] : [] });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
const { page, rec } = await recordedPage(ctx, { label: 'rescan' });
let exit = 0;
try {
  // ---- a restore that skipped the snapshot: scanning from genesis, nothing found yet
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 60000);
  await page.click(tid('restore'));
  await waitScreen(page, 'restore');
  await page.fill(tid('word-1'), funderWords().join(' '));
  await page.waitForFunction(() => !document.querySelector('[data-testid="restore-submit"]').disabled, null, { timeout: 30000 });
  await page.click(tid('restore-submit'));
  await waitScreen(page, 'setPassword');
  await page.fill(tid('pw1'), password);
  await page.fill(tid('pw2'), password);
  await page.click(tid('save-password'));
  await page.waitForFunction(() => ['passkeySetup', 'ipNotice', 'fastStart'].includes(document.getElementById('app').dataset.screen), null, { timeout: 30000 });
  if ((await page.evaluate(() => document.getElementById('app').dataset.screen)) === 'passkeySetup') await page.click(tid('passkey-skip'));
  await waitScreen(page, 'fastStart');
  await page.click(tid('fast-skip'));
  await waitHome(page, { timeout: 5 * 60000 });
  await sleep(20000);
  const b0 = await coinsTotal(page);
  log(`restored without the snapshot: ${b0} groth (scanning from genesis)`);
  await shot(page, 'rescan-00-home-before');

  // ---- 1. Rescan finds the coins
  const b1 = await rescan(page, 'rescan-01');
  if (!(b1 > 0n)) throw new Error('Rescan found no coins');
  if (b1 <= b0) throw new Error(`Rescan found nothing new (${b0} -> ${b1})`);
  await shot(page, 'rescan-02-home-after');
  const addrs1 = await page.evaluate(() => window.__campfire.addresses());

  // ---- 2. again: same balance, addresses kept
  const b2 = await rescan(page, 'rescan-03');
  if (b2 !== b1) throw new Error(`a second Rescan changed the balance: ${b1} -> ${b2}`);
  const addrs2 = await page.evaluate(() => window.__campfire.addresses());
  for (const a of addrs1) if (!addrs2.includes(a)) throw new Error('an address is gone after a Rescan');
  log(`second Rescan: same balance, ${addrs2.length} address(es) kept`);

  // ---- 3. a broken snapshot changes nothing
  if (BROKEN && existsSync(BROKEN)) {
    await page.evaluate(() => window.__campfire.go('settings'));
    await waitScreen(page, 'settings');
    await page.click(tid('rescan-row'));
    await waitScreen(page, 'fastStart');
    await page.waitForSelector(tid('fast-download'));
    await page.setInputFiles(tid('recovery-file'), BROKEN);
    await page.waitForSelector('.notice.error', { timeout: 10 * 60000 });
    const said = (await page.textContent('.notice.error')).trim();
    log(`broken snapshot refused: "${said.slice(0, 160)}"`);
    if (!/nothing changed/.test(said)) throw new Error('the failed Rescan does not say that nothing changed');
    if (await page.isVisible(tid('fast-skip'))) throw new Error('a failed Rescan offers "Skip and scan instead"');
    await shot(page, 'rescan-04-broken-refused');
    await page.click(tid('fast-cancel'));
    await waitScreen(page, 'settings', 60000);
    await page.evaluate(() => window.__campfire.go('home'));
    await waitScreen(page, 'home');
    await waitSynced(page, 10 * 60000);
    const b3 = await settled(page);
    if (b3 !== b1) throw new Error(`a failed Rescan changed the balance: ${b1} -> ${b3}`);
    log('failed Rescan: balance unchanged');
  } else log('3. skipped (no RESCAN_BROKEN_FILE)');

  const bad = rec.console.filter((c) => /Aborted\(|use_count|RuntimeError|out of bounds/.test(c.text));
  if (bad.length) throw new Error(`engine trouble: ${bad[0].text.slice(0, 200)}`);
  log(`PASS: ${b0} -> ${b1} groth (${Number(b1) / 1e8} BEAM); available ${await beam(page)}`);
} catch (e) {
  exit = 1;
  log('LIVE RESCAN FAILED:', e.message);
  await shot(page, 'rescan-failure').catch(() => {});
  console.log(rec.console.filter((c) => !/Password field/.test(c.text)).slice(-40).map((c) => `[console] ${c.text.slice(0, 200)}`).join('\n'));
} finally {
  await browser.close();
  srv.stop();
}
process.exit(exit);

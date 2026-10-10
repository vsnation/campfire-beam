// LIVE MONEY TEST on BEAM mainnet, tiny amounts only.
//
//   npm run e2e:live:dapp
//
// Test wallet FUNDER2, restored through the real Restore screen, buys 0.01
// BEAM with FOMO inside BEAM's own Beam DEX dApp, running in its sandboxed
// frame: Home → dApps → Beam DEX → the BEAM/FOMO pool → trade → "0.01" →
// the dApp's trade button. The request must reach the wallet's approval sheet
// with the dApp's name; the sheet is read, approved, the password given. The
// trade must complete on chain and the balances must move by what the sheet
// said: FOMO down by the FOMO paid, BEAM by the BEAM received minus the
// 0.011 BEAM network fee.
//
// Hard limits: receives 0.01 BEAM; refuses a sheet that pays more than 450
// FOMO or any other asset, receives anything but about 0.01 BEAM, or charges
// another fee; refuses to start under 0.02 BEAM or 450 FOMO available.
import { startServer, launch, recordedPage, shot, waitScreen, sleep, foreignHosts } from './harness.mjs';
import { waitHome, waitSynced } from './flows.mjs';
import { tid, log, funderWords, restoreFunder, total, waitTx } from './live_common.mjs';

const FOMO = 174;
const DEX = 'db851322f6674a6da3e84e9953db2ffd';
const BUY_GROTH = 1000000n; // 0.01 BEAM
const MAX_FOMO_GROTH = 45000000000n; // 450 FOMO
const FEE_GROTH = 1100000n; // 0.011 BEAM, one contract call
const PORT = Number(process.env.LIVE_PORT || 8799);
const password = `live-d-${Math.random().toString(36).slice(2, 10)}`;
const groth = (text) => {
  const m = /^[-+]?([0-9]+)(?:\.([0-9]{1,8}))?\b/.exec(String(text).replace(/,/g, '').trim());
  if (!m) throw new Error(`not an amount: ${text}`);
  return BigInt(m[1]) * 100000000n + BigInt((m[2] || '').padEnd(8, '0'));
};
const rows = (page, prefix) => page.$$eval(`[data-testid^="${prefix}"]`, (els) => els.map((e) => e.textContent.trim()));

const extra = process.env.BEAM_RECOVERY_FILE ? ['--recovery-file', process.env.BEAM_RECOVERY_FILE] : [];
const srv = await startServer({ port: PORT, extra });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
const { page, rec } = await recordedPage(ctx, { label: 'D' });
let exit = 0;
try {
  log('restoring FUNDER2 through the Restore screen + recovery snapshot');
  await page.goto(srv.url);
  await restoreFunder(page, funderWords(), password, 'live-dapp');
  await waitHome(page, { timeout: 20 * 60000 });
  await waitSynced(page, 15 * 60000);
  await page.waitForFunction(() => window.__campfire.sync().canSend, null, { timeout: 300000 });
  await sleep(8000);
  const beam0 = await total(page, 0);
  const fomo0 = await total(page, FOMO);
  log('before: BEAM', JSON.stringify(beam0), 'FOMO', JSON.stringify(fomo0));
  if (BigInt(beam0.available) < 2000000n) throw new Error('FUNDER2 has under 0.02 BEAM available');
  if (BigInt(fomo0.available) < MAX_FOMO_GROTH) throw new Error('FUNDER2 has under 450 FOMO available');
  const txs0 = new Set((await page.evaluate(() => window.__campfire.txs())).map((t) => t.txId));

  // ---- Home → dApps → Beam DEX, as a user
  await page.click(tid('open-dapps'));
  await waitScreen(page, 'dapps');
  await page.click(tid(`dapp-${DEX}`));
  await page.waitForSelector(tid('dapp-go'), { timeout: 10000 });
  await page.click(tid('dapp-go'));
  await page.waitForFunction(() => (window.__campfire.dapps()[0] || {}).state === 'running', null, { timeout: 180000 });
  const frame = page.frames().find((f) => f.url().includes('/dapp-run/'));
  if (!frame) throw new Error('no dApp frame');
  // The pool list comes from the chain through the bridge.
  await frame.waitForFunction(() => /FOMO\s*\n?\(id:174\)/.test(document.body.innerText), null, { timeout: 120000 });
  await shot(page, 'live-dapp-03-pools');

  // ---- the BEAM/FOMO pool card → trade
  const card = await frame.evaluate(() => {
    const els = [...document.querySelectorAll('div')].filter((e) => {
      const t = e.innerText || '';
      return /FOMO\s*\n?\(id:174\)/.test(t) && /BEAM\s*\n?\(id:0\)/.test(t) && /\btrade\b/.test(t);
    });
    const minimal = els.filter((e) => !els.some((o) => o !== e && e.contains(o)));
    if (minimal.length !== 1) return { count: minimal.length };
    const card = minimal[0];
    card.scrollIntoView({ block: 'center' });
    const btn = [...card.querySelectorAll('button,[role=button],div,span')].reverse().find((x) => /^\s*trade\s*$/i.test(x.innerText || ''));
    if (!btn) return { count: 1, button: false };
    btn.click();
    return { count: 1, button: true, text: card.innerText.replace(/\s+/g, ' ').slice(0, 120) };
  });
  log('pool card:', JSON.stringify(card));
  if (card.count !== 1 || !card.button) throw new Error('could not find exactly one BEAM/FOMO pool with a trade button');
  await frame.waitForFunction(() => /RECEIVE AMOUNT/i.test(document.body.innerText) && document.querySelectorAll('input').length >= 2, null, { timeout: 30000 });

  // ---- receive 0.01 BEAM, paying FOMO (the first field is what you receive)
  const head = await frame.evaluate(() => document.body.innerText.replace(/\s+/g, ' ').slice(0, 80));
  if (!/RECEIVE AMOUNT BEAM \(id:0\) SEND AMOUNT \(ESTIMATED\) FOMO \(id:174\)/i.test(head)) throw new Error(`unexpected trade page: ${head}`);
  await frame.locator('input').first().fill('0.01');
  await frame.waitForFunction(() => /Total Pay\s*[1-9][0-9.]*\s*FOMO/.test(document.body.innerText.replace(/\s+/g, ' ')), null, { timeout: 60000 });
  const summary = await frame.evaluate(() => {
    const t = document.body.innerText.replace(/\s+/g, ' ');
    return t.slice(t.indexOf('TRADE SUMMARY'), t.indexOf('POOL INFO')).trim();
  });
  log('dApp summary:', summary);
  await shot(page, 'live-dapp-04-trade');
  await frame.evaluate(() => {
    const b = [...document.querySelectorAll('button')].reverse().find((x) => /^\s*trade\s*$/i.test(x.innerText || ''));
    if (!b || b.disabled) throw new Error('trade button missing or disabled');
    b.click();
  });

  // ---- the wallet's approval sheet: check what it says before approving
  await page.waitForSelector(tid('consent'), { timeout: 90000 });
  const sheet = {
    app: await page.textContent(tid('consent-app')),
    pay: await rows(page, 'consent-pay-'),
    get: await rows(page, 'consent-get-'),
    fee: await page.textContent(tid('consent-fee')),
    button: await page.textContent(tid('consent-approve')),
  };
  log('sheet:', JSON.stringify(sheet));
  await shot(page, 'live-dapp-05-sheet');
  if (!/Beam DEX/.test(sheet.app)) throw new Error('the sheet does not name the dApp');
  if (groth(sheet.fee) !== FEE_GROTH) throw new Error(`refusing: the sheet charges ${sheet.fee}`);
  const fomoPay = sheet.pay.filter((p) => /FOMO$/.test(p));
  const otherPay = sheet.pay.filter((p) => !/FOMO$/.test(p));
  if (fomoPay.length !== 1 || otherPay.length) throw new Error(`refusing: the sheet pays ${sheet.pay.join(', ')}`);
  const fomoPayGroth = groth(fomoPay[0]);
  if (fomoPayGroth > MAX_FOMO_GROTH) throw new Error(`refusing: the sheet pays ${fomoPay[0]}`);
  const beamGet = sheet.get.filter((g) => /BEAM$/.test(g));
  if (beamGet.length !== 1 || sheet.get.length !== 1) throw new Error(`refusing: the sheet gives ${sheet.get.join(', ')}`);
  const beamGetGroth = groth(beamGet[0]);
  if (beamGetGroth < (BUY_GROTH * 99n) / 100n || beamGetGroth > BUY_GROTH) throw new Error(`refusing: the sheet gives ${beamGet[0]}`);

  await page.click(tid('consent-approve'));
  await page.waitForSelector(tid('auth-pw'), { timeout: 20000 });
  await page.fill(tid('auth-pw'), password);
  await page.click(tid('auth-submit'));
  await page.waitForSelector(tid('consent'), { state: 'detached', timeout: 60000 });
  // Inside a dApp the wallet says it went (the dApp itself may say nothing).
  await page.waitForSelector('.toast', { timeout: 10000 });
  log('toast:', await page.textContent('.toast'));
  await shot(page, 'live-dapp-06-after-approve');

  // ---- on chain
  const tx = await waitTx(page, (t) => !txs0.has(t.txId), 'dApp trade', 25 * 60000);
  log('dApp trade completed:', JSON.stringify(tx));
  await page.waitForFunction(
    ([id, before]) => BigInt((window.__campfire.totals()[id] || { available: '0' }).available) < BigInt(before),
    [FOMO, fomo0.available],
    { timeout: 300000, polling: 3000 },
  );
  await sleep(5000);
  const beam1 = await total(page, 0);
  const fomo1 = await total(page, FOMO);
  const beamDelta = BigInt(beam1.available) - BigInt(beam0.available);
  const fomoOut = BigInt(fomo0.available) - BigInt(fomo1.available);
  log('after: BEAM', JSON.stringify(beam1), 'FOMO', JSON.stringify(fomo1));
  log(`BEAM change ${beamDelta} groth (sheet: +${beamGetGroth} - fee ${FEE_GROTH}); FOMO out ${fomoOut} (sheet: ${fomoPayGroth})`);
  if (beamDelta !== beamGetGroth - FEE_GROTH) throw new Error('BEAM did not move by the sheet\'s receive minus fee');
  if (fomoOut !== fomoPayGroth) throw new Error('FOMO did not move by the sheet\'s pay');
  await shot(page, 'live-dapp-07-dapp-after');
  await page.click(tid('dapp-close'));
  await sleep(800);
  await page.evaluate(() => window.__campfire.go('activity'));
  await sleep(1500);
  await shot(page, 'live-dapp-08-activity');
  log('foreign hosts', JSON.stringify(foreignHosts(rec, srv.url)));
} catch (e) {
  exit = 1;
  log('LIVE DAPP FAILED:', e.message);
  await shot(page, 'live-dapp-failure').catch(() => {});
} finally {
  await browser.close();
  srv.stop();
}
process.exit(exit);

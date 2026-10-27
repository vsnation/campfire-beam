// System back in a Home Screen app (lib/back.js), with Chrome's own Back: Wallet is the first
// entry, a Back on it stays, also after a reload, which leaves the page before it in the history
// (a Back there started the app again at Unlock and asked for Face ID: owner, 2026-10-27). A
// throwaway wallet from fresh words (never printed); nothing is spent.
//
//   node --test test/e2e/back_home_screen.test.mjs   (port CAMPFIRE_BACKHS_PORT, default 8789)
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { startServer, launch, waitScreen, sleep } from './harness.mjs';
import { createWallet, waitHome, unlockWithPassword } from './flows.mjs';

const PORT = Number(process.env.CAMPFIRE_BACKHS_PORT || 8789);
const PASSWORD = `backhs-${randomBytes(6).toString('hex')}`;
let srv, browser;

before(async () => {
  srv = await startServer({ port: PORT });
  browser = await launch();
});

after(async () => {
  if (browser) await browser.close().catch(() => {});
  if (srv) await srv.stop();
});

const screenNow = (page) => page.evaluate(() => window.__campfire && window.__campfire.screen());
const entry = (page) => page.evaluate(() => (history.state && history.state.campfire === 'back' ? history.state.n : null));
const loads = (page) => page.evaluate(() => performance.getEntriesByType('navigation').length + ':' + performance.timeOrigin);
async function back(page) {
  await page.goBack({ waitUntil: 'commit', timeout: 3000 }).catch(() => {});
  await sleep(500);
}

test('in a Home Screen app a Back steps through the screens and stays on Wallet, also after a reload', { timeout: 20 * 60000 }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  // A Home Screen app, as iOS reports it.
  await ctx.addInitScript(() => Object.defineProperty(navigator, 'standalone', { get: () => true }));
  const page = await ctx.newPage();
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page, { timeout: 15 * 60000 });
  await page.mouse.click(5, 400); // the first touch, from which the app keeps its entries
  await sleep(300);
  const n0 = await entry(page);
  await page.click('.tabbar .tab:nth-child(3)');
  await waitScreen(page, 'settings');
  await page.click('[data-testid="node-row"]');
  await waitScreen(page, 'nodeSettings');
  assert.equal(await entry(page), n0 + 2);
  await back(page);
  assert.equal(await screenNow(page), 'settings');
  await back(page);
  assert.equal(await screenNow(page), 'home');
  const before = await loads(page);
  await back(page);
  assert.equal(await screenNow(page), 'home', 'Wallet stays');
  assert.equal(await loads(page), before, 'no page load');

  // A reload (an update, a lock in another tab) leaves the page before it in the history: a Back on
  // Wallet must not reach it.
  await page.reload();
  await unlockWithPassword(page, PASSWORD);
  await waitHome(page, { timeout: 15 * 60000 });
  await page.mouse.click(5, 400);
  await sleep(300);
  assert.equal(await entry(page), 1, 'one entry kept under Wallet');
  const reloaded = await loads(page);
  for (let i = 0; i < 3; i++) await back(page);
  assert.equal(await screenNow(page), 'home', 'still Wallet, not Unlock');
  assert.equal(await loads(page), reloaded, 'no page load');
  await ctx.close();
});

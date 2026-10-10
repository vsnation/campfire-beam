// System back (Android's back, the iPhone edge swipe, the browser's Back) does
// what the screen's own Back does, closes a sheet first, and leaves the app
// only from Wallet. A throwaway wallet; nothing is spent.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { startServer, launch, waitScreen, shot, sleep } from './harness.mjs';
import { createWallet, waitHome } from './flows.mjs';

const PORT = Number(process.env.CAMPFIRE_BACK_PORT || 8786);
const tid = (id) => `[data-testid="${id}"]`;
let srv, browser, page;

const screenNow = () => page.evaluate(() => window.__campfire && window.__campfire.screen());
async function back(expected) {
  await page.goBack({ waitUntil: 'commit' }).catch(() => {});
  if (expected) await waitScreen(page, expected, 15000);
}

before(async () => {
  srv = await startServer({ port: PORT });
  browser = await launch();
  page = await (await browser.newContext({ viewport: { width: 390, height: 844 } })).newPage();
  await page.goto('about:blank');
  await page.goto(srv.url);
  await createWallet(page, { password: `back-${randomBytes(6).toString('hex')}` });
  await waitHome(page, { timeout: 5 * 60000 });
});

after(async () => {
  if (browser) await browser.close().catch(() => {});
  if (srv) await srv.stop();
});

test('a tab goes back to Wallet', async () => {
  await page.click('.tabbar .tab:nth-child(3)');
  await waitScreen(page, 'settings');
  await back('home');
  await page.click('.tabbar .tab:nth-child(2)');
  await waitScreen(page, 'activity');
  await back('home');
});

test('a screen goes back where its own Back goes, step by step', async () => {
  await page.click(tid('receive'));
  await waitScreen(page, 'receive');
  await back('home');
  await page.click('.tabbar .tab:nth-child(3)');
  await waitScreen(page, 'settings');
  await page.click(tid('about'));
  await waitScreen(page, 'about');
  await back('settings');
  await back('home');
});

test('an open sheet closes first, and the screen stays', async () => {
  await page.click(tid('buy'));
  await page.waitForSelector('.overlay', { timeout: 10000 });
  await shot(page, 'back-01-sheet-open');
  await back(null);
  await page.waitForFunction(() => !document.querySelector('.overlay'), null, { timeout: 10000 });
  assert.equal(await screenNow(), 'home');
});

test('many Backs in a row never skip a step', async () => {
  await page.click('.tabbar .tab:nth-child(3)');
  await waitScreen(page, 'settings');
  await page.click(tid('about'));
  await waitScreen(page, 'about');
  await back('settings');
  await back('home');
  assert.equal(new URL(page.url()).pathname, new URL(srv.url).pathname, 'the address never changed');
});

test('from Wallet, Back leaves the app', async () => {
  assert.equal(await screenNow(), 'home');
  await page.goBack({ waitUntil: 'commit' }).catch(() => {});
  for (let i = 0; i < 20 && page.url() !== 'about:blank'; i++) await sleep(250);
  assert.equal(page.url(), 'about:blank');
});

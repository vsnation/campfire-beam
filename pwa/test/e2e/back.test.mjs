// Back, both the screens' own and the system's (Android's back, the iPhone
// edge swipe, the browser's Back): it returns where the person came from,
// closes a sheet or a running dApp first, never steps back into a finished
// flow, and leaves the app only from Wallet. A throwaway BEAM wallet and an
// Ethereum wallet from fresh words (never printed); nothing is spent. Every
// Ethereum server, buybeam.my and CoinGecko are refused: the screens open
// without them. The BeamX DAO dApp runs when its pinned package is in
// CFB_DAPP_PACKAGES (or ~/.cache/campfire-beam/dapps).
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, waitScreen, shot, sleep, SHOTS } from './harness.mjs';
import { createWallet, waitHome } from './flows.mjs';
import { ETH_RPC_HOSTS } from '../../src/lib/eth/hosts.js';
import { newMnemonic } from '../../src/lib/eth/crypto.js';

const PORT = Number(process.env.CAMPFIRE_BACK_PORT || 8786);
const PASSWORD = `back-${randomBytes(6).toString('hex')}`;
const DAO = 'abcc470e12c6422291f360f83d79355e';
const DAO_PACKAGE = join(process.env.CFB_DAPP_PACKAGES || join(homedir(), '.cache', 'campfire-beam', 'dapps'), 'dao-core-app.dapp');
const SHOTS_375 = process.env.CAMPFIRE_BACKNAV_SHOTS || join(SHOTS, 'backnav');
const tid = (id) => `[data-testid="${id}"]`;
let srv, browser, page;

const screenNow = () => page.evaluate(() => window.__campfire && window.__campfire.screen());
const backStack = () => page.evaluate(() => window.__campfire.backStack());
async function back(expected) {
  await page.goBack({ waitUntil: 'commit' }).catch(() => {});
  if (expected) await waitScreen(page, expected, 15000);
}
async function topBack(expected) {
  await page.click('.topbar button[aria-label="Back"]');
  await waitScreen(page, expected, 15000);
}
async function tab(n, name) {
  await page.click(`.tabbar .tab:nth-child(${n})`);
  await waitScreen(page, name);
}
/** 375 px, light and dark. */
async function shots375(name) {
  await mkdir(SHOTS_375, { recursive: true });
  await page.evaluate(() => document.querySelectorAll('.toast').forEach((t) => t.remove()));
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await page.setViewportSize({ width: 375, height: 812 });
    await sleep(150);
    await page.screenshot({ path: join(SHOTS_375, `${name}-375-${scheme}.png`) });
  }
  await page.emulateMedia({ colorScheme: 'light' });
  await page.setViewportSize({ width: 390, height: 844 });
}

before(async () => {
  srv = await startServer({ port: PORT });
  browser = await launch();
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await ctx.route((u) => ETH_RPC_HOSTS.some((x) => x.host === u.hostname) || u.hostname === 'buybeam.my' || u.hostname === 'api.coingecko.com', (r) => r.abort());
  if (existsSync(DAO_PACKAGE)) {
    await ctx.route('https://raw.githubusercontent.com/**', (r) =>
      r.request().url().endsWith('/dao-core-app.dapp') ? r.fulfill({ status: 200, body: readFileSync(DAO_PACKAGE), headers: { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/octet-stream' } }) : r.abort(),
    );
  }
  page = await ctx.newPage();
  await page.goto('about:blank');
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page, { timeout: 5 * 60000 });
  assert.deepEqual(await backStack(), [], 'setup is behind the wallet: nothing to go back to');
});

after(async () => {
  if (browser) await browser.close().catch(() => {});
  if (srv) await srv.stop();
});

test('a tab goes back to Wallet', async () => {
  await tab(3, 'settings');
  await back('home');
  await tab(2, 'activity');
  await back('home');
});

test('a screen goes back where its own Back goes, step by step', async () => {
  await page.click(tid('receive'));
  await waitScreen(page, 'receive');
  await back('home');
  await tab(3, 'settings');
  await page.click(tid('about'));
  await waitScreen(page, 'about');
  await back('settings');
  await back('home');
});

test('Receive goes back to where it was opened', async () => {
  await tab(2, 'activity');
  await page.click('.card.empty .btn-primary'); // "Receive BEAM" on an empty Activity
  await waitScreen(page, 'receive');
  await topBack('activity');
  await page.click('.card.empty .btn-primary');
  await waitScreen(page, 'receive');
  await back('activity');
  await back('home');
});

test('Settings → BEAM node → Your own node: Back, Back, Back steps out one at a time', async () => {
  await tab(3, 'settings');
  await page.click(tid('node-row'));
  await waitScreen(page, 'nodeSettings');
  await page.click(tid('node-own'));
  await waitScreen(page, 'ownNode');
  assert.deepEqual(await backStack(), ['settings', 'nodeSettings']);
  await back('nodeSettings');
  await back('settings');
  await back('home');
});

test('Settings → Backup → Show owner key: Back steps out', async () => {
  await tab(3, 'settings');
  await page.click(tid('backup-row'));
  await waitScreen(page, 'backup');
  await page.click(tid('owner-key-start'));
  await waitScreen(page, 'ownerKey');
  await back('backup');
  await back('settings');
  await back('home');
});

test('an open sheet on a screen closes first, and the screen stays', async () => {
  await page.click(tid('buy'));
  await page.waitForSelector('.overlay', { timeout: 10000 });
  await shot(page, 'back-01-sheet-open');
  await back(null);
  await page.waitForFunction(() => !document.querySelector('.overlay'), null, { timeout: 10000 });
  assert.equal(await screenNow(), 'home');

  await tab(3, 'settings');
  await page.click(tid('backup-row'));
  await waitScreen(page, 'backup');
  await page.click(tid('export-start'));
  await page.waitForSelector('.overlay', { timeout: 10000 });
  await back(null);
  await page.waitForFunction(() => !document.querySelector('.overlay'), null, { timeout: 10000 });
  assert.equal(await screenNow(), 'backup');
  await back('settings');
  await back('home');
});

test('a shown owner key: Back leaves it, Forward opens nothing again, and Done is never returned to', { timeout: 4 * 60000 }, async () => {
  const showKey = async () => {
    await page.click(tid('owner-key-start'));
    await waitScreen(page, 'ownerKey');
    await page.fill(tid('okey-pw'), PASSWORD);
    await page.click(tid('okey-show'));
    await page.waitForFunction(() => (document.querySelector('[data-testid="owner-key"]')?.textContent || '').length > 0, null, { timeout: 90000 });
  };
  const keyShown = () => page.evaluate(() => Boolean(document.querySelector('[data-testid="owner-key"]')?.textContent));
  await tab(3, 'settings');
  await page.click(tid('backup-row'));
  await waitScreen(page, 'backup');

  await showKey();
  const before = await page.evaluate(() => history.length);
  await back('backup');
  assert.equal(await keyShown(), false);
  await page.goForward({ waitUntil: 'commit' }).catch(() => {});
  await sleep(800);
  assert.equal(await screenNow(), 'backup', 'Forward re-opens nothing');
  assert.equal(await keyShown(), false);
  assert.equal(await page.evaluate(() => history.length), before, 'the browser history did not grow');

  await showKey();
  await page.click(tid('okey-done'));
  await waitScreen(page, 'backup');
  assert.deepEqual(await backStack(), ['settings'], 'the owner key is not a Back target after Done');
  await back('settings');
  await back('home');
});

test('dApps from Home: Back returns to Home; a running dApp closes first', { timeout: 4 * 60000 }, async (t) => {
  await page.click(tid('open-dapps'));
  await waitScreen(page, 'dapps');
  await back('home');
  if (!existsSync(DAO_PACKAGE)) return t.diagnostic(`no ${DAO_PACKAGE}: the running-dApp step is skipped`);
  await page.click(tid('open-dapps'));
  await waitScreen(page, 'dapps');
  await page.click(tid(`dapp-${DAO}`));
  await page.click(tid('dapp-go'));
  await page.waitForFunction(() => (window.__campfire.dapps()[0] || {}).state === 'running', null, { timeout: 120000 });
  assert.equal(await page.isVisible(tid('dapp-layer')), true);
  await back(null);
  await page.waitForFunction(() => document.querySelector('[data-testid="dapp-layer"]').classList.contains('hidden'), null, { timeout: 10000 });
  assert.equal(await screenNow(), 'dapps', 'the dApp closed; its list stays');
  await back('home');
});

test('Buy WBEAM with no Ethereum wallet: its start screen goes back to Home', { timeout: 2 * 60000 }, async () => {
  await page.click(tid('buy'));
  await page.waitForFunction(() => /Create an Ethereum wallet first/.test(document.querySelector('[data-testid="buy-choose-wbeam"]')?.textContent || ''));
  await page.click(tid('buy-choose-wbeam'));
  await waitScreen(page, 'ethStart');
  await page.waitForSelector(tid('eth-create'));
  await shots375('ethstart-from-buy');
  await back('home');
});

test('Move coins → add an Ethereum wallet: Back steps out of each step, and once it is set up Back skips the setup', { timeout: 3 * 60000 }, async () => {
  await page.click(tid('chain-move'));
  await waitScreen(page, 'bridgeMove');
  await page.click(tid('bridge-add-eth'));
  await waitScreen(page, 'ethStart');
  await page.waitForSelector(tid('eth-import'));
  await shots375('ethstart-from-move-coins');
  await back('bridgeMove');
  await page.click(tid('bridge-add-eth'));
  await waitScreen(page, 'ethStart');
  await page.click(tid('eth-import'));
  await waitScreen(page, 'ethImport');
  await back('ethStart');
  await page.click(tid('eth-import'));
  await waitScreen(page, 'ethImport');
  await page.fill(tid('eth-words-input'), newMnemonic(12));
  await page.click(tid('eth-import-submit'));
  await waitScreen(page, 'ethPrivacy');
  assert.deepEqual(await backStack(), ['home', 'bridgeMove', 'ethStart', 'ethImport']);
  await page.click(tid('eth-connect'));
  await waitScreen(page, 'bridgeMove', 60000);
  assert.deepEqual(await backStack(), ['home'], 'none of the setup steps is a Back target');
  await back('home');
});

test('Receive from the Ethereum side returns there; Ethereum goes back to Wallet', { timeout: 2 * 60000 }, async () => {
  await page.click(tid('chain-eth'));
  await waitScreen(page, 'ethHome');
  await page.click(tid('eth-receive'));
  await waitScreen(page, 'ethReceive');
  await back('ethHome');
  await page.click(tid('eth-receive'));
  await waitScreen(page, 'ethReceive');
  await topBack('ethHome');
  await back('home');
});

test('Buy from the Ethereum side returns there, through Buy BEAM and back', { timeout: 2 * 60000 }, async () => {
  await page.click(tid('chain-eth'));
  await waitScreen(page, 'ethHome');
  await page.click(tid('eth-buy-wbeam'));
  await waitScreen(page, 'ethSwap');
  await page.click(tid('uni-buy-native-beam'));
  await waitScreen(page, 'buyBeam');
  await back('ethSwap');
  await page.click(tid('uni-buy-native-beam'));
  await waitScreen(page, 'buyBeam');
  await topBack('ethSwap');
  await back('ethHome');
  await back('home');
});

test('rapid Backs step one screen at a time', async () => {
  await tab(3, 'settings');
  await page.click(tid('node-row'));
  await waitScreen(page, 'nodeSettings');
  await page.click(tid('node-own'));
  await waitScreen(page, 'ownNode');
  await page.evaluate(() => {
    const el = document.getElementById('app');
    window.__seen = [];
    new MutationObserver(() => window.__seen.push(el.dataset.screen)).observe(el, { attributes: true, attributeFilter: ['data-screen'] });
  });
  for (let i = 0; i < 3; i++) await page.goBack({ waitUntil: 'commit' }).catch(() => {});
  await waitScreen(page, 'home');
  await sleep(500);
  assert.deepEqual(await page.evaluate(() => window.__seen), ['nodeSettings', 'settings', 'home']);
  assert.equal(new URL(page.url()).pathname, new URL(srv.url).pathname, 'the address never changed');
});

test('from Wallet, Back leaves the app', async () => {
  assert.equal(await screenNow(), 'home');
  await page.goBack({ waitUntil: 'commit' }).catch(() => {});
  for (let i = 0; i < 20 && page.url() !== 'about:blank'; i++) await sleep(250);
  assert.equal(page.url(), 'about:blank');
});

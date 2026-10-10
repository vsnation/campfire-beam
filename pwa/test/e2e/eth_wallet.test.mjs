// The Ethereum wallet end-to-end, through the screens: the installed Google
// Chrome (headless), the dev server with the production headers, a throwaway
// BEAM wallet on BEAM mainnet (spends nothing), and Ethereum on the local
// anvil mainnet fork.
//
//   npm run e2e:eth   (stages the engine, builds dist/, runs this file)
//
// The app's Ethereum server is Stack Wallet's, as in production; Playwright
// routes that host to the fork (adding CORS headers) so the CSP and the app
// code are exactly what ships. Every other Ethereum host is refused here, so
// nothing can reach mainnet. Stack Wallet's history index (/export) answers
// with one made-up incoming payment.
//
// Under the shared fork lock, with evm_snapshot / evm_revert: anvil_setBalance,
// WBEAM minted by impersonating the bridge's pipe, then 0.01 ETH and 12.5
// WBEAM sent through Send -> review -> password -> status, with receipts and
// balances checked on the fork. Screenshots of every Ethereum screen at
// 390x844 and 1280x800, light and dark, into $CAMPFIRE_SHOTS. Never a
// screenshot of revealed words.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import jsQR from 'jsqr';
import { startServer, launch, recordedPage, shot, waitScreen, foreignHosts, sleep, SHOTS } from './harness.mjs';
import { createWallet, waitHome, unlockWithPassword } from './flows.mjs';
import { ANVIL, JUNK, ACCOUNT0, raw, anvilProblem, withFork, setBalance, sendAs, erc20Balance, freshAddress, mined } from '../fork/fork_support.mjs';
import { ethKeyFromMnemonic, wipe, toChecksumAddress } from '../../src/lib/eth/crypto.js';
import { encodeCall } from '../../src/lib/eth/abi.js';
import { ETH_RPC_HOSTS } from '../../src/lib/eth/hosts.js';
import { WBEAM } from '../../src/lib/eth/tokens.js';
import { routeById } from '../../src/lib/bridge/routes.js';

const PORT = 8840;
const PASSWORD = `eth-${Math.random().toString(36).slice(2, 10)}`;
const NODE = 'eu-nodes.mainnet.beam.mw:8200';
const STACK = 'eth2.stackwallet.com';
const ETHER = 10n ** 18n;
const tid = (id) => `[data-testid="${id}"]`;
const skip = await anvilProblem();

let srv, browser, ctx, page, rec;
let mode = 'fork'; // 'fork' | 'down'
const rpcMethods = [];
const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': 'content-type', 'access-control-allow-methods': 'GET, POST, OPTIONS' };

async function stackRoute(route) {
  const req = route.request();
  const url = new URL(req.url());
  if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
  if (mode === 'down') return route.fulfill({ status: 503, headers: { ...cors, 'content-type': 'text/plain' }, body: 'unavailable' });
  if (req.method() === 'GET' && url.pathname === '/export') {
    // The index: one made-up 1 ETH payment in, long ago; no token history (an empty body, as the index answers).
    if (url.searchParams.get('emitter')) return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: '' });
    const me = url.searchParams.get('addrs');
    const data = [{ blockHash: `0x${'b1'.repeat(32)}`, blockNumber: 22000000, from: '0x1111111111111111111111111111111111111111', to: me, gas: 21000, gasPrice: 1000000000, gasUsed: 21000, hash: `0x${'e1'.repeat(32)}`, nonce: 3, receipt: { effectiveGasPrice: 1000000000, gasUsed: 21000, logs: [], status: 1 }, timestamp: 1767225600, value: '1000000000000000000' }];
    return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: JSON.stringify({ data }) });
  }
  if (req.method() !== 'POST') return route.fulfill({ status: 404, headers: cors, body: '' });
  const body = req.postData();
  try {
    const j = JSON.parse(body);
    for (const m of [].concat(j)) rpcMethods.push(m.method);
  } catch {
    /* not JSON: anvil says so */
  }
  const r = await fetch(ANVIL, { method: 'POST', headers: { 'content-type': 'application/json' }, body });
  return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: await r.text() });
}

/** One screen, four ways: phone and desktop, light and dark. */
async function shots4(name) {
  // A toast from the step before would cover what is being looked at.
  await page.evaluate(() => document.querySelectorAll('.toast').forEach((t) => t.remove()));
  for (const scheme of ['light', 'dark']) {
    for (const [w, hh] of [[390, 844], [1280, 800]]) {
      await page.emulateMedia({ colorScheme: scheme });
      await page.setViewportSize({ width: w, height: hh });
      await sleep(120);
      await shot(page, `eth-${name}-${w}-${scheme}`);
    }
  }
  await page.emulateMedia({ colorScheme: 'light' });
  await page.setViewportSize({ width: 390, height: 844 });
}

async function ethHomeReady() {
  await waitScreen(page, 'ethHome');
  await page.waitForSelector(`${tid('eth-status')}[data-state="ok"]`, { timeout: 60000 });
}

before(async () => {
  srv = await startServer({ root: 'dist', port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  await ctx.route((u) => u.hostname === STACK, stackRoute);
  // Nothing may reach a real Ethereum server.
  await ctx.route((u) => ETH_RPC_HOSTS.some((x) => x.host === u.hostname && x.host !== STACK) || u.hostname === 'api.coingecko.com', (r) => r.abort());
  ({ page, rec } = await recordedPage(ctx, { label: 'eth' }));
  console.log(`# screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
});

test('a BEAM wallet; no Ethereum code is loaded until Ethereum is opened', { skip: skip || false, timeout: 10 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  await page.waitForSelector(tid('chain-eth'));
  // Only lib/eth/record.js (whether there is an Ethereum wallet: a store key, no crypto) and the lazy registry.
  const loaded = await page.evaluate(() => performance.getEntriesByType('resource').filter((e) => /\/lib\/eth\/(?!record\.js)|\/vendor\/noble\/|\/screens\/eth_(?!screens)/.test(e.name)).map((e) => e.name));
  assert.deepEqual(loaded, [], 'first paint carries no Ethereum code');
  await shots4('00-beam-home-switcher');
});

let createdAddress = null;

test('create an Ethereum wallet: 12 new words, 3 checked, the privacy notice, then its Home', { skip: skip || false, timeout: 3 * 60000 }, async () => {
  await page.click(tid('chain-eth'));
  await waitScreen(page, 'ethStart');
  await page.waitForSelector(tid('eth-create'));
  await shots4('01-start');
  await page.click(tid('eth-create'));
  await waitScreen(page, 'ethWords');
  await page.waitForSelector('[data-testid="words"] .word');
  assert.match(await page.textContent('.step'), /Step 1 of 3/);
  await shots4('02-words-hidden'); // blurred: no picture of words, ever
  await page.click(tid('reveal'));
  const words = await page.$$eval('[data-testid="words"] .word span:last-child', (els) => els.map((e) => e.textContent));
  assert.equal(words.length, 12);
  await page.click(tid('eth-wrote-down'));
  await waitScreen(page, 'ethConfirm');
  await page.waitForSelector('[data-position]');
  assert.match(await page.textContent('.step'), /Step 2 of 3/);
  await shots4('03-confirm');
  const positions = await page.$$eval('[data-position]', (els) => els.map((e) => Number(e.dataset.position)));
  assert.equal(positions.length, 3);
  // One wrong pick first: the screen says which word, and blames nobody.
  const wrongWord = await page.$eval(`[data-position="${positions[0]}"]`, (el, right) => [...el.querySelectorAll('[data-word]')].map((b) => b.dataset.word).find((w) => w !== right), words[positions[0] - 1]);
  await page.click(`[data-position="${positions[0]}"] [data-word="${wrongWord}"]`);
  for (const pos of positions.slice(1)) await page.click(`[data-position="${pos}"] [data-word="${words[pos - 1]}"]`);
  await page.click(tid('eth-confirm-words'));
  await page.waitForSelector('.notice.error');
  assert.match(await page.textContent('.notice.error'), new RegExp(`not word #${positions[0]}`));
  await shots4('04-confirm-wrong');
  await page.click(`[data-position="${positions[0]}"] [data-word="${words[positions[0] - 1]}"]`);
  await page.click(tid('eth-confirm-words'));
  await waitScreen(page, 'ethPrivacy');
  await page.waitForSelector(tid('eth-connect'));
  assert.match(await page.textContent('.step'), /Step 3 of 3/);
  assert.match(await page.textContent(tid('eth-privacy-text')), /Stack Wallet's.*sees your IP address together with your Ethereum address/);
  await shots4('05-privacy');
  await page.click(tid('eth-ip-how'));
  await page.click(`${tid('eth-privacy-more')} summary`);
  await shots4('06-privacy-details');
  const requestsBefore = rpcMethods.length;
  assert.equal(requestsBefore, 0, 'nothing asked of any Ethereum server before Connect');
  await page.click(tid('eth-connect'));
  await ethHomeReady();
  const { sk, address } = await ethKeyFromMnemonic(words.join(' '));
  wipe(sk);
  createdAddress = address;
  assert.equal(await page.getAttribute(tid('eth-address'), 'data-address'), address, 'the address of the 12 words (m/44\'/60\'/0\'/0/0)');
  assert.equal(await page.getAttribute(tid('eth-balance'), 'data-wei'), '0');
  // The words are not stored; the address is not in the clear either.
  const stored = await page.evaluate(async () => {
    const { store } = await import('./lib/store.js');
    return JSON.stringify(await store.get('eth'));
  });
  for (const w of new Set(words)) assert.ok(!stored.includes(`"${w}"`), 'no word in storage');
  assert.ok(!stored.toLowerCase().includes(address.slice(2).toLowerCase()), 'the address only inside the sealed envelope');
  await page.waitForSelector(tid('eth-activity'));
  await shots4('07-home-empty');
  assert.equal(await page.textContent(`${tid('eth-receive')}`), 'Receive ETH', 'nothing to send: Receive ETH is the primary');
});

test('receive: the address and a QR code that decodes to it', { skip: skip || false, timeout: 60000 }, async () => {
  await page.click(tid('eth-receive'));
  await waitScreen(page, 'ethReceive');
  await page.waitForSelector('.qr svg');
  assert.equal(await page.getAttribute(tid('eth-receive-address'), 'data-address'), createdAddress);
  const img = await page.evaluate(async () => {
    const svgEl = document.querySelector('.qr svg');
    const blob = new Blob([new XMLSerializer().serializeToString(svgEl)], { type: 'image/svg+xml' });
    const url = URL.createObjectURL(blob);
    const im = new Image();
    await new Promise((r, j) => ((im.onload = r), (im.onerror = j), (im.src = url)));
    const c = document.createElement('canvas');
    c.width = 400;
    c.height = 400;
    c.getContext('2d').drawImage(im, 0, 0, 400, 400);
    return Array.from(c.getContext('2d').getImageData(0, 0, 400, 400).data);
  });
  assert.equal(jsQR(Uint8ClampedArray.from(img), 400, 400).data, createdAddress);
  await shots4('08-receive');
});

test('Settings -> Ethereum wallet; Delete says both sets of words; Remove asks for the password', { skip: skip || false, timeout: 2 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.click(tid('eth-settings-row'));
  await waitScreen(page, 'ethSettings');
  await page.waitForSelector(tid('eth-backup'));
  assert.equal(await page.inputValue(tid('eth-server-select')), 'stackwallet', "Stack Wallet's server by default");
  assert.equal(await page.isChecked(tid('eth-history-switch')), true, 'history on by default');
  assert.match(await page.textContent(tid('eth-backup')), /Your Ethereum words are your backup.*12 words/);
  await shots4('09-settings');
  await page.click(tid('eth-privacy-row'));
  await waitScreen(page, 'ethPrivacy');
  await page.waitForSelector(tid('eth-privacy-done'));
  await shots4('10-privacy-from-settings');
  await page.click(tid('eth-privacy-done'));
  await waitScreen(page, 'ethSettings');

  await page.evaluate(() => window.__campfire.go('deleteWallet'));
  await page.waitForSelector(tid('delete-eth-words'));
  assert.match(await page.textContent(tid('delete-eth-words')), /Ethereum wallet is removed too.*both sets of words/);
  await shots4('11-delete-both-words');

  await page.evaluate(() => window.__campfire.go('ethSettings'));
  await page.waitForSelector(tid('eth-remove'));
  await page.click(tid('eth-remove'));
  await page.waitForSelector(tid('eth-remove-confirm'));
  await shots4('12-remove-sheet');
  await page.click(tid('eth-remove-confirm'));
  await page.waitForSelector(tid('auth-pw'));
  await page.fill(tid('auth-pw'), 'not the password');
  await page.click(tid('auth-submit'));
  await page.waitForSelector('.sheet .notice.error');
  assert.ok(await page.evaluate(async () => Boolean(await (await import('./lib/store.js')).store.get('eth'))), 'a wrong password removes nothing');
  await page.fill(tid('auth-pw'), PASSWORD);
  await page.click(tid('auth-submit'));
  await waitScreen(page, 'settings');
  assert.equal(await page.evaluate(async () => (await (await import('./lib/store.js')).store.get('eth')) ?? null), null, 'the sealed key is gone');
});

test('import "test test ... junk": 12 words checked as typed, privacy, Home with its address', { skip: skip || false, timeout: 2 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await page.click(tid('chain-eth'));
  await waitScreen(page, 'ethStart');
  await page.click(tid('eth-import'));
  await waitScreen(page, 'ethImport');
  await page.waitForSelector(tid('eth-words-input'));
  assert.match(await page.textContent('.step'), /Step 1 of 2/);
  await shots4('13-import-empty');
  await page.fill(tid('eth-words-input'), 'test test test test test test test test test test test jnuk');
  assert.match(await page.textContent(tid('eth-words-hint')), /Word #12 isn't one of the words/);
  await page.fill(tid('eth-words-input'), 'junk test test test test test test test test test test test');
  assert.match(await page.textContent(tid('eth-words-hint')), /don't fit together/);
  assert.equal(await page.isDisabled(tid('eth-import-submit')), true);
  await shots4('14-import-checksum');
  await page.fill(tid('eth-words-input'), `  ${JUNK.toUpperCase()}  `);
  assert.match(await page.textContent(tid('eth-words-hint')), /12 words\. They check out\./);
  await page.click(`${tid('eth-advanced')} summary`);
  await shots4('15-import-ready-advanced');
  await page.click(tid('eth-import-submit'));
  await waitScreen(page, 'ethPrivacy');
  await page.waitForSelector(tid('eth-connect'));
  assert.match(await page.textContent('.step'), /Step 2 of 2/);
  await page.click(tid('eth-connect'));
  await ethHomeReady();
  assert.equal(await page.getAttribute(tid('eth-address'), 'data-address'), ACCOUNT0);
});

test('on the fork: 0.01 ETH and 12.5 WBEAM sent through the screens; receipts and balances exact', { skip: skip || false, timeout: 6 * 60000 }, () =>
  withFork(async () => {
    const to = toChecksumAddress(freshAddress());
    await setBalance(ACCOUNT0, 5n * ETHER);
    await sendAs(routeById('beam').ethPipe, WBEAM.address, encodeCall('mint(address,uint256)', [ACCOUNT0, 100n * 10n ** 8n]));
    const wbeam0 = await erc20Balance(WBEAM.address, ACCOUNT0);

    await page.evaluate(() => window.__campfire.go('ethHome'));
    await ethHomeReady();
    await page.waitForSelector(`${tid('eth-balance')}[data-wei="${5n * ETHER}"]`, { timeout: 30000 });
    await page.waitForSelector(`${tid('eth-token-row')}[data-symbol="WBEAM"]`);
    assert.equal(await page.getAttribute(`${tid('eth-token-row')}[data-symbol="WBEAM"] ${tid('eth-token-balance')}`, 'data-units'), String(wbeam0));
    await page.waitForSelector(`${tid('eth-activity-row')}[data-hash="0x${'e1'.repeat(32)}"]`);
    await shots4('16-home-funded');

    // Send: refusals in words first.
    await page.click(tid('eth-send'));
    await waitScreen(page, 'ethSend');
    await page.waitForSelector(tid('eth-send-to'));
    await page.waitForFunction(() => !/Checking/.test(document.querySelector('[data-testid="eth-send-fee"]').textContent), null, { timeout: 30000 });
    const typo = to.replace(/[a-f]/, (c) => c.toUpperCase());
    await page.fill(tid('eth-send-to'), typo === to ? to.replace(/[A-F]/, (c) => c.toLowerCase()) : typo);
    await page.waitForFunction(() => /doesn't add up/.test(document.querySelector('[data-testid="eth-to-hint"]').textContent));
    await shots4('17-send-checksum');
    await page.fill(tid('eth-send-to'), routeById('beam').ethPipe);
    await page.waitForFunction(() => /bridge's contract/.test(document.querySelector('[data-testid="eth-to-hint"]').textContent));
    await page.fill(tid('eth-send-to'), WBEAM.address);
    await page.waitForFunction(() => /token's own contract/.test(document.querySelector('[data-testid="eth-to-hint"]').textContent));
    await page.fill(tid('eth-send-to'), to);
    await page.fill(tid('eth-send-amount'), '0.01');
    await page.waitForFunction(() => document.querySelector('[data-testid="eth-send-review"]').textContent === 'Send 0.01 ETH');
    await shots4('18-send-filled');
    await page.click(tid('eth-send-review'));
    await page.waitForSelector(tid('eth-review-send'));
    assert.equal(await page.textContent(tid('eth-review-amount')), '0.01 ETH');
    assert.equal(await page.getAttribute(tid('eth-review-to'), 'data-address'), to);
    assert.match(await page.textContent(tid('eth-review-fee')), /^about [0-9.]+ ETH$/);
    assert.match(await page.textContent(tid('eth-review-fee-max')), /^at most [0-9.]+ ETH$/);
    assert.equal(await page.textContent(tid('eth-review-send')), 'Send 0.01 ETH');
    await shots4('19-review');
    const sendsBefore = rpcMethods.filter((m) => m === 'eth_sendRawTransaction').length;
    await page.click(tid('eth-review-send'));
    await page.waitForSelector(tid('auth-pw'));
    await shots4('20-review-password');
    await page.fill(tid('auth-pw'), PASSWORD);
    await page.click(tid('auth-submit'));
    await waitScreen(page, 'ethTx');
    await page.waitForSelector(`${tid('eth-tx-title')}[data-state="confirmed"]`, { timeout: 60000 });
    assert.equal(rpcMethods.filter((m) => m === 'eth_sendRawTransaction').length, sendsBefore + 1, 'one broadcast');
    const hash = await page.getAttribute(tid('eth-tx-hash'), 'data-hash');
    const receipt = await mined(hash);
    assert.equal(receipt.status, '0x1');
    const fee = BigInt(receipt.gasUsed) * BigInt(receipt.effectiveGasPrice);
    assert.equal(await page.getAttribute(tid('eth-tx-fee'), 'data-wei'), String(fee), 'the fee shown is the fee paid');
    assert.equal(BigInt(await raw('eth_getBalance', [to, 'latest'])), 10n ** 16n);
    assert.equal(BigInt(await raw('eth_getBalance', [ACCOUNT0, 'latest'])), 5n * ETHER - 10n ** 16n - fee);
    assert.equal(await page.getAttribute(tid('eth-tx-explorer'), 'href'), `https://etherscan.io/tx/${hash}`);
    await shots4('21-tx-confirmed');

    // WBEAM
    await page.click(tid('eth-tx-done'));
    await ethHomeReady();
    await page.waitForSelector(`${tid('eth-activity-row')}[data-hash="${hash}"][data-state="confirmed"]`);
    await page.click(tid('eth-send'));
    await waitScreen(page, 'ethSend');
    await page.waitForSelector(`${tid('eth-send-asset')} option[value="WBEAM"]`, { state: 'attached' });
    await page.selectOption(tid('eth-send-asset'), 'WBEAM');
    await page.fill(tid('eth-send-to'), to.toLowerCase());
    await page.fill(tid('eth-send-amount'), '12.5');
    await page.waitForFunction(() => document.querySelector('[data-testid="eth-send-review"]').textContent === 'Send 12.5 WBEAM');
    await page.click(tid('eth-send-review'));
    await page.waitForSelector(tid('eth-review-send'));
    assert.equal(await page.textContent(tid('eth-review-amount')), '12.5 WBEAM');
    assert.match(await page.textContent(tid('eth-review-total')), /^12\.5 WBEAM \+ about [0-9.]+ ETH$/);
    await shots4('22-review-token');
    await page.click(tid('eth-review-send'));
    await page.waitForSelector(tid('auth-pw'));
    await page.fill(tid('auth-pw'), PASSWORD);
    await page.click(tid('auth-submit'));
    await waitScreen(page, 'ethTx');
    await page.waitForSelector(`${tid('eth-tx-title')}[data-state="confirmed"]`, { timeout: 60000 });
    const hash2 = await page.getAttribute(tid('eth-tx-hash'), 'data-hash');
    assert.equal((await mined(hash2)).status, '0x1');
    assert.equal(await erc20Balance(WBEAM.address, to), 1250000000n);
    assert.equal(await erc20Balance(WBEAM.address, ACCOUNT0), wbeam0 - 1250000000n);
    await page.click(tid('eth-tx-done'));
    await ethHomeReady();
    await page.waitForSelector(`${tid('eth-activity-row')}[data-hash="${hash2}"]`);
    await page.waitForSelector(`${tid('eth-token-row')}[data-symbol="WBEAM"] ${tid('eth-token-balance')}[data-units="${wbeam0 - 1250000000n}"]`, { timeout: 40000 });
    await shots4('23-home-after');

    // The server stops answering: who failed, and two ways out; nothing switches by itself.
    mode = 'down';
    await page.click(tid('eth-receive'));
    await waitScreen(page, 'ethReceive');
    await page.evaluate(() => window.__campfire.go('ethHome'));
    await page.waitForSelector(tid('eth-server-problem'), { timeout: 60000 });
    assert.match(await page.textContent(tid('eth-server-problem')), /Stack Wallet's Ethereum server didn't answer/);
    assert.match(await page.textContent(tid('eth-use-other')), /Use PublicNode instead/);
    await shots4('24-home-server-down');
    mode = 'fork';
    await page.click(tid('eth-retry'));
    await page.waitForSelector(`${tid('eth-status')}[data-state="ok"]`, { timeout: 60000 });
    assert.equal(await page.isVisible(tid('eth-server-problem')), false);
  }));

test('lock forgets the Ethereum wallet; unlocking opens it again', { skip: skip || false, timeout: 2 * 60000 }, async () => {
  await page.click(tid('lock'));
  await waitScreen(page, 'unlock');
  await page.evaluate(() => window.__campfire.go('ethHome'));
  await waitScreen(page, 'unlock'); // locked: no Ethereum screen opens
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  await page.click(tid('chain-eth'));
  await ethHomeReady();
  assert.equal(await page.getAttribute(tid('eth-address'), 'data-address'), ACCOUNT0);
});

test('IP privacy: only this origin, the BEAM node and the chosen Ethereum server; no CSP violation', { skip: skip || false }, async () => {
  assert.deepEqual(foreignHosts(rec, srv.url, [NODE]), [`https://${STACK}`]);
  assert.deepEqual(rec.csp, []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
  assert.ok(rpcMethods.includes('eth_sendRawTransaction'));
});

// Buy, end to end, through the screens: the installed Google Chrome
// (headless), the dev server with the production headers, a throwaway BEAM
// wallet on BEAM mainnet (spends nothing), buybeam.my mocked, and Ethereum on
// the local anvil mainnet fork.
//
//   npm run e2e:buy   (stages the engine, builds dist/, runs this file)
//
// 1. Home's Buy opens the chooser: BEAM (private, this wallet) or WBEAM on
//    Ethereum (public); with no Ethereum wallet the WBEAM card leads to
//    creating one.
// 2. Buy BEAM against a mocked buybeam.my (Playwright answers its API; no
//    order ever reaches the real one): the coin, an amount under the smallest
//    buy and its one-tap fix, the price, the order with its deposit address
//    and QR, then the order's states as buybeam.my reports them, the buys
//    list, and the buy still there after locking (sealed on this device).
// 3. An Ethereum wallet imported from fresh words, funded with
//    anvil_setBalance; Ethereum Home's primary becomes Buy WBEAM. Under the
//    shared fork lock, with evm_snapshot / evm_revert: ETH -> WBEAM through
//    the swap form, the review sheet and the password, then some WBEAM sold
//    back (the exact allowance first, then the Permit2 signature). What
//    arrived is checked on the fork against what the screens said.
//
// Screenshots of every screen at 390x844 and 1280x800, light and dark, into
// $CAMPFIRE_SHOTS. Never a screenshot of words.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import jsQR from 'jsqr';
import { startServer, launch, recordedPage, shot, waitScreen, foreignHosts, sleep, SHOTS } from './harness.mjs';
import { createWallet, waitHome, unlockWithPassword } from './flows.mjs';
import { ANVIL, raw, anvilProblem, withFork, setBalance, erc20Balance } from '../fork/fork_support.mjs';
import { ethKeyFromMnemonic, newMnemonic, wipe } from '../../src/lib/eth/crypto.js';
import { ETH_RPC_HOSTS } from '../../src/lib/eth/hosts.js';
import { WBEAM } from '../../src/lib/eth/tokens.js';
import { ASSETS, envelope, errorJson, statusJson } from '../unit/buy_fakes.mjs';
import { exactUnits } from '../../src/lib/compact.js';

const PORT = 8860;
const PASSWORD = `buy-${Math.random().toString(36).slice(2, 10)}`;
const NODE = 'eu-nodes.mainnet.beam.mw:8200';
const STACK = 'eth2.stackwallet.com';
const ETHER = 10n ** 18n;
const DEPOSIT = 'bc1qfake0deposit0address0for0the0e2e0test000';
const REFUND = 'bc1qfake0refund0address0for0the0e2e0test0000';
const tid = (id) => `[data-testid="${id}"]`;
const skipFork = await anvilProblem();

let srv, browser, ctx, page, rec;
const rpcMethods = [];
const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': 'content-type', 'access-control-allow-methods': 'GET, POST, OPTIONS' };

// ------------------------------------------------------------------ buybeam.my, mocked
const bb = { requests: [], state: 'awaiting_deposit', txId: null, orders: [] };

async function buybeamRoute(route) {
  const req = route.request();
  const url = new URL(req.url());
  if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
  const path = decodeURIComponent(url.pathname.replace('/api/v1/buy', ''));
  const body = req.postData() ? JSON.parse(req.postData()) : null;
  bb.requests.push({ method: req.method(), path, query: Object.fromEntries(url.searchParams), body, headers: req.headers() });
  const json = (status, j) => route.fulfill({ status, headers: { ...cors, 'content-type': 'application/json' }, body: JSON.stringify(j) });
  if (!url.pathname.startsWith('/api/v1/buy/')) return json(404, errorJson('not_found'));
  if (path === '/assets') return json(200, envelope({ count: ASSETS.length, assets: ASSETS }));
  if (path === '/limits') return json(200, envelope({ our_minimum_usd: 5, upstream_observed_minimum_usd: 1000 }));
  if (path === '/quote') {
    const a = ASSETS.find((x) => x.asset_id === url.searchParams.get('asset_id'));
    const amount = Number(url.searchParams.get('amount'));
    const usd = amount * a.price_usd;
    if (usd < 1000) return json(400, errorJson('amount_below_upstream_minimum', { minimumUsd: 1000, orderValueUsd: usd }));
    return json(200, envelope({ asset_id: a.asset_id, send_amount: amount, send_amount_raw: String(BigInt(Math.round(amount * Number(`1e${a.decimals}`)))), beam_estimate: usd * 110, beam_estimate_raw: String(BigInt(Math.round(usd * 110 * 1e8))), order_value_usd: usd, eta_seconds: 810 }));
  }
  if (path === '/order' && req.method() === 'POST') {
    const a = ASSETS.find((x) => x.asset_id === body.asset_id);
    bb.orders.push(body);
    return json(200, envelope({ deposit_address: DEPOSIT, asset_id: body.asset_id, send_amount: body.amount, send_amount_raw: String(BigInt(Math.round(body.amount * Number(`1e${a.decimals}`)))), beam_wallet: body.beam_wallet, beam_estimate: body.amount * a.price_usd * 110, deadline: Math.floor(Date.now() / 1000) + 3600, eta_seconds: 810, payable: true, created: true }));
  }
  if (path === `/order/${DEPOSIT}`) {
    const st = statusJson(bb.state, { deposit: DEPOSIT, pollAfter: 1, txId: bb.txId });
    const o = bb.orders[0];
    if (o) st.beam_estimate = o.amount * ASSETS.find((x) => x.asset_id === o.asset_id).price_usd * 110;
    return json(200, st);
  }
  return json(404, errorJson('order_not_found'));
}

// ------------------------------------------------------------------ Ethereum, on the fork
async function stackRoute(route) {
  const req = route.request();
  const url = new URL(req.url());
  if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
  if (req.method() === 'GET' && url.pathname === '/export') return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: url.searchParams.get('emitter') ? '' : JSON.stringify({ data: [] }) });
  if (req.method() !== 'POST') return route.fulfill({ status: 404, headers: cors, body: '' });
  const body = req.postData();
  try {
    for (const m of [].concat(JSON.parse(body))) rpcMethods.push(m.method);
  } catch {
    /* not JSON: anvil says so */
  }
  const r = await fetch(ANVIL, { method: 'POST', headers: { 'content-type': 'application/json' }, body });
  return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: await r.text() });
}

/** One screen, four ways: phone and desktop, light and dark. */
async function shots4(name) {
  await page.evaluate(() => document.querySelectorAll('.toast').forEach((t) => t.remove()));
  for (const scheme of ['light', 'dark']) {
    for (const [w, hh] of [[390, 844], [1280, 800]]) {
      await page.emulateMedia({ colorScheme: scheme });
      await page.setViewportSize({ width: w, height: hh });
      await sleep(150);
      await shot(page, `buy-${name}-${w}-${scheme}`);
    }
  }
  await page.emulateMedia({ colorScheme: 'light' });
  await page.setViewportSize({ width: 390, height: 844 });
  await sleep(100);
}

/** The primary button is on screen without scrolling (the 375 x 667 phone). */
async function ctaVisibleOnSmallPhone(selector) {
  await page.setViewportSize({ width: 375, height: 667 });
  await sleep(150);
  const box = await page.locator(selector).boundingBox();
  await page.setViewportSize({ width: 390, height: 844 });
  return Boolean(box && box.y >= 0 && box.y + box.height <= 667);
}

before(async () => {
  srv = await startServer({ root: 'dist', port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: new URL(srv.url).origin });
  await ctx.route((u) => u.hostname === 'buybeam.my', buybeamRoute);
  await ctx.route((u) => u.hostname === STACK, stackRoute);
  // Nothing may reach a real Ethereum server.
  await ctx.route((u) => ETH_RPC_HOSTS.some((x) => x.host === u.hostname && x.host !== STACK) || u.hostname === 'api.coingecko.com', (r) => r.abort());
  ({ page, rec } = await recordedPage(ctx, { label: 'buy' }));
  console.log(`# screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
});

test('a BEAM wallet; Home has Buy beside Send, Receive and Swap; no Buy or Ethereum code before it is opened', { timeout: 15 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  await page.waitForSelector(tid('buy'));
  const loaded = await page.evaluate(() => performance.getEntriesByType('resource').filter((e) => /\/lib\/eth\/(?!record\.js)|\/vendor\/noble\/|\/screens\/eth_(?!screens)|\/screens\/buy_(?!screens)/.test(e.name)).map((e) => e.name));
  assert.deepEqual(loaded, [], 'first paint carries no Buy screen and no Ethereum code');
  assert.equal(bb.requests.length, 0, 'nothing asked of buybeam.my before Buy BEAM is opened');
  await shots4('00-home');
});

test('the chooser without an Ethereum wallet: two cards; WBEAM leads to creating the Ethereum wallet', { timeout: 2 * 60000 }, async () => {
  await page.click(tid('buy'));
  await page.waitForSelector(tid('buy-chooser-title'));
  assert.equal(await page.textContent(tid('buy-chooser-title')), 'Both are BEAM. They live in different wallets.');
  await page.waitForFunction(() => /Create an Ethereum wallet first/.test((document.querySelector('[data-testid="buy-choose-wbeam"]')?.textContent || '')));
  assert.match(await page.textContent(tid('buy-choose-beam')), /Private.*in your BEAM wallet.*Bitcoin, Ether, USDT/);
  assert.match(await page.textContent(tid('buy-choose-wbeam')), /Public.*in your Ethereum wallet.*Pay with ETH/);
  await shots4('01-chooser-no-eth');
  await page.click(tid('buy-choose-wbeam'));
  await waitScreen(page, 'ethStart');
  await page.waitForSelector(tid('eth-create'));
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
});

test('Buy BEAM with a mocked buybeam.my: the coin, the smallest buy, the price, the order, its states', { timeout: 5 * 60000 }, async () => {
  await page.click(tid('buy'));
  await page.click(tid('buy-choose-beam'));
  await waitScreen(page, 'buyBeam');
  await page.waitForFunction(() => /BTC/.test((document.querySelector('[data-testid="buy-coin"]')?.textContent || '')));
  assert.match(await page.textContent(tid('buy-cta')), /^Get a BTC deposit address$/);
  await page.waitForFunction(() => /Smallest buy right now: about \$1,000/.test((document.querySelector('[data-testid="buy-minimum-hint"]')?.textContent || '')));
  assert.ok(await ctaVisibleOnSmallPhone(tid('buy-cta')), 'the button is on a 375 x 667 screen without scrolling');
  await shots4('02-buy-beam-empty');

  // The coin picker: the coins people bring most first.
  await page.click(tid('buy-coin'));
  await page.waitForSelector(tid('buy-coin-search'));
  const first = await page.$$eval(tid('buy-coin-row'), (els) => els.slice(0, 3).map((e) => e.dataset.assetId));
  assert.deepEqual(first, ['coin:btc', 'coin:eth', 'coin:tron-usdt']);
  await shots4('03-coin-picker');
  await page.fill(tid('buy-coin-search'), 'tron');
  assert.deepEqual(await page.$$eval(tid('buy-coin-row'), (els) => els.map((e) => e.dataset.assetId)), ['coin:tron-usdt']);
  await page.click(`${tid('buy-coin-row')}[data-asset-id="coin:tron-usdt"]`);
  await page.waitForFunction(() => /USDT/.test((document.querySelector('[data-testid="buy-coin"]')?.textContent || '')));
  await page.click(tid('buy-coin'));
  await page.click(`${tid('buy-coin-row')}[data-asset-id="coin:btc"]`);
  await page.waitForFunction(() => /BTC/.test((document.querySelector('[data-testid="buy-coin"]')?.textContent || '')));

  // Under the smallest buy: said in BTC, fixed in one tap.
  await page.fill(tid('buy-refund'), REFUND);
  await page.fill(tid('buy-amount'), '0.001');
  await page.waitForSelector(`${tid('buy-problem')}[data-code="amount_below_upstream_minimum"]`);
  assert.match(await page.textContent(tid('buy-problem')), /Buy at least 0\.0123 BTC \(\$1,000\).*Nothing was sent/);
  assert.equal(await page.isDisabled(tid('buy-cta')), true);
  await shots4('04-below-minimum');
  await page.click(tid('buy-fix'));
  assert.equal(await page.inputValue(tid('buy-amount')), '0.0123');
  await page.waitForSelector(tid('buy-estimate'));
  assert.equal(await page.textContent(tid('buy-estimate')), '≈\u00a0111,360.01', 'what buybeam.my said, rounded down');
  assert.equal(await page.getAttribute(tid('buy-estimate'), 'data-groth'), '11136001800000');
  assert.match(await page.textContent(tid('buy-eta')), /about 14 minutes/);
  assert.match(await page.textContent(tid('buy-worth')), /≈\s\$1,012/);
  await page.waitForFunction(() => document.querySelector('[data-testid="buy-cta"]')?.disabled === false);
  await shots4('05-buy-beam-priced');
  const quote = bb.requests.filter((r) => r.path === '/quote').at(-1);
  assert.deepEqual(quote.query, { asset_id: 'coin:btc', amount: '0.0123', refund_address: REFUND });
  assert.equal(quote.headers.cookie, undefined);

  // The order: a new address of this wallet, kept on this device before it is shown.
  await page.click(tid('buy-cta'));
  await waitScreen(page, 'buyOrder');
  await page.waitForSelector(tid('buy-deposit-address'));
  assert.equal(bb.orders.length, 1);
  const order = bb.orders[0];
  assert.deepEqual(Object.keys(order).sort(), ['amount', 'asset_id', 'beam_wallet', 'refund_address']);
  assert.equal(order.amount, 0.0123);
  assert.equal(order.refund_address, REFUND);
  const mine = await page.evaluate(() => window.__campfire.addresses());
  assert.ok(mine.includes(order.beam_wallet), 'the BEAM goes to an address this wallet made');
  assert.equal((await page.evaluate((a) => window.__campfire.validate(a), order.beam_wallet)).is_valid, true);
  assert.equal(await page.textContent(tid('buy-deposit-address')), DEPOSIT);
  assert.equal(await page.textContent(tid('buy-exact-amount')), '0.0123 BTC');
  assert.match(await page.textContent(tid('buy-network-warning')), /Send only BTC on the Bitcoin network/);
  assert.match(await page.textContent(tid('buy-deadline')), /This address works until \d\d:\d\d (today|on \d+ \w+)\./);
  assert.match(await page.textContent('.topbar h1'), /^Send 0\.0123 BTC$/);
  const img = await page.evaluate(async () => {
    const svgEl = document.querySelector('[data-testid="buy-qr"] svg');
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
  assert.equal(jsQR(Uint8ClampedArray.from(img), 400, 400).data, DEPOSIT, 'the QR code is the deposit address');
  assert.equal(await page.getAttribute(tid('buy-step-0'), 'data-mark'), 'active');
  assert.ok(await ctaVisibleOnSmallPhone(tid('buy-order-cta')));
  await page.click(tid('buy-order-cta'));
  await page.waitForFunction(() => /Address copied/.test((document.querySelector('[data-testid="buy-order-cta"]')?.textContent || '')));
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), DEPOSIT);
  await shots4('06-order-awaiting');

  // buybeam.my moves it on; the screen follows by itself.
  bb.state = 'deposit_detected';
  await page.waitForSelector(`${tid('buy-step-0')}[data-mark="done"]`, { timeout: 30000 });
  assert.match(await page.textContent(tid('buy-step-0')), /Payment received.*being confirmed/);
  assert.equal(await page.isVisible(tid('buy-deposit-address')), false);
  await shots4('07-order-received');
  bb.state = 'swapping';
  await page.waitForSelector(`${tid('buy-step-1')}[data-mark="active"]`, { timeout: 30000 });
  bb.state = 'sending';
  await page.waitForSelector(`${tid('buy-step-2')}[data-mark="active"]`, { timeout: 30000 });
  bb.state = 'delivered';
  bb.txId = 'e2e0beam0delivery0txid';
  await page.waitForSelector(tid('buy-delivered'), { timeout: 30000 });
  assert.equal(await page.getAttribute(tid('buy-step-3'), 'data-mark'), 'active');
  assert.match(await page.textContent(tid('buy-step-3')), /Arriving in your wallet/);
  assert.match(await page.textContent(tid('buy-beam-tx')), /e2e0be…txid/);
  await shots4('08-order-delivered');
  const polls = bb.requests.filter((r) => r.path === `/order/${DEPOSIT}`).length;
  // The wallet has the BEAM: "arrived", and the button opens it.
  await page.evaluate(async (txId) => {
    const { wallet } = await import('./lib/wallet.js');
    wallet.state.txs = [{ txId, income: true, status: 3, value: '1', fee: '0', create_time: Math.floor(Date.now() / 1000), asset_id: 0 }, ...wallet.state.txs];
    wallet.emit();
  }, bb.txId);
  await page.waitForSelector(tid('buy-arrived'));
  assert.equal(await page.getAttribute(tid('buy-step-3'), 'data-mark'), 'done');
  assert.equal(await page.textContent(tid('buy-order-cta')), 'See it in your wallet');
  await shots4('09-order-arrived');
  await sleep(3000);
  assert.equal(bb.requests.filter((r) => r.path === `/order/${DEPOSIT}`).length, polls, 'an ended buy is never asked about again');

  // The buys list, and the buy still there after locking: sealed on this device, nothing in the clear.
  await page.evaluate(() => window.__campfire.go('buyBeam'));
  await page.waitForSelector(tid('buy-your-buys'));
  await page.click(tid('buy-your-buys'));
  await waitScreen(page, 'buyOrders');
  await page.waitForSelector(`${tid('buy-order-row')}[data-deposit="${DEPOSIT}"][data-state="delivered"]`);
  await shots4('10-buys');
  const stored = await page.evaluate(async () => JSON.stringify(await (await import('./lib/store.js')).store.get('buybeam')));
  for (const s of [DEPOSIT, REFUND, order.beam_wallet]) assert.equal(stored.includes(s), false, 'sealed');
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await page.click(tid('lock'));
  await waitScreen(page, 'unlock');
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  await page.evaluate(() => window.__campfire.go('buyOrders'));
  await page.waitForSelector(`${tid('buy-order-row')}[data-deposit="${DEPOSIT}"]`);
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
});

test('Buy BEAM: buybeam.my unreachable says so and blames nobody; nothing was sent', { timeout: 2 * 60000 }, async () => {
  const quotes = (u) => u.hostname === 'buybeam.my' && u.pathname.endsWith('/quote');
  await page.route(quotes, (r) => r.fulfill({ status: 502, headers: { ...cors, 'content-type': 'text/html' }, body: '<html>Bad gateway</html>' }));
  await page.evaluate(() => window.__campfire.go('buyBeam'));
  await page.waitForFunction(() => /BTC/.test((document.querySelector('[data-testid="buy-coin"]')?.textContent || '')));
  await page.fill(tid('buy-refund'), REFUND);
  await page.fill(tid('buy-amount'), '0.02');
  await page.waitForSelector(`${tid('buy-problem')}[data-code="blocked"]`);
  assert.match(await page.textContent(tid('buy-problem')), /Couldn't reach buybeam\.my.*Nothing was sent/);
  await shots4('11-unreachable');
  await page.unroute(quotes);
  await page.click(tid('buy-fix'));
  await page.waitForSelector(tid('buy-estimate'));
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
});

let eth = null;

test('an Ethereum wallet from fresh words: the chooser now offers Buy WBEAM; Ethereum Home leads with it', { skip: skipFork || false, timeout: 5 * 60000 }, () => withFork(async () => {
  const words = newMnemonic(12);
  const k = await ethKeyFromMnemonic(words);
  wipe(k.sk);
  eth = { address: k.address };
  await setBalance(eth.address, 0n);
  await page.click(tid('chain-eth'));
  await waitScreen(page, 'ethStart');
  await page.click(tid('eth-import'));
  await waitScreen(page, 'ethImport');
  await page.fill(tid('eth-words-input'), words);
  await page.click(tid('eth-import-submit'));
  await waitScreen(page, 'ethPrivacy');
  await page.click(tid('eth-connect'));
  await waitScreen(page, 'ethHome');
  // No ETH yet: Receive ETH leads, and the swap form says what to do instead of a grey button alone.
  await page.waitForSelector(`${tid('eth-balance')}[data-wei="0"]`, { timeout: 60000 });
  assert.ok((await page.getAttribute(tid('eth-receive'), 'class')).includes('btn-primary'), 'Receive ETH is the primary with no ETH');
  await page.click(tid('eth-buy-wbeam'));
  await waitScreen(page, 'ethSwap');
  await page.waitForSelector(tid('uni-no-eth'), { timeout: 60000 });
  await shots4('12a-swap-no-eth');
  await page.click(tid('uni-receive-eth'));
  await waitScreen(page, 'ethReceive');
  await setBalance(eth.address, 2n * ETHER);
  await page.evaluate(() => window.__campfire.go('ethHome'));
  await waitScreen(page, 'ethHome');
  await page.waitForSelector(`${tid('eth-balance')}[data-wei="${2n * ETHER}"]`, { timeout: 60000 });
  assert.match(await page.textContent(`${tid('eth-buy-wbeam')}`), /Buy WBEAM/);
  assert.ok((await page.getAttribute(tid('eth-buy-wbeam'), 'class')).includes('btn-primary'), 'Buy WBEAM is the primary when there is ETH');
  assert.ok((await page.getAttribute(tid('eth-send'), 'class')).includes('btn-secondary'));
  await shots4('12-eth-home');
  await page.click(tid('chain-beam'));
  await waitScreen(page, 'home');
  await page.click(tid('buy'));
  await page.waitForFunction(() => /Buy WBEAM/.test((document.querySelector('[data-testid="buy-choose-wbeam"]')?.textContent || '')));
  await shots4('13-chooser-with-eth');
  await page.click(tid('buy-choose-wbeam'));
  await waitScreen(page, 'ethSwap');
  await page.waitForSelector(tid('uni-buy-native-beam'));
  await page.click(tid('uni-buy-native-beam'));
  await waitScreen(page, 'buyBeam');
  await page.evaluate(() => window.__campfire.go('ethHome'));
  await waitScreen(page, 'ethHome');
}));

test('on the fork: buy WBEAM with ETH, then sell some back; what arrived is what the screens said', { skip: skipFork || false, timeout: 20 * 60000 }, () =>
  withFork(async () => {
    await setBalance(eth.address, 2n * ETHER);
    await page.evaluate(() => window.__campfire.go('ethHome'));
    await page.waitForSelector(`${tid('eth-balance')}[data-wei="${2n * ETHER}"]`, { timeout: 60000 });
    await page.click(tid('eth-buy-wbeam'));
    await waitScreen(page, 'ethSwap');
    await page.waitForSelector(tid('uni-pay-amount'));
    await page.waitForFunction(() => /Balance 2 ETH/.test((document.querySelector('[data-testid="uni-pay-balance"]')?.textContent || '')), null, { timeout: 60000 });
    assert.ok(await ctaVisibleOnSmallPhone(tid('uni-swap-cta')));
    await shots4('14-swap-empty');
    await page.fill(tid('uni-pay-amount'), '0.01');
    await page.waitForFunction(() => /^Swap 0\.01 ETH for ≈[\d,.]+ WBEAM$/.test((document.querySelector('[data-testid="uni-swap-cta"]')?.textContent || '')), null, { timeout: 10 * 60000 });
    await page.waitForFunction(() => document.querySelector('[data-testid="uni-swap-cta"]')?.disabled === false, null, { timeout: 60000 });
    assert.match(await page.textContent(tid('uni-rate')), /^1 ETH ≈ [\d,.]+ WBEAM$/);
    assert.match(await page.textContent(tid('uni-protection')), /Price protection.*1%.*At least [\d,.]+ WBEAM/);
    assert.match(await page.textContent(tid('uni-network-fee')), /^about [\d.]+ ETH$/);
    assert.ok(await ctaVisibleOnSmallPhone(tid('uni-swap-cta')), 'the button is on a 375 x 667 screen without scrolling');
    // Wide: the pools beside the form, the ones the swap uses marked.
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.waitForSelector(`${tid('uni-pools-panel')} ${tid('uni-pool')}`, { timeout: 5 * 60000 });
    assert.ok((await page.$$(`${tid('uni-pools-panel')} ${tid('uni-pool')}[data-share]:not([data-share=""])`)).length >= 1, 'the pools the swap uses say their share');
    await page.setViewportSize({ width: 390, height: 844 });
    await shots4('15-swap-priced');
    // Phone: the pools are one tap away.
    await page.click(tid('uni-open-pools'));
    await page.waitForSelector(`${tid('uni-pools-sheet')} ${tid('uni-pool')}`, { timeout: 5 * 60000 });
    await shots4('16-pools-sheet');
    await page.click('.sheet .btn-text');
    // Price protection: 0.5 / 1 / 3 / 5 %, 1 % unless chosen.
    await page.click(tid('uni-protection'));
    await page.waitForSelector(tid('uni-slippage-300'));
    assert.equal(await page.$$eval('[data-testid^="uni-slippage-"]', (els) => els.length), 4);
    assert.equal(await page.getAttribute(tid('uni-slippage-100'), 'aria-checked'), 'true');
    await shots4('17-price-protection');
    await page.click(tid('uni-slippage-100'));

    // Review: the least that arrives, the router by name and address, the fee as "about" and "at most".
    const wbeam0 = await erc20Balance(WBEAM.address, eth.address);
    const eth0 = BigInt(await raw('eth_getBalance', [eth.address, 'latest']));
    await page.click(tid('uni-swap-cta'));
    await page.waitForSelector(tid('uni-review-cta'), { timeout: 5 * 60000 });
    assert.match(await page.textContent(tid('uni-review-minimum')), /^You receive at least [\d,.]+ WBEAM\. Ethereum enforces this\. $/);
    assert.match(await page.textContent(tid('uni-review-router')), /Uniswap Universal Router \(0x66a9…A8aF\)/i);
    assert.match(await page.textContent(tid('uni-review-fee')), /about [\d.]+ ETH.*at most [\d.]+ ETH/);
    assert.equal(await page.textContent(tid('uni-review-cta')), 'Swap 0.01 ETH');
    assert.equal(await page.isVisible(tid('uni-review-permit')), false, 'paying with ETH signs no permit');
    await shots4('18-review-buy');
    const minText = (await page.textContent(tid('uni-review-minimum'))).match(/least ([\d,.]+) WBEAM/)[1].replace(/,/g, '');
    const sends0 = rpcMethods.filter((m) => m === 'eth_sendRawTransaction').length;
    await page.click(tid('uni-review-cta'));
    await page.waitForSelector(tid('auth-pw'));
    await page.fill(tid('auth-pw'), PASSWORD);
    await page.click(tid('auth-submit'));
    await waitScreen(page, 'ethSwapTx', 120000);
    await page.waitForSelector(`${tid('uni-tx-title')}[data-state="confirmed"]`, { timeout: 120000 });
    await page.waitForSelector(`${tid('uni-tx-received')}:not([data-units=""])`, { timeout: 60000 });
    assert.equal(rpcMethods.filter((m) => m === 'eth_sendRawTransaction').length, sends0 + 1, 'one broadcast');
    const got = BigInt(await page.getAttribute(tid('uni-tx-received'), 'data-units'));
    const wbeam1 = await erc20Balance(WBEAM.address, eth.address);
    assert.equal(wbeam1 - wbeam0, got, 'the WBEAM the screen says arrived is the balance change');
    assert.ok(Number(got) / 1e8 >= Number(minText), 'at least the minimum');
    const hash = await page.getAttribute(tid('uni-tx-hash'), 'data-hash');
    const receipt = await raw('eth_getTransactionReceipt', [hash]);
    assert.equal(receipt.status, '0x1');
    assert.equal(receipt.to.toLowerCase(), '0x66a9893cc07d91d95644aedd05d03f95e1dba8af', 'sent to the Universal Router');
    const fee = BigInt(receipt.gasUsed) * BigInt(receipt.effectiveGasPrice);
    assert.equal(BigInt(await raw('eth_getBalance', [eth.address, 'latest'])), eth0 - 10n ** 16n - fee, '0.01 ETH and the network fee, nothing else');
    assert.equal(await page.getAttribute(tid('uni-tx-fee'), 'data-wei'), String(fee));
    assert.match(await page.textContent(tid('uni-tx-result')), /^You received [\d,.]+ WBEAM\. Network fee [\d.]+ ETH\.( Shared between \d pools\.)?$/);
    await shots4('19-swap-done');

    // Sell half of it back: the exact allowance, then a Permit2 signature in the review.
    await page.click(tid('uni-tx-done'));
    await waitScreen(page, 'ethHome');
    await page.waitForSelector(`${tid('eth-activity-row')}[data-hash="${hash}"][data-kind="swap"]`, { timeout: 60000 });
    await page.click(tid('eth-buy-wbeam'));
    await waitScreen(page, 'ethSwap');
    await page.waitForSelector(tid('uni-flip'));
    await page.click(tid('uni-flip'));
    await page.waitForFunction(() => /WBEAM/.test((document.querySelector('[data-testid="uni-pay-token"]')?.textContent || '')));
    const sell = got / 2n;
    const sellText = `${sell / 100000000n}.${String(sell % 100000000n).padStart(8, '0')}`.replace(/\.?0+$/, '');
    await page.fill(tid('uni-pay-amount'), sellText);
    await page.waitForFunction(() => /for ≈[\d,.]+ ETH$/.test((document.querySelector('[data-testid="uni-swap-cta"]')?.textContent || '')), null, { timeout: 10 * 60000 });
    await page.waitForFunction(() => document.querySelector('[data-testid="uni-swap-cta"]')?.disabled === false, null, { timeout: 60000 });
    assert.match(await page.textContent('.topbar h1'), /Swap on Uniswap/);
    await shots4('20-sell-priced');
    await page.click(tid('uni-swap-cta'));
    await page.waitForSelector(tid('uni-approve-cta'), { timeout: 120000 });
    await page.waitForFunction(() => document.querySelector('[data-testid="uni-approve-cta"]')?.disabled === false, null, { timeout: 60000 });
    const sellShown = exactUnits(sell, 8);
    assert.equal(await page.textContent(tid('uni-approve-cta')), `Allow ${sellShown} WBEAM`);
    assert.match(await page.textContent(tid('uni-approve-explain')), /Exactly what this swap uses/);
    await shots4('21-allow');
    await page.click(tid('uni-approve-cta'));
    await page.waitForSelector(tid('auth-pw'));
    await page.fill(tid('auth-pw'), PASSWORD);
    await page.click(tid('auth-submit'));
    await page.waitForSelector(tid('uni-review-permit'), { timeout: 5 * 60000 });
    assert.ok((await page.textContent(tid('uni-review-permit'))).includes(`Uniswap may take exactly ${sellShown} WBEAM, for 30 minutes`));
    const allowance = BigInt(await raw('eth_call', [{ to: WBEAM.address, data: `0xdd62ed3e${eth.address.slice(2).toLowerCase().padStart(64, '0')}${'000000000022d473030f116ddee9f6b43ac78ba3'.padStart(64, '0')}` }, 'latest']));
    assert.equal(allowance, sell, 'Permit2 may move exactly the amount, nothing more');
    await shots4('22-review-sell');
    const ethBefore = BigInt(await raw('eth_getBalance', [eth.address, 'latest']));
    await page.click(tid('uni-review-cta'));
    await page.waitForSelector(tid('auth-pw'));
    await page.fill(tid('auth-pw'), PASSWORD);
    await page.click(tid('auth-submit'));
    await waitScreen(page, 'ethSwapTx', 120000);
    await page.waitForSelector(`${tid('uni-tx-title')}[data-state="confirmed"]`, { timeout: 120000 });
    await page.waitForSelector(`${tid('uni-tx-received')}:not([data-units=""])`, { timeout: 60000 });
    const gotEth = BigInt(await page.getAttribute(tid('uni-tx-received'), 'data-units'));
    const hash2 = await page.getAttribute(tid('uni-tx-hash'), 'data-hash');
    const r2 = await raw('eth_getTransactionReceipt', [hash2]);
    const fee2 = BigInt(r2.gasUsed) * BigInt(r2.effectiveGasPrice);
    assert.equal(BigInt(await raw('eth_getBalance', [eth.address, 'latest'])), ethBefore + gotEth - fee2, 'the ETH the screen says arrived is the balance change, less the fee');
    assert.equal(await erc20Balance(WBEAM.address, eth.address), wbeam1 - sell, 'exactly the WBEAM sold left');
    assert.match(await page.textContent(tid('uni-tx-result')), /^You received [\d,.]+ ETH\. Network fee [\d.]+ ETH\./);
    await shots4('23-sell-done');
    await page.click(tid('uni-tx-done'));
    await waitScreen(page, 'ethHome');
    await page.waitForSelector(`${tid('eth-activity-row')}[data-kind="approve"]`, { timeout: 60000 });
    await page.waitForSelector(`${tid('eth-activity-row')}[data-hash="${hash2}"]`);
    await shots4('24-eth-home-after');
  }));

test('IP privacy: only this origin, the BEAM node, buybeam.my (mocked here) and the chosen Ethereum server; no CSP violation', async () => {
  const hosts = foreignHosts(rec, srv.url, [NODE]).sort();
  const allowed = ['https://buybeam.my', `https://${STACK}`];
  for (const x of hosts) assert.ok(allowed.includes(x), `unexpected host ${x}`);
  assert.deepEqual(rec.csp, []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
});

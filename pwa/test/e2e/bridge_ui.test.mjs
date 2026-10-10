// The bridge screens end to end: Move coins, the reviews, a move and the list,
// through the real screens (installed Google Chrome, headless, the built dist/).
//
//   node tools/stage_engine.mjs && node tools/build.mjs && \
//     node --test --test-concurrency=1 test/e2e/bridge_ui.test.mjs
//
// A throwaway BEAM wallet on BEAM mainnet, never funded, and an Ethereum wallet
// from fresh random words, imported through the screens and given ETH and WBEAM
// on the local anvil mainnet fork (never anvil's key 0). Stack Wallet's server
// is routed to the fork (with CORS headers) so the CSP and the app code are what
// ships; every other Ethereum host is refused, so nothing reaches Ethereum
// mainnet. CoinGecko is answered from the unit tests' fixture prices, and only
// after the person allowed it.
//
// (d) Prices: asked once; "Not now" sends nothing to CoinGecko and leaves
//     WBEAM -> BEAM; allowing them makes the first request.
// (a) To BEAM on the fork, under the shared fork lock (evm_snapshot/evm_revert):
//     0.01 ETH -> bETH and 100 WBEAM -> BEAM (an exact approval, then the lock),
//     each through the review sheet and the password, up to "On its way to
//     BEAM" (locked on Ethereum; the BEAM side of a fork lock can never come).
//     The BEAM wallet holds nothing, so for these two the page is told it holds
//     0.5 BEAM (wallet.available, in the page only) to pass the 0.121 BEAM
//     collect check; the real "needs 0.121 BEAM" block is checked first.
// (c) A reload in the middle resumes the move from the sealed store; locking on
//     the move's screen says "Unlock to follow" and goes back to it.
// (b) To Ethereum from the unfunded BEAM wallet: the real "Not enough BEAM",
//     then (the page told it holds 1,000 BEAM) the quote and the approve sheet
//     with the bridge's words and the engine's "not enough". Never approved:
//     there is no approve button; Cancel sends nothing.
// (e) Ready to collect: a record as the controller writes it once a lock has
//     reached BEAM, for one of the desktop app's recorded messages still
//     unclaimed on mainnet (somebody else's; this wallet could never claim it),
//     written into this wallet's sealed store: "Collect", then the approve sheet
//     in the bridge's words. Its button is never pressed; Cancel sends nothing.
// Screenshots of every screen and sheet at 390x844 and 1280x800, light and
// dark, into $CAMPFIRE_SHOTS.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startServer, launch, recordedPage, shot, waitScreen, foreignHosts, sleep, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced, unlockWithPassword } from './flows.mjs';
import { forkProblem, withFork, raw, mined, giveTokens, nextMsgId, pipeHoldings, erc20Balance, ethBalance, ETHER, PRICES, hex } from '../fork/bridge_eth_support.mjs';
import { ANVIL } from '../fork/fork_support.mjs';
import { newMnemonic, ethKeyFromMnemonic, wipe } from '../../src/lib/eth/crypto.js';
import { ETH_RPC_HOSTS } from '../../src/lib/eth/hosts.js';
import { routeById } from '../../src/lib/bridge/routes.js';
import { e2bRelayerFee } from '../../src/lib/bridge/fees.js';

const PORT = 8870;
const PASSWORD = `bridge-ui-${Math.random().toString(36).slice(2, 10)}`;
const NODE = 'eu-nodes.mainnet.beam.mw:8200';
const STACK = 'eth2.stackwallet.com';
const GECKO = 'api.coingecko.com';
const tid = (id) => `[data-testid="${id}"]`;
const skip = await forkProblem();
const T = (min) => ({ skip: skip || false, timeout: min * 60000 });

let srv, browser, ctx, page, rec;
const rpcMethods = [];
const geckoAsked = [];
const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': 'content-type', 'access-control-allow-methods': 'GET, POST, OPTIONS' };
// Fresh words for the Ethereum wallet: nobody else's key, never anvil's key 0.
const WORDS = newMnemonic(12).split(' ');
let ETH_ADDR = null;

async function stackRoute(route) {
  const req = route.request();
  const url = new URL(req.url());
  if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
  if (req.method() === 'GET' && url.pathname === '/export') {
    // The history index: nothing for a fresh address (an empty body for token logs, as the index answers).
    return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: url.searchParams.get('emitter') ? '' : JSON.stringify({ data: [] }) });
  }
  if (req.method() !== 'POST') return route.fulfill({ status: 404, headers: cors, body: '' });
  const body = req.postData();
  try {
    for (const m of [].concat(JSON.parse(body))) rpcMethods.push(m.method);
  } catch {
    /* not JSON: anvil says so */
  }
  const r = await fetch(ANVIL, { method: 'POST', headers: { 'content-type': 'application/json' }, body, signal: AbortSignal.timeout(120000) });
  return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: await r.text() });
}

async function geckoRoute(route) {
  const url = new URL(route.request().url());
  if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
  geckoAsked.push(url.searchParams.get('ids'));
  const body = Object.fromEntries(Object.entries(PRICES).map(([id, usd]) => [id, { usd }]));
  return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: JSON.stringify(body) });
}

/** One screen, four ways: phone and desktop, light and dark. */
async function shots4(name) {
  await page.evaluate(() => document.querySelectorAll('.toast').forEach((t) => t.remove()));
  for (const scheme of ['light', 'dark']) {
    for (const [w, hh] of [[390, 844], [1280, 800]]) {
      await page.emulateMedia({ colorScheme: scheme });
      await page.setViewportSize({ width: w, height: hh });
      await sleep(150);
      await shot(page, `bridge-${name}-${w}-${scheme}`);
    }
  }
  await page.emulateMedia({ colorScheme: 'light' });
  await page.setViewportSize({ width: 390, height: 844 });
}

/** Tells the page its BEAM wallet holds `groth` BEAM (wallet.available(0) only, in this page only); null undoes it. */
async function pretendBeam(groth) {
  await page.evaluate(async (g) => {
    const { wallet } = await import('./lib/wallet.js');
    if (!wallet.__realAvailable) wallet.__realAvailable = wallet.available;
    wallet.available = g === null ? wallet.__realAvailable : (id) => (Number(id) === 0 ? BigInt(g) : wallet.__realAvailable.call(wallet, id));
    wallet.emit();
  }, groth === null ? null : String(groth));
}

const ctaText = () => page.textContent(tid('bridge-cta'));
async function waitCta(text, timeout = 60000) {
  await page.waitForFunction((t) => {
    const b = document.querySelector('[data-testid="bridge-cta"]');
    return b && b.textContent === t && !b.disabled;
  }, text, { timeout });
}
async function waitReason(re, timeout = 60000) {
  await page.waitForFunction((src) => new RegExp(src).test(document.querySelector('[data-testid="bridge-reason"]')?.textContent || ''), re.source, { timeout });
}
async function crossingState(states, timeout = 120000) {
  await page.waitForFunction((s) => s.includes(document.querySelector('[data-testid="bridge-crossing-status"]')?.dataset.state), states, { timeout, polling: 500 });
  return page.getAttribute(tid('bridge-crossing-status'), 'data-state');
}
async function typeAmount(v) {
  await page.fill(tid('bridge-amount'), '');
  await page.fill(tid('bridge-amount'), v);
}

before(async () => {
  srv = await startServer({ root: 'dist', port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  await ctx.route((u) => u.hostname === STACK, stackRoute);
  await ctx.route((u) => u.hostname === GECKO, geckoRoute);
  // Nothing may reach a real Ethereum server.
  await ctx.route((u) => ETH_RPC_HOSTS.some((x) => x.host === u.hostname && x.host !== STACK), (r) => r.abort());
  ({ page, rec } = await recordedPage(ctx, { label: 'bridge-ui' }));
  const k = await ethKeyFromMnemonic(WORDS.join(' '));
  ETH_ADDR = k.address;
  wipe(k.sk);
  console.log(`# screenshots: ${SHOTS}; Ethereum wallet ${ETH_ADDR} (fresh words)`);
});

after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
});

test('a new BEAM wallet, synced; the ⇄ sits beside BEAM | Ethereum', T(20), async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  console.log(`# synced: ${JSON.stringify(await waitSynced(page))}`);
  await page.waitForSelector(tid('chain-move'));
  const loaded = await page.evaluate(() => performance.getEntriesByType('resource').filter((e) => /\/lib\/bridge\/|\/screens\/bridge_/.test(e.name)).map((e) => e.name));
  assert.deepEqual(loaded, [], 'no bridge code before the bridge is opened');
  await shots4('00-home');
});

test('no Ethereum wallet: Move leads to creating one, then comes back', T(4), async () => {
  await page.click(tid('chain-move'));
  await waitScreen(page, 'bridgeMove');
  await page.waitForSelector(tid('bridge-no-eth'));
  assert.equal(await page.textContent(tid('bridge-add-eth')), 'Create an Ethereum wallet');
  await shots4('01-move-no-eth-wallet');
  await page.click(tid('bridge-add-eth'));
  await waitScreen(page, 'ethStart');
  await page.click(tid('eth-import'));
  await waitScreen(page, 'ethImport');
  await page.fill(tid('eth-words-input'), WORDS.join(' '));
  await page.click(tid('eth-import-submit'));
  await waitScreen(page, 'ethPrivacy');
  await page.click(tid('eth-connect'));
  await waitScreen(page, 'bridgeMove');
  await page.waitForSelector(tid('bridge-cta'));
  assert.match(await page.textContent(tid('bridge-to')), new RegExp(`To your Ethereum wallet ${ETH_ADDR.slice(0, 6)}…${ETH_ADDR.slice(-4)}`, 'i'));
});

test('(d) CoinGecko only after it is allowed; "Not now" leaves WBEAM → BEAM, and says so', T(4), async () => {
  // From BEAM Home: to Ethereum, BEAM, and nothing asked of CoinGecko yet.
  await page.waitForSelector(tid('bridge-prices-ask'));
  assert.equal(geckoAsked.length, 0);
  assert.match(await page.textContent(tid('bridge-limits')), /At most 3,000,000 BEAM per move\./);
  await waitReason(/Allow prices above/);
  await shots4('02-move-prices-ask');
  await page.click(tid('bridge-prices-refuse'));
  await page.waitForSelector(tid('bridge-prices-off'));
  assert.match(await page.textContent(tid('bridge-prices-off')), /only WBEAM → BEAM can move/);
  await waitReason(/Prices are off/);
  await shots4('03-move-prices-off');
  await page.click(tid('bridge-use-wbeam'));
  await page.waitForSelector(`${tid('bridge-route-beam')}[aria-checked="true"]`);
  await page.waitForFunction(() => document.querySelector('[data-testid="bridge-limits"]').textContent === 'Collecting it on BEAM costs 0.121 BEAM from your BEAM wallet.');
  // Before anything is typed: the empty BEAM wallet cannot collect, and says what to do.
  await page.waitForSelector(`${tid('bridge-block')}[data-code="noClaimFee"]`);
  assert.match(await page.textContent(tid('bridge-block')), /needs 0\.121 BEAM to collect it/);
  assert.equal(await page.textContent(tid('bridge-block-action')), 'Receive BEAM');
  // WBEAM → BEAM needs no price: its fixed fee is quoted.
  await page.waitForFunction(() => /^0\.02 WBEAM$/.test(document.querySelector('[data-testid="bridge-fee"]').textContent));
  await shots4('04-move-wbeam-no-prices');
  await page.click(tid('bridge-route-eth'));
  await page.waitForSelector(tid('bridge-prices-off'));
  assert.equal(geckoAsked.length, 0, 'refused: CoinGecko is never asked');
  await page.click(`${tid('bridge-prices-off')} ${tid('bridge-prices-allow')}`);
  await page.waitForFunction(() => !document.querySelector('[data-testid="bridge-prices-off"]'));
  await page.waitForFunction(() => /ETH$/.test(document.querySelector('[data-testid="bridge-fee"]').textContent), null, { timeout: 30000 });
  assert.ok(geckoAsked.length >= 1, 'allowed: the first price request');
  assert.match(geckoAsked[0], /ethereum/);
  // The choice can be changed later, under Settings -> Ethereum wallet.
  await page.evaluate(() => window.__campfire.go('ethSettings'));
  await page.waitForSelector(tid('eth-bridge-prices-switch'));
  assert.equal(await page.isChecked(tid('eth-bridge-prices-switch')), true);
  await shots4('05a-eth-settings-prices');
  await page.evaluate(() => window.__campfire.go('bridgeMove'));
  await waitScreen(page, 'bridgeMove');
  await page.waitForSelector(tid('bridge-history'));
  // The list before any move.
  await page.click(tid('bridge-history'));
  await waitScreen(page, 'bridgeList');
  await page.waitForSelector(tid('bridge-list-empty'));
  assert.equal(await page.textContent(tid('bridge-list-move')), 'Move coins');
  await shots4('05-list-empty');
  await page.click(tid('bridge-list-move'));
  await waitScreen(page, 'bridgeMove');
});

const ETH_ROUTE = routeById('eth');
const WBEAM_ROUTE = routeById('beam');
const remoteOnMainnet = (routeId, msgId) =>
  page.evaluate(
    async ([id, m]) => {
      const { BeamPipe } = await import('./lib/bridge/beam_pipe.js');
      const { routeById: byId } = await import('./lib/bridge/routes.js');
      const msg = await new BeamPipe().remoteMessage(byId(id), m);
      return msg ? String(msg.amount) : null;
    },
    [routeId, msgId],
  );

test('(a) to BEAM on the fork: 0.01 ETH and 100 WBEAM locked through the screens; (c) a reload and a lock resume them', T(20), () =>
  withFork(async () => {
    await raw('anvil_setBalance', [ETH_ADDR, hex(ETHER)]);
    await giveTokens(WBEAM_ROUTE, ETH_ADDR.toLowerCase(), 10500000000n);

    // Ethereum Home shows the way in.
    await page.evaluate(() => window.__campfire.go('ethHome'));
    await page.waitForSelector(`${tid('eth-balance')}[data-wei="${ETHER}"]`, { timeout: 60000 });
    await page.waitForSelector(tid('eth-move-to-beam'));
    await shots4('06-eth-home-entry');
    await page.click(tid('eth-move-to-beam'));
    await waitScreen(page, 'bridgeMove');

    // ETH → bETH: first the honest answer for an empty BEAM wallet.
    await page.click(tid('bridge-route-eth'));
    await typeAmount('0.01');
    await waitReason(/needs 0\.121 BEAM to collect it/);
    await pretendBeam(50000000n);
    await page.click(tid('bridge-flip'));
    await page.click(tid('bridge-flip'));
    await typeAmount('0.01');
    await waitCta('Move 0.01 ETH to BEAM');
    const fee = e2bRelayerFee(ETH_ROUTE, PRICES);
    assert.match(await page.textContent(tid('bridge-costs')), /^Plus 0\.0000000\d ETH bridge fee, up to [0-9.]+ ETH network fee, and 0\.121 BEAM to collect it\. About 2 minutes\./);
    assert.equal(await page.textContent(tid('bridge-receive')), '0.01');
    await shots4('07-move-eth-to-beam');
    // The CTA is on screen on a small phone without scrolling.
    await page.setViewportSize({ width: 375, height: 667 });
    const box = await page.locator(tid('bridge-cta')).boundingBox();
    assert.ok(box && box.y + box.height <= 667, `the button is visible at 375x667 (${JSON.stringify(box)})`);
    await page.setViewportSize({ width: 390, height: 844 });

    const msgEth = await nextMsgId(ETH_ROUTE);
    const remoteEth = await remoteOnMainnet('eth', msgEth);
    const pipeBefore = await pipeHoldings(ETH_ROUTE);
    await page.click(tid('bridge-cta'));
    await page.waitForSelector(tid('bridge-review-move-btn'));
    assert.equal(await page.textContent(tid('bridge-review-move-btn')), 'Move 0.01 ETH to BEAM');
    assert.equal(await page.textContent(tid('bridge-review-receive')), '0.01 bETH');
    assert.match(await page.textContent(tid('bridge-review-eth-fee')), /^likely [0-9.]+ ETH$/);
    assert.match(await page.textContent(tid('bridge-review-eth-fee-max')), /^up to [0-9.]+ ETH$/);
    assert.equal(await page.isVisible(tid('bridge-review-approval')), false, 'ETH needs no approval');
    assert.match(await page.textContent(tid('bridge-review-public')), /public on both chains/);
    await shots4('08-review-eth');
    const sendsBefore = rpcMethods.filter((m) => m === 'eth_sendRawTransaction').length;
    await page.click(tid('bridge-review-move-btn'));
    await page.waitForSelector(tid('auth-pw'));
    await shots4('09-review-password');
    await page.fill(tid('auth-pw'), PASSWORD);
    await page.click(tid('auth-submit'));
    await waitScreen(page, 'bridgeCrossing');
    await crossingState(['locking', 'locked']);
    await shots4('10-crossing-eth-sent');
    const expectEth = remoteEth === null ? 'locked' : 'unknown';
    console.log(`# ETH lock: next message ${msgEth}; on BEAM mainnet that id is ${remoteEth === null ? 'absent' : `taken (${remoteEth} groth)`}, so the move should read "${expectEth}"`);
    assert.equal(await crossingState([expectEth]), expectEth);
    const lockHash = await page.getAttribute(tid('bridge-crossing-lock'), 'data-hash');
    assert.equal((await mined(lockHash)).status, '0x1');
    assert.equal(rpcMethods.filter((m) => m === 'eth_sendRawTransaction').length, sendsBefore + 1, 'one broadcast');
    assert.equal((await pipeHoldings(ETH_ROUTE)) - pipeBefore, ETHER / 100n + fee, 'the pipe holds 0.01 ETH and the bridge fee');
    assert.equal(await page.textContent(tid('bridge-crossing-number')), `#${msgEth}`);
    if (expectEth === 'locked') {
      assert.equal(await page.textContent(tid('bridge-crossing-title')), 'On its way to BEAM');
      assert.deepEqual(await page.$$eval('[data-testid^="bridge-step-"]', (els) => els.map((e) => e.dataset.status)), ['done', 'active', 'waiting']);
    }
    await shots4('11-crossing-eth-on-its-way');

    // WBEAM → BEAM: an exact approval, then the lock, with one confirmation.
    await page.click(tid('bridge-crossing-done'));
    await waitScreen(page, 'bridgeMove');
    await page.waitForSelector(tid('bridge-open-crossing'));
    await page.click(tid('bridge-route-beam'));
    await typeAmount('100');
    await waitCta('Move 100 WBEAM to BEAM');
    const msgW = await nextMsgId(WBEAM_ROUTE);
    const remoteW = await remoteOnMainnet('beam', msgW);
    await page.click(tid('bridge-cta'));
    await page.waitForSelector(tid('bridge-review-approval'));
    assert.match(await page.textContent(tid('bridge-review-approval')), /You sign 2 Ethereum transactions.*exactly 100\.02 WBEAM/);
    assert.match(await page.textContent(tid('bridge-review-freeze')), /WBEAM can be paused by its issuer/);
    await shots4('12-review-wbeam-two-steps');
    await page.click(tid('bridge-review-move-btn'));
    await page.fill(tid('auth-pw'), PASSWORD);
    await page.click(tid('auth-submit'));
    await waitScreen(page, 'bridgeCrossing');
    const first = await crossingState(['approving', 'locking', 'locked', 'unknown']);
    if (first === 'approving') await shots4('13-crossing-wbeam-approving');
    const expectW = remoteW === null ? 'locked' : 'unknown';
    console.log(`# WBEAM lock: next message ${msgW}; on BEAM mainnet ${remoteW === null ? 'absent' : `taken (${remoteW})`}`);
    assert.equal(await crossingState([expectW]), expectW);
    assert.equal(await erc20Balance(WBEAM_ROUTE.ethToken, ETH_ADDR.toLowerCase()), 498000000n, '100.02 WBEAM taken, 4.98 left');
    assert.equal(await raw('eth_call', [{ to: WBEAM_ROUTE.ethToken, data: `0xdd62ed3e${ETH_ADDR.slice(2).toLowerCase().padStart(64, '0')}${WBEAM_ROUTE.ethPipe.slice(2).padStart(64, '0')}` }, 'latest']), `0x${'0'.repeat(64)}`, 'the approval was used up exactly');
    assert.ok((await ethBalance(ETH_ADDR.toLowerCase())) < ETHER - ETHER / 100n);
    await shots4('14-crossing-wbeam-on-its-way');

    // (c) A reload in the middle: unlock, and the move is still being followed.
    await page.reload();
    await unlockWithPassword(page, PASSWORD);
    await waitScreen(page, 'home', 120000);
    await page.waitForSelector(`${tid('chain-move')}[data-badge="open"]`, { timeout: 60000 });
    await shots4('15-home-move-on-its-way');
    await page.click(tid('chain-move'));
    await waitScreen(page, 'bridgeMove');
    await page.waitForSelector(tid('bridge-open-crossing'));
    assert.match(await page.textContent(tid('bridge-history')), /History \(2\)/);
    await page.click(tid('bridge-history'));
    await waitScreen(page, 'bridgeList');
    await page.waitForSelector(tid('bridge-list-open'));
    const rows = await page.$$eval(`${tid('bridge-list-open')} ${tid('bridge-row')}`, (els) => els.map((e) => [e.querySelector('.t').textContent, e.dataset.state]));
    assert.deepEqual(rows.map((r) => r[0]), ['100 WBEAM → BEAM', '0.01 ETH → BEAM'], 'newest first');
    await shots4('16-list-on-their-way');
    await page.click(`${tid('bridge-list-open')} ${tid('bridge-row')}`);
    await waitScreen(page, 'bridgeCrossing');
    assert.equal(await crossingState([expectW]), expectW);

    // Locked while following it: the unlock screen says so, and goes back to it.
    await page.evaluate(async () => (await import('./app.js')).app.lock('timeout'));
    await waitScreen(page, 'unlock');
    await page.waitForSelector(tid('unlock-follow'));
    const follow = await page.textContent(tid('unlock-follow'));
    assert.match(follow, /Unlock to follow your move\. Your move to BEAM was at "/);
    assert.ok(!/100|WBEAM|0x/.test(follow), 'no amount, coin or address on the lock screen');
    await shots4('17-unlock-to-follow');
    await unlockWithPassword(page, PASSWORD);
    await waitScreen(page, 'bridgeCrossing', 120000);
    assert.equal(await crossingState([expectW]), expectW);
  }));

test('(b) to Ethereum from the unfunded BEAM wallet: the quote, then the approve sheet in the bridge\'s words, "not enough"; never approved', T(10), async () => {
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await page.click(tid('chain-move'));
  await waitScreen(page, 'bridgeMove');
  await page.click(tid('bridge-route-beam'));
  await page.waitForSelector(`${tid('bridge-route-beam')}[aria-checked="true"]`);
  assert.match(await page.textContent('.swap-label'), /From your BEAM wallet/);
  // The real wallet: nothing in it.
  await page.waitForFunction(() => /^More than the bridge fee \(now [0-9.]+ BEAM\), at most 3,000,000 BEAM per move\.$/.test(document.querySelector('[data-testid="bridge-limits"]').textContent), null, { timeout: 60000 });
  await typeAmount('300');
  await waitReason(/^Not enough BEAM\.$/);
  await page.waitForSelector(`${tid('bridge-block')}[data-code="notEnough"]`);
  await shots4('18-move-to-ethereum-not-enough');
  // Told it holds 1,000 BEAM, the quote goes through and the button says the outcome.
  await pretendBeam(100000000000n);
  await typeAmount('');
  await typeAmount('300');
  await waitCta('Move 300 BEAM to Ethereum');
  const fee = (await page.textContent(tid('bridge-fee'))).replace(/ BEAM$/, '');
  assert.match(await page.textContent(tid('bridge-costs')), /^Plus [0-9.]+ BEAM bridge fee and 0\.011 BEAM network fee\. About 1 hour\./);
  assert.equal(await page.textContent(tid('bridge-receive')), '300');
  assert.match(await page.textContent(tid('bridge-time')), /^About 1 hour$/);
  await shots4('19-move-to-ethereum');
  await page.click(tid('bridge-cta'));
  await page.waitForSelector(`${tid('consent')}[data-bridge="send"]`, { timeout: 120000 });
  assert.equal(await page.textContent(`${tid('consent')} h2`), 'Confirm your move');
  assert.equal(await page.textContent(tid('consent-bridge-amount')), '300 BEAM');
  assert.equal(await page.textContent(tid('consent-bridge-receives')), '300 WBEAM');
  assert.equal(await page.getAttribute(tid('consent-bridge-to'), 'data-address'), ETH_ADDR.toLowerCase());
  assert.equal(await page.textContent(tid('consent-fee')), '0.011 BEAM');
  assert.equal(await page.textContent(tid('consent-bridge-time')), 'About 1 hour');
  assert.equal(await page.isVisible(tid('consent-bridge-public')), false, 'what is missing comes first: the public note is for a move that can be approved');
  assert.match(await page.textContent(tid('consent-not-enough')), /^Not enough BEAM\./);
  assert.equal(await page.isVisible(tid('consent-approve')), false, 'the engine says it is not enough: no approve button');
  // What leaves adds up: 300 + the bridge fee + 0.011, every groth.
  const groth = (t) => {
    const [w, f = ''] = t.replace(/ (BEAM|WBEAM)$/, '').replace(/,/g, '').split('.');
    return BigInt(w) * 100000000n + BigInt(f.padEnd(8, '0'));
  };
  const bridgeFee = groth(await page.textContent(tid('consent-bridge-fee')));
  assert.equal(groth(await page.textContent(tid('consent-total'))), 30000000000n + bridgeFee + 1100000n);
  assert.ok(groth(`${fee} BEAM`) >= bridgeFee && groth(`${fee} BEAM`) - bridgeFee < 10000n, `Move showed the same fee, rounded up (${fee} vs ${bridgeFee} groth)`);
  await shots4('20-consent-to-ethereum-not-enough');
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(tid('bridge-error'));
  assert.match(await page.textContent(tid('bridge-error')), /Nothing was sent\. You did not approve it/);
  await shots4('21-move-after-cancel');
  const truth = await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    return { txs: (await wallet.session.call('tx_list', { count: 100, skip: 0 })).length, consents: window.__campfire.consents().at(-1) };
  });
  assert.equal(truth.txs, 0, 'nothing was sent');
  assert.equal(truth.consents.decision, 'rejected');
  assert.equal(truth.consents.isEnough, false);
  assert.equal(truth.consents.fee, '0.011');
  const dec = (g) => `${g / 100000000n}${g % 100000000n ? `.${String(g % 100000000n).padStart(8, '0').replace(/0+$/, '')}` : ''}`;
  assert.deepEqual(truth.consents.spends, [{ assetId: 0, amount: dec(30000000000n + bridgeFee) }], 'the engine reported 300 BEAM + the bridge fee leaving');
  await pretendBeam(null);
  // The list: on their way first, the one not sent below.
  await page.click(tid('bridge-history'));
  await waitScreen(page, 'bridgeList');
  await page.waitForSelector(tid('bridge-list-done'));
  assert.equal(await page.textContent(`${tid('bridge-list-done')} ${tid('bridge-row-status')}`), 'Not sent');
  await shots4('22-list-with-finished');
  await page.click(`${tid('bridge-list-done')} ${tid('bridge-row')}`);
  await waitScreen(page, 'bridgeCrossing');
  await crossingState(['failed']);
  assert.equal(await page.textContent(tid('bridge-crossing-title')), 'Not sent');
  await shots4('23-crossing-not-sent');
});

// The desktop app's recording of real unclaimed moves to BEAM (test/e2e/bridge_beam.test.mjs uses them too).
const RECORDED = [['eth', 67, 500000n], ['usdt', 78, 91049000n], ['beam', 226, 2000000n]];

test('(e) a move ready to collect: "Collect", then the approve sheet in the bridge\'s words; never approved', T(6), async (t) => {
  // A record as the controller writes it once a lock has reached BEAM, for one of the recorded
  // messages still unclaimed on mainnet (it is somebody else's: this wallet could never sign the
  // claim, and the engine says "not enough" before that matters). Written into this wallet's own
  // sealed store, then picked up by unlocking again, as after a reload.
  let pick = null;
  for (const [id, msgId, amount] of RECORDED) {
    const left = await remoteOnMainnet(id, msgId);
    if (left === String(amount)) {
      pick = { id, msgId, amount };
      break;
    }
  }
  if (!pick) return t.skip('every recorded message has been claimed since');
  const id = await page.evaluate(async ({ id, msgId, amount, fee }) => {
    const { bridgeOf } = await import('./screens/bridge_ui.js');
    const { makeCrossing } = await import('./lib/bridge/store.js');
    const { app } = await import('./app.js');
    const s = await bridgeOf(app);
    const now = Date.now();
    const c = makeCrossing({
      id: `xrecorded${msgId}`, route: id, direction: 'toBeam', state: 'delivered', amount: BigInt(amount) * (id === 'eth' ? 10000000000n : id === 'usdt' ? 1n : 1n) / (id === 'usdt' ? 100n : 1n),
      receives: BigInt(amount), relayerFee: BigInt(fee), beamNetworkFee: 12100000n, ethNetworkFee: 200000000000000n, beamWalletId: s.ctl.beamWalletId, ethWalletId: s.ctl.ethWalletId, ethAddress: s.eth.owner,
      createdAt: now - 4 * 60000, updatedAt: now, msgId, deliveredAt: now, lockedAt: now - 3 * 60000,
    });
    await s.ctl.store.save(c);
    return c.id;
  }, { id: pick.id, msgId: pick.msgId, amount: String(pick.amount), fee: String(e2bRelayerFee(routeById(pick.id), PRICES)) });
  // Locked from Home (from a bridge screen, unlocking would go back to that screen).
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await page.evaluate(async () => (await import('./app.js')).app.lock('manual'));
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 120000);
  await page.waitForSelector(`${tid('chain-move')}[data-badge="collect"]`, { timeout: 60000 });
  await shots4('23a-home-move-ready-to-collect');
  await page.evaluate((x) => window.__campfire.go('bridgeCrossing', { id: x, back: 'bridgeList' }), id);
  await waitScreen(page, 'bridgeCrossing');
  assert.equal(await crossingState(['delivered']), 'delivered');
  assert.equal(await page.textContent(tid('bridge-crossing-title')), 'Ready to collect');
  const label = await page.textContent(tid('bridge-collect'));
  assert.match(label, /^Collect [0-9.]+ b(ETH|USDT)$|^Collect 0\.02 BEAM$/);
  assert.match(await page.textContent(tid('bridge-collect-fee')), /Network fee 0\.121 BEAM, from your BEAM wallet\./);
  await shots4('24-crossing-ready-to-collect');
  // Told it holds 0.5 BEAM (in the page only), so the sheet looks as it does for a wallet that can
  // pay the 0.121 BEAM: its button is there and is never pressed. Cancel sends nothing.
  await pretendBeam(50000000n);
  await page.click(tid('bridge-collect'));
  await page.waitForSelector(`${tid('consent')}[data-bridge="collect"]`, { timeout: 120000 });
  assert.equal(await page.textContent(`${tid('consent')} h2`), 'Collect your coins');
  assert.equal(await page.textContent(tid('consent-fee')), '0.121 BEAM');
  assert.equal(await page.textContent(tid('consent-bridge-from')), "BEAM's official bridge");
  assert.match(await page.textContent(tid('consent-bridge')), new RegExp(`transfer #${pick.msgId}, from your Ethereum wallet`));
  assert.equal(await page.textContent(tid('consent-approve')), label, 'the button says the outcome; it is never pressed');
  assert.equal(await crossingState(['claiming']), 'claiming', 'written down before the claim is shown');
  await shots4('25-consent-collect');
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(tid('bridge-crossing-error'));
  assert.match(await page.textContent(tid('bridge-crossing-error')), /You did not approve it, so nothing was collected/);
  assert.equal(await crossingState(['delivered']), 'delivered', 'back to ready to collect: nothing was sent');
  const truth = await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    return { txs: (await wallet.session.call('tx_list', { count: 100, skip: 0 })).length, last: window.__campfire.consents().at(-1) };
  });
  assert.equal(truth.txs, 0);
  assert.equal(truth.last.decision, 'rejected');
  assert.deepEqual(truth.last.receives.map((r) => r.amount), [String(Number(pick.amount) / 1e8)]);
  await pretendBeam(null);
});

test('IP privacy: this origin, the BEAM node, the chosen Ethereum server and (once allowed) CoinGecko; no CSP violation', T(1), async () => {
  assert.deepEqual(foreignHosts(rec, srv.url, [NODE]).sort(), [`https://${GECKO}`, `https://${STACK}`]);
  assert.deepEqual(rec.csp, []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
});

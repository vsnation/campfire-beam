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
//
// Then a wallet imported from a fresh random private key (never printed):
// the one import box tells it is a key, says what is wrong with a bad one,
// shows the address before anything is saved; Home opens that address; the
// Backup shows the key only after the password, and locking leaves it nowhere
// in the page (DOM and JS heap). Those screens at 375 px, light and dark,
// into $CAMPFIRE_ETHKEY_SHOTS, with every key painted over.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import jsQR from 'jsqr';
import { join } from 'node:path';
import { startServer, launch, recordedPage, shot, waitScreen, foreignHosts, sleep, SHOTS } from './harness.mjs';
import { createWallet, waitHome, unlockWithPassword } from './flows.mjs';
import { ANVIL, JUNK, ACCOUNT0, raw, anvilProblem, withFork, setBalance, sendAs, erc20Balance, freshAddress, mined } from '../fork/fork_support.mjs';
import { ethKeyFromMnemonic, wipe, toChecksumAddress, privateKeyToAddress } from '../../src/lib/eth/crypto.js';
import { bytesToHex, hexToBytes } from '../../src/lib/eth/hex.js';
import { encodeCall } from '../../src/lib/eth/abi.js';
import { ETH_RPC_HOSTS } from '../../src/lib/eth/hosts.js';
import { WBEAM } from '../../src/lib/eth/tokens.js';
import { routeById } from '../../src/lib/bridge/routes.js';

const PORT = Number(process.env.CAMPFIRE_ETH_PORT || 8840);
const PASSWORD = `eth-${Math.random().toString(36).slice(2, 10)}`;
const STACK = 'eth2.stackwallet.com';
const ETHER = 10n ** 18n;
const tid = (id) => `[data-testid="${id}"]`;
const skip = await anvilProblem();
const KEY_SHOTS = process.env.CAMPFIRE_ETHKEY_SHOTS || join(SHOTS, 'ethkey');
const SECP_N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const KEY_WARNING = 'This wallet has no recovery words. The private key is the only way back to it: keep it somewhere safe and never share it.';

let srv, browser, ctx, page, rec;
let mode = 'fork'; // 'fork' | 'down' | 'refuse' (eth_sendRawTransaction refused, the rest from the fork) | 'dear' (fee history: 5,000 gwei)
const rpcMethods = [];
// More rows for the history index (/export), for a test that needs it to show a transaction mined.
const indexExtra = [];
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
    const data = [{ blockHash: `0x${'b1'.repeat(32)}`, blockNumber: 22000000, from: '0x1111111111111111111111111111111111111111', to: me, gas: 21000, gasPrice: 1000000000, gasUsed: 21000, hash: `0x${'e1'.repeat(32)}`, nonce: 3, receipt: { effectiveGasPrice: 1000000000, gasUsed: 21000, logs: [], status: 1 }, timestamp: 1767225600, value: '1000000000000000000' }, ...indexExtra];
    return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: JSON.stringify({ data }) });
  }
  if (req.method() !== 'POST') return route.fulfill({ status: 404, headers: cors, body: '' });
  const body = req.postData();
  let j = null;
  try {
    j = JSON.parse(body);
    for (const m of [].concat(j)) rpcMethods.push(m.method);
  } catch {
    /* not JSON: anvil says so */
  }
  // Ethereum far dearer than Beam PWA pays (as on 2022-05-01, above 8,000 gwei for a few blocks).
  if (mode === 'dear' && j && !Array.isArray(j) && j.method === 'eth_feeHistory') {
    const base = `0x${(5000n * 10n ** 9n).toString(16)}`;
    return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: j.id, result: { oldestBlock: '0x1', baseFeePerGas: Array(6).fill(base), gasUsedRatio: Array(5).fill(0.5), reward: Array(5).fill(['0x3b9aca00']) } }) });
  }
  // A server that refuses the bytes (it may still have passed them on): "Not sent yet".
  if (mode === 'refuse' && j && !Array.isArray(j) && j.method === 'eth_sendRawTransaction') {
    return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: j.id, error: { code: -32000, message: 'transaction underpriced' } }) });
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

/**
 * One state at 375 px, light and dark, into KEY_SHOTS. `masks`: selectors of
 * anything that shows a key (typed or revealed), painted over in the picture.
 * `focus`: scrolled into view first.
 */
async function keyShots(name, { masks = [], focus = null } = {}) {
  await page.evaluate(() => document.querySelectorAll('.toast').forEach((t) => t.remove()));
  const { mkdir } = await import('node:fs/promises');
  await mkdir(KEY_SHOTS, { recursive: true });
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await page.setViewportSize({ width: 375, height: 812 });
    if (focus) await page.locator(focus).first().scrollIntoViewIfNeeded();
    await sleep(150);
    await page.screenshot({ path: join(KEY_SHOTS, `ethkey-${name}-375-${scheme}.png`), mask: masks.map((m) => page.locator(m)), maskColor: '#8a8f98' });
  }
  await page.emulateMedia({ colorScheme: 'light' });
  await page.setViewportSize({ width: 390, height: 844 });
}

/** A random valid secp256k1 key, 64 lowercase hex: only ever typed into the page, never printed. */
function randomKeyHex() {
  for (;;) {
    const b = new Uint8Array(32);
    globalThis.crypto.getRandomValues(b);
    const hex = bytesToHex(b, false);
    wipe(b);
    const k = BigInt(`0x${hex}`);
    if (k > 0n && k < SECP_N) return hex;
  }
}

/**
 * How many of `needles` occur in the page's JS heap, after a full garbage
 * collection. A string built with += is a "(concatenated string)" in a heap
 * snapshot, its text only in the pieces, so those are joined again from their
 * first/second edges; a sliced string counts as its whole parent.
 */
async function inHeap(needles) {
  const cdp = await page.context().newCDPSession(page);
  let snap;
  try {
    await cdp.send('HeapProfiler.enable');
    await cdp.send('HeapProfiler.collectGarbage');
    await cdp.send('HeapProfiler.collectGarbage');
    const chunks = [];
    cdp.on('HeapProfiler.addHeapSnapshotChunk', (e) => chunks.push(e.chunk));
    await cdp.send('HeapProfiler.takeHeapSnapshot', { reportProgress: false });
    snap = JSON.parse(chunks.join(''));
  } finally {
    await cdp.detach().catch(() => {});
  }
  const { meta } = snap.snapshot;
  const NF = meta.node_fields.length;
  const EF = meta.edge_fields.length;
  const [nType, nName, nEdges] = ['type', 'name', 'edge_count'].map((f) => meta.node_fields.indexOf(f));
  const [eType, eName, eTo] = ['type', 'name_or_index', 'to_node'].map((f) => meta.edge_fields.indexOf(f));
  const types = meta.node_types[0];
  const edgeTypes = meta.edge_types[0];
  const { nodes, edges, strings } = snap;
  const count = nodes.length / NF;
  const firstEdge = new Uint32Array(count + 1);
  for (let i = 0; i < count; i++) firstEdge[i + 1] = firstEdge[i] + nodes[i * NF + nEdges] * EF;
  const memo = new Map();
  const CAP = 4096;
  const text = (i, depth = 0) => {
    if (memo.has(i)) return memo.get(i);
    const type = types[nodes[i * NF + nType]];
    let out = '';
    if (type === 'string') out = strings[nodes[i * NF + nName]];
    else if ((type === 'concatenated string' || type === 'sliced string') && depth < 4000) {
      const parts = {};
      for (let e = firstEdge[i]; e < firstEdge[i + 1]; e += EF) {
        if (edgeTypes[edges[e + eType]] !== 'internal') continue;
        parts[strings[edges[e + eName]]] = edges[e + eTo] / NF;
      }
      if (type === 'sliced string') out = parts.parent !== undefined ? text(parts.parent, depth + 1) : '';
      else out = `${parts.first !== undefined ? text(parts.first, depth + 1) : ''}${parts.second !== undefined ? text(parts.second, depth + 1) : ''}`;
    }
    out = out.length > CAP ? out.slice(0, CAP) : out;
    memo.set(i, out);
    return out;
  };
  const found = new Set();
  for (let i = 0; i < count && found.size < needles.length; i++) {
    const type = types[nodes[i * NF + nType]];
    if (type !== 'string' && type !== 'concatenated string' && type !== 'sliced string') continue;
    const t = text(i);
    needles.forEach((n, j) => t.includes(n) && found.add(j));
  }
  return found.size;
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
  // Values only: key names such as "path" and "kind" are BIP39 words too.
  const values = [];
  JSON.parse(stored, (k, v) => (typeof v === 'string' && values.push(v), v));
  for (const w of new Set(words)) assert.ok(!values.includes(w), 'no word in storage');
  assert.ok(!stored.includes(words.join(' ')), 'nor the phrase');
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

test('BM-1: a payment the server refused holds back the next one: Home, Send, Buy WBEAM and Move to BEAM say so; settled, they open up', { skip: skip || false, timeout: 6 * 60000 }, () =>
  withFork(async () => {
    const to = toChecksumAddress(freshAddress());
    await setBalance(ACCOUNT0, 5n * ETHER);
    await page.evaluate(() => window.__campfire.go('ethHome'));
    await ethHomeReady();
    await page.waitForSelector(`${tid('eth-balance')}[data-wei="${5n * ETHER}"]`, { timeout: 30000 });
    assert.equal(await page.isVisible(tid('eth-doubt-line')), false, 'nothing in doubt: no line');

    // The server refuses the payment's bytes: "Not sent yet" (it may have passed them on first).
    mode = 'refuse';
    await page.click(tid('eth-send'));
    await waitScreen(page, 'ethSend');
    await page.waitForSelector(tid('eth-send-fee'));
    await page.waitForFunction(() => !/Checking/.test(document.querySelector('[data-testid="eth-send-fee"]').textContent), null, { timeout: 30000 });
    await page.fill(tid('eth-send-to'), to);
    await page.fill(tid('eth-send-amount'), '0.001');
    await page.waitForFunction(() => document.querySelector('[data-testid="eth-send-review"]').textContent === 'Send 0.001 ETH');
    await page.click(tid('eth-send-review'));
    await page.click(tid('eth-review-send'));
    await page.fill(tid('auth-pw'), PASSWORD);
    await page.click(tid('auth-submit'));
    await waitScreen(page, 'ethTx');
    await page.waitForSelector(`${tid('eth-tx-title')}[data-refused="true"]`, { timeout: 30000 });
    assert.equal(await page.textContent(tid('eth-tx-title')), 'Not sent yet');
    const hash = await page.getAttribute(tid('eth-tx-hash'), 'data-hash');

    // Home: one line above Send, opening that payment.
    await page.click(tid('eth-tx-done'));
    await ethHomeReady();
    await page.waitForSelector(`${tid('eth-doubt-line')}[data-hash="${hash}"]`);
    assert.equal(await page.textContent(tid('eth-doubt-line')), 'Sending is paused: a payment is "Not sent yet". See it');
    await shots4('25-home-doubt');

    // Send: named at the top with the way out; the button stays grey whatever is typed.
    await page.click(tid('eth-send'));
    await waitScreen(page, 'ethSend');
    await page.waitForSelector(`${tid('eth-doubt')}[data-hash="${hash}"]`);
    const words = await page.textContent(tid('eth-doubt'));
    assert.match(words, /^Your payment of 0\.001 ETH to 0x[0-9a-fA-F]{4}…[0-9a-fA-F]{4} is "Not sent yet"\. It may still go through, so nothing new is sent from this Ethereum wallet until it is settled, or both could go through\./);
    assert.match(words, /Wait until Beam PWA knows what happened to it, or choose another Ethereum server in Settings: it is checked there\./);
    await page.fill(tid('eth-send-to'), to);
    await page.fill(tid('eth-send-amount'), '0.002');
    await sleep(400);
    assert.equal(await page.isDisabled(tid('eth-send-review')), true, 'no second payment while the first is in doubt');
    assert.equal(await page.textContent(tid('eth-send-review')), 'Sending is paused (see above)');
    await shots4('26-send-doubt');
    await page.click(tid('eth-doubt-settings'));
    await waitScreen(page, 'ethSettings');

    // Buy WBEAM: the same, above the button.
    await page.evaluate(() => window.__campfire.go('ethSwap'));
    await waitScreen(page, 'ethSwap');
    await page.waitForSelector(`${tid('eth-doubt')}[data-hash="${hash}"]`, { timeout: 30000 });
    await page.fill(tid('uni-pay-amount'), '0.001');
    await page.waitForFunction(() => /Paused until your last Ethereum transaction is settled/.test(document.querySelector('[data-testid="uni-reason"]').textContent), null, { timeout: 30000 });
    assert.equal(await page.isDisabled(tid('uni-swap-cta')), true);
    await shots4('27-swap-doubt');

    // Move to BEAM signs from the same account: the same.
    await page.evaluate(() => window.__campfire.go('bridgeMove', { dir: 'toBeam', back: 'ethHome' }));
    await waitScreen(page, 'bridgeMove');
    await page.waitForSelector(`${tid('bridge-eth-doubt')}[data-hash="${hash}"]`, { timeout: 60000 });
    await shots4('28-bridge-doubt');

    // The server takes the bytes again: the same payment (never a second) is offered by itself,
    // mined, and the move opens up without a tap.
    const sends = rpcMethods.filter((m) => m === 'eth_sendRawTransaction').length;
    mode = 'fork';
    await page.waitForSelector(tid('bridge-eth-doubt'), { state: 'detached', timeout: 60000 });
    assert.equal((await mined(hash)).status, '0x1', 'the very payment that was in doubt');
    assert.equal(BigInt(await raw('eth_getBalance', [to, 'latest'])), 10n ** 15n, 'paid once');
    assert.ok(rpcMethods.filter((m) => m === 'eth_sendRawTransaction').length > sends);
    await page.evaluate(() => window.__campfire.go('ethHome'));
    await ethHomeReady();
    await page.waitForSelector(`${tid('eth-activity-row')}[data-hash="${hash}"][data-state="confirmed"]`, { timeout: 30000 });
    assert.equal(await page.isVisible(tid('eth-doubt-line')), false);
  }));

test('BM-1: a payment that falls in doubt while the review is open is not signed, and the sheet says why', { skip: skip || false, timeout: 4 * 60000 }, () =>
  withFork(async () => {
    await setBalance(ACCOUNT0, 5n * ETHER);
    await page.evaluate(() => window.__campfire.go('ethHome'));
    await ethHomeReady();
    await page.click(tid('eth-send'));
    await waitScreen(page, 'ethSend');
    await page.waitForSelector(tid('eth-send-fee'));
    await page.waitForFunction(() => !/Checking/.test(document.querySelector('[data-testid="eth-send-fee"]').textContent), null, { timeout: 30000 });
    await page.fill(tid('eth-send-to'), toChecksumAddress(freshAddress()));
    await page.fill(tid('eth-send-amount'), '0.001');
    await page.waitForFunction(() => document.querySelector('[data-testid="eth-send-review"]').textContent === 'Send 0.001 ETH');
    await page.click(tid('eth-send-review'));
    await page.waitForSelector(tid('eth-review-send'));
    // Meanwhile a payment of this wallet is refused by its server (written as lib/eth/send.js does).
    const doubtful = `0x${'a7'.repeat(32)}`;
    const write = (patch) =>
      page.evaluate(
        async ({ hash, from, to, patch }) => {
          const { app } = await import('./app.js');
          const { ethWallet } = await import('./lib/eth/wallet.js');
          const { addToOutbox, updateOutbox } = await import('./lib/eth/outbox.js');
          const w = await ethWallet(app);
          if (patch) await updateOutbox(app, hash, patch, { ethId: w.ethId });
          else await addToOutbox(app, { hash, raw: `0x02${'a7'.repeat(40)}`, nonce: '901', from, to, asset: 'ETH', token: null, amount: '2000000000000000', gasLimit: '21000', maxFeePerGas: '30000000000', maxPriorityFeePerGas: '1000000000', createdAt: Date.now(), sentAt: null, state: 'signed', receipt: null, error: 'transaction underpriced', refusedAt: Date.now() }, { ethId: w.ethId });
          await w.reloadOutbox();
        },
        { hash: doubtful, from: ACCOUNT0, to: toChecksumAddress(freshAddress()), patch },
      );
    await write(null);
    const counts = rpcMethods.filter((m) => m === 'eth_getTransactionCount').length;
    await page.click(tid('eth-review-send'));
    await page.waitForSelector(`${tid('eth-review-doubt')}[data-hash="${doubtful}"]`);
    assert.equal(await page.isVisible(tid('auth-pw')), false, 'not even the password is asked');
    assert.match(await page.textContent(tid('eth-review-doubt')), /is "Not sent yet"\. It may still go through/);
    assert.equal(rpcMethods.filter((m) => m === 'eth_getTransactionCount').length, counts, 'no nonce asked');
    await shots4('32-review-doubt');
    // Settled (never sent): nothing holds the next payment back.
    await write({ state: 'rejected' });
    await page.click(tid('eth-review-change'));
    await page.evaluate(() => window.__campfire.go('ethHome'));
    await ethHomeReady();
    assert.equal(await page.isVisible(tid('eth-doubt-line')), false);
  }));

/** An outbox entry of ACCOUNT0 that never reached Ethereum, refused for 40 minutes and ended as never sent; `over` changes it. */
const fake = (n, over = {}) => ({ hash: `0x${n.repeat(32)}`, raw: `0x02${n.repeat(40)}`, nonce: '900', from: ACCOUNT0, to: toChecksumAddress(freshAddress()), asset: 'ETH', token: null, amount: '2000000000000000', gasLimit: '21000', maxFeePerGas: '30000000000', maxPriorityFeePerGas: '1000000000', createdAt: Date.now() - 40 * 60000, sentAt: null, state: 'rejected', receipt: null, error: 'transaction underpriced', refusedAt: Date.now() - 40 * 60000, ...over });

/** Writes an outbox entry (or changes one) in the page, as lib/eth/send.js would, and reloads the wallet's copy. */
async function outboxWrite({ add = null, hash = null, patch = null }) {
  await page.evaluate(async ({ add, hash, patch }) => {
    const { app } = await import('./app.js');
    const { ethWallet } = await import('./lib/eth/wallet.js');
    const { addToOutbox, updateOutbox } = await import('./lib/eth/outbox.js');
    const w = await ethWallet(app);
    if (add) await addToOutbox(app, add, { ethId: w.ethId });
    if (hash) await updateOutbox(app, hash, patch, { ethId: w.ethId });
    await w.reloadOutbox();
  }, { add, hash, patch });
}

test('BM-2: "Not sent" is the server\'s word: a block (its receipt, or the history index) turns it into confirmed', { skip: skip || false, timeout: 4 * 60000 }, () =>
  withFork(async () => {
    await setBalance(ACCOUNT0, 5n * ETHER);
    await page.evaluate(() => window.__campfire.go('ethHome'));
    await ethHomeReady();
    // A payment that never reached Ethereum, ended as never sent after half an hour of refusals.
    const lost = fake('c3');
    await outboxWrite({ add: lost });
    await page.evaluate((h) => window.__campfire.go('ethTx', { hash: h }), lost.hash);
    await waitScreen(page, 'ethTx');
    await page.waitForSelector(`${tid('eth-tx-title')}[data-state="rejected"]`);
    const note = await page.textContent(tid('eth-not-sent'));
    assert.match(note, /most likely it never left and nothing was spent\. That is the server's word, not Ethereum's\./);
    assert.ok(!/so it never left/.test(note));
    assert.equal(await page.getAttribute(tid('eth-not-sent-explorer'), 'href'), `https://etherscan.io/tx/${lost.hash}`, 'Etherscan one tap away, in the notice');
    assert.equal(await page.getAttribute(tid('eth-tx-explorer'), 'href'), `https://etherscan.io/tx/${lost.hash}`);
    await sleep(1500); // its receipt asked again: none, so it stays as it was
    assert.equal(await page.getAttribute(tid('eth-tx-title'), 'data-state'), 'rejected');
    await shots4('29-tx-not-sent');

    // A payment the chain has (mined on the fork) that a server's refusals had ended as "Not sent":
    // opening Ethereum Home asks for its receipt again, and it is confirmed.
    const to = toChecksumAddress(freshAddress());
    await page.click(tid('eth-tx-done'));
    await ethHomeReady();
    await page.click(tid('eth-send'));
    await waitScreen(page, 'ethSend');
    await page.waitForSelector(tid('eth-send-fee'));
    await page.waitForFunction(() => !/Checking/.test(document.querySelector('[data-testid="eth-send-fee"]').textContent), null, { timeout: 30000 });
    await page.fill(tid('eth-send-to'), to);
    await page.fill(tid('eth-send-amount'), '0.001');
    await page.waitForFunction(() => document.querySelector('[data-testid="eth-send-review"]').textContent === 'Send 0.001 ETH');
    await page.click(tid('eth-send-review'));
    await page.click(tid('eth-review-send'));
    await page.fill(tid('auth-pw'), PASSWORD);
    await page.click(tid('auth-submit'));
    await waitScreen(page, 'ethTx');
    await page.waitForSelector(`${tid('eth-tx-title')}[data-state="confirmed"]`, { timeout: 60000 });
    const minedHash = await page.getAttribute(tid('eth-tx-hash'), 'data-hash');
    await outboxWrite({ hash: minedHash, patch: { state: 'rejected', receipt: null, refusedAt: Date.now() - 40 * 60000 } });
    await page.evaluate(() => window.__campfire.go('ethHome'));
    await ethHomeReady();
    await page.waitForSelector(`${tid('eth-activity-row')}[data-hash="${minedHash}"][data-state="confirmed"]`, { timeout: 30000 });

    // The history index shows another "Not sent" one in a block: the block wins, and the entry is written down.
    const shown = fake('d4');
    await outboxWrite({ add: shown });
    indexExtra.push({ blockHash: `0x${'b2'.repeat(32)}`, blockNumber: 22000100, from: ACCOUNT0.toLowerCase(), to: shown.to.toLowerCase(), gas: 21000, gasPrice: 1000000000, gasUsed: 21000, hash: shown.hash, nonce: 900, receipt: { effectiveGasPrice: 1000000000, gasUsed: 21000, logs: [], status: 1 }, timestamp: 1767225700, value: shown.amount });
    try {
      await page.evaluate(() => window.__campfire.go('ethReceive'));
      await page.evaluate(() => window.__campfire.go('ethHome'));
      await ethHomeReady();
      await page.waitForSelector(`${tid('eth-activity-row')}[data-hash="${shown.hash}"][data-state="confirmed"]`, { timeout: 30000 });
      const stored = await page.evaluate(async (h) => {
        const { app } = await import('./app.js');
        const { ethWallet } = await import('./lib/eth/wallet.js');
        const w = await ethWallet(app);
        const e = w.state.outbox.find((x) => x.hash === h);
        return e && { state: e.state, block: e.receipt && e.receipt.blockNumber };
      }, shown.hash);
      assert.deepEqual(stored, { state: 'confirmed', block: 22000100 });
      assert.equal(await page.getAttribute(`${tid('eth-activity-row')}[data-hash="${lost.hash}"]`, 'data-state'), 'rejected', 'the one nobody shows stays "Not sent"');
      await shots4('30-home-after-recheck');
    } finally {
      indexExtra.length = 0;
    }
  }));

test('BM-2: a swap "Not sent" is the server\'s word too, with Etherscan in it', { skip: skip || false, timeout: 2 * 60000 }, async () => {
  const swapLost = fake('e5', { kind: 'swap', tokenOut: WBEAM.address, tokenOutSymbol: 'WBEAM', quotedOut: '1000000000', minimumOut: '990000000', pools: 1 });
  await outboxWrite({ add: swapLost });
  await page.evaluate((h) => window.__campfire.go('ethSwapTx', { hash: h }), swapLost.hash);
  await waitScreen(page, 'ethSwapTx');
  await page.waitForSelector(`${tid('uni-tx-title')}[data-state="rejected"]`);
  assert.match(await page.textContent(tid('eth-not-sent')), /That is the server's word, not Ethereum's\..*The server said: transaction underpriced/);
  assert.equal(await page.getAttribute(tid('eth-not-sent-explorer'), 'href'), `https://etherscan.io/tx/${swapLost.hash}`);
  await shots4('33-swap-not-sent');
  await page.evaluate(() => window.__campfire.go('ethHome'));
  await ethHomeReady();
});

// Re-audit RE2-5: a verified "Replaced" is not overwritten by an index row; the index's word is shown beside it.
test('RE2-5: "Replaced" stays while only the history index lists the payment in a block; both are said', { skip: skip || false, timeout: 2 * 60000 }, async () => {
  const rep = fake('a9', { state: 'replaced', refusedAt: null, error: null, replacedBy: `0x${'aa'.repeat(32)}`, replacedIn: 21999990 });
  await outboxWrite({ add: rep });
  indexExtra.push({ blockHash: `0x${'b3'.repeat(32)}`, blockNumber: 22000200, from: ACCOUNT0.toLowerCase(), to: rep.to.toLowerCase(), gas: 21000, gasPrice: 1000000000, gasUsed: 21000, hash: rep.hash, nonce: 900, receipt: { effectiveGasPrice: 1000000000, gasUsed: 21000, logs: [], status: 1 }, timestamp: 1767225800, value: rep.amount });
  try {
    await page.evaluate(() => window.__campfire.go('ethReceive'));
    await page.evaluate(() => window.__campfire.go('ethHome'));
    await ethHomeReady();
    await page.waitForSelector(`${tid('eth-activity-row')}[data-hash="${rep.hash}"][data-state="replaced"]`, { timeout: 30000 });
    await page.click(`${tid('eth-activity-row')}[data-hash="${rep.hash}"]`);
    await waitScreen(page, 'ethTx');
    await page.waitForSelector(tid('eth-index-says'));
    assert.equal(await page.getAttribute(tid('eth-tx-title'), 'data-state'), 'replaced');
    assert.match(await page.textContent(tid('eth-index-says')), /^Stack Wallet's history index says this payment is in block 22,000,200\. Your Ethereum server showed another transaction from this wallet in its place, so it stays "Replaced" here until your server shows this payment in a block too\./);
    assert.equal(await page.isVisible(tid('eth-tx-replaced-by')), true, 'the evidence is kept');
    await sleep(1500); // its receipt asked of the server: none, so it stays as it was
    assert.equal(await page.getAttribute(tid('eth-tx-title'), 'data-state'), 'replaced');
    await shots4('37-tx-replaced-index');
    await page.click(tid('eth-tx-done'));
    await ethHomeReady();
  } finally {
    indexExtra.length = 0;
  }
});

// Re-audit RE2-2: a payment no server can settle used to pause this wallet for good. The notice names
// History when it is off and, after a day in doubt with every look failing, offers "Forget this payment".
test('RE2-2: a payment in doubt for a day can be forgotten, after a plain warning; that one only, and sending opens up', { skip: skip || false, timeout: 3 * 60000 }, () =>
  withFork(async () => {
    await setBalance(ACCOUNT0, 5n * ETHER);
    await page.evaluate(() => window.__campfire.go('ethHome'));
    await ethHomeReady();
    const day = 24 * 3600000;
    // "Not sure yet" for 25 hours, the last look a moment ago (nonce 900: nothing on the fork decides it).
    const stuck = fake('f6', { state: 'pending', sentAt: Date.now() - 25 * 3600000, refusedAt: null, error: null, unsureSince: Date.now() - 25 * 3600000, doubtLookAt: Date.now() });
    const young = fake('f7', { nonce: '901', state: 'pending', sentAt: Date.now() - 3600000, refusedAt: null, error: null, unsureSince: Date.now() - 3600000, doubtLookAt: Date.now(), createdAt: Date.now() - 2 * day });
    await outboxWrite({ add: young });
    await page.click(tid('eth-send'));
    await waitScreen(page, 'ethSend');
    await page.waitForSelector(`${tid('eth-doubt')}[data-hash="${young.hash}"]`);
    assert.equal(await page.isVisible(tid('eth-doubt-forget')), false, 'an hour in doubt: no Forget');
    // History off: the notice names it.
    await page.evaluate(async () => (await import('./app.js')).app.setPrefs({ ethHistory: false }));
    await page.evaluate(() => window.__campfire.go('ethSend'));
    await page.waitForSelector(`${tid('eth-doubt')}[data-hash="${young.hash}"]`);
    assert.match(await page.textContent(tid('eth-doubt')), /Or turn on History from Stack Wallet in Settings: it then finds what took its place, if anything did\./);
    await page.evaluate(async () => (await import('./app.js')).app.setPrefs({ ethHistory: true }));
    await outboxWrite({ hash: young.hash, patch: { state: 'confirmed', unsureSince: null, receipt: { blockNumber: 1, status: 1, gasUsed: '21000', effectiveGasPrice: '1' } } });

    // Release audit RE3-2: marks from days ago (a device that was off) never offer Forget; the look the
    // screen takes a moment after it opens does, once that look also fails. Its nonce is one nobody
    // used: this server says it is free, has never seen the payment and refuses its bytes, so the
    // look leaves it "Not sure yet" (nonce 900 was used on mainnet: a look settles that one).
    const stale = fake('f8', { nonce: '99999999', state: 'pending', sentAt: Date.now() - 4 * day, refusedAt: null, error: null, unsureSince: Date.now() - 4 * day, doubtLookAt: Date.now() - 3 * day, createdAt: Date.now() - 4 * day });
    await outboxWrite({ add: stale });
    await page.evaluate(() => window.__campfire.go('ethSend'));
    await page.waitForSelector(`${tid('eth-doubt')}[data-hash="${stale.hash}"]`);
    assert.equal(await page.getAttribute(tid('eth-doubt'), 'data-forgettable'), null, 'its last look is three days old: no Forget yet');
    await page.waitForSelector(`${tid('eth-doubt')}[data-hash="${stale.hash}"][data-forgettable="true"]`, { timeout: 60000 });
    const looked = await page.evaluate(async (h) => {
      const { app } = await import('./app.js');
      const { ethWallet } = await import('./lib/eth/wallet.js');
      return (await ethWallet(app)).state.outbox.find((e) => e.hash === h).doubtLookAt;
    }, stale.hash);
    assert.ok(Date.now() - looked < 60000, 'Forget came with a look just now');
    await outboxWrite({ hash: stale.hash, patch: { state: 'confirmed', unsureSince: null, receipt: { blockNumber: 1, status: 1, gasUsed: '21000', effectiveGasPrice: '1' } } });

    await outboxWrite({ add: stuck });
    await page.evaluate(() => window.__campfire.go('ethSend'));
    await page.waitForSelector(`${tid('eth-doubt')}[data-hash="${stuck.hash}"][data-forgettable="true"]`);
    assert.match(await page.textContent(tid('eth-doubt')), /It has been like this for over a day: you can also forget it\./);
    assert.ok(!/turn on History/.test(await page.textContent(tid('eth-doubt'))), 'History is on: not named');
    assert.equal(await page.textContent(tid('eth-doubt-forget')), 'Forget this payment');
    await shots4('34-send-forgettable');
    await page.click(tid('eth-doubt-forget'));
    await page.waitForSelector(tid('eth-forget-title'));
    assert.equal(await page.textContent(tid('eth-forget-title')), 'Forget this payment?');
    assert.equal(await page.textContent(tid('eth-forget-warning')), 'It may still go through. If it does and you send again, both go through.');
    await shots4('35-forget-sheet');
    await page.click(tid('eth-forget-keep'));
    await page.waitForSelector(tid('eth-forget-title'), { state: 'detached' });
    assert.equal(await page.isVisible(`${tid('eth-doubt')}[data-hash="${stuck.hash}"]`), true, 'kept: still in doubt');
    await page.click(tid('eth-doubt-forget'));
    await page.click(tid('eth-forget-confirm'));
    await page.waitForSelector(tid('eth-doubt'), { state: 'detached', timeout: 10000 });
    const left = await page.evaluate(async () => {
      const { app } = await import('./app.js');
      const { ethWallet } = await import('./lib/eth/wallet.js');
      return (await ethWallet(app)).state.outbox.map((e) => e.hash);
    });
    assert.ok(!left.includes(stuck.hash), 'forgotten');
    assert.ok(left.includes(young.hash), 'the other entry stays');
    await page.fill(tid('eth-send-to'), toChecksumAddress(freshAddress()));
    await page.fill(tid('eth-send-amount'), '0.001');
    await page.waitForFunction(() => document.querySelector('[data-testid="eth-send-review"]').textContent === 'Send 0.001 ETH', null, { timeout: 30000 });
    assert.equal(await page.isDisabled(tid('eth-send-review')), false, 'sending opens up again');
    await shots4('36-send-after-forget');
    await page.evaluate(() => window.__campfire.go('ethHome'));
    await ethHomeReady();
  }));

test('BM-6: a fee far above what Beam PWA pays is said as such, not as impossible; nothing is signed', { skip: skip || false, timeout: 2 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('ethHome'));
  await ethHomeReady();
  mode = 'dear';
  try {
    await page.click(tid('eth-send'));
    await waitScreen(page, 'ethSend');
    await page.waitForSelector(`${tid('eth-server-problem')}[data-code="bad_fees"]`, { timeout: 30000 });
    const said = await page.textContent(tid('eth-server-problem'));
    assert.match(said, /^The network fee is far above anything Beam PWA will pay\. Stack Wallet's Ethereum server says Ethereum is that expensive right now\. It has been, but only for minutes at a time\. Nothing was sent, and nothing was paid\./);
    assert.doesNotMatch(said, /can't be right|cannot have|gwei/);
    await shots4('31-send-fee-too-high');
  } finally {
    mode = 'fork';
  }
  await page.evaluate(() => window.__campfire.go('ethHome'));
  await ethHomeReady();
});

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

test('a words wallet: "Show private key" in Backup, behind the password', { skip: skip || false, timeout: 2 * 60000 }, async () => {
  const junk = await ethKeyFromMnemonic(JUNK);
  const junkHex = bytesToHex(junk.sk, false);
  wipe(junk.sk);
  await page.evaluate(() => window.__campfire.go('ethSettings'));
  await waitScreen(page, 'ethSettings');
  await page.waitForSelector(tid('eth-show-key'));
  assert.equal(await page.getAttribute(tid('eth-backup'), 'data-kind'), 'words');
  assert.match(await page.textContent(tid('eth-backup')), /Your Ethereum words are your backup/, 'the words backup is unchanged');
  await keyShots('01-words-backup', { focus: tid('eth-show-key') });
  await page.click(tid('eth-show-key'));
  await page.waitForSelector(tid('auth-pw'));
  assert.match(await page.textContent('.sheet h2'), /Show the private key/);
  await page.click(tid('auth-cancel'));
  assert.equal(await page.$(tid('eth-key-text')), null, 'cancelled: nothing opened');
  await page.click(tid('eth-show-key'));
  await page.fill(tid('auth-pw'), PASSWORD);
  await page.click(tid('auth-submit'));
  await page.waitForSelector(`${tid('eth-key-box')}[data-state="shown"]`);
  assert.equal(await page.textContent(tid('eth-key-text')), junkHex, 'the key of the words (m/44\'/60\'/0\'/0/0)');
  assert.match(await page.textContent(tid('eth-key-card')), /never share it/);
  await keyShots('02-words-show-private-key', { masks: [tid('eth-key-text')], focus: tid('eth-key-card') });
  await page.click(tid('eth-key-hide'));
  await page.waitForSelector(tid('eth-show-key'));
  assert.equal(await page.$(tid('eth-key-text')), null, 'hidden again');
});

test('import by private key: one box knows it is a key, shows the address first; Backup shows it behind the password; lock wipes it', { skip: skip || false, timeout: 5 * 60000 }, async () => {
  const key = randomKeyHex();
  const keyBytes = hexToBytes(key);
  const address = privateKeyToAddress(keyBytes);
  wipe(keyBytes);
  const box = tid('eth-words-input');
  const hint = tid('eth-words-hint');

  // The words wallet goes first: one Ethereum wallet per device.
  await page.click(tid('eth-remove'));
  await page.click(tid('eth-remove-confirm'));
  await page.fill(tid('auth-pw'), PASSWORD);
  await page.click(tid('auth-submit'));
  await waitScreen(page, 'settings');

  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await page.click(tid('chain-eth'));
  await waitScreen(page, 'ethStart');
  assert.equal(await page.textContent(tid('eth-import')), 'Import words or private key');
  await page.click(tid('eth-import'));
  await waitScreen(page, 'ethImport');
  await page.waitForSelector(box);
  assert.equal(await page.getAttribute(box, 'aria-label'), 'Recovery words or private key');
  assert.match(await page.textContent('label.field .banner'), /Recovery words or private key/);
  await keyShots('03-import-empty');

  // Still typing is not an error; a wrong character or length is, in words.
  await page.fill(box, `0x${key.slice(0, 63)}`);
  assert.equal(await page.textContent(hint), '63 of 64 characters so far.');
  assert.equal(await page.getAttribute(hint, 'class'), 'hint');
  assert.equal(await page.getAttribute(hint, 'data-kind'), 'key');
  assert.equal(await page.isDisabled(tid('eth-import-submit')), true);
  assert.equal(await page.isVisible(tid('eth-advanced')), false, 'no passphrase for a key');
  await keyShots('04-import-key-typing', { masks: [box] });
  await page.fill(box, `0x${key.slice(0, 63)}g`);
  assert.equal(await page.textContent(hint), "That isn't a private key: it needs 64 characters, 0–9 and a–f.");
  assert.equal(await page.getAttribute(hint, 'class'), 'hint bad');
  await keyShots('05-import-key-invalid', { masks: [box] });
  await page.fill(box, `${key}0`);
  assert.equal(await page.textContent(hint), "That isn't a private key: it needs 64 characters, 0–9 and a–f.", '65 characters');
  await page.fill(box, `0x${'0'.repeat(64)}`);
  assert.equal(await page.textContent(hint), 'That private key is not valid. Copy it again from the wallet it came from.');
  await keyShots('06-import-key-zero', { masks: [box] });
  await page.fill(box, SECP_N.toString(16));
  assert.match(await page.textContent(hint), /not valid/, 'n itself');
  assert.equal(await page.isDisabled(tid('eth-import-submit')), true);
  // Words still go the words way.
  await page.fill(box, 'abandon add face');
  assert.equal(await page.getAttribute(hint, 'data-kind'), 'words');
  assert.equal(await page.textContent(hint), '3 of 12 words so far.');
  assert.equal(await page.isVisible(tid('eth-advanced')), true);

  // Pasted as people paste: 0X, capitals, spaces around. The address it opens, before anything is saved.
  await page.fill(box, `  0X${key.toUpperCase()}\n`);
  assert.equal(await page.textContent(hint), `This opens ${address.slice(0, 6)}…${address.slice(-4)}. Check it's the account you expect.`);
  assert.equal(await page.getAttribute(hint, 'class'), 'hint good');
  assert.equal(await page.getAttribute(hint, 'data-address'), address);
  assert.equal(await page.isDisabled(tid('eth-import-submit')), false);
  assert.equal(await page.textContent(tid('eth-import-submit')), 'Import Ethereum wallet');
  assert.equal(await page.evaluate(async () => (await (await import('./lib/store.js')).store.get('eth')) ?? null), null, 'nothing saved yet');
  await keyShots('07-import-address-check', { masks: [box] });

  await page.click(tid('eth-import-submit'));
  await waitScreen(page, 'ethPrivacy');
  await page.waitForSelector(tid('eth-connect'));
  assert.match(await page.textContent('.step'), /Step 2 of 2/);
  await page.click(tid('eth-connect'));
  await ethHomeReady();
  assert.equal(await page.getAttribute(tid('eth-address'), 'data-address'), address, 'Home opens the address of the key');
  const stored = await page.evaluate(async () => JSON.stringify(await (await import('./lib/store.js')).store.get('eth')));
  const rec = JSON.parse(stored);
  assert.equal(rec.kind, 'key');
  assert.deepEqual(Object.keys(rec).sort(), ['createdAt', 'envelope', 'id', 'kind', 'v']);
  assert.ok(!stored.toLowerCase().includes(key), 'the key only inside the sealed envelope');
  assert.ok(!stored.toLowerCase().includes(address.slice(2).toLowerCase()), 'the address too');

  // Backup: the key, blurred dots until the password; then Copy and Hide.
  await page.evaluate(() => window.__campfire.go('ethSettings'));
  await waitScreen(page, 'ethSettings');
  await page.waitForSelector(tid('eth-key-reveal'));
  assert.equal(await page.getAttribute(tid('eth-backup'), 'data-kind'), 'key');
  assert.ok((await page.textContent(tid('eth-backup'))).includes(KEY_WARNING));
  assert.equal(await page.getAttribute(tid('eth-key-box'), 'data-state'), 'masked');
  assert.match(await page.textContent(tid('eth-key-text')), /^•{64}$/, 'dots under the blur, not the key');
  assert.equal(await page.$(tid('eth-show-key')), null, 'the backup is the key itself');
  await keyShots('08-key-backup-masked', { focus: tid('eth-backup') });
  await page.click(tid('eth-key-reveal'));
  await page.waitForSelector(tid('auth-pw'));
  await page.fill(tid('auth-pw'), 'not the password');
  await page.click(tid('auth-submit'));
  await page.waitForSelector('.sheet .notice.error');
  assert.equal(await page.getAttribute(tid('eth-key-box'), 'data-state'), 'masked', 'a wrong password shows nothing');
  await page.fill(tid('auth-pw'), PASSWORD);
  await page.click(tid('auth-submit'));
  await page.waitForSelector(`${tid('eth-key-box')}[data-state="shown"]`);
  assert.equal(await page.textContent(tid('eth-key-text')), key);
  await keyShots('09-key-backup-shown', { masks: [tid('eth-key-text')], focus: tid('eth-backup') });
  // Copy, without touching this machine's clipboard.
  await page.evaluate(() => {
    navigator.clipboard.writeText = async (t) => {
      window.__copied = t;
    };
  });
  await page.click(tid('eth-key-copy'));
  assert.equal(await page.evaluate(() => window.__copied === undefined ? 'none' : 'copied'), 'copied');
  assert.equal(await page.evaluate((k) => window.__copied === k, key), true, 'Copy gives the key');
  await page.evaluate(() => delete window.__copied);
  await page.waitForSelector('.toast');
  assert.equal(await page.textContent('.toast'), 'Private key copied. Beam PWA empties the clipboard in 1 minute (clipboard history apps may keep it).');
  await page.click(tid('eth-key-hide'));
  assert.equal(await page.getAttribute(tid('eth-key-box'), 'data-state'), 'masked');
  assert.match(await page.textContent(tid('eth-key-text')), /^•{64}$/);

  // Remove and Delete name the key, not words.
  await page.click(tid('eth-remove'));
  await page.waitForSelector(tid('eth-remove-confirm'));
  assert.match(await page.textContent('.sheet'), /Only its private key can bring it back/);
  await keyShots('10-key-remove-sheet');
  await page.click('.sheet .btn-text');
  await page.evaluate(() => window.__campfire.go('deleteWallet'));
  await page.waitForSelector(`${tid('delete-eth-words')}[data-kind="key"]`);
  assert.match(await page.textContent(tid('delete-eth-words')), /Its private key brings it back/);
  await keyShots('11-key-delete-wallet', { focus: tid('delete-eth-words') });

  // Shown at lock time: afterwards it is nowhere in the page.
  await page.evaluate(() => window.__campfire.go('ethSettings'));
  await page.waitForSelector(tid('eth-key-reveal'));
  await page.click(tid('eth-key-reveal'));
  await page.fill(tid('auth-pw'), PASSWORD);
  await page.click(tid('auth-submit'));
  await page.waitForSelector(`${tid('eth-key-box')}[data-state="shown"]`);
  assert.equal(await inHeap([key]), 1, 'the heap search finds the key while it is shown (so its "0" below means something)');
  await page.evaluate(() => window.__campfire.go('settings'));
  await page.click(tid('lock-now'));
  await waitScreen(page, 'unlock');
  assert.equal(await page.evaluate((k) => document.documentElement.outerHTML.toLowerCase().includes(k), key), false, 'not in the DOM');
  assert.equal(await inHeap([key, key.toUpperCase(), `0x${key}`]), 0, 'not in the JS heap');

  // Unlocking opens the same wallet; the key is blurred again.
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  await page.click(tid('chain-eth'));
  await ethHomeReady();
  assert.equal(await page.getAttribute(tid('eth-address'), 'data-address'), address);
  await page.evaluate(() => window.__campfire.go('ethSettings'));
  await page.waitForSelector(tid('eth-key-reveal'));
  assert.equal(await page.getAttribute(tid('eth-key-box'), 'data-state'), 'masked');
});

test('IP privacy: only this origin, the BEAM node and the chosen Ethereum server; no CSP violation', { skip: skip || false }, async () => {
  assert.deepEqual(foreignHosts(rec, srv.url), [`https://${STACK}`]);
  assert.deepEqual(rec.csp, []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
  assert.ok(rpcMethods.includes('eth_sendRawTransaction'));
});

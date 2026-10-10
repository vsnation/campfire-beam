// Your own BEAM node, end to end on BEAM mainnet (the installed Google Chrome,
// headless, one persistent profile). Spends nothing (a throwaway wallet).
//
//   npm run e2e:own-node
//
// The "own node" is a local TLS WebSocket relay on 127.0.0.1 that relays the
// raw WebSocket stream to eu-node01.mainnet.beam.mw:8200 (test/e2e/node_relay.mjs).
// Its certificate is self-signed, so this test - and only this test - starts
// Chrome with --ignore-certificate-errors.
//
// 1. A new wallet on random BEAM nodes reaches Synced.
// 2. Settings -> BEAM node -> Your own node: an address that hangs shows the
//    check in progress, then the failure; a dead address fails at once; neither
//    saves anything (the worker's own-node entry and prefs are unchanged).
// 3. The relay's address, pasted as wss://...: the check passes, the password
//    sheet guards the switch (cancel: nothing changes; wrong password: refused),
//    then the app reopens and reaches Synced at the explorer's height through the
//    relay. After the switch the engine opened zero connections to BEAM's nodes,
//    the pages and workers are served with exactly one extra connect-src origin,
//    and the CSP still blocks a wss connection to any other host (a canary
//    listener that would see it counts nothing).
// 4. Cold start with every BEAM pool host unresolvable: still Synced, through
//    the own node only.
// 5. The own node goes away: "Can't reach your node" with "Use random nodes";
//    no fallback by itself (no connection to BEAM's nodes). One tap and the
//    password: back on random nodes, Synced, and the own node is gone from the CSP.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { chromium } from 'playwright-core';
import { CHROME, NODE_HOSTS, startServer, recordedPage, shot, waitScreen, sleep, waitHeightNearExplorer, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced, unlockWithPassword } from './flows.mjs';
import { selfSignedCert, upstreamCa, startRelay, startCanary, startBlackhole, deadPort } from './node_relay.mjs';
import { CSP } from '../../tools/headers.mjs';

const PORT = Number(process.env.CAMPFIRE_OWN_NODE_PORT || 8796);
const RELAY_PORT = Number(process.env.CAMPFIRE_OWN_NODE_RELAY_PORT || 9643); // and the next two
const CANARY_PORT = RELAY_PORT + 1;
const HANG_PORT = RELAY_PORT + 2;
const UPSTREAM = { host: 'eu-node01.mainnet.beam.mw', port: 8200 };
const OWN = `127.0.0.1:${RELAY_PORT}`;
const PASSWORD = `own-${randomBytes(6).toString('hex')}`;
const tid = (id) => `[data-testid="${id}"]`;
const POOL_UNRESOLVABLE = NODE_HOSTS.map((n) => `MAP ${n.split(':')[0]} ~NOTFOUND`).join(', ');

let tmp, srv, relay, canary, hang, tlsCert, ca;
let ctx = null;
let page = null;
let rec = null;
const ws = []; // every WebSocket the page (and its frames) created: {url, at}

async function coldStart({ extraArgs = [] } = {}) {
  if (ctx) await ctx.close().catch(() => {});
  ctx = await chromium.launchPersistentContext(join(tmp, 'profile'), {
    executablePath: CHROME,
    headless: !process.env.HEADED,
    viewport: { width: 375, height: 667 },
    deviceScaleFactor: 2,
    colorScheme: 'light',
    ignoreHTTPSErrors: true,
    args: ['--ignore-certificate-errors', '--disable-features=AutofillServerCommunication', ...extraArgs],
  });
  for (const p of ctx.pages()) await p.close().catch(() => {});
  ({ page, rec } = await recordedPage(ctx, { label: 'own' }));
  page.on('websocket', (w) => ws.push({ url: w.url(), at: Date.now() }));
  await page.goto(srv.url);
}

/** Light and dark, 375 px. */
async function shots(name) {
  await sleep(250);
  await shot(page, `${name}-light`);
  await page.emulateMedia({ colorScheme: 'dark' });
  await sleep(150);
  await shot(page, `${name}-dark`);
  await page.emulateMedia({ colorScheme: 'light' });
}

const hostOf = (u) => new URL(u).host;
const wsSince = (t) => ws.filter((w) => w.at >= t).map((w) => hostOf(w.url));

async function loaderNode() {
  return page.evaluate(async () => {
    const r = await (await caches.open('campfire-meta')).match(new URL('__campfire_node', document.baseURI).href);
    return r ? (await r.json()).node : null;
  });
}

/** The CSP the service worker serves a page and the engine's worker with now. */
async function servedCsp() {
  return page.evaluate(async () => {
    const a = await fetch('./', { cache: 'no-store' });
    const b = await fetch('vendor/engine/wasm-client.worker.js', { cache: 'no-store' });
    return { page: a.headers.get('content-security-policy'), worker: b.headers.get('content-security-policy') };
  });
}

const connectSrc = (csp) => csp.split('; ').find((d) => d.startsWith('connect-src ')).split(' ').slice(1);

async function openOwnNodeScreen() {
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.click(tid('node-row'));
  await waitScreen(page, 'nodeSettings');
  await page.click(tid('node-own'));
  await waitScreen(page, 'ownNode');
}

before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-own-node-'));
  tlsCert = selfSignedCert(join(tmp, 'cert'));
  ca = await upstreamCa();
  relay = await startRelay({ port: RELAY_PORT, tlsCert, ca, upstream: () => UPSTREAM });
  canary = await startCanary(CANARY_PORT, tlsCert);
  hang = await startBlackhole(HANG_PORT);
  srv = await startServer({ root: 'dist', port: PORT });
  console.log(`# own node relay ${OWN} -> ${UPSTREAM.host}:${UPSTREAM.port}; screenshots: ${SHOTS}`);
});

after(async () => {
  if (ctx) await ctx.close().catch(() => {});
  for (const x of [relay, canary, hang]) if (x) await x.stop().catch(() => {});
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

test('own node: checked before saving, password-gated, the only node after the switch, CSP exact, no silent fallback', { timeout: 30 * 60000 }, async () => {
  // ---- 1. random BEAM nodes
  await coldStart();
  await waitScreen(page, 'welcome', 180000);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  const synced0 = await waitSynced(page, 5 * 60000);
  assert.equal(await page.evaluate(() => window.__campfire.nodeMode()), 'random');
  const firstNode = await page.evaluate(() => window.__campfire.node());
  assert.ok(NODE_HOSTS.includes(firstNode), `started on a pool node: ${firstNode}`);
  console.log(`# random node: Synced on ${firstNode}, height ${synced0.height}`);

  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await shots('own-01-settings');
  await page.click(tid('node-row'));
  await waitScreen(page, 'nodeSettings');
  await page.waitForFunction(() => /Connected to/.test(document.querySelector('[data-testid="node-connection"]')?.textContent || ''));
  await shots('own-02-list-random');

  // ---- 2. checks that fail save nothing
  await page.click(tid('node-own'));
  await waitScreen(page, 'ownNode');
  await shots('own-03-add-empty');
  // The owner-key line opens Show owner key, and Back comes back here.
  await page.click(tid('owner-key-link'));
  await waitScreen(page, 'ownerKey');
  await page.click('button[aria-label="Back"]');
  await waitScreen(page, 'ownNode');
  await page.fill(tid('own-node-address'), 'https://node.example.com:8200/ws');
  await shots('own-04-add-invalid');
  assert.match(await page.textContent(tid('own-node-hint')), /Leave out https:\/\//);

  await page.fill(tid('own-node-address'), `127.0.0.1:${HANG_PORT}`);
  await page.click(tid('own-node-submit'));
  await page.waitForFunction(() => /Checking the node/.test(document.querySelector('[data-testid="own-node-submit"]').textContent));
  await shots('own-05-testing');
  const tHang = Date.now();
  await page.waitForFunction(() => /Couldn't reach that node/.test(document.querySelector('[data-testid="own-node-msg"]').textContent), null, { timeout: 20000 });
  console.log(`# hanging address: failure shown after ${Date.now() - tHang} ms`);
  await shots('own-06-failed-timeout');
  assert.match(await page.textContent(tid('own-node-msg')), /It needs a secure connection \(wss\) with a valid certificate\..*Nothing was saved/);

  const dead = await deadPort();
  await page.fill(tid('own-node-address'), `127.0.0.1:${dead}`);
  const tDead = Date.now();
  await page.click(tid('own-node-submit'));
  await page.waitForFunction(() => /Couldn't reach that node/.test(document.querySelector('[data-testid="own-node-msg"]').textContent) && !document.querySelector('[data-testid="own-node-submit"]').disabled, null, { timeout: 20000 });
  console.log(`# dead address: failure shown after ${Date.now() - tDead} ms`);
  await shots('own-07-failed-dead');
  assert.equal(await loaderNode(), null, 'a failed check saves nothing in the worker');
  assert.equal(await page.evaluate(() => window.__campfire.nodeMode()), 'random', 'and the wallet stays on random nodes');
  assert.equal(relay.total, 0, 'nothing reached the relay yet');

  // ---- 3. the relay: check, password gate, switch
  await page.fill(tid('own-node-address'), `wss://${OWN}/`);
  await page.click(tid('own-node-key')); // the person says the node has the owner key (it does not: the engine will say so)
  await page.click(tid('own-node-submit'));
  await page.waitForSelector(tid('auth-pw'), { timeout: 20000 });
  assert.equal(await page.inputValue(tid('own-node-address')), OWN, 'the pasted wss:// address is written as host:port');
  await shots('own-08-password');
  await page.click(tid('auth-cancel'));
  await page.waitForFunction(() => /Nothing was changed/.test(document.querySelector('[data-testid="own-node-msg"]').textContent));
  assert.equal(await loaderNode(), null, 'cancelled: nothing saved');
  await page.click(tid('own-node-submit'));
  await page.waitForSelector(tid('auth-pw'), { timeout: 20000 });
  await page.fill(tid('auth-pw'), `${PASSWORD}-wrong`);
  await page.click(tid('auth-submit'));
  await page.waitForFunction(() => /didn't match/.test(document.querySelector('.sheet')?.textContent || ''));
  await shots('own-09-password-wrong');
  assert.equal(await loaderNode(), null, 'wrong password: nothing saved');
  assert.equal(relay.total, 2, 'two checks reached the relay (one per tap)');
  await page.fill(tid('auth-pw'), PASSWORD);
  const tSwitch = Date.now();
  await page.click(tid('auth-submit'));
  await waitScreen(page, 'unlock', 60000);
  await page.waitForFunction(() => /Unlock to connect through your node/.test(document.body.textContent), null, { timeout: 30000 });
  await shots('own-10-unlock-note');
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  const synced1 = await waitSynced(page, 5 * 60000);
  const near = await waitHeightNearExplorer(page, srv.url);
  assert.equal(await page.evaluate(() => window.__campfire.node()), OWN);
  assert.equal(await page.evaluate(() => window.__campfire.nodeMode()), 'own');
  assert.equal(await page.evaluate(() => window.__campfire.inSync()), true);
  console.log(`# own node: Synced through the relay in ${Date.now() - tSwitch} ms after the switch (incl. unlock); height ${near.height}, explorer ${near.explorer}`);
  const after1 = wsSince(tSwitch);
  assert.ok(after1.length >= 1 && after1.every((h) => h === OWN), `after the switch only the own node: ${JSON.stringify(after1)}`);
  assert.equal(after1.filter((h) => NODE_HOSTS.includes(h)).length, 0, 'zero connections to BEAM pool nodes after the switch');
  assert.deepEqual(await page.evaluate(() => window.__campfire.guard().blocked), {}, 'the engine tried no other node');
  console.log(`# relay connections: ${relay.total} (2 checks + ${relay.total - 2} engine); page WebSockets after the switch: ${after1.length}, all to ${OWN}`);

  // Served policy: exactly one extra wss origin, for pages and workers.
  const csp1 = await servedCsp();
  for (const which of ['page', 'worker']) {
    const extra = connectSrc(csp1[which]).filter((s) => !connectSrc(CSP).includes(s));
    assert.deepEqual(extra, [`wss://${OWN}`], `${which}: exactly the own node added`);
    assert.equal(csp1[which].split('; ').filter((d) => !d.startsWith('connect-src')).join('; '), CSP.split('; ').filter((d) => !d.startsWith('connect-src')).join('; '), `${which}: every other directive unchanged`);
  }
  assert.equal(await loaderNode(), OWN);

  // The CSP still blocks every other host: the canary would count any connection.
  const blocked = await page.evaluate(async (port) => {
    const Native = Object.getPrototypeOf(window.WebSocket); // past the node guard, straight to the browser
    const out = [];
    for (const u of [`wss://localhost:${port}/`, `wss://127.0.0.1:${port}/`]) {
      try {
        const s = new Native(u);
        out.push(await new Promise((r) => {
          s.onopen = () => r(`${u} opened`);
          s.onerror = () => r(`${u} error`);
          setTimeout(() => r(`${u} pending`), 3000);
        }));
      } catch (e) {
        out.push(`${u} threw ${e.name}`);
      }
    }
    return { out, violations: window.__cspViolations.slice() };
  }, CANARY_PORT);
  await sleep(1500);
  console.log(`# CSP: ${JSON.stringify(blocked.out)}; canary TCP connections: ${canary.tcp}`);
  assert.equal(canary.tcp, 0, 'no connection reached the canary');
  assert.ok(blocked.violations.filter((v) => v.startsWith('connect-src') && v.includes(`:${CANARY_PORT}`)).length >= 2, `CSP violations reported: ${JSON.stringify(blocked.violations)}`);
  assert.ok(!blocked.out.some((o) => o.endsWith('opened')));

  // In use: the node screen in words (the relay's node has no owner key, and the engine says so).
  await page.evaluate(() => window.__campfire.go('nodeSettings'));
  await waitScreen(page, 'nodeSettings');
  await page.waitForFunction(() => /Connected to your node/.test(document.querySelector('[data-testid="node-connection"]')?.textContent || ''));
  await page.waitForFunction(() => /doesn't know this wallet's owner key/.test(document.querySelector('[data-testid="node-key-status"]')?.textContent || ''), null, { timeout: 30000 });
  assert.equal(await page.evaluate(() => window.__campfire.ownNodeConfirmed()), false, 'the engine reports no owner key on this node');
  await shots('own-11-in-use');
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await shots('own-12-home-synced');

  // ---- 4. BEAM's pool unresolvable: the own node alone keeps the wallet working
  const tCold = Date.now();
  await coldStart({ extraArgs: [`--host-resolver-rules=${POOL_UNRESOLVABLE}`] });
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  await waitSynced(page, 5 * 60000);
  const near2 = await waitHeightNearExplorer(page, srv.url);
  const after2 = wsSince(tCold);
  assert.ok(after2.length >= 1 && after2.every((h) => h === OWN), JSON.stringify(after2));
  console.log(`# cold start, every pool host unresolvable: Synced through the own node, height ${near2.height}, explorer ${near2.explorer}`);

  // ---- 5. the own node goes away: said plainly, no fallback, one tap back
  const tDown = Date.now();
  await relay.stop();
  await page.waitForFunction(() => window.__campfire.sync().state === 'offline', null, { timeout: 90000, polling: 500 });
  await page.waitForSelector(tid('home-use-random'));
  console.log(`# own node stopped: "Can't reach your node" after ${Date.now() - tDown} ms`);
  await shots('own-13-home-own-unreachable');
  await sleep(20000);
  const down = wsSince(tDown);
  assert.equal(down.filter((h) => h !== OWN).length, 0, `no fallback to other nodes: ${JSON.stringify(down)}`);
  await page.evaluate(() => window.__campfire.go('nodeSettings'));
  await waitScreen(page, 'nodeSettings');
  await page.waitForSelector(tid('node-use-random'));
  await shots('own-14-in-use-unreachable');
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  // Back in a browser that can resolve BEAM's nodes.
  await coldStart();
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  await page.waitForSelector(tid('home-use-random'), { timeout: 90000 });
  const tBack = Date.now();
  await page.click(tid('home-use-random'));
  await page.waitForSelector(tid('auth-pw'));
  await page.fill(tid('auth-pw'), PASSWORD);
  await page.click(tid('auth-submit'));
  await page.waitForFunction(() => window.__campfire.nodeMode() === 'random', null, { timeout: 60000 });
  const synced3 = await waitSynced(page, 5 * 60000);
  const back = await page.evaluate(() => window.__campfire.node());
  assert.ok(NODE_HOSTS.includes(back));
  assert.equal(await loaderNode(), null, 'the own node is gone from the worker');
  const csp3 = await servedCsp();
  assert.equal(csp3.page, CSP, 'served CSP is the static one again');
  assert.equal(csp3.worker, CSP);
  const back3 = wsSince(tBack);
  assert.ok(back3.every((h) => NODE_HOSTS.includes(h)), JSON.stringify(back3));
  console.log(`# back to random nodes: Synced on ${back} in ${Date.now() - tBack} ms (height ${synced3.height}); served CSP is the static one`);
  await page.evaluate(() => window.__campfire.go('nodeSettings'));
  await waitScreen(page, 'nodeSettings');
  await page.waitForFunction(() => /Connected to/.test(document.querySelector('[data-testid="node-connection"]')?.textContent || ''));
  await shots('own-15-list-random-again');
  assert.deepEqual(rec.errors, [], 'no page errors');
});

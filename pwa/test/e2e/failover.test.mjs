// Random node failover, end to end on BEAM mainnet (the installed Google
// Chrome, headless). Spends nothing (a throwaway wallet). Nothing in the app is
// changed for the test: the shipped pool and CSP are used as they are.
//
//   npm run e2e:failover
//
// Chrome maps every pool host name to 127.0.0.1 (--host-resolver-rules), where
// one TLS relay (test/e2e/node_relay.mjs, self-signed, so this test starts
// Chrome with --ignore-certificate-errors) sees which node the app asked for
// (TLS SNI) and either relays to that real BEAM node or plays a broken one.
// The app always starts on one of eu-node02/03/04, so making those three bad
// means it must move past all three, whichever it picked first.
//
// 1. eu-node02/03/04 refuse connections: a new wallet moves on by itself
//    ("Reconnecting to another node…"), reaches eu-nodes and Synced at the
//    explorer's height; eu-node01 (last in the order) is never needed.
// 2. eu-node02/03/04 accept the WebSocket and then say nothing: after unlock
//    the wallet moves past each silent node and reaches Synced.
// The time from start to Synced and each hop are printed.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { chromium } from 'playwright-core';
import { CHROME, NODE_HOSTS, startServer, recordedPage, shot, waitScreen, sleep, waitHeightNearExplorer, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced, unlockWithPassword, lock } from './flows.mjs';
import { selfSignedCert, upstreamCa, startRelay } from './node_relay.mjs';

const PORT = Number(process.env.CAMPFIRE_FAILOVER_PORT || 8806);
const RELAY_PORT = 8200; // the pool's port: the mapped names land here
const PASSWORD = `fo-${randomBytes(6).toString('hex')}`;
const BAD = ['eu-node02.mainnet.beam.mw', 'eu-node03.mainnet.beam.mw', 'eu-node04.mainnet.beam.mw'];
const MAP = NODE_HOSTS.map((n) => `MAP ${n.split(':')[0]} 127.0.0.1`).join(', ');

let tmp, srv, relay;
let mode = 'refuse';
let ctx = null;
let page = null;
let rec = null;

async function shots(name) {
  await shot(page, `${name}-light`);
  await page.emulateMedia({ colorScheme: 'dark' });
  await sleep(120);
  await shot(page, `${name}-dark`);
  await page.emulateMedia({ colorScheme: 'light' });
}

const hops = () => page.evaluate(() => window.__campfire.nodeSwitches());

function printHops(label, list, t0) {
  for (const h of list) console.log(`#   ${label}: +${((h.at - t0) / 1000).toFixed(1)} s  ${h.from.split('.')[0]} ${h.reason} -> ${h.to.split('.')[0]}`);
}

before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-failover-'));
  const tlsCert = selfSignedCert(join(tmp, 'cert'));
  const ca = await upstreamCa();
  relay = await startRelay({
    port: RELAY_PORT,
    tlsCert,
    ca,
    behaviour: (name) => (BAD.includes(name) ? mode : 'forward'),
    upstream: (name) => ({ host: name, port: 8200 }),
  });
  srv = await startServer({ root: 'dist', port: PORT });
  ctx = await chromium.launchPersistentContext(join(tmp, 'profile'), {
    executablePath: CHROME,
    headless: !process.env.HEADED,
    viewport: { width: 375, height: 667 },
    deviceScaleFactor: 2,
    colorScheme: 'light',
    ignoreHTTPSErrors: true,
    args: [`--host-resolver-rules=${MAP}`, '--ignore-certificate-errors', '--disable-features=AutofillServerCommunication'],
  });
  for (const p of ctx.pages()) await p.close().catch(() => {});
  ({ page, rec } = await recordedPage(ctx, { label: 'failover' }));
  await page.goto(srv.url);
  console.log(`# pool mapped to the relay on 127.0.0.1:${RELAY_PORT}; screenshots: ${SHOTS}`);
});

after(async () => {
  if (ctx) await ctx.close().catch(() => {});
  if (relay) await relay.stop().catch(() => {});
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

test('failover: three pool nodes refuse connections; the wallet moves on by itself and reaches Synced', { timeout: 15 * 60000 }, async () => {
  mode = 'refuse';
  await waitScreen(page, 'welcome', 180000);
  const t0 = Date.now();
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  // The sync line while it moves: "Reconnecting to another node…".
  await page.waitForFunction(() => window.__campfire.sync().reconnecting === true, null, { timeout: 60000, polling: 100 });
  assert.match(await page.textContent('[data-testid="sync"]'), /Reconnecting to another node…/);
  await shots('failover-01-home-reconnecting');
  await waitSynced(page, 5 * 60000);
  const tSynced = Date.now();
  const near = await waitHeightNearExplorer(page, srv.url);
  const list = await hops();
  const node = await page.evaluate(() => window.__campfire.node());
  printHops('refuse', list, t0);
  console.log(`# refuse: Synced on ${node} ${((tSynced - t0) / 1000).toFixed(1)} s after Connect, ${list.length} hops; height ${near.height}, explorer ${near.explorer}`);
  console.log(`# relay connections by name: ${JSON.stringify(Object.fromEntries(relay.counts))}`);
  assert.equal(node, 'eu-nodes.mainnet.beam.mw:8200', 'past the three refusing nodes, on eu-nodes');
  assert.equal(list.length, 3);
  assert.deepEqual(list.map((h) => h.reason), ['unreachable', 'unreachable', 'unreachable']);
  assert.deepEqual([...new Set(list.map((h) => h.from.split(':')[0]))].sort(), [...BAD].sort(), 'each refusing node tried once');
  for (const b of BAD) assert.ok(relay.counts.get(b) >= 1, `${b} was tried`);
  assert.equal(relay.counts.get('eu-node01.mainnet.beam.mw') || 0, 0, 'eu-node01 (last) never needed');
  const hosts = [...new Set(rec.websockets.map((u) => new URL(u).host))];
  assert.ok(hosts.every((h) => NODE_HOSTS.includes(h)), `only pool nodes: ${hosts}`);
  await shots('failover-02-home-synced-after-failover');
});

test('failover: three pool nodes accept and then say nothing; the wallet moves past each and reaches Synced', { timeout: 20 * 60000 }, async () => {
  mode = 'silent';
  await lock(page);
  relay.counts.clear();
  const t0 = Date.now();
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  await waitSynced(page, 10 * 60000);
  const tSynced = Date.now();
  const near = await waitHeightNearExplorer(page, srv.url);
  const list = await hops();
  const node = await page.evaluate(() => window.__campfire.node());
  printHops('silent', list, t0);
  console.log(`# silent: Synced on ${node} ${((tSynced - t0) / 1000).toFixed(1)} s after unlock, ${list.length} hops; height ${near.height}, explorer ${near.explorer}`);
  console.log(`# relay connections by name: ${JSON.stringify(Object.fromEntries(relay.counts))}`);
  assert.equal(node, 'eu-nodes.mainnet.beam.mw:8200');
  assert.equal(list.length, 3);
  assert.deepEqual(list.map((h) => h.reason), ['silent', 'silent', 'silent']);
  assert.equal(relay.counts.get('eu-node01.mainnet.beam.mw') || 0, 0);
  assert.deepEqual(rec.errors, [], 'no page errors');
});

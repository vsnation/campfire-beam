// BEAM's DApp Store, end to end: the installed Google Chrome (headless), its own build and port,
// BEAM mainnet, a throwaway wallet that holds nothing. The store is read from the chain for real; the
// copy of the store's packages next to the app is a folder beside the build holding the store's real
// "Test N1" package (and, for one test, a changed copy). Nothing is signed or sent.
//
//   npm run e2e:dapp-store   (own build folder and port 8830)
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, copyFileSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen, shot, sleep, foreignHosts, PWA, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';

const PORT = 8830;
const tid = (id) => `[data-testid="${id}"]`;
const TEST_N1 = 'QmY2xgq85jf6AywaKXTxowiH5GJbN3bHgoGuUtmcEKoC2z'; // "Test N1" by ABRAKADABRA
const FIXTURE = join(PWA, 'test', 'fixtures', 'store-test-n1.dapp');

let tmp, dist, srv, browser, ctx, page, rec;

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-store-'));
  dist = join(tmp, 'dist');
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', dist, '--quiet'], { cwd: PWA });
  mkdirSync(join(dist, 'dapp-store'));
  copyFileSync(FIXTURE, join(dist, 'dapp-store', `${TEST_N1}.dapp`));
  srv = await startServer({ root: dist, port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  ({ page, rec } = await recordedPage(ctx, { label: 'store' }));
  console.log(`# screenshots: ${SHOTS}`);
});

test.after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

async function both(name) {
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(250);
    await shot(page, `${name}-${scheme}`);
  }
  await page.emulateMedia({ colorScheme: 'light' });
}

const names = () => page.$$eval(`${tid('store-results')} ${tid('store-row')}`, (els) => els.map((e) => e.dataset.name));

test('dApps -> DApp Store: read from the chain, every listed dApp with its publisher', { timeout: 15 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: `store-${Math.random().toString(36).slice(2, 10)}` });
  await waitHome(page);
  await waitSynced(page);
  await page.click(tid('open-dapps'));
  await waitScreen(page, 'dapps');
  await page.locator(tid('dapp-store-entry')).scrollIntoViewIfNeeded();
  await page.click(tid('dapp-store-entry'));
  await waitScreen(page, 'dappStore');
  await page.waitForSelector(tid('store-results'), { timeout: 120000 });
  const all = await names();
  console.log(`# store: ${all.length} dApps`);
  assert.ok(all.length >= 21, `${all.length} dApps`);
  assert.ok(all.includes('Nephrite application') && all.includes('BEAM Explorer'));
  const n1 = page.locator(`${tid('store-row')}[data-name="Test N1"]`).first();
  assert.match(await n1.textContent(), /by (ABRAKADABRA|Teeest)/);
  assert.ok((await page.$$(tid('store-row-flag'))).length >= 2, 'the two "Test N1" from different publishers are marked');
  // The first dApp is on screen at 375x667.
  await page.setViewportSize({ width: 375, height: 667 });
  const box = await page.locator(tid('store-row')).first().boundingBox();
  assert.ok(box && box.y + box.height <= 667, 'the first dApp fits a small phone');
  await page.setViewportSize({ width: 390, height: 844 });
  await both('store-01-list');
});

test('search and categories narrow the list; a search with no match says so and offers the way back', { timeout: 2 * 60000 }, async () => {
  await page.fill(tid('store-search'), 'nephrite');
  await page.waitForFunction(() => document.querySelectorAll('[data-testid="store-row"]').length <= 3);
  assert.ok((await names()).every((n) => /nephrite/i.test(n)));
  await page.fill(tid('store-search'), 'zzzz-nothing');
  await page.waitForSelector(tid('store-empty'));
  await page.click(tid('store-clear'));
  await page.waitForSelector(tid('store-results'));
  await page.click(tid('store-cat-2'));
  await page.waitForFunction(() => document.querySelector('[data-testid="store-cat-2"]').getAttribute('aria-checked') === 'true');
  const finance = await page.evaluate(async () => {
    const { storeData } = await import('./screens/dapp_store.js');
    const s = await storeData();
    return s.dapps.filter((d) => d.category === 2).map((d) => d.name).sort();
  });
  assert.deepEqual([...new Set(await names())].sort(), [...new Set(finance)].sort(), 'exactly the Finance dApps');
  await page.click(tid('store-cat-all'));
});

test("a publisher's page: who they are, their key, their dApps; hidden, their dApps leave the store", { timeout: 3 * 60000 }, async () => {
  await page.click(`${tid('store-row')}[data-name="BEAM Explorer"]`);
  await waitScreen(page, 'dappStoreItem');
  await page.waitForSelector(tid('store-item-cta'));
  await page.click(tid('store-item-publisher'));
  await waitScreen(page, 'dappPublisher');
  await page.waitForSelector(tid('publisher-name'));
  assert.equal(await page.textContent(tid('publisher-name')), 'Beam Community');
  assert.equal((await page.$$(tid('publisher-dapp'))).length, 3);
  assert.match(await page.textContent(tid('publisher-key')), /^[0-9a-f]{8}…[0-9a-f]{6}$/);
  await both('store-02-publisher');
  await page.click(tid('publisher-hide'));
  await page.waitForFunction(() => /Show this publisher/.test(document.querySelector('[data-testid="publisher-hide"]').textContent));
  await page.evaluate(() => window.__campfire.go('dappStore'));
  await page.waitForSelector(tid('store-results'));
  const left = await names();
  assert.ok(!left.includes('BEAM Explorer') && !left.includes('BeamScreener'), 'hidden from the store');
  assert.match(await page.textContent(tid('store-publishers')), /1 hidden/);
  await page.click(tid('store-publishers'));
  await waitScreen(page, 'dappPublishers');
  await page.waitForSelector(tid('publishers-list'));
  await both('store-02b-publishers');
  const box = await page.locator(tid('publishers-open')).first().boundingBox();
  const row = await page.locator(`${tid('publishers-list')} .row`).first().boundingBox();
  assert.ok(box && row && box.x - row.x < 40, 'the name starts at the row, as a row reads');
  const sw = page.locator(`${tid('publishers-switch')}:not(:checked)`);
  assert.equal(await sw.count(), 1);
  await sw.click();
  // Saved (the switch writes the preference), then the store.
  // (page.waitForFunction takes an async function's promise as a yes: poll here.)
  for (let i = 0; i < 50; i++) {
    const n = await page.evaluate(async () => {
      const { getPrefs } = await import('./lib/store.js');
      return ((await getPrefs()).hiddenPublishers || []).length;
    });
    if (n === 0) break;
    await sleep(200);
  }
  await page.evaluate(() => window.__campfire.go('dappStore'));
  await page.waitForSelector(tid('store-results'));
  assert.ok((await names()).includes('BEAM Explorer'), 'shown again');
});

test("install: the copy next to the app, checked against the publisher's on-chain hash, then it opens", { timeout: 5 * 60000 }, async () => {
  await page.evaluate(async (cid) => {
    const { storeData } = await import('./screens/dapp_store.js');
    const s = await storeData();
    const d = s.dapps.find((x) => x.cid === cid);
    window.__campfire.go('dappStoreItem', { id: d.id });
  }, TEST_N1);
  await waitScreen(page, 'dappStoreItem');
  await page.waitForSelector(tid('store-item-cta'));
  assert.equal(await page.textContent(tid('store-item-name')), 'Test N1');
  assert.equal(await page.textContent(tid('store-item-publisher')), 'by ABRAKADABRA');
  assert.ok((await page.$$(tid('store-item-flag'))).length >= 1, 'another publisher lists a "Test N1"');
  assert.match(await page.textContent(tid('store-item-note')), /exactly the file ABRAKADABRA recorded on the chain/);
  await both('store-03-item');
  // A changed copy is refused, and nothing is installed.
  writeFileSync(join(dist, 'dapp-store', `${TEST_N1}.dapp`), Buffer.concat([readFileSync(FIXTURE).subarray(0, 100), Buffer.from([readFileSync(FIXTURE)[100] ^ 1]), readFileSync(FIXTURE).subarray(101)]));
  await page.click(tid('store-item-cta'));
  await page.waitForFunction(() => /is not the file its publisher listed/.test(document.querySelector('[data-testid="store-item-msg"]')?.textContent || ''), null, { timeout: 60000 });
  assert.equal(await page.evaluate(async () => (await (await import('./lib/dapps/installed.js')).installed.list()).length), 0);
  // The real copy: installed and opened.
  copyFileSync(FIXTURE, join(dist, 'dapp-store', `${TEST_N1}.dapp`));
  await page.click(tid('store-item-cta'));
  await waitScreen(page, 'dapps', 60000);
  const list = await page.evaluate(async () => (await (await import('./lib/dapps/installed.js')).installed.list()).map((r) => ({ name: r.name, store: r.store })));
  assert.equal(list.length, 1);
  assert.equal(list[0].name, 'Test N1');
  assert.equal(list[0].store.cid, 'QmY2xgq85jf6AywaKXTxowiH5GJbN3bHgoGuUtmcEKoC2z');
  assert.equal(list[0].store.publisherName, 'ABRAKADABRA');
  await page.waitForSelector(tid('dapp-layer'), { timeout: 60000 });
  await shot(page, 'store-04-opened');
});

test('not in the copy: said plainly, with a way on (its .dapp file)', { timeout: 3 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('dappStore'));
  await page.waitForSelector(tid('store-results'));
  await page.click(`${tid('store-row')}[data-name="Nephrite application"]`);
  await waitScreen(page, 'dappStoreItem');
  await page.waitForSelector(tid('store-item-cta'));
  await page.click(tid('store-item-cta'));
  await page.waitForFunction(() => /isn't in Beam PWA's copy of the store yet/.test(document.querySelector('[data-testid="store-item-msg"]')?.textContent || ''), null, { timeout: 60000 });
  assert.equal(await page.isVisible(tid('store-item-from-file')), true);
  await both('store-05-not-mirrored');
});

test('the copy is handed over as data only: never as a page, nothing else under its folder', async () => {
  const nav = await ctx.newPage();
  const r = await nav.goto(`${srv.url}dapp-store/${TEST_N1}.dapp`).catch((e) => e);
  assert.ok(!r || r.status === undefined || r.status() === 404, 'a navigation to a package gets a 404');
  const other = await page.evaluate(async () => (await fetch('dapp-store/index.html')).status);
  assert.equal(other, 404);
  const ok = await page.evaluate(async (cid) => {
    const r = await fetch(`dapp-store/${cid}.dapp`);
    return { status: r.status, type: r.headers.get('content-type'), csp: r.headers.get('content-security-policy') };
  }, TEST_N1);
  assert.deepEqual(ok, { status: 200, type: 'application/octet-stream', csp: "default-src 'none'; sandbox" });
  await nav.close();
});

test('privacy: no host but the origin and BEAM nodes; no CSP violation; no page error', async () => {
  assert.deepEqual(foreignHosts(rec, srv.url), []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
});

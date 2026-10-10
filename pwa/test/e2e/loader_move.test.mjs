// An Update that brings a new loader, from the published 0.1.8 to this tree,
// on a Pages-like host, then Buy BEAM against the real buybeam.my in the same
// session. A page keeps the headers (CSP) of the loader that served it, so
// until the page is loaded again under the new loader, hosts this release
// added are refused; 0.1.8's loader names only the BEAM nodes.
//
// 1. The usual move: after Update the page reloads into the new loader by
//    itself while still locked; unlock, Buy reaches buybeam.my.
// 2. The new loader cannot be fetched at first (a phone that closed the app,
//    or the address hiccuped): Home says one step is left and Buy says to
//    finish the update; once the loader can be fetched, "Finish now" moves the
//    page and Buy works.
//
// The 0.1.8 release comes from its GitHub release, checked against its
// SHA256SUMS. Mainnet: throwaway wallets, no funds.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createHash, randomBytes } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, symlinkSync, unlinkSync, mkdirSync } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, normalize, sep } from 'node:path';
import { PWA, launch, waitScreen, sleep, shot } from './harness.mjs';
import { createWallet, waitHome, unlockWithPassword } from './flows.mjs';
import { mimeFor } from '../../tools/headers.mjs';

const PORT = Number(process.env.CAMPFIRE_LOADER_MOVE_PORT || 8789);
const BASE = '/beam-campfire-pwa/';
const URL_ = `http://127.0.0.1:${PORT}${BASE}`;
const PREV = 'https://github.com/vsnation/campfire-beam/releases/download/web-v0.1.8/';
const tid = (id) => `[data-testid="${id}"]`;
const pkg = JSON.parse(readFileSync(join(PWA, 'package.json'), 'utf8'));

let tmp, old, next, live, newLoader, oldLoader, server, browser;
let blockNewLoader = false;
const loaderFetches = [];

function point(dir) {
  try {
    unlinkSync(live);
  } catch {
    /* first */
  }
  symlinkSync(dir, live);
}

before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-loader-move-'));
  const sums = await (await fetch(`${PREV}SHA256SUMS.txt`)).text();
  const zipBytes = Buffer.from(await (await fetch(`${PREV}beam-campfire-web-0.1.8.zip`)).arrayBuffer());
  const want = sums.split('\n').find((l) => l.endsWith(' beam-campfire-web-0.1.8.zip')).split(/\s+/)[0];
  assert.equal(createHash('sha256').update(zipBytes).digest('hex'), want, 'the 0.1.8 zip matches its release SHA256SUMS');
  mkdirSync(join(tmp, 'zip'));
  writeFileSync(join(tmp, 'zip', 'web.zip'), zipBytes);
  old = join(tmp, 'old');
  execFileSync('unzip', ['-q', join(tmp, 'zip', 'web.zip'), '-d', old]);
  next = join(tmp, 'next');
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', next, '--version', pkg.version, '--quiet'], { cwd: PWA });
  const loaderOf = (dir) => readFileSync(join(dir, 'lib', 'version.js'), 'utf8').match(/LOADER = "(sw-[0-9a-f]+\.js)"/)[1];
  oldLoader = loaderOf(old);
  newLoader = loaderOf(next);
  assert.notEqual(oldLoader, newLoader, 'this tree brings a new loader');
  live = join(tmp, 'live');
  server = http.createServer(async (req, res) => {
    const path = new URL(req.url, 'http://x').pathname;
    if (path.endsWith(`/${newLoader}`)) {
      loaderFetches.push(blockNewLoader ? 'refused' : 'served');
      if (blockNewLoader) {
        res.writeHead(503, { 'Content-Type': 'text/plain' });
        return res.end('busy');
      }
    }
    if (!path.startsWith(BASE)) {
      res.writeHead(404);
      return res.end();
    }
    let rp = decodeURIComponent(path.slice(BASE.length));
    if (rp === '' || rp.endsWith('/')) rp += 'index.html';
    const root = live;
    const full = normalize(join(root, rp));
    if (!full.startsWith(root + sep)) {
      res.writeHead(403);
      return res.end();
    }
    try {
      if (!(await stat(full)).isFile()) throw new Error('dir');
      res.writeHead(200, { 'Content-Type': mimeFor(full), 'Cache-Control': 'max-age=600' });
      res.end(await readFile(full));
    } catch {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('not found');
    }
  });
  await new Promise((r) => server.listen(PORT, '127.0.0.1', r));
  browser = await launch();
  console.log(`# 0.1.8 (${oldLoader}) -> ${pkg.version} (${newLoader}) on ${URL_}`);
});

after(async () => {
  if (browser) await browser.close().catch(() => {});
  if (server) await new Promise((r) => server.close(r));
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

/** 0.1.8 installed with a wallet, then Check for updates -> Update to this tree. Returns {page, password}. */
async function installOldThenUpdate(label, { refuseLoaderAfterCheck = false } = {}) {
  point(old);
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  await page.goto(URL_);
  for (let i = 0; i < 120; i++) {
    if ((await page.evaluate(() => window.__campfire && window.__campfire.screen()).catch(() => null)) === 'welcome') break;
    await sleep(1000);
  }
  const password = `move-${randomBytes(6).toString('hex')}`;
  await createWallet(page, { password });
  await waitHome(page, { timeout: 5 * 60000 });
  point(next);
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.click(tid('check-updates'));
  try {
    await page.waitForSelector(tid('update-apply-sheet'), { timeout: 120000 });
  } catch (e) {
    console.log(`# no Update offered; screen: ${(await page.evaluate(() => document.body.innerText)).slice(0, 400).replace(/\n/g, ' / ')}; loader fetches ${JSON.stringify(loaderFetches)}`);
    throw e;
  }
  // The update is downloaded and verified; from here the new loader cannot be fetched.
  if (refuseLoaderAfterCheck) blockNewLoader = true;
  await Promise.all([page.waitForEvent('load', { timeout: 60000 }), page.click(tid('update-apply-sheet'))]);
  await shot(page, `${label}-after-update`);
  return { page, password };
}

const controller = (page) => page.evaluate(() => (navigator.serviceWorker.controller ? navigator.serviceWorker.controller.scriptURL.split('/').pop() : null));

async function buyReachesBuybeam(page, label) {
  await page.evaluate(() => window.__campfire.go('buyBeam'));
  await waitScreen(page, 'buyBeam', 30000);
  await page.waitForFunction(() => {
    const b = document.querySelector('[data-testid="buy-coin"]');
    return b && b.textContent.trim() && !/…|Choose/.test(b.textContent);
  }, null, { timeout: 60000 });
  assert.equal(await page.isVisible(tid('buy-assets-why')), false);
  await shot(page, `${label}-buy`);
}

test('after Update the page reloads into the new loader while locked; Buy reaches buybeam.my in the same session', { timeout: 15 * 60000 }, async () => {
  blockNewLoader = false;
  const { page, password } = await installOldThenUpdate('loader-move');
  // The page that came back from Update runs under 0.1.8's loader; once the new
  // one takes over, the still-locked page loads again under it by itself.
  await page.waitForFunction(() => window.__campfire && window.__campfire.loaderBehind() === false, null, { timeout: 60000 });
  assert.equal(await controller(page), newLoader);
  assert.equal(await page.evaluate(() => window.__campfire.intrusion()), null, 'the move is not a takeover');
  await unlockWithPassword(page, password);
  await waitScreen(page, 'home', 60000);
  await sleep(11000);
  assert.equal(await page.isVisible(tid('update-finishing')), false, 'nothing left to finish');
  await buyReachesBuybeam(page, 'loader-move');
  await page.context().close();
});

test('the new loader unreachable at first: Home and Buy say one step is left; "Finish now" moves the page and Buy works', { timeout: 15 * 60000 }, async () => {
  blockNewLoader = false;
  const { page, password } = await installOldThenUpdate('loader-stuck', { refuseLoaderAfterCheck: true });
  await waitScreen(page, 'unlock', 60000);
  await sleep(5000);
  assert.equal(await controller(page), oldLoader, 'the older loader still serves');
  await unlockWithPassword(page, password);
  await waitScreen(page, 'home', 60000);
  await page.waitForSelector(tid('update-finishing'), { timeout: 30000 });
  await shot(page, 'loader-stuck-home');
  await page.evaluate(() => window.__campfire.go('buyBeam'));
  await waitScreen(page, 'buyBeam', 30000);
  await page.waitForSelector(tid('buy-update-finish'), { timeout: 90000 });
  await shot(page, 'loader-stuck-buy');
  assert.ok(loaderFetches.includes('refused'));
  // The address answers again; the person taps Finish now.
  blockNewLoader = false;
  await Promise.all([page.waitForEvent('load', { timeout: 60000 }), page.click(tid('buy-update-finish'))]);
  await page.waitForFunction(() => window.__campfire && window.__campfire.loaderBehind() === false, null, { timeout: 90000 });
  assert.equal(await controller(page), newLoader);
  assert.equal(await page.evaluate(() => window.__campfire.intrusion()), null);
  await unlockWithPassword(page, password);
  await waitScreen(page, 'home', 60000);
  await buyReachesBuybeam(page, 'loader-stuck');
  await page.context().close();
});

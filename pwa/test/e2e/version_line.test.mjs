// Issue #82, end to end: the version in small print on first-run setup (from the signed release, once
// the loader verified it), on Welcome and on Unlock. The installed Google Chrome (headless), its own
// build and a small host of its own that slows the engine file down so first-run setup stays on
// screen; a throwaway mainnet wallet that holds nothing.
//
//   npm run e2e:version   (port CAMPFIRE_VERSION_PORT, default 8836)
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, normalize, sep } from 'node:path';
import { launch, recordedPage, waitScreen, shot, sleep, foreignHosts, PWA, SHOTS } from './harness.mjs';
import { createWallet, waitHome } from './flows.mjs';
import { headersFor, mimeFor } from '../../tools/headers.mjs';

const PORT = Number(process.env.CAMPFIRE_VERSION_PORT || 8836);
const URL_ = `http://localhost:${PORT}/`;
const tid = (id) => `[data-testid="${id}"]`;
const VERSION = JSON.parse(readFileSync(join(PWA, 'package.json'), 'utf8')).version;
const WORDS = `Version ${VERSION}`;
const SLOW = /wasm-client\.wasm$/; // the engine: biggest file, so setup stays on screen a while

let tmp, root, server, browser, ctx, page, rec;
let slowMs = 6000;

function startHost() {
  server = http.createServer(async (req, res) => {
    const path = new URL(req.url, 'http://x').pathname;
    let rel = decodeURIComponent(path.slice(1));
    if (rel === '' || rel.endsWith('/')) rel += 'index.html';
    const full = normalize(join(root, rel));
    const h = { ...headersFor(rel), 'Cache-Control': 'no-cache' };
    try {
      if (!full.startsWith(root + sep)) throw new Error('outside');
      if (!(await stat(full)).isFile()) throw new Error('dir');
      const body = await readFile(full);
      if (slowMs && SLOW.test(rel)) await sleep(slowMs);
      res.writeHead(200, { ...h, 'Content-Type': mimeFor(full), 'Content-Length': body.length });
      res.end(body);
    } catch {
      res.writeHead(404, { ...h, 'Content-Type': 'text/plain' });
      res.end('not found');
    }
  });
  return new Promise((r) => server.listen(PORT, '127.0.0.1', r));
}

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-version-'));
  root = join(tmp, 'dist');
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', root, '--quiet'], { cwd: PWA });
  await startHost();
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, colorScheme: 'light' });
  // Every line first-run setup shows under its bar, kept across the reload into the verified copy.
  await ctx.addInitScript(() => {
    const keep = () => {
      const l = document.querySelector('[data-testid="install-line"]');
      if (!l) return;
      const seen = JSON.parse(sessionStorage.getItem('__lines') || '[]');
      if (seen[seen.length - 1] !== l.textContent) sessionStorage.setItem('__lines', JSON.stringify([...seen, l.textContent]));
    };
    new MutationObserver(keep).observe(document, { subtree: true, childList: true, characterData: true });
  });
  ({ page, rec } = await recordedPage(ctx, { label: 'version' }));
  console.log(`# version ${VERSION}; screenshots: ${SHOTS}`);
});

test.after(async () => {
  if (browser) await browser.close();
  if (server) await new Promise((r) => server.close(() => r()));
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

async function shots(name) {
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(200);
    await shot(page, `${name}-390-${scheme}`);
  }
  const size = page.viewportSize();
  await page.setViewportSize({ width: 1280, height: 800 });
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(200);
    await shot(page, `${name}-1280-${scheme}`);
  }
  await page.setViewportSize(size);
  await page.emulateMedia({ colorScheme: 'light' });
}

/** The line is the screen's last element, inside the page and readable. */
async function lineAtBottom() {
  return page.evaluate(() => {
    const el = document.querySelector('main [data-testid="app-version"]');
    const main = el && el.closest('main');
    const r = el ? el.getBoundingClientRect() : null;
    return { text: el && el.textContent, last: Boolean(main && main.lastElementChild === el), visible: Boolean(el && el.checkVisibility()), fontSize: el && getComputedStyle(el).fontSize, inside: Boolean(r && r.left >= 0 && r.right <= innerWidth) };
  });
}

async function primaryFits(selector) {
  const size = page.viewportSize();
  await page.setViewportSize({ width: 375, height: 667 });
  await sleep(250);
  const box = await page.locator(selector).first().boundingBox();
  await page.setViewportSize(size);
  return box && box.y >= 0 && box.y + box.height <= 667;
}

test('first-run setup: the version appears once the signed release names it, and "checked" at the end', { timeout: 5 * 60000 }, async () => {
  await page.goto(URL_);
  await waitScreen(page, 'install', 60000);
  await page.waitForSelector(`${tid('app-version')}:not(.hidden)`, { timeout: 60000 });
  assert.equal(await page.textContent(tid('app-version')), WORDS);
  // The page's own claim is not what shows: the loader had verified release.json by then.
  const p = await page.evaluate(async () => (await (await caches.open('campfire-meta')).match(new URL('__campfire_install', location.href).href)).json());
  assert.equal(p.version, VERSION, 'the progress record of the signed release');
  assert.ok(p.state === 'downloading' && p.total > 0, `still downloading: ${p.state}`);
  await shots('version-01-install');
  slowMs = 0;
  await waitScreen(page, 'welcome', 120000);
  const lines = await page.evaluate(() => JSON.parse(sessionStorage.getItem('__lines') || '[]'));
  assert.ok(lines.includes(`Version ${VERSION} checked. Opening Beam PWA…`), `the last line said it: ${JSON.stringify(lines.slice(-3))}`);
});

test('Welcome: "Version X" in small print, last on the screen; Create still in sight on a small phone', { timeout: 2 * 60000 }, async () => {
  await waitScreen(page, 'welcome', 60000);
  const l = await lineAtBottom();
  assert.deepEqual(l, { text: WORDS, last: true, visible: true, fontSize: '13px', inside: true });
  assert.ok(await primaryFits(tid('create')), 'Create a new wallet is visible at 375 x 667');
  await shots('version-02-welcome');
});

test('Unlock: the same line after a reload; Unlock still in sight on a small phone', { timeout: 10 * 60000 }, async () => {
  await createWallet(page, { password: `ver-${Math.random().toString(36).slice(2, 10)}` });
  await waitHome(page);
  assert.equal(await page.$(tid('app-version')), null, 'not on Home: only before a wallet is open');
  await page.reload();
  await waitScreen(page, 'unlock', 120000);
  const l = await lineAtBottom();
  assert.deepEqual(l, { text: WORDS, last: true, visible: true, fontSize: '13px', inside: true });
  assert.ok(await primaryFits(tid('unlock-submit')), 'Unlock is visible at 375 x 667');
  await shots('version-03-unlock');
});

test('privacy: no host but this one and BEAM nodes; no CSP violation; no page error', async () => {
  await sleep(200);
  assert.deepEqual(foreignHosts(rec, URL_), []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
});

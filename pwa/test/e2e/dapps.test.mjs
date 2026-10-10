// dApp isolation, proven from inside a running dApp frame (headless Chrome).
//
//   npm run e2e:dapps
//
// A throwaway wallet is created (nothing is funded), BeamX DAO (the smallest
// of the nine packages, 198 KB) is opened through the dApps screen, and then,
// from inside the dApp's own frame:
//   - the wallet page's DOM, storage and engine are out of reach;
//   - the frame's origin is opaque, and requests to the wallet's origin and to
//     hosts the dApp was not granted are refused by the frame's policy;
//   - a message posted to the wallet window, or a port forged by another
//     frame, reaches nothing;
//   - navigating the frame to a wallet page loads nothing, and the wallet
//     closes the dApp.
// The package comes from BEAM's GitHub unless CFB_DAPP_PACKAGES (or
// ~/.cache/campfire-beam/dapps) has the pinned file, which is then served in
// its place (the pin is checked either way).
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen, sleep, shot } from './harness.mjs';
import { createWallet, waitHome } from './flows.mjs';

const DAO = 'abcc470e12c6422291f360f83d79355e';
const PORT = Number(process.env.CAMPFIRE_DAPPS_PORT || 8794);
const tid = (id) => `[data-testid="${id}"]`;
const cacheDir = process.env.CFB_DAPP_PACKAGES || join(homedir(), '.cache', 'campfire-beam', 'dapps');

let server;
let browser;
let ctx;
let page;
let rec;
let dappFrame;

const stats = () => page.evaluate(() => window.__campfire.dapps());

test.before(async () => {
  server = await startServer({ root: 'dist', port: PORT, extra: ['--verbose'] });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  const local = join(cacheDir, 'dao-core-app.dapp');
  if (existsSync(local)) {
    await ctx.route('https://raw.githubusercontent.com/**', (route) =>
      route.request().url().endsWith('/dao-core-app.dapp')
        ? route.fulfill({ status: 200, body: readFileSync(local), headers: { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/octet-stream' } })
        : route.continue(),
    );
  }
  ({ page, rec } = await recordedPage(ctx, { label: 'iso' }));
  await page.goto(server.url);
  await createWallet(page, { password: `iso-${Math.random().toString(36).slice(2, 10)}` });
  await waitHome(page);
  // Test-only: record the id and method of every request that reaches the bridge (the dApp polls on its own).
  await page.evaluate(async () => {
    const m = await import('./lib/dapps/session.js');
    const orig = m.DappSession.prototype.handle;
    window.__bridgeSeen = [];
    m.DappSession.prototype.handle = function (text) {
      try {
        const j = JSON.parse(text);
        window.__bridgeSeen.push({ id: j.id, method: j.method });
      } catch {
        window.__bridgeSeen.push({ id: null, method: null });
      }
      return orig.call(this, text);
    };
  });
  await page.click(tid('open-dapps'));
  await waitScreen(page, 'dapps');
  await page.click(tid(`dapp-${DAO}`));
  await page.click(tid('dapp-go'));
  await page.waitForFunction(() => (window.__campfire.dapps()[0] || {}).state === 'running', null, { timeout: 120000 });
  dappFrame = page.frames().find((f) => f.url().includes('/dapp-run/'));
  assert.ok(dappFrame, 'the dApp frame is there');
  await dappFrame.waitForFunction(() => document.querySelector('#main-page, #main-page-mobile'), null, { timeout: 30000 });
});

test.after(async () => {
  await browser?.close();
  server?.stop();
});

test('the frame is opaque and sandboxed, served from the verified copy with its own policy', async () => {
  const r = await dappFrame.evaluate(() => ({ origin: self.origin, coi: self.crossOriginIsolated, href: location.href }));
  assert.equal(r.origin, 'null');
  assert.match(r.href, /\/dapp-run\/e0r0\/app\/index\.html$/, 'BeamX DAO needs no eval and was granted no hosts');
  const attrs = await page.$eval(tid('dapp-frame'), (f) => ({ sandbox: f.getAttribute('sandbox'), src: f.getAttribute('src') }));
  assert.equal(attrs.sandbox, 'allow-scripts');
  // The frame document did not come from the network: the server logs every request and never saw it.
  assert.ok(server.output.join('').includes('GET /index.html') || server.output.join('').includes('GET / '), 'the server log is on');
  assert.ok(!server.output.join('').includes('/dapp-run/'), 'the frame was served by the service worker');
});

test("the wallet page's DOM, storage and engine are out of reach", async () => {
  const r = await dappFrame.evaluate(async () => {
    const out = {};
    const tryIt = (k, fn) => {
      try {
        out[k] = fn();
      } catch (e) {
        out[k] = `throws ${e.name}`;
      }
    };
    tryIt('parentDocument', () => typeof parent.document.body);
    tryIt('parentLocalStorage', () => parent.localStorage.length);
    tryIt('parentIndexedDB', () => typeof parent.indexedDB.open);
    tryIt('parentEngine', () => typeof parent.BeamModule);
    tryIt('parentCampfire', () => typeof parent.__campfire.record);
    tryIt('serviceWorker', () => typeof navigator.serviceWorker.controller);
    out.engineHere = typeof window.BeamModule;
    // localStorage here is the frame's own, in memory, empty.
    out.localStorageKeys = localStorage.length;
    // IndexedDB here is the frame's own, in memory: the wallet's database name opens empty.
    out.idb = await new Promise((resolve) => {
      const q = indexedDB.open('beam-campfire-app');
      q.onupgradeneeded = () => {};
      q.onsuccess = () => resolve({ version: q.result.version, stores: Array.from(q.result.objectStoreNames) });
      q.onerror = () => resolve({ error: String(q.error) });
    });
    out.caches = await (async () => {
      try {
        await caches.keys();
        return 'reachable';
      } catch (e) {
        return `refused ${e.name}`;
      }
    })();
    return out;
  });
  for (const k of ['parentDocument', 'parentLocalStorage', 'parentIndexedDB', 'parentEngine', 'parentCampfire', 'serviceWorker']) assert.match(String(r[k]), /^throws SecurityError/, `${k}: ${r[k]}`);
  assert.equal(r.engineHere, 'undefined');
  assert.equal(r.localStorageKeys, 0);
  assert.deepEqual(r.idb, { version: 1, stores: [] }, "the wallet's IndexedDB (store kv) is not what the frame opens");
  assert.match(r.caches, /^refused/);
  // And the wallet's own database is untouched.
  assert.ok(await page.evaluate(() => window.__campfire.record() && window.__campfire.record().setupDone !== undefined));
});

test("requests to the wallet's origin, and to hosts not granted, are refused by the frame's policy", async () => {
  const origin = new URL(server.url).origin;
  const r = await dappFrame.evaluate(async (o) => {
    const attempt = async (url, opts) => {
      try {
        const res = await fetch(url, opts);
        return `status ${res.status}`;
      } catch (e) {
        return `refused ${e.name}`;
      }
    };
    const img = (url) =>
      new Promise((resolve) => {
        const i = new Image();
        i.onload = () => resolve('loaded');
        i.onerror = () => resolve('refused');
        i.src = url;
      });
    return {
      walletIndex: await attempt(`${o}/index.html`),
      walletIndexNoCors: await attempt(`${o}/index.html`, { mode: 'no-cors' }),
      walletRelease: await attempt(`${o}/release.json`),
      walletEngine: await attempt(`${o}/vendor/engine/wasm-client.js`),
      walletImage: await img(`${o}/img/logo.svg`),
      notGranted: await attempt('https://api.coingecko.com/api/v3/ping'),
      ownShader: await attempt('./daoCore.wasm'),
    };
  }, origin);
  for (const k of ['walletIndex', 'walletIndexNoCors', 'walletRelease', 'walletEngine', 'notGranted']) assert.match(r[k], /^refused/, `${k}: ${r[k]}`);
  assert.equal(r.walletImage, 'refused');
  assert.equal(r.ownShader, 'status 200', "the dApp's own files are served from its package");
  assert.ok(rec.csp.some((l) => /connect-src/.test(l)), 'the refusals are CSP refusals');
});

test('a message posted to the wallet window reaches no wallet call', async () => {
  const before = (await stats())[0];
  await dappFrame.evaluate(() => {
    const forged = JSON.stringify({ jsonrpc: '2.0', id: 'forged', method: 'tx_send', params: { address: 'x', value: 1 } });
    parent.postMessage({ t: 'rpc', json: forged }, '*');
    parent.postMessage({ type: 'create_beam_api', apiver: 'current' }, '*');
    top.postMessage(forged, '*');
  });
  await sleep(1500);
  const seen = await page.evaluate(() => window.__bridgeSeen);
  assert.ok(seen.length > 0, 'the trace sees the dApp\'s own requests');
  assert.deepEqual(seen.filter((r) => r.id === 'forged' || r.method === 'tx_send' || r.id === null), [], 'nothing posted to the wallet window reached the bridge');
  assert.equal((await stats())[0].dropped, before.dropped);
  assert.equal(await page.$(tid('consent')), null, 'no approval was asked for');
});

test('a port or reply forged by another frame is ignored by the dApp frame', async () => {
  // Another frame of the wallet page, as a second dApp would be: the same bootstrap, no port.
  await page.evaluate(() => {
    const f = document.createElement('iframe');
    f.id = 'intruder';
    f.src = 'dapp-run/e1r0/app/index.html';
    document.body.appendChild(f);
  });
  let intruder = null;
  for (let i = 0; i < 40 && !intruder; i++) {
    await sleep(250);
    intruder = page.frames().find((f) => f.url().includes('/dapp-run/') && f !== dappFrame);
  }
  assert.ok(intruder, 'the second frame is there');
  await intruder.waitForFunction(() => document.readyState === 'complete');
  const heard = await intruder.evaluate(async () => {
    const target = parent.frames[0];
    const ch = new MessageChannel();
    const got = [];
    ch.port1.onmessage = (e) => got.push(e.data);
    target.postMessage({ t: 'campfire-port' }, '*', [ch.port2]);
    target.postMessage({ t: 'deliver', json: '{"jsonrpc":"2.0","id":"x","result":1}' }, '*');
    target.postMessage('apiInjected', '*');
    await new Promise((r) => setTimeout(r, 1500));
    return got;
  });
  assert.deepEqual(heard, [], 'the dApp frame did not take the forged port (it answers ready on a port it accepts)');
  const after = (await stats())[0];
  assert.equal(after.state, 'running', 'the dApp still runs on its own port');
  assert.equal((await stats()).length, 1, 'the second frame is no dApp: it got no port and no files');
  await page.evaluate(() => document.getElementById('intruder').remove());
});

test('navigating the frame to a wallet page loads nothing, and the wallet closes the dApp', async () => {
  await shot(page, 'dapps-iso-running');
  await dappFrame.evaluate(() => {
    location.href = new URL('/index.html', location.href).href;
  }).catch(() => {});
  await sleep(1000);
  // Whatever the frame shows now is an error page, never the wallet.
  const children = page.frames().filter((f) => f !== page.mainFrame());
  assert.ok(children.length >= 1);
  for (const f of children) {
    const r = await f.evaluate(() => ({ text: document.body ? document.body.innerText : '', campfire: typeof window.__campfire })).catch(() => ({ text: '', campfire: 'inaccessible' }));
    assert.ok(!/BEAM Campfire/.test(r.text) && r.campfire !== 'object', `a wallet page loaded in a frame: ${f.url()}`);
  }
  // The navigation went past the service worker (sandboxed frame) and the server's copy refuses to be framed.
  assert.ok(/GET \/index\.html/.test(server.output.join('')), 'the navigation reached the server, not the verified copy');
  await page.waitForSelector(tid('dapp-stopped'), { timeout: 15000 });
  assert.equal(await page.evaluate(() => window.__campfire.screen()), 'dapps');
  assert.equal((await stats()).length, 0, 'the dApp was closed');
});

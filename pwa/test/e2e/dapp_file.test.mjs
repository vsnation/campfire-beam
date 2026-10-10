// dApps installed from a .dapp file (headless Chrome, a 375 px phone).
//
//   npm run e2e:dapp-file
//
// A throwaway wallet is created (nothing is funded). Then:
// 1. A tiny .dapp built by this test: installed through the file chooser
//    (confirm sheet: unknown publisher, not checked), run in the sandboxed
//    frame with its inline script and handler, asked about the one server it
//    tries (Not now, then Allow; the server is answered by the test), the
//    sign and approve sheets say it was not checked, the hosts are listed in More with
//    Remove access, it survives an app reload and opens offline, a higher
//    version replaces it (and keeps its servers), a name copying Beam DEX is
//    warned about, every refusal says why, and Remove deletes it and its data.
//    BeamX DAO's own package, picked as a file (when the local package cache
//    has it), goes in as the checked dApp.
// 2. The real BEAM Explorer package (CFB_EXPLORER_DAPP, else
//    ~/beam-campfire-test/fixtures/beam-explorer.dapp; skipped when absent):
//    installed, its server allowed when it asks, the block height it shows
//    compared with the explorer's API, still installed and allowed after a
//    reload, then removed.
// Screenshots, light and dark, go to CAMPFIRE_DAPP_FILE_SHOTS (default: the
// shots folder's dapp-file/).
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen, sleep, SHOTS } from './harness.mjs';
import { createWallet, waitHome, unlockWithPassword } from './flows.mjs';
import { makeZip } from '../unit/helpers/zipwriter.mjs';

const PORT = Number(process.env.CAMPFIRE_DAPP_FILE_PORT || 8880);
const SHOT_DIR = process.env.CAMPFIRE_DAPP_FILE_SHOTS || join(SHOTS, 'dapp-file');
const EXPLORER = process.env.CFB_EXPLORER_DAPP || join(homedir(), 'beam-campfire-test', 'fixtures', 'beam-explorer.dapp');
const EXPLORER_API = 'https://explorer.0xmx.net/api/status';
const tid = (id) => `[data-testid="${id}"]`;

const TINY = 'c0ffee00c0ffee00c0ffee00c0ffee00';
const HOST = 'dapp-host.example.com';
const DEX_GUID = 'db851322f6674a6da3e84e9953db2ffd';
const tinyPage = `<!doctype html><html><head><meta charset="utf-8"><title>Tiny</title>
<style>body{font:16px system-ui;color:#fff;padding:16px}button{font-size:16px;padding:8px 14px;margin:6px 0}</style></head>
<body><h1>Tiny dApp</h1><p id="x">not run</p><p id="net">-</p>
<button id="b" onclick="this.textContent='clicked'">Tap me</button><br>
<button id="sign" onclick="signIt()">Sign a message</button>
<script>
document.getElementById('x').textContent = 'ran inline';
fetch('https://${HOST}/data.json').then(function (r) { return r.json(); }).then(function (j) { document.getElementById('net').textContent = 'got ' + j.n; }, function () { document.getElementById('net').textContent = 'refused'; });
function signIt() { window.BEAM.callWalletApi(JSON.stringify({ jsonrpc: '2.0', id: 'sig', method: 'sign_message', params: { message: 'hello from a file', key_material: '0102' } })); }
var pend = {};
window.BEAM.callWalletApiResult(function (s) { var j = JSON.parse(s); if (pend[j.id]) pend[j.id](j); });
function call(m, p) { return new Promise(function (r) { var id = 'c' + Math.random(); pend[id] = r; window.BEAM.callWalletApi(JSON.stringify({ jsonrpc: '2.0', id: id, method: m, params: p })); }); }
window.payIt = function () { return call('create_address', {}).then(function (a) { return call('tx_send', { address: a.result, value: 1000 }); }); };
</script></body></html>`;
const ICON = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10" rx="2" fill="#25c2a0"/><path d="M3 7l2-4 2 4z" fill="#042548"/></svg>';
const manifest = (extra = {}) => ({ name: 'Tiny dApp', description: 'A tiny dApp made by the test', url: 'localapp/app/index.html', icon: 'localapp/app/icon.svg', guid: TINY, version: '1.0.0', api_version: '7.3', min_api_version: '7.0', ...extra });
const pkg = (m = manifest(), more = []) =>
  Buffer.from(
    makeZip([
      { name: 'manifest.json', data: JSON.stringify(m) },
      { name: 'app/index.html', data: tinyPage },
      { name: 'app/icon.svg', data: ICON },
      ...more,
    ]),
  );
const file = (name, buffer) => ({ name, mimeType: 'application/octet-stream', buffer });

let server;
let browser;
let ctx;
let page;
let rec;
const password = `df-${Math.random().toString(36).slice(2, 10)}`;
const shots = [];

/** The screen as a 375 px phone shows it, light and dark. */
async function snap(name) {
  await mkdir(SHOT_DIR, { recursive: true });
  await sleep(350);
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(120);
    const p = join(SHOT_DIR, `${name}-${scheme}.png`);
    await page.screenshot({ path: p });
    shots.push(p);
  }
  await page.emulateMedia({ colorScheme: 'light' });
}

const stats = () => page.evaluate(() => window.__campfire.dapps());
const dappFrame = () => page.frames().find((f) => f.url().includes('/dapp-run/'));

async function waitRunning() {
  await page.waitForFunction(() => (window.__campfire.dapps()[0] || {}).state === 'running', null, { timeout: 60000 });
  const f = dappFrame();
  assert.ok(f, 'the dApp frame is there');
  return f;
}

async function closeDapp() {
  await page.click(tid('dapp-close'));
  await page.waitForFunction(() => window.__campfire.dapps().length === 0);
}

async function install(f) {
  await page.setInputFiles(tid('dapp-file-input'), f);
}

async function installError(f) {
  await install(f);
  await page.waitForSelector(tid('dapp-install-error'));
  const r = await page.$eval(tid('dapp-install-error'), (e) => ({ code: e.dataset.code, text: e.textContent }));
  return r;
}

async function closeSheets() {
  await page.evaluate(() => document.querySelectorAll('.overlay').forEach((o) => o.remove()));
}

const kvKeys = () =>
  page.evaluate(async () => {
    const { store } = await import('./lib/store.js');
    const list = (await store.get('dapp-files')) || [];
    const out = { list: list.map((r) => ({ guid: r.guid, version: r.version, origins: r.origins })), packages: [] };
    for (const r of list) if (await store.get(`dapp-file:${r.guid}`)) out.packages.push(r.guid);
    out.tinyBytes = Boolean(await store.get('dapp-file:c0ffee00c0ffee00c0ffee00c0ffee00'));
    return out;
  });

async function openDappsScreen() {
  await page.click(tid('open-dapps'));
  await waitScreen(page, 'dapps');
  await page.waitForSelector(tid('dapp-install-file'));
}

async function reloadAndUnlock() {
  await page.reload();
  await unlockWithPassword(page, password);
  await waitHome(page, { timeout: 120000 });
  await openDappsScreen();
}

test.before(async () => {
  server = await startServer({ root: 'dist', port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 375, height: 812 }, deviceScaleFactor: 2 });
  // The one server the tiny dApp asks for: answered here, with CORS (the frame is an opaque origin).
  await ctx.route(`https://${HOST}/**`, (route) => route.fulfill({ status: 200, body: '{"n":42}', headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } }));
  ({ page, rec } = await recordedPage(ctx, { label: 'dappfile' }));
  await page.goto(server.url);
  await createWallet(page, { password });
  await waitHome(page);
});

test.after(async () => {
  if (shots.length) console.log(`screenshots: ${SHOT_DIR} (${shots.length})`);
  await browser?.close();
  server?.stop();
});

// ------------------------------------------------------------ 1. a tiny dApp built here
test('the dApps screen offers Install from file below the list', async () => {
  await openDappsScreen();
  assert.equal(await page.textContent('.dapp-file-block .small'), "Have a .dapp file from a dApp's publisher?");
  assert.equal((await page.textContent(tid('dapp-install-file'))).trim(), 'Install from file');
  assert.equal(await page.getAttribute(tid('dapp-file-input'), 'accept'), null, 'no type filter: iOS has none for .dapp');
  assert.equal(await page.$(tid('dapp-installed')), null, 'nothing installed yet');
  assert.ok(await page.$(tid('dapp-available')));
  await snap('01-store');
  await page.$eval(tid('dapp-install-file'), (b) => b.scrollIntoView({ block: 'end' }));
  await snap('01b-store-install-from-file');
  await page.evaluate(() => window.scrollTo(0, 0));
});

test('a file is checked, then the confirm sheet: version, unknown publisher, not checked, one primary', async () => {
  await install(file('tiny.dapp', pkg()));
  await page.waitForSelector(tid('dapp-install-title'));
  assert.equal(await page.textContent(tid('dapp-install-title')), 'Install Tiny dApp?');
  assert.equal(await page.textContent(tid('dapp-install-meta')), 'Version 1.0.0 · unknown publisher');
  assert.match(await page.textContent(tid('dapp-install-unchecked')), /BEAM Campfire did not check this dApp: it is not one of BEAM's own dApps\. Install it only if you trust where it came from\./);
  assert.equal(await page.$(tid('dapp-install-replaces')), null);
  assert.equal(await page.$(tid('dapp-install-copies')), null);
  assert.equal(await page.$$eval('.overlay .btn-primary', (b) => b.length), 1);
  assert.equal(await page.textContent(tid('dapp-install-go')), 'Install Tiny dApp');
  const box = await page.$eval(tid('dapp-install-go'), (b) => b.getBoundingClientRect().bottom);
  assert.ok(box <= 812, 'the primary button is on screen without scrolling');
  await snap('02-confirm');
  await page.click(tid('dapp-install-go'));
  await page.waitForSelector(tid(`dapp-file-${TINY}`));
  assert.match(await page.textContent(tid(`dapp-file-${TINY}`)), /Version 1\.0\.0 · from a file, not checked by BEAM Campfire/);
  const k = await kvKeys();
  assert.deepEqual(k.list, [{ guid: TINY, version: '1.0.0', origins: [] }]);
  assert.deepEqual(k.packages, [TINY]);
  await snap('03-store-installed');
});

test('it runs in the sandboxed frame under the file policy: inline script and handler run, no server is reachable', async () => {
  await page.click(tid(`dapp-file-${TINY}`));
  const f = await waitRunning();
  assert.match(f.url(), /\/dapp-run\/f\/app\/index\.html$/);
  assert.deepEqual((await stats())[0].file, true);
  await f.waitForFunction(() => document.getElementById('x') && document.getElementById('x').textContent === 'ran inline');
  // The server prompt is already up (the dApp fetches at once), so the handler is run by a script click.
  assert.equal(await f.evaluate(() => (document.getElementById('b').click(), document.getElementById('b').textContent)), 'clicked', 'the inline onclick handler ran');
  assert.equal(await f.evaluate(() => self.origin), 'null');
  assert.equal(await page.getAttribute(tid('dapp-frame'), 'sandbox'), 'allow-scripts');
  await f.waitForFunction(() => document.getElementById('net').textContent === 'refused');
  assert.ok(!server.output.join('').includes('/dapp-run/'), 'the frame came from the service worker');
});

test('the server it tried is asked about by name; Not now keeps it refused for this run', async () => {
  await page.waitForSelector(tid('dapp-host-title'));
  assert.equal(await page.textContent(tid('dapp-host-title')), `Let Tiny dApp connect to ${HOST}?`);
  assert.match(await page.textContent('.overlay'), new RegExp(`${HOST.replace(/\./g, '\\.')} will see your IP address and everything Tiny dApp asks it\\.`));
  assert.equal(await page.textContent(tid('dapp-host-allow')), 'Allow');
  assert.equal(await page.textContent(tid('dapp-host-later')), 'Not now');
  await snap('05-network-prompt');
  await page.click(tid('dapp-host-later'));
  await sleep(1500);
  assert.equal(await page.$(tid('dapp-host-title')), null, 'asked once');
  assert.equal(await dappFrame().textContent('#net'), 'refused');
  await snap('04-running');
});

test('the approve sheet says it was installed from a file and not checked', async () => {
  await dappFrame().click('#sign');
  await page.waitForSelector(tid('dapp-sign'));
  assert.match(await page.textContent('.overlay'), /Installed from a file · not checked by BEAM Campfire/);
  assert.match(await page.textContent('.overlay'), /hello from a file/);
  await snap('06-sign-unchecked');
  await page.click(tid('dapp-sign-reject'));
});

test('the approve sheet for a payment says so too (an empty wallet: nothing can be sent)', async () => {
  dappFrame().evaluate(() => window.payIt()).catch(() => {});
  await page.waitForSelector(tid('consent'), { timeout: 30000 });
  assert.equal(await page.textContent(tid('consent-unchecked')), 'Installed from a file · not checked by BEAM Campfire');
  assert.match(await page.textContent(tid('consent-app')), /Tiny dApp asks you to approve/);
  await snap('06b-approve-unchecked');
  await page.click(tid('consent-cancel'));
  await page.waitForFunction(() => !document.querySelector('[data-testid="consent"]'));
});

test('reopened, it asks again; Allow reloads it with that server, and its data arrives', async () => {
  await closeDapp();
  await page.click(tid(`dapp-file-${TINY}`));
  await waitRunning();
  await page.waitForSelector(tid('dapp-host-title'));
  await page.click(tid('dapp-host-allow'));
  await page.waitForFunction((h) => [...document.querySelectorAll('iframe')].some((f) => f.src.includes(`/dapp-run/f,${h}/`)), HOST, { timeout: 30000 });
  const f = await waitRunning();
  assert.match(f.url(), new RegExp(`/dapp-run/f,${HOST.replace(/\./g, '\\.')}/app/index\\.html$`));
  await f.waitForFunction(() => document.getElementById('net').textContent === 'got 42');
  assert.equal(await page.$(tid('dapp-host-title')), null, 'an allowed server is not asked about again');
  assert.deepEqual((await kvKeys()).list[0].origins, [`https://${HOST}`]);
});

test('More lists the servers it can reach, each with Remove access', async () => {
  await page.click(tid('dapp-more'));
  await page.waitForSelector(tid('dapp-hosts'));
  assert.deepEqual(await page.$$eval(tid('dapp-host-revoke'), (b) => b.map((x) => x.dataset.host)), [HOST]);
  assert.match(await page.textContent(tid('dapp-more-meta')), /Version 1\.0\.0 · unknown publisher · installed from a file, not checked by BEAM Campfire\./);
  await snap('07-more-hosts');
});

test('the app reloaded: still installed, still allowed; it opens offline from this device', async () => {
  await closeSheets();
  await reloadAndUnlock();
  assert.ok(await page.$(tid(`dapp-file-${TINY}`)), 'still installed');
  await page.click(tid(`dapp-file-${TINY}`));
  let f = await waitRunning();
  assert.ok(f.url().includes(`/dapp-run/f,${HOST}/`), 'still allowed');
  await f.waitForFunction(() => document.getElementById('net').textContent === 'got 42');
  await closeDapp();
  await ctx.setOffline(true);
  try {
    await page.click(tid(`dapp-file-${TINY}`));
    f = await waitRunning();
    await f.waitForFunction(() => document.getElementById('x').textContent === 'ran inline');
    await closeDapp();
  } finally {
    await ctx.setOffline(false);
  }
});

test('Remove access reloads it without that server, which it is then asked about again', async () => {
  await page.click(tid(`dapp-file-${TINY}`));
  await waitRunning();
  await page.click(tid('dapp-more'));
  await page.click(tid('dapp-host-revoke'));
  await page.waitForFunction(() => [...document.querySelectorAll('iframe')].some((f) => /\/dapp-run\/f\/app\//.test(f.src)), null, { timeout: 30000 });
  const f = await waitRunning();
  await f.waitForFunction(() => document.getElementById('net').textContent === 'refused');
  await page.waitForSelector(tid('dapp-host-title'));
  await page.click(tid('dapp-host-later'));
  assert.deepEqual((await kvKeys()).list[0].origins, []);
  await page.click(tid('dapp-more'));
  await page.waitForSelector(tid('dapp-hosts-none'));
  await snap('08-more-no-hosts');
  await closeSheets();
  await closeDapp();
});

test('a higher version replaces it, and keeps the servers it was allowed', async () => {
  // Allowed again first, so the replace line has something to keep.
  await page.click(tid(`dapp-file-${TINY}`));
  await waitRunning();
  await page.waitForSelector(tid('dapp-host-title'));
  await page.click(tid('dapp-host-allow'));
  await page.waitForFunction((h) => [...document.querySelectorAll('iframe')].some((f) => f.src.includes(`/dapp-run/f,${h}/`)), HOST, { timeout: 30000 });
  await waitRunning();
  await closeDapp();
  await install(file('tiny-1.1.dapp', pkg(manifest({ version: '1.1.0', publisher: 'Tiny Labs' }))));
  await page.waitForSelector(tid('dapp-install-replaces'));
  assert.equal(await page.textContent(tid('dapp-install-replaces')), `Replaces the installed version 1.0.0. It keeps the servers you let it reach: ${HOST}.`);
  assert.equal(await page.textContent(tid('dapp-install-meta')), 'Version 1.1.0 · by Tiny Labs');
  assert.equal(await page.textContent(tid('dapp-install-go')), 'Replace Tiny dApp');
  await snap('09-replace');
  await page.click(tid('dapp-install-go'));
  await page.waitForFunction((g) => /Version 1\.1\.0/.test(document.querySelector(`[data-testid="dapp-file-${g}"]`)?.textContent || ''), TINY);
  const k = await kvKeys();
  assert.deepEqual(k.list, [{ guid: TINY, version: '1.1.0', origins: [`https://${HOST}`] }]);
});

test("a name copying one of BEAM's dApps is warned about; Cancel installs nothing", async () => {
  await install(file('fake-dex.dapp', pkg(manifest({ name: 'Beam DEX', guid: 'feedface0000feedface0000feedface' }))));
  await page.waitForSelector(tid('dapp-install-copies'));
  assert.equal(await page.textContent(tid('dapp-install-copies')), 'Its name matches Beam DEX, one of the dApps BEAM Campfire checks, but it is a different app.');
  await snap('10-imitation');
  await page.click(tid('dapp-install-cancel'));
  assert.equal((await kvKeys()).list.length, 1);
});

test('every refusal says what happened and what to do, and installs nothing', async () => {
  const generic = "This file isn't a dApp package BEAM Campfire can install safely, so nothing was installed. Ask the dApp's publisher for a new copy.";
  const cases = [
    ['not-a-zip.dapp', Buffer.from('this is not a zip archive at all'), 'cantOpenFile', generic],
    ['no-manifest.dapp', Buffer.from(makeZip([{ name: 'app/index.html', data: 'x' }])), 'cantReadManifest', generic],
    ['climbs-out.dapp', pkg(manifest(), [{ name: '../evil.js', data: 'x' }]), 'unsafePath', generic],
    ['symlink.dapp', pkg(manifest(), [{ name: 'app/link', data: '/etc/passwd', method: 0, externalAttr: 0o120777 << 16 }]), 'unsafeEntry', generic],
    ['bomb.dapp', pkg(manifest(), [{ name: 'app/zeros.bin', data: new Uint8Array(3 * 1024 * 1024) }]), 'tooLarge', generic],
    ['bidi-name.dapp', pkg(manifest({ name: 'Beam\u202eXED' })), 'invalidFile', generic],
    ['outside-url.dapp', pkg(manifest({ url: 'https://evil.example/index.html' })), 'invalidFile', generic],
    ['newer-api.dapp', pkg(manifest({ api_version: '9.0', min_api_version: '8.0' })), 'unsupported', 'Tiny dApp needs a newer wallet than this version of BEAM Campfire.'],
    ['claims-dex.dapp', pkg(manifest({ guid: DEX_GUID, name: 'Beam DEX' })), 'reservedGuid', 'This file claims to be Beam DEX, but it is not the package BEAM Campfire checks, so nothing was installed. Open Beam DEX from the list of dApps instead.'],
  ];
  for (const [name, buffer, code, text] of cases) {
    const r = await installError(file(name, buffer));
    assert.equal(r.code, code, name);
    assert.equal(r.text, text, name);
    assert.equal(await page.textContent('.overlay .btn-primary'), 'Choose another file');
    if (code === 'invalidFile' && name === 'bidi-name.dapp') await snap('11-error');
    if (code === 'reservedGuid') await snap('12-error-claims-dex');
    await page.click(tid('dapp-install-close'));
  }
  assert.equal((await kvKeys()).list.length, 1, 'nothing more was installed');
});

test("BEAM's own package, picked as a file, goes in as that dApp: checked, no warning", async (t) => {
  const dir = process.env.CFB_DAPP_PACKAGES || join(homedir(), '.cache', 'campfire-beam', 'dapps');
  const dao = join(dir, 'dao-core-app.dapp');
  if (!existsSync(dao)) return t.skip(`no BeamX DAO package in ${dir}`);
  const DAO = 'abcc470e12c6422291f360f83d79355e';
  await install(file('dao-core-app.dapp', readFileSync(dao)));
  await page.waitForSelector(`${tid('dapp-installed')} ${tid(`dapp-${DAO}`)}`);
  assert.equal(await page.$(tid('dapp-install-title')), null, 'no confirm sheet: it is the checked package');
  assert.match(await page.textContent('.toast'), /BeamX DAO is installed: this file is BEAM's own package, checked against its fingerprint\./);
  assert.match(await page.textContent(tid(`dapp-${DAO}`)), /Downloaded · checked against its fingerprint/);
  // Removed again from its row: back under Available.
  await page.click(tid(`dapp-remove-${DAO}`));
  await page.click(tid('dapp-remove-confirm'));
  await page.waitForSelector(`${tid('dapp-available')} ${tid(`dapp-${DAO}`)}`);
});

test('Remove asks first, then deletes its files and what it may reach', async () => {
  await page.click(tid(`dapp-remove-${TINY}`));
  await page.waitForSelector(tid('dapp-remove-title'));
  assert.equal(await page.textContent(tid('dapp-remove-title')), 'Remove Tiny dApp?');
  assert.match(await page.textContent('.overlay'), /Its files and the data it saved on this device are deleted\. Your funds and transactions are not affected\./);
  await snap('13-remove');
  await page.click(tid('dapp-remove-confirm'));
  await page.waitForFunction((g) => !document.querySelector(`[data-testid="dapp-file-${g}"]`), TINY);
  const k = await kvKeys();
  assert.deepEqual(k.list, []);
  assert.equal(k.tinyBytes, false, 'the package bytes are gone');
  assert.equal(await page.$(tid('dapp-installed')), null);
  assert.deepEqual(rec.errors, [], 'no page errors');
});

// ------------------------------------------------------------ 2. the real BEAM Explorer package
test('BEAM Explorer from its .dapp file: install, allow its server, real chain data, reload, remove', async (t) => {
  if (!existsSync(EXPLORER)) return t.skip(`no Explorer package at ${EXPLORER} (set CFB_EXPLORER_DAPP)`);
  const bytes = readFileSync(EXPLORER);
  await install(file('beam-explorer.dapp', bytes));
  await page.waitForSelector(tid('dapp-install-title'));
  assert.equal(await page.textContent(tid('dapp-install-title')), 'Install BEAM Explorer?');
  assert.match(await page.textContent(tid('dapp-install-meta')), /^Version 1\.0\.0 · unknown publisher$/);
  await snap('20-explorer-confirm');
  await page.click(tid('dapp-install-go'));
  const row = await page.waitForSelector('[data-name="BEAM Explorer"]');
  const guid = (await row.getAttribute('data-testid')).replace('dapp-file-', '');

  await row.click();
  await waitRunning();
  await page.waitForSelector(tid('dapp-host-title'), { timeout: 30000 });
  assert.equal(await page.textContent(tid('dapp-host-title')), 'Let BEAM Explorer connect to explorer.0xmx.net?');
  await snap('21-explorer-network-prompt');
  await page.click(tid('dapp-host-allow'));
  await page.waitForFunction(() => [...document.querySelectorAll('iframe')].some((f) => f.src.includes('/dapp-run/f,explorer.0xmx.net/')), null, { timeout: 30000 });
  const readHeight = async () => {
    const f = await waitRunning();
    await f.waitForFunction(() => [...document.querySelectorAll('.stat-card')].some((c) => /Block Height/.test(c.textContent) && /\d/.test(c.querySelector('.stat-value').textContent)), null, { timeout: 60000 });
    const shown = await f.evaluate(() => [...document.querySelectorAll('.stat-card')].find((c) => /Block Height/.test(c.textContent)).querySelector('.stat-value').textContent);
    const api = (await (await fetch(EXPLORER_API)).json()).height;
    const wallet = await page.evaluate(() => window.__campfire.height());
    return { shown, height: Number(shown.replace(/\D/g, '')), api, wallet };
  };
  // Any other server it tries (none expected for its data) is left refused.
  const later = setInterval(() => page.click(tid('dapp-host-later'), { timeout: 200 }).catch(() => {}), 500);
  let h1;
  try {
    h1 = await readHeight();
  } finally {
    clearInterval(later);
  }
  console.log(`Explorer shows block height ${h1.shown}; explorer.0xmx.net/api/status says ${h1.api}; this wallet's BEAM node says ${h1.wallet}`);
  assert.ok(Math.abs(h1.height - h1.api) <= 3, `shown ${h1.height} vs API ${h1.api}`);
  await snap('22-explorer-running');
  await page.click(tid('dapp-more'));
  await page.waitForSelector(tid('dapp-hosts'));
  assert.deepEqual(await page.$$eval(tid('dapp-host-revoke'), (b) => b.map((x) => x.dataset.host)), ['explorer.0xmx.net']);
  await snap('23-explorer-more');
  await closeSheets();

  await reloadAndUnlock();
  await page.click(tid(`dapp-file-${guid}`));
  const h2 = await readHeight();
  assert.ok(Math.abs(h2.height - h2.api) <= 3, `after reload: shown ${h2.height} vs API ${h2.api}`);
  console.log(`after the reload: Explorer shows ${h2.shown}; API ${h2.api}; wallet node ${h2.wallet}`);
  assert.equal(await page.$(tid('dapp-host-title')), null, 'allowed: not asked again');
  assert.ok(dappFrame().url().includes('/dapp-run/f,explorer.0xmx.net/'));

  await page.click(tid('dapp-more'));
  await page.click(tid('dapp-remove-file'));
  await page.waitForSelector(tid('dapp-remove-title'));
  assert.equal(await page.textContent(tid('dapp-remove-title')), 'Remove BEAM Explorer?');
  await page.click(tid('dapp-remove-confirm'));
  await page.waitForFunction((g) => !document.querySelector(`[data-testid="dapp-file-${g}"]`), guid);
  const k = await kvKeys();
  assert.deepEqual(k.list, []);
  assert.deepEqual(k.packages, []);
  assert.equal(await page.evaluate((g) => import('./lib/store.js').then(({ store }) => store.get(`dapp-file:${g}`)), guid), undefined, 'its package is gone');
  assert.equal((await stats()).length, 0, 'it was closed');
});

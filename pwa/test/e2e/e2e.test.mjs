// BEAM Campfire end-to-end: the installed Google Chrome (headless), the dev
// server, and BEAM mainnet. Spends nothing: it uses a throwaway wallet.
//
//   npm run e2e        (stages the engine, builds dist/, runs this file)
//
// Env: CAMPFIRE_SHOTS=<dir> for the screenshots (default: $TMPDIR/beam-campfire-shots),
//      BEAM_RECOVERY_FILE=<path> to serve a local copy of the recovery snapshot
//      instead of streaming BEAM's (saves the 330 MB download; the proxy path is
//      what a deployment uses, so leave it unset for a full run).
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, symlinkSync, unlinkSync, mkdirSync, appendFileSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import jsQR from 'jsqr';
import { PWA, startServer, launch, recordedPage, addVirtualAuthenticator, shot, waitScreen, foreignHosts, explorerHeight, sleep, SHOTS } from './harness.mjs';
import { createWallet, restoreWallet, waitHome, waitSynced, unlockWithPassword } from './flows.mjs';

const PORT = 8791;
// The release under test is package.json's version; the update tests build the next ones.
const V0 = JSON.parse(readFileSync(join(PWA, 'package.json'), 'utf8')).version;
const nextVersion = (n) => V0.replace(/\d+$/, (p) => String(Number(p) + n));
const V1 = nextVersion(1);
const V2 = nextVersion(2);
const V3 = nextVersion(3);
const PASSWORD = `e2e-${Math.random().toString(36).slice(2, 10)}`;
const NODE = 'eu-nodes.mainnet.beam.mw:8200';
const tid = (id) => `[data-testid="${id}"]`;

let tmp, live, srv, browser, ctx, page, rec, blockNode = false, throwawayWords = null;

function pointLive(dir) {
  try {
    unlinkSync(live);
  } catch {
    /* first time */
  }
  symlinkSync(dir, live);
}

function build(version, out) {
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', out, '--version', version, '--quiet'], { cwd: PWA });
  return out;
}

async function screenName() {
  return page.evaluate(() => document.getElementById('app').dataset.screen);
}

async function servedVersion() {
  // Fetched by the page, so it goes through the service worker's verified cache.
  const text = await page.evaluate(() => fetch('lib/version.js', { cache: 'no-store' }).then((r) => r.text()));
  return (text.match(/APP_VERSION = "([^"]+)"/) || [])[1];
}

async function openSettingsAndCheckUpdates() {
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.click(tid('check-updates'));
}

before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-e2e-'));
  live = join(tmp, 'live');
  pointLive(join(PWA, 'dist'));
  const extra = process.env.BEAM_RECOVERY_FILE ? ['--recovery-file', process.env.BEAM_RECOVERY_FILE] : [];
  srv = await startServer({ root: live, port: PORT, extra });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 375, height: 667 }, deviceScaleFactor: 2 });
  ({ page, rec } = await recordedPage(ctx, { label: 'e2e' }));
  await addVirtualAuthenticator(page);
  await page.routeWebSocket(/\.mainnet\.beam\.mw/, (ws) => {
    if (blockNode) ws.close({ code: 1006, reason: 'blocked by the test' });
    else ws.connectToServer();
  });
  console.log(`# screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

test('(a) first load: cross-origin isolated, verified copy installed, CSP clean', { timeout: 120000 }, async () => {
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 60000);
  const env = await page.evaluate(() => ({
    isolated: self.crossOriginIsolated,
    sab: typeof SharedArrayBuffer,
    controlled: Boolean(navigator.serviceWorker.controller),
    csp: window.__cspViolations,
  }));
  assert.equal(env.isolated, true, 'crossOriginIsolated');
  assert.equal(env.sab, 'function', 'SharedArrayBuffer');
  assert.equal(env.controlled, true, 'served by the verified service worker copy');
  assert.deepEqual(env.csp, []);
  assert.deepEqual(rec.csp, []);
  await shot(page, 'e2e-01-welcome');
});

test('(b) create: backup + confirm + password + passkey (PRF); no download, no scan; Synced within 5 blocks of the explorer; HF6 rules', { timeout: 20 * 60000 }, async () => {
  const { words, connectedAt } = await createWallet(page, { password: PASSWORD, passkey: true, shots: 'e2e' });
  throwawayWords = words;
  await waitHome(page, { shots: 'e2e' });
  const homeMs = Date.now() - connectedAt;
  await shot(page, 'e2e-11-home-first');
  await waitSynced(page);
  const syncedMs = Date.now() - connectedAt;
  console.log(`# new wallet: Connect -> home ${homeMs} ms, Connect -> Synced ${syncedMs} ms`);
  assert.ok(syncedMs < 60000, `a new wallet should be Synced within a minute, took ${syncedMs} ms`);
  assert.equal(await page.evaluate(() => window.__campfire.scanning()), false, 'a new wallet does not scan block bodies');
  assert.ok(!rec.requests.some((u) => u.includes('/recovery/')), 'create did not download the recovery snapshot');
  const conn = await page.evaluate(() => window.__campfire.connection());
  assert.equal(conn && conn.node_connected, true, 'ev_connection_changed reports the node (engine patch 0104)');
  // What a scan-less wallet cannot do, measured: offline / max-privacy addresses are refused.
  const mp = await page.evaluate(() => window.__campfire.createAddress('max_privacy'));
  const off = await page.evaluate(() => window.__campfire.createAddress('offline'));
  console.log(`# scan-less create_address: max_privacy ${JSON.stringify(mp)}, offline ${JSON.stringify(off)}`);
  assert.equal(mp.ok, false);
  assert.equal(mp.code, -32005);
  assert.equal(off.code, -32005);
  await page.waitForFunction(() => window.__campfire.sync().verified === true, null, { timeout: 180000, polling: 1000 });
  const h = await page.evaluate(() => window.__campfire.height());
  const ex = await explorerHeight(srv.url);
  console.log(`# wallet height ${h}, explorer height ${ex}`);
  assert.ok(Math.abs(h - ex) <= 5, `wallet ${h} vs explorer ${ex}`);
  await sleep(500);
  await shot(page, 'e2e-12-home-synced');
  const rules = rec.console.map((m) => m.text).join('\n');
  assert.ok(rules.includes('Rules signature'), 'engine printed its rules signature');
  assert.ok(rules.includes('3928666-96df3f33ee02ad9e'), 'engine follows HF6');
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
});

test('(c) receive: the address validates and its QR decodes to it', { timeout: 120000 }, async () => {
  await page.click(tid('receive'));
  await waitScreen(page, 'receive');
  await page.waitForFunction(() => document.querySelector('[data-testid="receive-address"]').textContent.length > 20, null, { timeout: 60000 });
  const address = await page.textContent(tid('receive-address'));
  const v = await page.evaluate((a) => window.__campfire.validate(a), address);
  assert.equal(v.is_valid, true);
  assert.equal(v.is_mine, true);
  assert.equal(v.type, 'regular');
  // Rasterise the on-screen QR in the page and decode it here with jsQR (independent decoder).
  const img = await page.evaluate(async () => {
    const svgEl = document.querySelector('.qr svg');
    const blob = new Blob([new XMLSerializer().serializeToString(svgEl)], { type: 'image/svg+xml' });
    const url = URL.createObjectURL(blob);
    const im = new Image();
    await new Promise((r, j) => ((im.onload = r), (im.onerror = j), (im.src = url)));
    const c = document.createElement('canvas');
    c.width = 400;
    c.height = 400;
    const g = c.getContext('2d');
    g.drawImage(im, 0, 0, 400, 400);
    return Array.from(g.getImageData(0, 0, 400, 400).data);
  });
  const decoded = jsQR(Uint8ClampedArray.from(img), 400, 400);
  assert.ok(decoded, 'QR decodes');
  assert.equal(decoded.data, address);
  await shot(page, 'e2e-13-receive');
  await page.click('.topbar .icon-btn');
  await waitScreen(page, 'home');
});

test('(d) lock -> unlock with passkey; lock -> wrong password refused -> password unlocks', { timeout: 180000 }, async () => {
  await page.click(tid('lock'));
  await waitScreen(page, 'unlock');
  await shot(page, 'e2e-14-unlock-passkey');
  await page.click(tid('unlock-passkey'));
  await waitScreen(page, 'home', 60000);
  await page.click(tid('lock'));
  await waitScreen(page, 'unlock');
  await page.click(tid('use-password'));
  await page.fill(tid('unlock-pw'), `${PASSWORD}x`);
  await page.click(tid('unlock-submit'));
  await page.waitForSelector('.notice.error', { timeout: 30000 });
  const err = await page.textContent('.notice.error');
  assert.match(err, /didn't open the wallet/);
  assert.equal(await screenName(), 'unlock');
  await shot(page, 'e2e-15-unlock-wrong-password');
  await page.fill(tid('unlock-pw'), PASSWORD);
  await page.click(tid('unlock-submit'));
  await waitScreen(page, 'home', 60000);
});

test('(e) reload: the wallet and its addresses persist', { timeout: 240000 }, async () => {
  const before = await page.evaluate(() => window.__campfire.addresses());
  assert.ok(before.length >= 1);
  const resp = await page.reload();
  assert.equal(resp.fromServiceWorker(), true, 'second load is served from the verified cache');
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  const after = await page.evaluate(() => window.__campfire.addresses());
  assert.deepEqual(after, before);
  await waitSynced(page, 180000);
});

test('screens: send, activity, settings, about, IP privacy, change password, delete', { timeout: 120000 }, async () => {
  const visit = async (name, file, params) => {
    await page.evaluate(([n, p]) => window.__campfire.go(n, p), [name, params || {}]);
    await waitScreen(page, name);
    await sleep(700);
    await shot(page, file);
  };
  await visit('send', 'e2e-16-send-empty');
  await page.fill(tid('send-address'), 'not-an-address');
  await page.waitForFunction(() => /isn't a BEAM address/.test(document.querySelector('[data-testid="address-hint"]').textContent), null, { timeout: 20000 });
  await page.fill(tid('send-amount'), '5');
  await shot(page, 'e2e-17-send-errors');
  await visit('activity', 'e2e-18-activity-empty');
  await visit('settings', 'e2e-19-settings');
  assert.match(await page.textContent(tid('passkey-row')), /On/);
  await visit('about', 'e2e-20-about');
  assert.match(await page.textContent(tid('about-rules')), /includes HF6/);
  assert.equal(await page.textContent(tid('about-loader')), 'yes');
  await visit('ipNotice', 'e2e-21-ip-privacy-settings');
  await visit('changePassword', 'e2e-22-change-password');
  await visit('deleteWallet', 'e2e-23-delete-wallet');
  await visit('home', 'e2e-24-home');
});

test('(f) blocked node: an honest error, sending off', { timeout: 240000 }, async () => {
  await page.click(tid('lock'));
  await waitScreen(page, 'unlock');
  blockNode = true;
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  await page.waitForFunction(() => window.__campfire.sync().state === 'offline', null, { timeout: 120000, polling: 1000 });
  const text = await page.textContent(tid('sync'));
  assert.match(text, /Can't reach the BEAM network/);
  assert.equal(await page.isDisabled(tid('send')), true);
  await shot(page, 'e2e-25-node-blocked');
  blockNode = false;
  await page.click(tid('lock'));
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  await waitSynced(page, 180000);
});

test('restore: the same 12 words in a fresh browser profile, with the snapshot download and import', { timeout: 20 * 60000 }, async () => {
  assert.ok(throwawayWords, 'needs the words from (b)');
  const ctx2 = await browser.newContext({ viewport: { width: 375, height: 667 }, deviceScaleFactor: 2 });
  const r2 = await recordedPage(ctx2, { label: 'restore' });
  try {
    await r2.page.goto(srv.url);
    const t0 = Date.now();
    await restoreWallet(r2.page, { words: throwawayWords, password: PASSWORD, shots: 'e2e-restore' });
    await waitHome(r2.page, { timeout: 15 * 60000, shots: 'e2e-restore' });
    await waitSynced(r2.page, 10 * 60000);
    console.log(`# restore: Connect -> Synced ${Date.now() - t0} ms (download + import + scan)`);
    assert.equal(await r2.page.evaluate(() => window.__campfire.scanning()), true, 'a restored wallet scans');
    assert.ok(r2.rec.requests.some((u) => u.includes('/recovery/mainnet_recovery.bin')));
    assert.deepEqual(foreignHosts(r2.rec, srv.url, [NODE]), []);
    assert.deepEqual((await r2.page.evaluate(() => window.__campfire.guard())).blocked, {});
    await shot(r2.page, 'e2e-restore-03-home');
  } finally {
    await ctx2.close();
  }
});

test('find coins from other wallets: Settings -> snapshot import turns scanning on', { timeout: 20 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.click(tid('find-coins'));
  await waitScreen(page, 'fastStart');
  await page.waitForSelector(tid('fast-download'));
  await shot(page, 'e2e-26a-find-coins');
  await page.click(tid('fast-download'));
  await waitHome(page, { timeout: 15 * 60000 });
  await waitSynced(page, 10 * 60000);
  assert.equal(await page.evaluate(() => window.__campfire.scanning()), true);
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  assert.equal(await page.isVisible(tid('find-coins')), false, 'offered only while the wallet does not scan');
});

test('IP privacy: the page contacted only this origin and the chosen node; the guard refused nothing', async () => {
  const foreign = foreignHosts(rec, srv.url, [NODE]);
  assert.deepEqual(foreign, [], `unexpected hosts: ${foreign.join(', ')}`);
  const wsHosts = [...new Set(rec.websockets.map((u) => new URL(u).host))];
  assert.deepEqual(wsHosts, [NODE]);
  const blocked = (await page.evaluate(() => window.__campfire.guard())).blocked;
  console.log(`# node guard refusals this session: ${JSON.stringify(blocked)}`);
  assert.deepEqual(blocked, {}, 'the engine no longer dials anything but the chosen node (engine patch 0103)');
  console.log(`# requests recorded: ${rec.requests.length}, websocket opens: ${rec.websockets.length} (all to ${NODE})`);
});

test('(g1) the verified copy works without the server (cache only)', { timeout: 120000 }, async () => {
  const empty = join(tmp, 'empty');
  mkdirSync(empty, { recursive: true });
  pointLive(empty);
  const resp = await page.reload();
  assert.equal(resp.fromServiceWorker(), true);
  await waitScreen(page, 'unlock', 60000);
  await shot(page, 'e2e-26-offline-cache-unlock');
  assert.equal(await servedVersion(), V0);
  pointLive(join(PWA, 'dist'));
});

test('(g2) a signed update is staged, but applied only after "Update"', { timeout: 300000 }, async () => {
  const v2 = build(V1, join(tmp, 'v2'));
  pointLive(v2);
  await page.reload();
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  await openSettingsAndCheckUpdates();
  await page.waitForSelector(tid('update-apply-sheet'), { timeout: 120000 });
  await shot(page, 'e2e-27-update-ready');
  // Staged and verified, still not in use: a reload keeps serving V0.
  assert.equal(await servedVersion(), V0);
  await page.reload();
  await waitScreen(page, 'unlock', 60000);
  assert.equal(await servedVersion(), V0);
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  await openSettingsAndCheckUpdates();
  await page.waitForSelector(tid('update-apply-sheet'), { timeout: 120000 });
  await Promise.all([page.waitForEvent('load', { timeout: 60000 }), page.click(tid('update-apply-sheet'))]);
  await waitScreen(page, 'unlock', 60000);
  assert.equal(await servedVersion(), V1);
});

test('(g3) a tampered update and a wrongly signed update are refused; the app stays on the first update', { timeout: 300000 }, async () => {
  // Tampered file: app.js changed after signing.
  const v3 = build(V2, join(tmp, 'v3'));
  appendFileSync(join(v3, 'app.js'), '\n/* tampered */\n');
  pointLive(v3);
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  await openSettingsAndCheckUpdates();
  await page.waitForSelector('text=Update refused', { timeout: 120000 });
  const why = await page.textContent('.sheet .notice');
  assert.match(why, /app\.js/);
  await shot(page, 'e2e-28-update-refused-tampered');
  assert.equal(await servedVersion(), V1);
  assert.ok(!(await page.evaluate(() => fetch('app.js').then((r) => r.text()))).includes('tampered'));
  await page.click('.sheet .btn-primary');

  // Wrong key: release.json re-signed by a key that is not BEAM Campfire's.
  const v4 = build(V3, join(tmp, 'v4'));
  const k = await webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const sig = new Uint8Array(await webcrypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, k.privateKey, readFileSync(join(v4, 'release.json'))));
  writeFileSync(join(v4, 'release.sig'), Buffer.from(sig).toString('base64') + '\n');
  pointLive(v4);
  await openSettingsAndCheckUpdates();
  await page.waitForSelector('text=Update refused', { timeout: 120000 });
  assert.match(await page.textContent('.sheet .notice'), /not signed with the BEAM Campfire release key/);
  await shot(page, 'e2e-29-update-refused-signature');
  assert.equal(await servedVersion(), V1);
  pointLive(join(PWA, 'dist'));
});

test('password change, Face ID off, and delete from this device', { timeout: 240000 }, async () => {
  // We are on V1 at the unlock screen after (g3).
  await page.reload();
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  const NEW_PASSWORD = `${PASSWORD}-new`;
  await page.evaluate(() => window.__campfire.go('changePassword'));
  await waitScreen(page, 'changePassword');
  await page.fill(tid('cp-current'), 'wrong-password');
  await page.fill(tid('cp-new'), NEW_PASSWORD);
  await page.fill(tid('cp-new2'), NEW_PASSWORD);
  await page.click(tid('cp-save'));
  await page.waitForSelector('.notice.error', { timeout: 30000 });
  assert.match(await page.textContent('.notice.error'), /current password didn't match/);
  await page.fill(tid('cp-current'), PASSWORD);
  await page.click(tid('cp-save'));
  await waitScreen(page, 'settings', 30000);
  // Face ID off (asks for Face ID first), then only the new password opens the wallet.
  await page.click(tid('passkey-row'));
  await page.click(tid('auth-passkey'));
  await page.waitForFunction(() => /Off/.test(document.querySelector('[data-testid="passkey-row"]')?.textContent || ''), null, { timeout: 30000 });
  await page.click(tid('lock-now'));
  await waitScreen(page, 'unlock');
  assert.equal(await page.isVisible(tid('unlock-passkey')), false, 'no Face ID button once it is off');
  await page.fill(tid('unlock-pw'), PASSWORD);
  await page.click(tid('unlock-submit'));
  await page.waitForSelector('.notice.error', { timeout: 30000 });
  await page.fill(tid('unlock-pw'), NEW_PASSWORD);
  await page.click(tid('unlock-submit'));
  await waitScreen(page, 'home', 60000);
  // Delete: needs the typed confirmation, ends at Welcome, and stays deleted after a reload.
  await page.evaluate(() => window.__campfire.go('deleteWallet'));
  await waitScreen(page, 'deleteWallet');
  assert.equal(await page.isDisabled(tid('delete-submit')), true);
  await page.fill(tid('delete-confirm'), 'delete');
  await page.click(tid('delete-submit'));
  await waitScreen(page, 'welcome', 60000);
  await page.reload();
  await waitScreen(page, 'welcome', 60000);
  await shot(page, 'e2e-30-after-delete-welcome');
  const leftover = await page.evaluate(async () => (await indexedDB.databases()).map((d) => d.name));
  console.log(`# IndexedDB databases after delete: ${JSON.stringify(leftover)}`);
});

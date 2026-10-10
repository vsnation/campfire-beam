// GitHub Pages, emulated: the app under a sub-path (/beam-campfire-pwa/) on a
// static host that sends NO security headers and has no relays (404 HTML for
// /explorer and /recovery), like https://vsnation.github.io/beam-campfire-pwa/.
//
//   npm run e2e:pages
//
// 1. First open: the setup screen (never "this browser can't run it"), the
//    verified copy installs under the sub-path scope, one reload, and the page
//    is cross-origin isolated (COOP/COEP come from the service worker).
// 2. Create a wallet through the screens -> Synced on mainnet (is_in_sync, height
//    = the explorer's, asked by this test); nothing asked of /explorer or /recovery.
// 3. Restore with 12 words on this host: no snapshot here -> "Use a recovery file I
//    downloaded" is the main button, the download says plainly there is none; no crash.
// 4. Check for updates works under the sub-path (up to date).
// 5. The 0.1.2 that is publicly served (downloaded from Pages, signature-checked):
//    on a header-less host it stops at "can't run" (the bug this release fixes);
//    installed where headers exist, it accepts this release as a signed update.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync, symlinkSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { webcrypto } from 'node:crypto';
import { PWA, launch, recordedPage, shot, waitScreen, sleep, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';
import { startStaticHost } from './static_host.mjs';
import { EXPLORER_UPSTREAMS } from '../../tools/headers.mjs';
import { verifyReleaseSignature, verifyManifest, verifyFile, compareVersions } from '../../src/lib/release.js';

const PORT = Number(process.env.CAMPFIRE_PAGES_PORT || 8797); // and PORT + 1
const PUBLIC = 'https://vsnation.github.io/beam-campfire-pwa/';
const PASSWORD = `pages-${Math.random().toString(36).slice(2, 10)}`;
const tid = (id) => `[data-testid="${id}"]`;
const pkg = JSON.parse(readFileSync(join(PWA, 'package.json'), 'utf8'));
const pub = JSON.parse(readFileSync(join(PWA, 'keys', 'release_public.jwk'), 'utf8'));

let tmp, rel, host, browser, words = null;

async function networkHeight() {
  for (const u of EXPLORER_UPSTREAMS) {
    try {
      const r = await fetch(u, { signal: AbortSignal.timeout(6000) });
      if (r.ok) {
        const j = await r.json();
        if (Number.isSafeInteger(j.height)) return j.height;
      }
    } catch {
      /* next */
    }
  }
  return null;
}

async function freshPage(label) {
  const ctx = await browser.newContext({ viewport: { width: 375, height: 667 }, deviceScaleFactor: 2 });
  const { page, rec } = await recordedPage(ctx, { label });
  return { ctx, page, rec };
}

before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-pages-'));
  rel = join(tmp, 'rel');
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', rel, '--version', pkg.version, '--quiet'], { cwd: PWA });
  host = await startStaticHost({ root: rel, port: PORT });
  browser = await launch();
  console.log(`# Pages emulation at ${host.url}, release ${pkg.version}; screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close();
  if (host) await host.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

test('first open on a header-less static host: setup screen, install under the sub-path, then cross-origin isolated', { timeout: 180000 }, async () => {
  const { ctx, page } = await freshPage('pages-1');
  const screens = [];
  host.setDelay(120); // a slower line, so the first run can be seen and photographed
  await page.goto(host.url);
  const t0 = Date.now();
  // Record every screen until Welcome; "problem" must never appear.
  while (Date.now() - t0 < 120000) {
    const s = await page.evaluate(() => document.getElementById('app')?.dataset.screen || null).catch(() => null);
    if (s && screens[screens.length - 1] !== s) screens.push(s);
    if (s === 'install' && !screens.includes('install-shot')) {
      const iso = await page.evaluate(() => self.crossOriginIsolated);
      assert.equal(iso, false, 'the first, unverified load has no isolation (no server headers)');
      await page.waitForFunction(() => Number(document.querySelector('main.install')?.dataset.done || 0) >= 5, null, { timeout: 60000, polling: 100 }).catch(() => {});
      await shot(page, 'pages-01-first-run').catch(() => console.log('# (the page reloaded before the screenshot)'));
      screens.push('install-shot');
    }
    if (s === 'welcome') break;
    await sleep(100);
  }
  console.log(`# screens on first open: ${screens.filter((x) => x !== 'install-shot').join(' -> ')}`);
  assert.ok(screens.includes('install'), 'the setup screen came first');
  assert.ok(!screens.includes('problem'), 'never "this browser can\'t run BEAM Campfire"');
  const env = await page.evaluate(async () => {
    const reg = await navigator.serviceWorker.getRegistration();
    return { iso: self.crossOriginIsolated, sab: typeof SharedArrayBuffer, controller: navigator.serviceWorker.controller && new URL(navigator.serviceWorker.controller.scriptURL).pathname, scope: reg && new URL(reg.scope).pathname };
  });
  console.log(`# after the reload: ${JSON.stringify(env)}`);
  assert.equal(env.iso, true, 'cross-origin isolated: the service worker added COOP/COEP');
  assert.equal(env.sab, 'function');
  assert.match(env.controller, /^\/beam-campfire-pwa\/sw-[0-9a-f]{16}\.js$/);
  assert.equal(env.scope, '/beam-campfire-pwa/');
  await shot(page, 'pages-02-welcome');
  host.setDelay(0);
  await ctx.close();
});

test('create a wallet on the Pages host and sync with mainnet; nothing asked of /explorer or /recovery', { timeout: 10 * 60000 }, async () => {
  const { ctx, page, rec } = await freshPage('pages-2');
  await page.goto(host.url);
  await waitScreen(page, 'welcome', 120000);
  const from = host.requests.length;
  ({ words } = await createWallet(page, { password: PASSWORD }));
  await waitHome(page, { timeout: 5 * 60000 });
  await waitSynced(page, 5 * 60000);
  assert.equal(await page.evaluate(() => window.__campfire.inSync()), true, 'is_in_sync');
  const t0 = Date.now();
  for (;;) {
    const h = await page.evaluate(() => window.__campfire.height());
    const ex = await networkHeight();
    if (h && ex && Math.abs(h - ex) <= 5) {
      console.log(`# Pages host: new wallet Synced at ${h}, explorer ${ex}, is_in_sync true`);
      break;
    }
    if (Date.now() - t0 > 180000) throw new Error(`height ${h} vs explorer ${ex}`);
    await sleep(3000);
  }
  await shot(page, 'pages-03-home-synced');
  const asked = host.requests.slice(from).filter((r) => /\/(explorer|recovery)\//.test(r.path));
  assert.deepEqual(asked, [], 'no explorer, no snapshot requests');
  const app = host.requests.slice(from).filter((r) => !(r.sw === 'script') && !(r.dest === 'document' && r.path === '/beam-campfire-pwa/'));
  assert.deepEqual(app, [], 'after install, nothing but the browser\'s own requests reached the host');
  assert.deepEqual(rec.errors, []);
  await ctx.close();
});

test('restore with 12 words on a host without the snapshot: the recovery file is the way, plainly; no crash', { timeout: 5 * 60000 }, async () => {
  assert.ok(words, 'needs the words from the previous test');
  const { ctx, page, rec } = await freshPage('pages-3');
  await page.goto(host.url);
  await waitScreen(page, 'welcome', 120000);
  await page.click(tid('restore'));
  await waitScreen(page, 'restore');
  await page.fill(tid('word-1'), words.join(' '));
  await page.waitForFunction(() => !document.querySelector('[data-testid="restore-submit"]').disabled, null, { timeout: 30000 });
  await page.click(tid('restore-submit'));
  await waitScreen(page, 'setPassword');
  await page.fill(tid('pw1'), PASSWORD);
  await page.fill(tid('pw2'), PASSWORD);
  await page.click(tid('save-password'));
  for (let i = 0; i < 60; i++) {
    const s = await page.evaluate(() => document.getElementById('app').dataset.screen);
    if (s === 'fastStart') break;
    if (s === 'passkeySetup') await page.click(tid('passkey-skip')).catch(() => {});
    if (s === 'ipNotice') await page.click(tid('ip-connect')).catch(() => {});
    await sleep(500);
  }
  await waitScreen(page, 'fastStart');
  await page.waitForSelector(tid('recovery-file-choose'), { timeout: 30000 });
  assert.match(await page.getAttribute(tid('recovery-file-choose'), 'class'), /btn-primary/, 'the recovery file is the main way here');
  assert.match(await page.textContent(tid('recovery-file-help')), /mobile-restore\.beam\.mw\/mainnet\/mainnet_recovery\.bin/);
  assert.match(await page.textContent('main'), /This site has no copy of it/);
  await shot(page, 'pages-04-restore-no-snapshot');
  await page.click(tid('fast-download'));
  await page.waitForSelector('.notice.error', { timeout: 30000 });
  assert.match(await page.textContent('.notice.error'), /hosted without BEAM's snapshot/);
  assert.equal(await page.isVisible(tid('recovery-file-choose')), true, 'and the file is still offered');
  await shot(page, 'pages-05-restore-download-absent');
  assert.deepEqual(rec.errors, [], 'no crash');
  await ctx.close();
});

test('check for updates works under the sub-path', { timeout: 120000 }, async () => {
  const { ctx, page } = await freshPage('pages-4');
  await page.goto(host.url);
  await waitScreen(page, 'welcome', 120000);
  await page.evaluate(() => window.__campfire.go('settings'));
  // Settings needs an open wallet; the update check itself is the worker's: ask it directly.
  const r = await page.evaluate(() => new Promise((resolve) => {
    const ch = new MessageChannel();
    ch.port1.onmessage = (e) => resolve(e.data);
    navigator.serviceWorker.controller.postMessage({ type: 'check-update' }, [ch.port2]);
  }));
  console.log(`# update check on the Pages host: ${JSON.stringify(r)}`);
  assert.equal(r.result, 'none', 'the signed release under the sub-path verifies and is this one');
  await ctx.close();
});

test('the publicly served release (installed, with a wallet) takes this one through Check for updates; the loader moves once, no false alarm', { timeout: 15 * 60000 }, async () => {
  // Download what GitHub Pages serves now and check it against the release key, file by file.
  const old = join(tmp, 'public');
  const get = async (p) => new Uint8Array(await (await fetch(new URL(p, PUBLIC), { signal: AbortSignal.timeout(60000) })).arrayBuffer());
  const relBytes = await get('release.json');
  const sig = await get('release.sig');
  const release = await verifyReleaseSignature(relBytes, new TextDecoder().decode(sig), pub);
  const manifestBytes = await get('manifest.json');
  const manifest = await verifyManifest(release, manifestBytes);
  mkdirSync(old, { recursive: true });
  writeFileSync(join(old, 'release.json'), relBytes);
  writeFileSync(join(old, 'release.sig'), sig);
  writeFileSync(join(old, 'manifest.json'), manifestBytes);
  for (const f of manifest.files) {
    const b = await get(f.path);
    await verifyFile(f, b);
    mkdirSync(dirname(join(old, f.path)), { recursive: true });
    writeFileSync(join(old, f.path), b);
  }
  const oldLoader = manifest.files.map((f) => f.path).find((p) => /^sw(-[0-9a-f]+)?\.js$/.test(p));
  console.log(`# public release ${release.version} (${manifest.files.length} files, manifest ${release.manifest_sha256.slice(0, 16)}…, loader ${oldLoader}) downloaded and verified`);
  // When the public site already serves this version or a later one, update to
  // the next patch version after it, built from this tree, so the move between
  // loaders is always tested (an older one would rightly be refused).
  let next = rel;
  let nextVersion = pkg.version;
  if (compareVersions(release.version, pkg.version) >= 0) {
    const v = release.version.split('.').map(Number);
    nextVersion = `${v[0]}.${v[1]}.${v[2] + 1}`;
    next = join(tmp, 'rel-next');
    execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', next, '--version', nextVersion, '--quiet'], { cwd: PWA });
    console.log(`# the public site serves ${release.version} (this tree: ${pkg.version}); updating it to ${nextVersion} built from this tree`);
  }

  // Serve it like Pages does, install it, and make a wallet with it.
  const live = join(tmp, 'live');
  const point = (dir) => {
    try {
      unlinkSync(live);
    } catch {
      /* first */
    }
    symlinkSync(dir, live);
  };
  point(old);
  const host2 = await startStaticHost({ root: live, port: PORT + 1 });
  try {
    const { ctx, page, rec } = await freshPage('pages-upd');
    const served = async () => (await page.evaluate(() => fetch('lib/version.js', { cache: 'no-store' }).then((r) => r.text()))).match(/APP_VERSION = "([^"]+)"/)[1];
    await page.goto(host2.url);
    await waitScreen(page, 'welcome', 120000);
    assert.equal(await served(), release.version);
    assert.equal(await page.evaluate(() => self.crossOriginIsolated), true, `${release.version} runs isolated on the static host`);
    await createWallet(page, { password: PASSWORD });
    await waitHome(page, { timeout: 5 * 60000 });
    await waitSynced(page, 5 * 60000);
    const addrsBefore = await page.evaluate(() => window.__campfire.addresses());

    // The host now serves this release. The person taps Check for updates, then Update.
    point(next);
    await page.evaluate(() => window.__campfire.go('settings'));
    await waitScreen(page, 'settings');
    await page.click(tid('check-updates'));
    await page.waitForSelector(tid('update-apply-sheet'), { timeout: 120000 });
    await shot(page, 'pages-06-update-ready');
    await Promise.all([page.waitForEvent('load', { timeout: 60000 }), page.click(tid('update-apply-sheet'))]);
    await waitScreen(page, 'unlock', 120000);
    assert.equal(await served(), nextVersion, `the installed ${release.version} now runs ${nextVersion}`);
    // This release's loader has a new name: the page moves to it once; that is not a takeover.
    const loader = readFileSync(join(next, 'lib', 'version.js'), 'utf8').match(/LOADER = "(sw-[0-9a-f]+\.js)"/)[1];
    await page.waitForFunction((l) => navigator.serviceWorker.controller && navigator.serviceWorker.controller.scriptURL.endsWith(`/${l}`), loader, { timeout: 20000 });
    assert.equal(await page.evaluate(() => window.__campfire.intrusion()), null, 'the approved move to the new loader is not mistaken for a takeover');
    assert.equal(await page.evaluate(() => self.crossOriginIsolated), true);
    await page.fill(tid('unlock-pw'), PASSWORD);
    await page.click(tid('unlock-submit'));
    await waitScreen(page, 'home', 60000);
    await waitSynced(page, 180000);
    assert.deepEqual(await page.evaluate(() => window.__campfire.addresses()), addrsBefore, 'the same wallet, after the update');
    console.log(`# ${release.version} (${oldLoader}) -> ${nextVersion} (${loader}) through Check for updates on the static host: wallet kept, Synced, loader moved, no tripwire`);
    await shot(page, 'pages-07-after-update');
    // A cold start after the move: still this release, still no alarm.
    await page.reload();
    await waitScreen(page, 'unlock', 60000);
    assert.equal(await served(), nextVersion);
    assert.equal(await page.evaluate(() => window.__campfire.intrusion()), null);
    assert.deepEqual(rec.errors, []);
    await ctx.close();
  } finally {
    await host2.stop();
  }
});

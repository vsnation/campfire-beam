// Import a wallet.db, end to end: the installed Google Chrome (headless), the
// dev server, BEAM mainnet, and a REAL wallet.db made by BEAM's 7.5.14493
// core (native beam-wallet CLI, throwaway wallet, random password; see
// walletdb.mjs). Spends nothing.
//
//   npm run e2e:import     (stages the engine, then builds its own release in a temp dir)
//
// What it proves: three choices on Welcome without scrolling; files that are
// not wallets are refused, and a wrong password is refused, with nothing
// added to the device; the right password brings the wallet in, it syncs on
// mainnet (is_in_sync, height within 5 blocks of the explorer) and it is the
// same wallet (its CLI address is in the app's address list); lock/unlock and
// a reload keep it; the backup screen says "no recovery phrase" and shows no
// words; nothing offers a rescan; delete removes it. And: no request other
// than GET left the page, the original file is unchanged, the password is in
// no console line and no server log, and the page talked only to this origin
// and the chosen node.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync, readFileSync, existsSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PWA, startServer, launch, recordedPage, shot, waitScreen, foreignHosts, waitHeightNearExplorer, sleep, SHOTS, NODE_HOSTS } from './harness.mjs';
import { waitHome, waitSynced, unlockWithPassword, skipsIpNotice } from './flows.mjs';
import { makeWalletDb, cliVersion, sha256File, openWithCli, WANT_CORE, BEAM_CLI } from './walletdb.mjs';
import { IMPORT_PROBLEM, NO_PHRASE_NOTICE } from '../../src/lib/wallet_file.js';

const PORT = Number(process.env.CAMPFIRE_IMPORT_PORT || 8792);
const tid = (id) => `[data-testid="${id}"]`;
const pkg = JSON.parse(readFileSync(join(PWA, 'package.json'), 'utf8'));

let tmp, wdb, junk, srv, browser, ctx, page, rec;
const nonGet = [];

async function screenName(p = page) {
  return p.evaluate(() => document.getElementById('app').dataset.screen);
}

/** Keys of the engine's IndexedDB file store (what survives a reload). */
async function idbFiles(p = page) {
  return p.evaluate(
    () =>
      new Promise((resolve) => {
        const r = indexedDB.open('/beam_wallet');
        r.onsuccess = () => {
          const db = r.result;
          if (!db.objectStoreNames.contains('FILE_DATA')) {
            db.close();
            return resolve([]);
          }
          const q = db.transaction('FILE_DATA', 'readonly').objectStore('FILE_DATA').getAllKeys();
          q.onsuccess = () => {
            db.close();
            resolve(q.result.map(String).filter((k) => k !== '/beam_wallet').sort());
          };
          q.onerror = () => resolve(['<error>']);
        };
        r.onerror = () => resolve(['<error>']);
      }),
  );
}

async function problemText() {
  await page.waitForSelector(tid('import-problem'), { timeout: 120000 });
  return page.textContent(tid('import-problem'));
}

async function nothingAdded(label) {
  assert.equal(await page.evaluate(() => window.__campfire.record()), null, `${label}: no wallet record`);
  const idb = await idbFiles();
  assert.deepEqual(idb, [], `${label}: nothing saved to IndexedDB (${idb.join(', ')})`);
  const files = await page.evaluate(() => window.__campfire.walletFiles());
  assert.ok(!files.includes('wallet.db'), `${label}: no wallet.db in the engine (${files.join(', ')})`);
}

async function chooseFile(path) {
  await page.setInputFiles(tid('import-file'), path);
}

before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-import-'));
  const v = cliVersion(join(tmp, 'cli'));
  assert.equal(v, WANT_CORE, `BEAM CLI at ${BEAM_CLI} must be ${WANT_CORE} (got ${v})`);
  wdb = makeWalletDb(join(tmp, 'src'));
  console.log(`# test wallet.db: ${wdb.size} bytes from beam-wallet ${v}, ${wdb.addresses.length} address(es) listed by the CLI`);
  assert.ok(wdb.addresses.length >= 1, 'the CLI lists the new wallet\'s default address');
  junk = {
    tiny: join(tmp, 'tiny.db'),
    photo: join(tmp, 'IMG_0001.jpg'),
    random: join(tmp, 'notes.db'),
  };
  writeFileSync(junk.tiny, randomBytes(300));
  writeFileSync(junk.photo, Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), randomBytes(48_997)]));
  writeFileSync(junk.random, randomBytes(64 * 1024)); // whole pages, but not a database
  const rel = join(tmp, 'rel');
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', rel, '--version', pkg.version, '--quiet'], { cwd: PWA });
  srv = await startServer({ root: rel, port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 375, height: 667 }, deviceScaleFactor: 2 });
  ctx.on('request', (r) => {
    if (!['GET', 'HEAD'].includes(r.method())) nonGet.push(`${r.method()} ${r.url()}`);
  });
  // Headless Chrome has no share sheet: the export takes the download path (iPhone: share sheet).
  await ctx.addInitScript(() => {
    Object.defineProperty(Navigator.prototype, 'share', { value: undefined, configurable: true });
    Object.defineProperty(Navigator.prototype, 'canShare', { value: undefined, configurable: true });
  });
  ({ page, rec } = await recordedPage(ctx, { label: 'import' }));
  console.log(`# screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
  if (tmp) assert.equal(existsSync(tmp), false, 'the throwaway wallet.db is deleted');
});

test('Welcome: three choices, all visible on a 375 x 667 screen without scrolling', { timeout: 120000 }, async () => {
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 60000);
  for (const id of ['create', 'restore', 'import']) {
    const b = await page.locator(tid(id)).boundingBox();
    assert.ok(b && b.y >= 0 && b.y + b.height <= 667, `${id} is above the fold (${JSON.stringify(b)})`);
  }
  assert.equal(await page.textContent(tid('import')), 'Import a wallet.db file');
  assert.match(await page.getAttribute(tid('create'), 'class'), /btn-primary/);
  assert.match(await page.getAttribute(tid('import'), 'class'), /btn-secondary/);
  await shot(page, 'import-01-welcome');

  // The same screen as an iPhone Safari tab sees it, with the "add to Home Screen" guide.
  const ios = await browser.newContext({
    viewport: { width: 375, height: 667 },
    deviceScaleFactor: 2,
    isMobile: true,
    hasTouch: true,
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
  });
  try {
    const p2 = await ios.newPage();
    await p2.goto(srv.url);
    await waitScreen(p2, 'welcome', 60000);
    await p2.waitForSelector(tid('a2hs'));
    const bottoms = {};
    for (const id of ['create', 'restore', 'import']) {
      const b = await p2.locator(tid(id)).boundingBox();
      bottoms[id] = Math.round(b.y + b.height);
    }
    console.log(`# iPhone tab with the Home Screen guide, 375x667: button bottoms ${JSON.stringify(bottoms)}`);
    for (const [id, y] of Object.entries(bottoms)) assert.ok(y <= 667, `${id} above the fold with the guide (${y})`);
    await shot(p2, 'import-01b-welcome-iphone-tab-guide');
  } finally {
    await ios.close();
  }
});

test('files that are not wallets are refused before any password, plainly', { timeout: 120000 }, async () => {
  await page.click(tid('import'));
  await waitScreen(page, 'importWallet');
  await page.waitForSelector(tid('import-choose'));
  await shot(page, 'import-02-choose');
  const accept = await page.getAttribute(tid('import-file'), 'accept');
  assert.equal(accept, null, 'no accept filter: iOS must not grey out a .db file');
  // Tapping the button opens the browser's own file chooser (one file, any type).
  const [chooser] = await Promise.all([page.waitForEvent('filechooser', { timeout: 10000 }), page.click(tid('import-choose'))]);
  assert.equal(chooser.isMultiple(), false);
  await chooser.setFiles(junk.tiny);
  assert.equal((await problemText()).trim(), IMPORT_PROBLEM.tooSmall);
  await chooseFile(junk.photo);
  assert.equal((await problemText()).trim(), IMPORT_PROBLEM.notDatabase);
  await shot(page, 'import-03-not-a-wallet');
  assert.equal(await page.isVisible(tid('import-pw')), false, 'no password asked for a file that cannot be a wallet');
  await nothingAdded('after refused files');
});

test('a whole-page file that is not a database: the password check refuses it, nothing added', { timeout: 300000 }, async () => {
  await chooseFile(junk.random);
  await page.waitForFunction(() => document.querySelector('[data-testid="import-file-name"]')?.textContent === 'notes.db', null, { timeout: 30000 });
  await page.fill(tid('import-pw'), 'some-password');
  const t0 = Date.now();
  await page.click(tid('import-submit'));
  assert.equal((await problemText()).trim(), IMPORT_PROBLEM.wrongPassword);
  console.log(`# random 64 KB file: refused after ${Date.now() - t0} ms`);
  await nothingAdded('after a non-wallet file');
});

test('the real wallet.db with a wrong password: refused with the right message, nothing added', { timeout: 300000 }, async () => {
  await chooseFile(wdb.path);
  await page.waitForFunction(() => document.querySelector('[data-testid="import-file-name"]')?.textContent === 'wallet.db', null, { timeout: 30000 });
  assert.equal(await page.inputValue(tid('import-pw')), '', 'a new file starts with an empty password field');
  await shot(page, 'import-04-file-chosen');
  await page.fill(tid('import-pw'), `${wdb.password}x`);
  const t0 = Date.now();
  await page.click(tid('import-submit'));
  assert.equal((await problemText()).trim(), IMPORT_PROBLEM.wrongPassword);
  console.log(`# wrong password refused after ${Date.now() - t0} ms`);
  assert.equal(await screenName(), 'importWallet');
  const cta = await page.locator(tid('import-submit')).boundingBox();
  assert.ok(cta.y + cta.height <= 667, `"Import my wallet" stays above the fold with the error shown (${Math.round(cta.y + cta.height)})`);
  await shot(page, 'import-05-wrong-password');
  await nothingAdded('after a wrong password');
});

test('the right password: the wallet comes in, connects and is Synced on mainnet; it is the same wallet', { timeout: 10 * 60000 }, async () => {
  await page.fill(tid('import-pw'), wdb.password);
  const t0 = Date.now();
  await page.click(tid('import-submit'));
  await page.waitForFunction(() => ['passkeySetup', 'ipNotice', 'fastStart', 'home'].includes(document.getElementById('app').dataset.screen), null, { timeout: 180000 });
  console.log(`# right password: wallet added after ${Date.now() - t0} ms`);
  if ((await screenName()) === 'passkeySetup') await page.click(tid('passkey-skip'));
  await skipsIpNotice(page);
  const connectedAt = Date.now();
  await waitHome(page, { timeout: 5 * 60000 });
  await waitSynced(page, 5 * 60000);
  console.log(`# imported wallet: Connect -> Synced ${Date.now() - connectedAt} ms`);
  const rec0 = await page.evaluate(() => window.__campfire.record());
  assert.deepEqual({ imported: rec0.imported, restored: rec0.restored, scan: rec0.scan }, { imported: true, restored: false, scan: false });
  assert.equal(await page.evaluate(() => window.__campfire.scanning()), false, 'an imported wallet runs without the block scan');
  assert.equal(await page.evaluate(() => window.__campfire.inSync()), true, 'wallet_status.is_in_sync');
  const { height: h, explorer: ex } = await waitHeightNearExplorer(page, srv.url);
  console.log(`# imported wallet height ${h}, explorer height ${ex}, is_in_sync true`);
  assert.ok(Math.abs(h - ex) <= 5, `wallet ${h} vs explorer ${ex}`);
  const addrs = await page.evaluate(() => window.__campfire.addresses());
  for (const a of wdb.addresses) assert.ok(addrs.includes(a), 'the address the CLI made for this wallet is in the app: it is the same wallet');
  const idb = await idbFiles();
  assert.deepEqual(idb, ['/beam_wallet/wallet.db'], 'saved as wallet.db, nothing else');
  assert.deepEqual(await page.evaluate(() => window.__campfire.walletFiles()), ['wallet.db']);
  assert.ok(rec.requests.every((u) => !u.includes('/recovery/')), 'no snapshot download');
  const rules = rec.console.map((m) => m.text).join('\n');
  assert.ok(rules.includes('3928666-96df3f33ee02ad9e'), 'engine follows HF6');
  await sleep(500);
  assert.equal(await page.isVisible(tid('backup-prompt')), true, 'Home asks for a copy outside this phone: the wallet has no 12 words');
  await shot(page, 'import-06-home-synced');
});

test('receive: an address of this wallet, valid and mine', { timeout: 120000 }, async () => {
  await page.click(tid('receive'));
  await waitScreen(page, 'receive');
  await page.waitForFunction(() => document.querySelector('[data-testid="receive-address"]').textContent.length > 20, null, { timeout: 60000 });
  const address = await page.textContent(tid('receive-address'));
  const v = await page.evaluate((a) => window.__campfire.validate(a), address);
  assert.equal(v.is_valid, true);
  assert.equal(v.is_mine, true);
  await shot(page, 'import-07-receive');
  await page.click('.topbar .icon-btn');
  await waitScreen(page, 'home');
});

test('the backup prompt leads to Export wallet.db; the export opens in BEAM\'s native core; then Home stops asking', { timeout: 300000 }, async () => {
  await page.click(tid('backup-prompt-export'));
  await waitScreen(page, 'backup');
  assert.equal(await page.textContent(tid('export-last')), 'Not exported yet.');
  await page.click(tid('export-start'));
  await page.fill(tid('export-pw'), wdb.password);
  await page.click(tid('export-prepare'));
  await page.waitForSelector(tid('export-save'), { timeout: 180000 });
  const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 30000 }), page.click(tid('export-save'))]);
  const dest = join(tmp, 'exported-imported.db');
  await dl.saveAs(dest);
  const cli = openWithCli(dest, wdb.password, join(tmp, 'cli2'));
  assert.equal(cli.opened, true, 'the exported copy of the imported wallet opens in BEAM\'s native core with its password');
  for (const a of wdb.addresses) assert.ok(cli.addresses.includes(a), 'and it is the same wallet');
  console.log(`# imported wallet exported: ${readFileSync(dest).length} bytes; BEAM CLI ${WANT_CORE} opened it`);
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  assert.equal(await page.isVisible(tid('backup-prompt')), false, 'after one export Home no longer asks');
  await page.evaluate(() => window.__campfire.go('backup'));
  await waitScreen(page, 'backup');
  assert.match(await page.textContent(tid('export-last')), /^Last exported /);
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await waitSynced(page, 180000);
});

test('backup shows the no-phrase notice and never words; Rescan is offered without words', { timeout: 120000 }, async () => {
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  assert.match(await page.textContent(tid('backup-row')), /wallet\.db file and its password/);
  // Rescan keeps wallet.db and rebuilds only its coins, so an imported wallet gets it too.
  assert.equal(await page.isVisible(tid('rescan-row')), true, 'Rescan is offered for an imported wallet');
  assert.ok(!/12 words/.test(await page.textContent('main')), 'Settings does not mention 12 words for it');
  await shot(page, 'import-08-settings');
  await page.click(tid('backup-row'));
  await waitScreen(page, 'backup');
  assert.equal((await page.textContent(tid('no-recovery-phrase'))).trim(), NO_PHRASE_NOTICE);
  assert.equal(await page.locator('.word, .words, [data-testid="words"], [data-testid="reveal"]').count(), 0, 'no word grid, no reveal button');
  await shot(page, 'import-09-backup-no-phrase');
  // Its Rescan screen never mentions words; Not now leaves the wallet running.
  await page.evaluate(() => window.__campfire.go('fastStart', { rescan: true }));
  await waitScreen(page, 'fastStart');
  await page.waitForSelector(tid('fast-cancel'));
  assert.ok(!/12 words/.test(await page.textContent('main')), 'the Rescan screen does not mention 12 words for it');
  await shot(page, 'import-09b-rescan-imported');
  await page.click(tid('fast-cancel'));
  await waitScreen(page, 'settings');
  await waitSynced(page, 180000);
  await page.evaluate(() => window.__campfire.go('deleteWallet'));
  await waitScreen(page, 'deleteWallet');
  const del = await page.textContent('main');
  assert.match(del, /Only the original wallet\.db file and its password can bring this wallet back/);
  assert.ok(!/Only your 12 words/.test(del));
  await shot(page, 'import-10-delete-wording');
  await page.evaluate(() => window.__campfire.go('changePassword'));
  await waitScreen(page, 'changePassword');
  assert.match(await page.textContent('main'), /original wallet\.db file keeps the password it had/);
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
});

test('lock -> wrong password refused -> the file\'s password unlocks; a reload keeps the wallet', { timeout: 300000 }, async () => {
  const before = await page.evaluate(() => window.__campfire.addresses());
  await page.click(tid('lock'));
  await waitScreen(page, 'unlock');
  await page.fill(tid('unlock-pw'), `${wdb.password}-nope`);
  await page.click(tid('unlock-submit'));
  await page.waitForSelector('.notice.error', { timeout: 30000 });
  assert.match(await page.textContent('.notice.error'), /didn't open the wallet/);
  await page.fill(tid('unlock-pw'), wdb.password);
  await page.click(tid('unlock-submit'));
  await waitScreen(page, 'home', 60000);
  await waitSynced(page, 180000);
  const resp = await page.reload();
  assert.equal(resp.fromServiceWorker(), true, 'served from the verified copy');
  await unlockWithPassword(page, wdb.password);
  await waitScreen(page, 'home', 60000);
  await waitSynced(page, 180000);
  assert.deepEqual(await page.evaluate(() => window.__campfire.addresses()), before, 'same addresses after a reload');
  assert.equal((await page.evaluate(() => window.__campfire.record())).imported, true);
});

test('delete removes it; Welcome again after a reload, nothing left in storage', { timeout: 240000 }, async () => {
  await page.evaluate(() => window.__campfire.go('deleteWallet'));
  await waitScreen(page, 'deleteWallet');
  await page.fill(tid('delete-confirm'), 'DELETE');
  await page.click(tid('delete-submit'));
  await waitScreen(page, 'welcome', 60000);
  await page.reload();
  await waitScreen(page, 'welcome', 60000);
  assert.deepEqual(await idbFiles(), []);
  assert.equal(await page.evaluate(() => window.__campfire.record()), null);
  assert.deepEqual(await page.evaluate(() => window.__campfire.walletFiles()), []);
});

test('nothing left the device: GET only, this origin and the node only, no password anywhere, original file unchanged', async () => {
  assert.deepEqual(nonGet, [], 'no POST/PUT: the file was never uploaded');
  assert.deepEqual(foreignHosts(rec, srv.url), []);
  assert.ok([...new Set(rec.websockets.map((u) => new URL(u).host))].every((h) => NODE_HOSTS.includes(h)), 'BEAM pool nodes only');
  assert.deepEqual((await page.evaluate(() => window.__campfire.guard())).blocked, {});
  assert.deepEqual(rec.csp, []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  const consoleText = rec.console.map((m) => m.text).join('\n');
  assert.ok(!consoleText.includes(wdb.password), 'password in no console line');
  assert.ok(!srv.output.join('').includes(wdb.password), 'password in no server log');
  assert.ok(!rec.requests.some((u) => u.includes(wdb.password)), 'password in no URL');
  assert.equal(sha256File(wdb.path), wdb.sha256, 'the original wallet.db is unchanged');
  assert.deepEqual(rec.errors, [], 'no uncaught page errors');
  console.log(`# requests: ${rec.requests.length} (all GET), websocket opens: ${rec.websockets.length} (all to BEAM pool nodes: ${[...new Set(rec.websockets.map((u) => new URL(u).host))].join(', ')})`);
});

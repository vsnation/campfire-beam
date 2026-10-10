// Show owner key, end to end: the installed Google Chrome (headless), the dev
// server, BEAM mainnet (the wallet connects; nothing is synced for the key and
// nothing is spent), the real wasm engine with patch 0106, and BEAM's native
// 7.5.14493 CLI and beam-node (see walletdb.mjs).
//
//   npm run e2e:owner-key     (stages the engine, then builds its own release in a temp dir)
//
// What it proves:
// - Settings -> Backup offers "Show owner key" for a wallet made from 12 words and for an
//   imported wallet.db, as a secondary button (Export stays the one primary);
// - the screen explains it first; a wrong password shows nothing, nor does the right password with
//   a failed Face ID; the password and then Face ID (a passkey with PRF on Chrome's virtual
//   authenticator) show the key; "Copy owner key" puts exactly that key on the clipboard;
// - leaving the screen and auto-lock take the key off the page; it is in no console line, no
//   server log line, no IndexedDB / localStorage / sessionStorage entry;
// - format equality: for the wallet.db the app exports (re-keyed to the person's password),
//   `beam-wallet export_owner_key` with that password prints the SAME string the app showed
//   (BEAM's KeyString is deterministic: PBKDF2 without salt, IV from the key); beam-node started
//   with --owner_key=<the app's key> --pass=<the password> lists one owned account, and with a
//   wrong password says "key import failed"; the CLI with a wrong password exports nothing;
// - the same for a wallet.db made by the native CLI and imported: the app's key equals the
//   CLI's key for the original file and its password.
// Keys, passwords and CLI/node output are never printed; screenshots blur the key.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, readFileSync, existsSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PWA, startServer, launch, recordedPage, waitScreen, foreignHosts, addVirtualAuthenticator, sleep, SHOTS } from './harness.mjs';
import { createWallet, waitHome, unlockWithPassword } from './flows.mjs';
import { makeWalletDb, cliVersion, cliOwnerKey, nodeReadsOwnerKey, WANT_CORE, BEAM_CLI, BEAM_NODE } from './walletdb.mjs';
import { looksLikeOwnerKey, OWNER_KEY_TEXT as T } from '../../src/lib/owner_key.js';

const PORT = Number(process.env.CAMPFIRE_OWNER_KEY_PORT || 8850);
const tid = (id) => `[data-testid="${id}"]`;
const pkg = JSON.parse(readFileSync(join(PWA, 'package.json'), 'utf8'));
const PASSWORD = `okey-${randomBytes(9).toString('base64url')}`; // throwaway wallet
const SHOT_DIR = process.env.OWNER_KEY_SHOTS || join(SHOTS, 'owner-key');

let tmp, srv, browser, ctx, page, rec, authn;
let appKey = null;
const nonGet = [];
const shots = [];

async function screenName(p = page) {
  return p.evaluate(() => document.getElementById('app').dataset.screen);
}

/** The visible 375 x 667 screen, light and dark. With blurKey the key is blurred (never a readable picture of it). */
async function bothSchemes(p, name, { blurKey = false } = {}) {
  mkdirSync(SHOT_DIR, { recursive: true });
  if (blurKey) {
    const n = await p.evaluate(() => {
      const el = document.querySelector('[data-testid="owner-key"]');
      if (el) el.style.filter = 'blur(7px)';
      return el ? el.textContent.length : 0;
    });
    assert.ok(n > 0, `${name}: the key element is there to blur`);
  }
  for (const scheme of ['light', 'dark']) {
    await p.emulateMedia({ colorScheme: scheme });
    await sleep(150);
    const path = join(SHOT_DIR, `${name}-${scheme}.png`);
    await p.screenshot({ path });
    shots.push(path);
  }
  await p.emulateMedia({ colorScheme: 'light' });
  if (blurKey) await p.evaluate(() => document.querySelector('[data-testid="owner-key"]')?.style.removeProperty('filter'));
}

/** Where the key could have been kept: web storage and every IndexedDB store (bytes read as text). */
async function storedAnywhere(p, needle) {
  return p.evaluate(async (n) => {
    const hits = [];
    for (const [label, s] of [['localStorage', localStorage], ['sessionStorage', sessionStorage]]) {
      for (let i = 0; i < s.length; i++) if (`${s.key(i)}${s.getItem(s.key(i))}`.includes(n)) hits.push(label);
    }
    const text = (v) => {
      try {
        return typeof v === 'string' ? v : JSON.stringify(v, (_, x) => (ArrayBuffer.isView(x) ? new TextDecoder('latin1').decode(x) : x));
      } catch {
        return '';
      }
    };
    for (const { name } of await indexedDB.databases()) {
      const db = await new Promise((res, rej) => {
        const r = indexedDB.open(name);
        r.onsuccess = () => res(r.result);
        r.onerror = () => rej(r.error);
      });
      for (const store of db.objectStoreNames) {
        const all = await new Promise((res) => {
          const q = db.transaction(store, 'readonly').objectStore(store).getAll();
          q.onsuccess = () => res(q.result);
          q.onerror = () => res([]);
        });
        if (all.some((v) => text(v).includes(n))) hits.push(`${name}/${store}`);
      }
      db.close();
    }
    return hits;
  }, needle);
}

/** The message under the password field is fully on screen, above the pinned button bar. */
async function messageVisible(p) {
  return p.evaluate(() => {
    const m = document.querySelector('[data-testid="okey-msg"]').getBoundingClientRect();
    const bar = document.querySelector('main .actions').getBoundingClientRect();
    return m.height > 0 && m.top >= 0 && m.bottom <= bar.top + 0.5;
  });
}

async function keyOnPage(p, key) {
  return p.evaluate((k) => document.documentElement.outerHTML.includes(k) || document.body.innerText.includes(k), key);
}

async function openBackup(p) {
  await p.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(p, 'settings');
  await p.click(tid('backup-row'));
  await waitScreen(p, 'backup');
}

/** Backup -> Show owner key -> password (+ Face ID) -> the key. */
async function revealKey(p, password) {
  await openBackup(p);
  await p.click(tid('owner-key-start'));
  await waitScreen(p, 'ownerKey');
  await p.fill(tid('okey-pw'), password);
  await p.click(tid('okey-show'));
  await p.waitForFunction(() => (document.querySelector('[data-testid="owner-key"]')?.textContent || '').length > 0, null, { timeout: 60000 });
  return p.textContent(tid('owner-key'));
}

async function exportWalletDb(p, password, dest) {
  await openBackup(p);
  await p.click(tid('export-start'));
  await p.fill(tid('export-pw'), password);
  await p.click(tid('export-prepare'));
  await p.waitForSelector(tid('export-save'), { timeout: 180000 });
  const [dl] = await Promise.all([p.waitForEvent('download', { timeout: 30000 }), p.click(tid('export-save'))]);
  await dl.saveAs(dest);
  return dest;
}

before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-okey-'));
  const v = cliVersion(join(tmp, 'cli'));
  assert.equal(v, WANT_CORE, `BEAM CLI at ${BEAM_CLI} must be ${WANT_CORE} (got ${v})`);
  assert.ok(existsSync(BEAM_NODE), `beam-node next to the CLI (${BEAM_NODE}) or $BEAM_NODE_CLI`);
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
  await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: new URL(srv.url).origin });
  ({ page, rec } = await recordedPage(ctx, { label: 'okey' }));
  authn = await addVirtualAuthenticator(page);
  console.log(`# screenshots: ${SHOT_DIR}`);
});

after(async () => {
  if (page) await page.evaluate(() => navigator.clipboard.writeText('')).catch(() => {});
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
  if (tmp) assert.equal(existsSync(tmp), false, 'the throwaway wallets and keys are deleted');
});

test('a wallet from 12 words with Face ID: Backup offers "Show owner key" as a secondary button', { timeout: 5 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD, passkey: true });
  await waitHome(page, { timeout: 3 * 60000 });
  assert.equal((await page.evaluate(() => window.__campfire.record())).passkey, true, 'Face ID is on for this wallet');
  await openBackup(page);
  await page.waitForSelector(tid('owner-key-card'));
  assert.match(await page.getAttribute(tid('owner-key-start'), 'class'), /btn-secondary/);
  assert.equal(await page.locator('main .btn-primary').count(), 1, 'Backup keeps one primary button (Export wallet.db)');
  assert.equal((await page.textContent(tid('owner-key-start'))).trim(), T.backupCta);
  await page.locator(tid('owner-key-card')).scrollIntoViewIfNeeded();
  await bothSchemes(page, '01-backup-owner-key-card');
});

test('the screen explains first; a wrong password is refused and nothing is shown', { timeout: 120000 }, async () => {
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.click(tid('owner-key-start'));
  await waitScreen(page, 'ownerKey');
  const body = await page.textContent('main');
  for (const line of [T.lead, T.can, T.cannot, T.share, T.passwordHint, T.faceIdHint]) assert.ok(body.includes(line), `says: ${line}`);
  const cta = await page.locator(tid('okey-show')).boundingBox();
  console.log(`# "Show owner key" bottom at ${Math.round(cta.y + cta.height)} of 667`);
  assert.ok(cta.y + cta.height <= 667, 'the primary button is above the fold at 375 x 667');
  await bothSchemes(page, '02-explain-and-password');

  await page.click(tid('okey-show'));
  await page.waitForFunction(() => /Enter your password/.test(document.querySelector('[data-testid="okey-msg"]')?.textContent || ''));
  await page.fill(tid('okey-pw'), `${PASSWORD}-wrong`);
  await page.click(tid('okey-show'));
  await page.waitForFunction(() => /didn't match/.test(document.querySelector('[data-testid="okey-msg"]')?.textContent || ''), null, { timeout: 30000 });
  assert.equal(await page.textContent(tid('owner-key')).catch(() => ''), '', 'no key on the page');
  assert.equal(await screenName(), 'ownerKey');
  const cta2 = await page.locator(tid('okey-show')).boundingBox();
  assert.ok(cta2.y + cta2.height <= 667, 'still above the fold with the error showing');
  assert.equal(await messageVisible(page), true, 'the error is on screen, above the button');
  await bothSchemes(page, '03-wrong-password');
});

test('the right password, then Face ID: the key; "Copy owner key" copies exactly it', { timeout: 120000 }, async () => {
  await page.fill(tid('okey-pw'), PASSWORD);
  await page.click(tid('okey-show'));
  await page.waitForFunction(() => (document.querySelector('[data-testid="owner-key"]')?.textContent || '').length > 0, null, { timeout: 60000 });
  appKey = await page.textContent(tid('owner-key'));
  assert.equal(looksLikeOwnerKey(appKey), true, 'a BEAM KeyString: 144 base64 characters');
  assert.equal(await page.isVisible(tid('okey-pw')), false, 'the password field is gone');
  const body = await page.textContent('main');
  assert.ok(body.includes(T.shownLead) && body.includes(T.shownWarn));
  const copy = await page.locator(tid('okey-copy')).boundingBox();
  assert.ok(copy.y + copy.height <= 667, '"Copy owner key" is above the fold');
  assert.match(await page.getAttribute(tid('okey-copy'), 'class'), /btn-primary/);
  await bothSchemes(page, '04-key-shown', { blurKey: true });

  await page.evaluate(() => navigator.clipboard.writeText('-'));
  await page.click(tid('okey-copy'));
  await page.waitForSelector('.toast');
  assert.equal(await page.textContent('.toast'), T.copied);
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), appKey, 'the clipboard holds exactly the key shown');
  await bothSchemes(page, '05-copied', { blurKey: true });
  await page.evaluate(() => navigator.clipboard.writeText(''));
});

test('leaving the screen takes the key off the page; coming back asks again; the key is stored nowhere', { timeout: 120000 }, async () => {
  await page.click(tid('okey-done'));
  await waitScreen(page, 'backup');
  assert.equal(await keyOnPage(page, appKey), false, 'after Done: not in the page');
  await page.click(tid('owner-key-start'));
  await waitScreen(page, 'ownerKey');
  assert.equal(await page.inputValue(tid('okey-pw')), '', 'an empty password field');
  assert.equal(await keyOnPage(page, appKey), false, 'back on the screen: asks again, shows nothing');
  await page.click('header [aria-label="Back"]');
  await waitScreen(page, 'backup');
  assert.deepEqual(await storedAnywhere(page, appKey), [], 'the key is in no web storage and no IndexedDB store');
});

test('auto-lock takes the key off the page', { timeout: 4 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.selectOption(tid('autolock-select'), '1');
  const k = await revealKey(page, PASSWORD);
  assert.equal(k, appKey, 'the same key again (deterministic for the same wallet and password)');
  const t0 = Date.now();
  await waitScreen(page, 'unlock', 120000); // 1 min without input, checked every 15 s
  console.log(`# auto-lock after ${Math.round((Date.now() - t0) / 1000)} s without input`);
  assert.equal(await keyOnPage(page, appKey), false, 'locked: the key is not in the page');
  assert.equal(await page.evaluate(() => window.__campfire.record()).then((r) => r.passkey), true);
  await unlockWithPassword(page, PASSWORD);
  await waitHome(page, { timeout: 2 * 60000 });
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.selectOption(tid('autolock-select'), '15');
});

test('format equality: BEAM\'s CLI exports the same key from the exported wallet.db; beam-node accepts it; wrong passwords fail', { timeout: 6 * 60000 }, async () => {
  const exported = await exportWalletDb(page, PASSWORD, join(tmp, 'exported.db'));
  const scratch = join(tmp, 'native');
  const cliKey = cliOwnerKey(exported, PASSWORD, scratch);
  assert.ok(cliKey, 'beam-wallet export_owner_key opens the exported wallet.db with the password');
  assert.equal(appKey === cliKey, true, 'the key the app showed is byte for byte the key BEAM\'s CLI exports');
  assert.equal(cliOwnerKey(exported, `${PASSWORD}-wrong`, scratch), null, 'the CLI exports nothing with a wrong password');
  const ok = await nodeReadsOwnerKey(appKey, PASSWORD, scratch);
  assert.deepEqual(ok, { accepted: true, rejected: false, accounts: 1, version: WANT_CORE }, 'beam-node reads the app\'s key with the same password');
  const bad = await nodeReadsOwnerKey(appKey, `${PASSWORD}-wrong`, scratch);
  assert.equal(bad.rejected, true, 'beam-node: "key import failed" with a wrong password');
  assert.equal(bad.accepted, false);
  console.log(`# created wallet: app key == CLI ${WANT_CORE} export_owner_key (144 chars); beam-node ${ok.version}: ${ok.accounts} owned account with the password, "key import failed" with a wrong one`);
});

test('the right password but Face ID fails: still nothing shown, and the way forward is said', { timeout: 120000 }, async () => {
  // Last of the Face ID tests: Chrome's virtual authenticator keeps refusing once user
  // verification was turned off, even after it is turned back on.
  await openBackup(page);
  await page.click(tid('owner-key-start'));
  await waitScreen(page, 'ownerKey');
  await authn.cdp.send('WebAuthn.setUserVerified', { authenticatorId: authn.authenticatorId, isUserVerified: false });
  await page.fill(tid('okey-pw'), PASSWORD);
  await page.click(tid('okey-show'));
  await page.waitForFunction(() => /Face ID (was cancelled|didn't work)/.test(document.querySelector('[data-testid="okey-msg"]')?.textContent || ''), null, { timeout: 60000 });
  assert.equal(await page.textContent(tid('owner-key')).catch(() => ''), '', 'no key without Face ID');
  assert.equal(await keyOnPage(page, appKey), false);
  assert.equal(await page.isEnabled(tid('okey-show')), true, 'Show owner key can be tapped again');
  const cta = await page.locator(tid('okey-show')).boundingBox();
  assert.ok(cta.y + cta.height <= 667, `the primary button stays on screen with the Face ID message (${Math.round(cta.y + cta.height)})`);
  assert.equal(await messageVisible(page), true, 'the Face ID message is on screen, above the button');
  await bothSchemes(page, '03b-face-id-failed');
  await page.click('header [aria-label="Back"]');
  await waitScreen(page, 'backup');
});

test('an imported wallet.db (made by BEAM\'s CLI): the same flow, and the key BEAM\'s CLI exports from the original', { timeout: 8 * 60000 }, async () => {
  const wdb = makeWalletDb(join(tmp, 'imported'));
  const ctx2 = await browser.newContext({ viewport: { width: 375, height: 667 }, deviceScaleFactor: 2 });
  try {
    const { page: p2, rec: rec2 } = await recordedPage(ctx2, { label: 'okey-import' });
    await p2.goto(srv.url);
    await waitScreen(p2, 'welcome', 60000);
    await p2.click(tid('import'));
    await waitScreen(p2, 'importWallet');
    await p2.setInputFiles(tid('import-file'), wdb.path);
    await p2.fill(tid('import-pw'), wdb.password);
    await p2.click(tid('import-submit'));
    await p2.waitForFunction(() => ['passkeySetup', 'ipNotice'].includes(document.getElementById('app').dataset.screen), null, { timeout: 180000 });
    if ((await screenName(p2)) === 'passkeySetup') await p2.click(tid('passkey-skip'));
    await waitScreen(p2, 'ipNotice', 30000);
    await p2.click(tid('ip-connect'));
    await waitHome(p2, { timeout: 3 * 60000 });
    assert.equal((await p2.evaluate(() => window.__campfire.record())).imported, true);
    await openBackup(p2);
    await p2.waitForSelector(tid('owner-key-card'));
    await p2.locator(tid('owner-key-card')).scrollIntoViewIfNeeded();
    await bothSchemes(p2, '06-backup-imported-wallet');
    await p2.click(tid('owner-key-start'));
    await waitScreen(p2, 'ownerKey');
    assert.equal((await p2.textContent('main')).includes(T.faceIdHint), false, 'no Face ID line without Face ID');
    await bothSchemes(p2, '07-imported-explain-password-only');
    await p2.fill(tid('okey-pw'), wdb.password);
    await p2.click(tid('okey-show'));
    await p2.waitForFunction(() => (document.querySelector('[data-testid="owner-key"]')?.textContent || '').length > 0, null, { timeout: 60000 });
    const k2 = await p2.textContent(tid('owner-key'));
    await bothSchemes(p2, '08-imported-key-shown', { blurKey: true });
    const scratch = join(tmp, 'native2');
    const cliKey = cliOwnerKey(wdb.path, wdb.password, scratch);
    assert.ok(cliKey, 'the CLI exports the original file\'s owner key');
    assert.equal(k2 === cliKey, true, 'the imported wallet\'s key in the app equals the CLI\'s for the original file');
    assert.notEqual(k2, appKey, 'another wallet, another key');
    const ok = await nodeReadsOwnerKey(k2, wdb.password, scratch);
    assert.equal(ok.accepted, true, 'beam-node reads it with the file\'s password');
    await p2.click(tid('okey-done'));
    await waitScreen(p2, 'backup');
    assert.equal(await keyOnPage(p2, k2), false);
    assert.deepEqual(await storedAnywhere(p2, k2), []);
    for (const k of [k2, wdb.password]) assert.ok(!rec2.console.some((m) => m.text.includes(k)), 'not in the console');
    assert.deepEqual(foreignHosts(rec2, srv.url), []);
    assert.deepEqual(rec2.errors, []);
    console.log('# imported wallet.db: app key == CLI export_owner_key of the original file; beam-node accepts it');
  } finally {
    await ctx2.close();
  }
});

test('nothing leaked: console, server log, requests, CSP', async () => {
  for (const [what, s] of [['key', appKey], ['password', PASSWORD]]) {
    assert.ok(!rec.console.some((m) => m.text.includes(s)), `the ${what} is in no console line`);
    assert.ok(!srv.output.join('').includes(s), `the ${what} is in no server log line`);
    assert.ok(!rec.requests.some((u) => u.includes(s)), `the ${what} is in no URL`);
  }
  assert.deepEqual(nonGet, [], 'GET only');
  assert.deepEqual(foreignHosts(rec, srv.url), [], 'only this origin and the BEAM node');
  assert.deepEqual(rec.csp, []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, [], 'no page errors');
  console.log(`# ${shots.length} screenshots in ${SHOT_DIR}`);
});

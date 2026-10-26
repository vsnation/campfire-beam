// Several BEAM wallets on one device, end to end: the installed Google Chrome (headless), BEAM
// mainnet, throwaway wallets only, no money moves.
//
//   npm run e2e:multiwallet   (its own build in a temp folder, ports 8940 and 8941)
//
// What it proves:
//   1. Wallet A is created (with Face ID); B is added by restoring a throwaway's 12 words (made by
//      BEAM's native CLI) with Face ID of its own; C by importing a wallet.db made by the CLI. Each
//      has its own database file and sees only its own addresses.
//   2. Switching: Home's wallet name -> a wallet -> its own unlock. Another wallet's password is
//      refused; each wallet's Face ID opens it. On the lock screen the picker shows names, no amounts.
//   3. A payment under way in the open wallet: switching says so first, and staying is one tap.
//   4. Settings -> Wallets lists them, marks the open one, renames; the primary buttons fit a
//      375 x 667 phone.
//   5. A reload keeps all three, the last opened first.
//   6. Deleting B (not open) leaves A's and C's files and records exactly as they were.
//   7. Deleting the open wallet brings the next one up locked, and it opens.
//   8. Migration: the published 0.2.7 (from its GitHub release, checked against its SHA256SUMS)
//      makes a wallet; Check for updates moves it to this build; its store and files are unchanged,
//      it opens as "Wallet 1" with the same addresses, and a second wallet can be added beside it.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, symlinkSync, unlinkSync, existsSync } from 'node:fs';
import { createHash, randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PWA, startServer, launch, recordedPage, addVirtualAuthenticator, waitScreen, shot, sleep, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced, unlockWithPassword } from './flows.mjs';
import { makeWalletDb, BEAM_CLI } from './walletdb.mjs';
import { startStaticHost } from './static_host.mjs';

const PORT = Number(process.env.CAMPFIRE_MULTIWALLET_PORT || 8940);
const PAGES_PORT = PORT + 1;
const VERSION = '0.2.8'; // newer than the published 0.2.7, so its updater takes this build
const PREV = 'https://github.com/vsnation/campfire-beam/releases/download/web-v0.2.7/';
const tid = (id) => `[data-testid="${id}"]`;
const pw = (tag) => `${tag}-${randomBytes(6).toString('hex')}`;
const PA = pw('mw-a');
const PB = pw('mw-b');

let tmp, srv, browser, ctx, page, rec;
let restoreWords, cdb; // B's words (a throwaway made by the CLI), C's wallet.db
const W = {}; // name -> {id, addresses}

/** A throwaway seed made by BEAM's native CLI; the words are parsed, never printed. */
function cliSeedWords(dir) {
  mkdirSync(dir, { recursive: true });
  const cfg = join(dir, `.${randomBytes(6).toString('hex')}.cfg`);
  writeFileSync(cfg, `pass=${pw('seed')}\n`, { mode: 0o600 });
  let r;
  try {
    r = spawnSync(BEAM_CLI, ['init', `--wallet_path=${join(dir, 'wallet.db')}`, `--config_file=${cfg}`, '--log_level=info', '--file_log_level=error'], { cwd: dir, encoding: 'utf8', timeout: 120000 });
  } finally {
    rmSync(cfg, { force: true });
  }
  const m = `${r.stdout}${r.stderr}`.match(/\b([a-z]+(?:;[a-z]+){11})\b/);
  rmSync(dir, { recursive: true, force: true });
  if (r.status !== 0 || !m) throw new Error(`beam-wallet init gave no seed phrase (exit ${r.status}; output withheld)`);
  return m[1].split(';');
}

const screenName = (p = page) => p.evaluate(() => document.getElementById('app').dataset.screen);
const wallets = (p = page) => p.evaluate(() => window.__campfire.wallets());
const addresses = (p = page) => p.evaluate(() => window.__campfire.addresses());

/** The open wallet's own addresses; one is made when it has none yet. */
async function ownAddresses(p = page) {
  await p.waitForFunction(() => window.__campfire.running(), null, { timeout: 60000 });
  let a = await addresses(p);
  if (!a.length) {
    const r = await p.evaluate(() => window.__campfire.createAddress('regular'));
    assert.ok(r.ok, 'an address could be made');
    a = await addresses(p);
  }
  assert.ok(a.length >= 1);
  return a;
}

async function both(p, name) {
  for (const scheme of ['light', 'dark']) {
    await p.emulateMedia({ colorScheme: scheme });
    await sleep(300);
    await shot(p, `${name}-${scheme}`);
  }
  await p.emulateMedia({ colorScheme: 'light' });
}

/** The primary button is on screen at 375 x 667 without scrolling. */
async function fitsSmallPhone(p, selector, label) {
  const size = p.viewportSize();
  await p.setViewportSize({ width: 375, height: 667 });
  await sleep(300);
  const box = await p.locator(selector).first().boundingBox();
  await p.setViewportSize(size);
  assert.ok(box && box.y >= 0 && box.y + box.height <= 667, `${label}: the primary button is visible at 375 x 667 (${JSON.stringify(box)})`);
}

/** The app's own store ("beam-campfire-app"): every key and value, typed arrays as plain arrays. */
function kvDump(p = page) {
  return p.evaluate(
    () =>
      new Promise((resolve, reject) => {
        const r = indexedDB.open('beam-campfire-app');
        r.onerror = () => reject(r.error);
        r.onsuccess = () => {
          const db = r.result;
          const t = db.transaction('kv', 'readonly');
          const s = t.objectStore('kv');
          const keys = s.getAllKeys();
          const vals = s.getAll();
          t.oncomplete = () => {
            db.close();
            const out = {};
            keys.result.forEach((k, i) => (out[String(k)] = JSON.stringify(vals.result[i], (_, v) => (ArrayBuffer.isView(v) ? Array.from(v) : v))));
            resolve(out);
          };
        };
      }),
  );
}

/** The engine's IndexedDB file store: path -> {timestamp, sha256} (files) or {dir: true}. */
function idbFiles(p = page) {
  return p.evaluate(
    () =>
      new Promise((resolve, reject) => {
        const r = indexedDB.open('/beam_wallet');
        r.onerror = () => reject(r.error);
        r.onsuccess = async () => {
          const db = r.result;
          if (!db.objectStoreNames.contains('FILE_DATA')) {
            db.close();
            return resolve({});
          }
          const t = db.transaction('FILE_DATA', 'readonly');
          const s = t.objectStore('FILE_DATA');
          const keys = s.getAllKeys();
          const vals = s.getAll();
          t.oncomplete = async () => {
            db.close();
            const out = {};
            for (let i = 0; i < keys.result.length; i++) {
              const k = String(keys.result[i]);
              if (k === '/beam_wallet') continue;
              const v = vals.result[i];
              if (v && v.contents) {
                const d = new Uint8Array(await crypto.subtle.digest('SHA-256', v.contents));
                out[k] = { timestamp: Number(v.timestamp), sha256: Array.from(d, (b) => b.toString(16).padStart(2, '0')).join('') };
              } else out[k] = { dir: true };
            }
            resolve(out);
          };
        };
      }),
  );
}

async function openSwitcher(p = page) {
  await p.click(tid('wallet-chip'));
  await p.waitForSelector(tid('switcher'));
}

/** Home's wallet name -> Add a wallet -> the add screen, its suggested name filled in. */
async function startAdd(expectName) {
  await openSwitcher();
  await page.click(tid('switch-add'));
  await waitScreen(page, 'addWallet');
  await page.waitForFunction((n) => document.querySelector('[data-testid="add-name"]').value === n, expectName, { timeout: 30000 });
}

async function afterProtect(p, { passkey }) {
  await p.waitForFunction(() => ['passkeySetup', 'fastStart', 'home'].includes(document.getElementById('app').dataset.screen), null, { timeout: 120000 });
  if ((await screenName(p)) === 'passkeySetup') await p.click(tid(passkey ? 'passkey-on' : 'passkey-skip'));
}

async function homeOf(name, p = page) {
  await waitScreen(p, 'home', 120000);
  await p.waitForFunction((n) => document.querySelector('[data-testid="wallet-name"]')?.textContent === n, name, { timeout: 30000 });
}

before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-multiwallet-'));
  assert.ok(existsSync(BEAM_CLI), `BEAM's native CLI is needed for B's words and C's wallet.db: ${BEAM_CLI}`);
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--version', VERSION, '--quiet'], { cwd: PWA });
  restoreWords = cliSeedWords(join(tmp, 'cli-b'));
  cdb = makeWalletDb(join(tmp, 'cli-c'));
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  ({ page, rec } = await recordedPage(ctx, { label: 'mw' }));
  await addVirtualAuthenticator(page);
  console.log(`# screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close().catch(() => {});
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

test('1. A created with Face ID; B added by restore (its own Face ID), C by import; each its own file and only its own addresses', { timeout: 20 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PA, passkey: true });
  await homeOf('Wallet 1');
  W.A = { addresses: await ownAddresses() };
  // Synced once (no balance is kept for the switcher any more: audit A-4).
  await waitSynced(page, 180000);
  let list = await wallets();
  assert.equal(list.length, 1);
  assert.equal(list[0].slot0, true, 'the first wallet takes the first slot');
  assert.equal(list[0].passkey, true);
  W.A.id = list[0].id;

  // B: Add a wallet -> Restore with 12 words.
  await startAdd('Wallet 2');
  await both(page, 'mw-01-add-wallet');
  await fitsSmallPhone(page, tid('add-create'), 'Add a wallet');
  await page.click(tid('add-restore'));
  await waitScreen(page, 'restore');
  await page.fill(tid('word-1'), restoreWords.join(' '));
  await page.waitForFunction(() => !document.querySelector('[data-testid="restore-submit"]').disabled, null, { timeout: 30000 });
  await page.click(tid('restore-submit'));
  await waitScreen(page, 'setPassword');
  assert.match(await page.textContent('.lead'), /password for Wallet 2/);
  await both(page, 'mw-01b-add-password');
  await page.fill(tid('pw1'), PB);
  await page.fill(tid('pw2'), PB);
  await page.click(tid('save-password'));
  await afterProtect(page, { passkey: true });
  // A restored seed offers the snapshot; scanning instead keeps this test off a 330 MB download.
  await waitScreen(page, 'fastStart', 60000);
  await page.click(tid('fast-skip'));
  await homeOf('Wallet 2');
  W.B = { addresses: await ownAddresses() };
  list = await wallets();
  assert.equal(list.length, 2);
  const b = list.find((w) => w.name === 'Wallet 2');
  assert.ok(b && !b.slot0 && b.open && b.running && b.restored && b.passkey);
  W.B.id = b.id;
  assert.ok(!list.find((w) => w.name === 'Wallet 1').running, 'A stopped when B opened');

  // C: Add a wallet -> Import a wallet.db file, named by the person.
  await startAdd('Wallet 3');
  await page.fill(tid('add-name'), 'wallet 1');
  await page.click(tid('add-import'));
  assert.match(await page.textContent(tid('add-msg')), /already have a wallet named/);
  assert.equal(await screenName(), 'addWallet');
  await page.fill(tid('add-name'), 'Savings');
  await page.click(tid('add-import'));
  await waitScreen(page, 'importWallet');
  await page.setInputFiles(tid('import-file'), cdb.path);
  await page.fill(tid('import-pw'), cdb.password);
  await page.click(tid('import-submit'));
  await afterProtect(page, { passkey: false });
  await homeOf('Savings');
  W.C = { addresses: await ownAddresses() };
  list = await wallets();
  assert.equal(list.length, 3);
  const c = list.find((w) => w.name === 'Savings');
  assert.ok(c && c.imported && c.open && !c.passkey);
  W.C.id = c.id;

  for (const a of cdb.addresses) assert.ok(W.C.addresses.includes(a), 'C is the CLI wallet');
  const all = [W.A.addresses, W.B.addresses, W.C.addresses];
  for (let i = 0; i < 3; i++) for (let j = i + 1; j < 3; j++) assert.equal(all[i].filter((x) => all[j].includes(x)).length, 0, `wallets ${i} and ${j} share no address`);
  const files = await page.evaluate(() => window.__campfire.walletFiles());
  for (const f of ['wallet.db', `${W.B.id}/wallet.db`, `${W.C.id}/wallet.db`]) assert.ok(files.includes(f), `${f} in ${files.join(', ')}`);
});

test('2. switching: Home\'s name -> a wallet -> its own unlock; another wallet\'s password refused; Face ID per wallet', { timeout: 10 * 60000 }, async () => {
  await openSwitcher();
  const rows = await page.$$eval('[data-testid="switch-row"]', (els) => els.map((e) => ({ name: e.dataset.name, current: e.getAttribute('aria-current') === 'true', sub: e.querySelector('.s').textContent })));
  assert.deepEqual(rows.map((r) => r.name), ['Savings', 'Wallet 1', 'Wallet 2']);
  assert.deepEqual(rows.filter((r) => r.current).map((r) => r.name), ['Savings']);
  assert.match(rows.find((r) => r.name === 'Savings').sub, /^Open/);
  // No amount of a locked wallet is kept on the device (audit A-4): another wallet says Locked.
  for (const r of rows.filter((x) => !x.current)) assert.equal(r.sub, 'Locked', `${r.name}: no figure for a locked wallet`);
  assert.deepEqual(Object.keys(await kvDump()).filter((k) => /:balance$/.test(k)), [], 'no balance in the app database');
  await both(page, 'mw-02-switcher');
  await page.click('[data-testid="switch-row"][data-name="Wallet 1"]');
  await waitScreen(page, 'unlock', 60000);
  await page.waitForFunction(() => document.querySelector('[data-testid="unlock-lead"]').textContent === 'Unlock Wallet 1', null, { timeout: 30000 });
  assert.match(await page.textContent(tid('locked-notice')), /Savings is locked/);
  assert.equal(await page.isVisible(tid('unlock-passkey')), true, "Wallet 1's Face ID");
  await page.click(tid('use-password'));
  await page.fill(tid('unlock-pw'), PB); // Wallet 2's password
  await page.click(tid('unlock-submit'));
  await page.waitForSelector('.notice.error', { timeout: 60000 });
  assert.match(await page.textContent('.notice.error'), /didn't open the wallet/);
  assert.equal(await screenName(), 'unlock');
  assert.equal((await wallets()).some((w) => w.open), false, 'nothing opened');
  await both(page, 'mw-03-unlock-picker');
  await fitsSmallPhone(page, tid('unlock-submit'), 'Unlock with the picker');
  await page.fill(tid('unlock-pw'), PA);
  await page.click(tid('unlock-submit'));
  await homeOf('Wallet 1');
  assert.deepEqual(await ownAddresses(), W.A.addresses);

  // Locked: the picker shows names only; picking Wallet 2 offers its own Face ID.
  await page.click(tid('lock'));
  await waitScreen(page, 'unlock');
  await page.click(tid('unlock-wallet-pick'));
  await page.waitForSelector(tid('switcher'));
  const lockedText = await page.textContent(tid('switcher'));
  assert.doesNotMatch(lockedText, /BEAM/, 'no amounts on the lock screen');
  await both(page, 'mw-04-unlock-switcher');
  await page.click('[data-testid="switch-row"][data-name="Wallet 2"]');
  await page.waitForFunction(() => document.querySelector('[data-testid="unlock-lead"]')?.textContent === 'Unlock Wallet 2', null, { timeout: 30000 });
  assert.equal(await page.textContent(tid('unlock-wallet-name')), 'Wallet 2');
  await page.click(tid('unlock-passkey'));
  await homeOf('Wallet 2');
  assert.deepEqual(await ownAddresses(), W.B.addresses);
  const list = await wallets();
  assert.deepEqual(list.filter((w) => w.running).map((w) => w.name), ['Wallet 2'], 'one engine, one wallet');
  // Each wallet has its own passkey (credential) and its own envelopes, bound to its own id.
  const kv = await kvDump();
  const ra = JSON.parse(kv.wallet);
  const rb = JSON.parse(kv[`w:${W.B.id}:wallet`]);
  const rc = JSON.parse(kv[`w:${W.C.id}:wallet`]);
  assert.ok(ra.envelopes.passkey && rb.envelopes.passkey && !rc.envelopes.passkey);
  assert.notEqual(ra.envelopes.passkey.credId, rb.envelopes.passkey.credId, 'two passkeys');
  assert.deepEqual([ra.envelopes.password.walletId, rb.envelopes.password.walletId, rc.envelopes.password.walletId], [W.A.id, W.B.id, W.C.id]);
});

test('3. a payment under way: switching says so first; staying is the main button', { timeout: 5 * 60000 }, async () => {
  // Stands in for a payment (none moves in this test): the running wallet reports one under way.
  await page.evaluate(async () => {
    const m = await import(new URL('lib/wallet.js', location.href).href);
    m.wallet.paymentUnderWay = () => true;
  });
  await openSwitcher();
  await page.click('[data-testid="switch-row"][data-name="Savings"]');
  await page.waitForSelector(tid('pause-title'));
  assert.equal(await page.textContent(tid('pause-title')), 'Wallet 2 has a payment under way');
  assert.equal(await page.getAttribute(tid('pause-stay'), 'class'), 'btn btn-primary');
  await both(page, 'mw-05-payment-under-way');
  await page.click(tid('pause-stay'));
  await sleep(500);
  assert.equal(await screenName(), 'home');
  assert.equal((await wallets()).find((w) => w.name === 'Wallet 2').open, true, 'still open');
  await page.evaluate(async () => {
    const m = await import(new URL('lib/wallet.js', location.href).href);
    delete m.wallet.paymentUnderWay;
  });
});

// Re-audit RE1-12: one wallet runs at a time, so Send says how a regular payment to another wallet
// of this device goes (its offline address, or switch after sending and back).
test('3b. Send to another wallet of this device: one line on how it goes; not for its own address', { timeout: 5 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('send'));
  await waitScreen(page, 'send');
  await page.fill(tid('send-address'), W.A.addresses[0]);
  await page.waitForFunction(() => /^Regular address\./.test(document.querySelector('[data-testid="address-hint"]').textContent), null, { timeout: 30000 });
  await page.waitForSelector(`${tid('send-other-wallet-hint')}:not([hidden])`);
  assert.equal(await page.textContent(tid('send-other-wallet-hint')), 'Paying another of your wallets here? A regular payment needs both open, and only one can be: use its offline address, or after sending, switch to it and then back.');
  await both(page, 'mw-05b-send-other-wallet');
  await fitsSmallPhone(page, tid('review'), 'Send with the other-wallet line');
  // This wallet's own address: refused as before, and no such line.
  await page.fill(tid('send-address'), W.B.addresses[0]);
  await page.waitForFunction(() => /one of your own addresses/.test(document.querySelector('[data-testid="address-hint"]').textContent), null, { timeout: 30000 });
  assert.equal(await page.isVisible(tid('send-other-wallet-hint')), false);
  await page.fill(tid('send-address'), '');
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
});

test('4. Settings -> Wallets: the list, the open one marked, rename', { timeout: 5 * 60000 }, async () => {
  // An add flow left midway leaves nothing behind: Backup is this wallet's, never new words.
  await startAdd('Wallet 4');
  await page.click(tid('add-restore'));
  await waitScreen(page, 'restore');
  await page.click('.topbar .icon-btn');
  await waitScreen(page, 'addWallet');
  await page.click('.topbar .icon-btn');
  await waitScreen(page, 'home');
  await page.evaluate(() => window.__campfire.go('backup'));
  await waitScreen(page, 'backup');
  assert.equal(await page.isVisible(tid('export-last')), true, "this wallet's backup");
  assert.equal(await page.$(tid('words')), null, 'no new words');
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.waitForFunction(() => /3 on this device/.test(document.querySelector('[data-testid="wallets-row"]').textContent), null, { timeout: 30000 });
  assert.match(await page.textContent(tid('wallets-row')), /Wallet 2 is open · 3 on this device/);
  await both(page, 'mw-06a-settings');
  await page.click(tid('wallets-row'));
  await waitScreen(page, 'wallets');
  await page.waitForSelector(tid('wallet-row'));
  const rows = await page.$$eval('[data-testid="wallet-row"]', (els) => els.map((e) => ({ name: e.dataset.name, open: e.dataset.open })));
  assert.deepEqual(rows, [{ name: 'Savings', open: 'false' }, { name: 'Wallet 1', open: 'false' }, { name: 'Wallet 2', open: 'true' }]);
  await both(page, 'mw-06-settings-wallets');
  await fitsSmallPhone(page, tid('wallets-add'), 'Settings -> Wallets');
  await page.click('[data-testid="wallet-row"][data-name="Wallet 2"]');
  await page.waitForSelector(tid('wallet-rename'));
  await both(page, 'mw-07-wallet-actions');
  await page.click(tid('wallet-rename'));
  await page.fill(tid('rename-input'), 'savings');
  await page.click(tid('rename-save'));
  await page.waitForSelector('.sheet .notice.warn');
  assert.match(await page.textContent('.sheet .notice.warn'), /already have a wallet named/);
  await page.fill(tid('rename-input'), 'Spending');
  await page.click(tid('rename-save'));
  await page.waitForSelector('[data-testid="wallet-row"][data-name="Spending"]');
  await page.evaluate(() => window.__campfire.go('home'));
  await homeOf('Spending');
});

test('5. a reload keeps all three; the last opened comes first', { timeout: 5 * 60000 }, async () => {
  await page.reload();
  await waitScreen(page, 'unlock', 60000);
  await page.waitForFunction(() => document.querySelector('[data-testid="unlock-lead"]')?.textContent === 'Unlock Spending', null, { timeout: 30000 });
  assert.deepEqual((await wallets()).map((w) => w.name), ['Savings', 'Spending', 'Wallet 1']);
  await unlockWithPassword(page, PB);
  await homeOf('Spending');
  assert.deepEqual(await ownAddresses(), W.B.addresses);
});

test('5b. the store names per-wallet data for the open wallet, and refuses to write it while locked', { timeout: 5 * 60000 }, async () => {
  // B (Spending) is open: the code that writes 'dapp-files' (installed dApps) writes B's copy.
  const r = await page.evaluate(async () => {
    const { store, rawStore } = await import(new URL('lib/store.js', location.href).href);
    await store.set('dapp-files', []);
    return { mine: await store.get('dapp-files'), keys: (await rawStore.keys('')).filter((k) => k.includes('dapp-files')) };
  });
  assert.deepEqual(r.mine, []);
  assert.deepEqual(r.keys, [`w:${W.B.id}:dapp-files`], "only B's copy exists; the first slot's plain key is untouched");
  await page.click(tid('lock'));
  await waitScreen(page, 'unlock');
  const locked = await page.evaluate(async () => {
    const { store } = await import(new URL('lib/store.js', location.href).href);
    const read = await store.get('dapp-files');
    const write = await store.set('dapp-files', [1]).then(() => 'written', (e) => e.code);
    return { read, write };
  });
  assert.deepEqual(locked, { read: [], write: 'locked' }, 'readable, not writable while locked');
  await unlockWithPassword(page, PB);
  await homeOf('Spending');
});

test('6. deleting B (not open) leaves A and C exactly as they were: files and records', { timeout: 10 * 60000 }, async () => {
  // Open C, then delete B from Settings -> Wallets.
  await openSwitcher();
  await page.click('[data-testid="switch-row"][data-name="Savings"]');
  await waitScreen(page, 'unlock', 60000);
  await page.waitForFunction(() => document.querySelector('[data-testid="unlock-lead"]')?.textContent === 'Unlock Savings', null, { timeout: 30000 });
  await unlockWithPassword(page, cdb.password);
  await homeOf('Savings');
  await sleep(2000);
  const filesBefore = await idbFiles();
  const kvBefore = await kvDump();
  assert.ok(Object.keys(filesBefore).some((k) => k.startsWith(`/beam_wallet/${W.B.id}/`)), "B's folder is there");
  assert.ok(Object.keys(kvBefore).some((k) => k.startsWith(`w:${W.B.id}:`)), "B's keys are there");

  await page.evaluate(() => window.__campfire.go('wallets'));
  await waitScreen(page, 'wallets');
  await page.click('[data-testid="wallet-row"][data-name="Spending"]');
  // B keeps saved airdrop codes and a purchase (sealed: B is not open, so they can only be seen, not opened).
  await page.evaluate(async (id) => {
    const { rawStore } = await import(new URL('lib/store.js', location.href).href);
    await rawStore.set(`w:${id}:airdropCodes`, { v: 2, walletId: id, kdf: 'hkdf-sha256', salt: 'AAAA', iv: 'AAAA', ct: 'AAAA' });
    await rawStore.set(`w:${id}:buybeam`, { v: 1, kind: 'buybeam-orders', walletId: id, kdf: 'hkdf-sha256', salt: 'AAAA', iv: 'AAAA', ct: 'AAAA' });
  }, W.B.id);
  await page.click(tid('wallet-delete'));
  await waitScreen(page, 'deleteWallet');
  await page.waitForSelector(tid('delete-others'));
  assert.match(await page.textContent(tid('delete-what')), /removes Spending/);
  assert.match(await page.textContent(tid('delete-others')), /Only Spending is deleted\. Your other 2 wallets stay as they are\./);
  // BM-4: what may still be under way is said, and Delete waits for "Delete anyway".
  await page.waitForSelector(tid('delete-in-flight'));
  assert.equal(await page.getAttribute(tid('delete-in-flight'), 'data-kinds'), 'airdrop buy');
  assert.match(await page.textContent(tid('delete-in-flight-unseen')), /saved airdrop codes and purchases at buybeam\.my, the only record of any still under way\. Beam PWA can't look inside them without the wallet's password/);
  assert.equal(await page.isVisible('[data-testid^="delete-way-"]'), false, 'not open: no way in from here');
  await both(page, 'mw-08-delete-one');
  await page.fill(tid('delete-confirm'), 'DELETE');
  assert.equal(await page.isDisabled(tid('delete-submit')), true, 'typed, not yet ticked');
  await page.check(tid('delete-flight-ack'));
  await page.click(tid('delete-submit'));
  await waitScreen(page, 'wallets', 60000);
  await page.waitForFunction(() => document.querySelectorAll('[data-testid="wallet-row"]').length === 2, null, { timeout: 30000 });
  assert.deepEqual((await wallets()).map((w) => w.name), ['Savings', 'Wallet 1']);
  assert.equal((await wallets()).find((w) => w.name === 'Savings').open, true, 'C stayed open');
  await sleep(2000);

  const filesAfter = await idbFiles();
  const kvAfter = await kvDump();
  assert.deepEqual(Object.keys(filesAfter).filter((k) => k.includes(W.B.id)), [], "B's files are gone");
  assert.deepEqual(Object.keys(kvAfter).filter((k) => k.includes(W.B.id)), [], "B's keys are gone");
  assert.deepEqual(filesAfter['/beam_wallet/wallet.db'], filesBefore['/beam_wallet/wallet.db'], "A's wallet.db: same bytes, same timestamp");
  assert.ok(filesAfter[`/beam_wallet/${W.C.id}/wallet.db`], "C's wallet.db is there");
  for (const [k, v] of Object.entries(kvBefore)) {
    if (k.includes(W.B.id) || k === 'prefs' || k === `w:${W.C.id}:balance`) continue;
    assert.equal(kvAfter[k], v, `${k} unchanged`);
  }
  assert.equal(kvAfter.wallet, kvBefore.wallet, "A's record and envelopes");
  assert.equal(kvAfter[`w:${W.C.id}:wallet`], kvBefore[`w:${W.C.id}:wallet`], "C's record and envelopes");
});

test('7. deleting the open wallet brings the other up locked, and it opens', { timeout: 5 * 60000 }, async () => {
  // BM-4, BC-6: Savings (open) keeps an open bridge move, a batch of airdrop codes nobody claimed
  // and a purchase under way, sealed as the app writes them; nothing is sent anywhere.
  await page.evaluate(async () => {
    const at = (p) => new URL(p, location.href).href;
    const { app } = await import(at('app.js'));
    const { walletStore } = await import(at('lib/wallets.js'));
    const { bridgeStoreFor, makeCrossing, STATES } = await import(at('lib/bridge/store.js'));
    const { codeVault, codeHash, AIRDROP_CID } = await import(at('lib/airdrop.js'));
    const { sealedBuyStore, makeOrder } = await import(at('lib/buy/store.js'));
    const kv = walletStore(app.record);
    const now = Date.now();
    await bridgeStoreFor(app, kv).save(makeCrossing({ id: 'e2e-move', route: 'eth', direction: 'toBeam', state: STATES.delivered, amount: 10n ** 16n, receives: 1000000n, relayerFee: 3000000000000n, beamNetworkFee: 12100000n, beamWalletId: app.record.id, ethWalletId: 'e2e', ethAddress: '0x7a3e5b1c2d4f6e8a9b0c1d2e3f4a5b6c7d8e91c4', msgId: 999999, createdAt: now, updatedAt: now }));
    const code = 'ABCD-EFGH-JKLM-NPQR';
    await codeVault({ kv, walletId: app.record.id, secret: app.dbPass, imported: Boolean(app.record.imported) }).put({ localId: 'e2e-batch', contractId: AIRDROP_CID, assetId: 0, createdAt: new Date(now).toISOString(), txId: null, txStatus: 'confirmed', codes: [{ code, hash: await codeHash(code), value: '100000', status: 'available' }] });
    await sealedBuyStore(app, { kv }).save(makeOrder({ depositAddress: 'bc1q6rga95756htd0kxemtdaehw7mlswrchr6zzx2s', assetId: 'coin:btc', symbol: 'BTC', chain: 'btc', decimals: 8, sendAmount: '0.0123', sendAmountRaw: 1230000n, beamAddress: `${'1'.repeat(64)}aa`, beamWalletId: app.record.id, refundAddress: 'bc1qfake0refund0address0for0tests0only00000', createdAt: now, lastState: 'awaiting_deposit' }));
  });
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.click(tid('delete-wallet'));
  await waitScreen(page, 'deleteWallet');
  await page.waitForSelector(tid('delete-others'));
  assert.match(await page.textContent(tid('delete-others')), /Only Savings is deleted\. Your other wallet stays as it is\./);
  await page.waitForSelector(tid('delete-in-flight'));
  assert.equal(await page.getAttribute(tid('delete-in-flight'), 'data-kinds'), 'bridge airdrop buy');
  const said = await page.$$eval(`${tid('delete-in-flight')} li`, (els) => els.map((e) => e.textContent));
  assert.match(said[0], /^1 bridge move still under way\. The coins are not lost/);
  assert.match(said[1], /^1 airdrop batch with codes that may not all be claimed\. The codes are kept only here: save them as a CSV file first/);
  assert.match(said[2], /^1 purchase at buybeam\.my still under way\. Its deposit address is kept only here/);
  assert.deepEqual(await page.$$eval('[data-testid^="delete-way-"]', (els) => els.map((e) => e.textContent)), ['Bridge moves', 'My batches', 'Purchases']);
  await both(page, 'mw-09-delete-in-flight');
  await page.fill(tid('delete-confirm'), 'DELETE');
  assert.equal(await page.isDisabled(tid('delete-submit')), true, 'typed, not yet ticked');
  await page.check(tid('delete-flight-ack'));
  assert.equal(await page.isDisabled(tid('delete-submit')), false);
  await page.click(tid('delete-submit'));
  await waitScreen(page, 'unlock', 60000);
  assert.match(await page.textContent(tid('deleted-notice')), /Savings was deleted from this device/);
  const list = await wallets();
  assert.deepEqual(list.map((w) => w.name), ['Wallet 1']);
  assert.equal(list[0].selected, true);
  assert.equal(await page.isVisible(tid('unlock-wallet-pick')), false, 'one wallet: no picker');
  const files = Object.keys(await idbFiles());
  assert.deepEqual(files.filter((f) => f.split('/').length > 3), [], 'no other wallet folder is left');
  await unlockWithPassword(page, PA);
  await homeOf('Wallet 1');
  assert.deepEqual(await ownAddresses(), W.A.addresses);
  assert.deepEqual(rec.errors, [], 'no page errors');
  assert.deepEqual(rec.csp, [], 'no CSP violations');
});

test('8. migration: a wallet made in the published 0.2.7 is "Wallet 1" after Check for updates, unchanged, and another can be added beside it', { timeout: 20 * 60000 }, async () => {
  const sums = await (await fetch(`${PREV}SHA256SUMS.txt`)).text();
  const zipBytes = Buffer.from(await (await fetch(`${PREV}beam-campfire-web-0.2.7.zip`)).arrayBuffer());
  const want = sums.split('\n').find((l) => l.endsWith(' beam-campfire-web-0.2.7.zip')).split(/\s+/)[0];
  assert.equal(createHash('sha256').update(zipBytes).digest('hex'), want, 'the 0.2.7 zip matches its release SHA256SUMS');
  mkdirSync(join(tmp, 'zip'));
  writeFileSync(join(tmp, 'zip', 'web.zip'), zipBytes);
  const old = join(tmp, 'old');
  execFileSync('unzip', ['-q', join(tmp, 'zip', 'web.zip'), '-d', old]);
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
  const host = await startStaticHost({ root: live, port: PAGES_PORT });
  const mctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  const { page: p, rec: prec } = await recordedPage(mctx, { label: 'migrate' });
  try {
    await p.goto(host.url);
    for (let i = 0; i < 120; i++) {
      if ((await p.evaluate(() => window.__campfire && window.__campfire.screen()).catch(() => null)) === 'welcome') break;
      await sleep(1000);
    }
    assert.equal(await p.evaluate(() => typeof window.__campfire.wallets), 'undefined', 'this is the single-wallet 0.2.7');
    const PM = pw('mw-m');
    await createWallet(p, { password: PM });
    await waitHome(p, { timeout: 5 * 60000 });
    const addrM = await ownAddresses(p);

    // Update to this build through Check for updates.
    point(join(tmp, 'dist'));
    await p.evaluate(() => window.__campfire.go('settings'));
    await waitScreen(p, 'settings');
    await p.click(tid('check-updates'));
    await p.waitForSelector(tid('update-apply-sheet'), { timeout: 180000 });
    await sleep(2000);
    // What 0.2.7 has stored, just before the update: its record, envelopes, preferences, files.
    const kvOld = await kvDump(p);
    const filesOld = await idbFiles(p);
    assert.ok(kvOld.wallet, '0.2.7 keeps its record under "wallet"');
    assert.deepEqual(Object.keys(filesOld).filter((k) => !k.startsWith('/beam_wallet/wallet.db')), [], '0.2.7 keeps one wallet.db');
    await Promise.all([p.waitForEvent('load', { timeout: 120000 }), p.click(tid('update-apply-sheet'))]);
    // The new build runs (and has taken over the loader, when it brought a new one).
    for (let i = 0; i < 120; i++) {
      const ready = await p.evaluate(() => Boolean(window.__campfire && typeof window.__campfire.wallets === 'function' && window.__campfire.loaderBehind() === false && window.__campfire.screen() === 'unlock')).catch(() => false);
      if (ready) break;
      await sleep(1000);
    }
    assert.equal(await p.evaluate(() => typeof window.__campfire.wallets), 'function', 'the update reached this build');
    await waitScreen(p, 'unlock', 60000);
    await shot(p, 'mw-09-migrated-unlock');
    // Before unlocking: the update and the new boot moved and rewrote nothing.
    const kvNew = await kvDump(p);
    assert.deepEqual(Object.keys(kvNew).sort(), Object.keys(kvOld).sort(), 'the same keys: nothing moved');
    for (const k of Object.keys(kvOld)) assert.equal(kvNew[k], kvOld[k], `${k}: as 0.2.7 left it`);
    const filesNew = await idbFiles(p);
    assert.deepEqual(Object.keys(filesNew).sort(), Object.keys(filesOld).sort(), 'the same files, where 0.2.7 kept them');
    const list = await wallets(p);
    assert.equal(list.length, 1);
    assert.deepEqual({ name: list[0].name, slot0: list[0].slot0 }, { name: 'Wallet 1', slot0: true });
    assert.equal(await p.isVisible(tid('unlock-wallet-pick')), false);
    await unlockWithPassword(p, PM);
    await homeOf('Wallet 1', p);
    assert.deepEqual(await ownAddresses(p), addrM, 'the same wallet');
    await shot(p, 'mw-10-migrated-home');

    // A second wallet beside it, then back to the first.
    await p.click(tid('wallet-chip'));
    await p.click(tid('switch-add'));
    await waitScreen(p, 'addWallet');
    await p.waitForFunction(() => document.querySelector('[data-testid="add-name"]').value === 'Wallet 2', null, { timeout: 30000 });
    await p.click(tid('add-create'));
    await waitScreen(p, 'backup');
    await p.waitForSelector('[data-testid="words"] .word');
    await p.click(tid('reveal'));
    const words = await p.$$eval('[data-testid="words"] .word span:last-child', (els) => els.map((e) => e.textContent));
    await p.click(tid('wrote-down'));
    await waitScreen(p, 'confirmWords');
    for (const pos of await p.$$eval('[data-position]', (els) => els.map((e) => Number(e.dataset.position)))) await p.click(`[data-position="${pos}"] [data-word="${words[pos - 1]}"]`);
    words.fill('');
    await p.click(tid('confirm-words'));
    await waitScreen(p, 'setPassword');
    const P2 = pw('mw-m2');
    await p.fill(tid('pw1'), P2);
    await p.fill(tid('pw2'), P2);
    await p.click(tid('save-password'));
    await afterProtect(p, { passkey: false });
    await homeOf('Wallet 2', p);
    const addr2 = await ownAddresses(p);
    assert.equal(addr2.filter((a) => addrM.includes(a)).length, 0);
    await p.click(tid('wallet-chip'));
    await p.click('[data-testid="switch-row"][data-name="Wallet 1"]');
    await unlockWithPassword(p, PM);
    await homeOf('Wallet 1', p);
    assert.deepEqual(await ownAddresses(p), addrM, 'the migrated wallet still opens beside the new one');
    const kvEnd = await kvDump(p);
    assert.equal(JSON.parse(kvEnd.wallet).id, JSON.parse(kvOld.wallet).id, 'the first slot is still the 0.2.7 wallet');
    assert.deepEqual(JSON.parse(kvEnd.wallet).envelopes, JSON.parse(kvOld.wallet).envelopes, 'with the envelopes it had');
    const filesEnd = await idbFiles(p);
    assert.ok(filesEnd['/beam_wallet/wallet.db'], "its wallet.db where 0.2.7 kept it");
    assert.deepEqual(prec.errors, [], 'no page errors');
  } finally {
    await mctx.close().catch(() => {});
    await host.stop();
  }
});

test('9. on a fresh device, a first wallet restored or imported from Welcome takes the first slot, as before', { timeout: 10 * 60000 }, async () => {
  for (const kind of ['restore', 'import']) {
    const c2 = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const { page: p, rec: r2 } = await recordedPage(c2, { label: `first-${kind}` });
    try {
      await p.goto(srv.url);
      await waitScreen(p, 'welcome', 60000);
      if (kind === 'restore') {
        await p.click(tid('restore'));
        await waitScreen(p, 'restore');
        await p.fill(tid('word-1'), restoreWords.join(' '));
        await p.waitForFunction(() => !document.querySelector('[data-testid="restore-submit"]').disabled, null, { timeout: 30000 });
        await p.click(tid('restore-submit'));
        await waitScreen(p, 'setPassword');
        assert.doesNotMatch(await p.textContent('.lead'), /other wallets/);
        const P = pw('mw-f');
        await p.fill(tid('pw1'), P);
        await p.fill(tid('pw2'), P);
        await p.click(tid('save-password'));
        await afterProtect(p, { passkey: false });
        await waitScreen(p, 'fastStart', 60000);
        await p.click(tid('fast-skip'));
      } else {
        await p.click(tid('import'));
        await waitScreen(p, 'importWallet');
        await p.setInputFiles(tid('import-file'), cdb.path);
        await p.fill(tid('import-pw'), cdb.password);
        await p.click(tid('import-submit'));
        await afterProtect(p, { passkey: false });
      }
      await homeOf('Wallet 1', p);
      const list = await wallets(p);
      assert.equal(list.length, 1);
      assert.equal(list[0].slot0, true);
      assert.equal(list[0][kind === 'restore' ? 'restored' : 'imported'], true);
      const files = await p.evaluate(() => window.__campfire.walletFiles());
      assert.ok(files.includes('wallet.db') && !files.some((f) => f.includes('/')), `one wallet.db where a single-wallet version keeps it: ${files.join(', ')}`);
      if (kind === 'import') for (const a of cdb.addresses) assert.ok((await ownAddresses(p)).includes(a));
      assert.deepEqual(r2.errors, []);
    } finally {
      await c2.close();
    }
  }
});

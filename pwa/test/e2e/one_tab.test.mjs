// One tab at a time, end to end: the installed Google Chrome (headless), two pages of the SAME
// browser context (one origin, one IndexedDB), BEAM mainnet, throwaway wallets only, no money moves.
//
//   node tools/stage_engine.mjs && node --test --test-concurrency=1 test/e2e/one_tab.test.mjs
//   (its own build in a temp folder, port 8991; CAMPFIRE_ONETAB_PORT to change it)
//
// The reported case (2026-10-12): wallet A open in one tab, wallet B in a second tab; a payment from
// A to B failed. Every wallet's file is in ONE IDBFS mount (/beam_wallet) that each tab writes back
// whole, and IDBFS deletes the stored files the writing tab does not have.
//
// What it proves:
//   1. Tab 2 shows "open in another tab": no IndexedDB opened, no engine loaded, no node contacted,
//      and no way into a wallet (asking for Welcome or the words lands on the same screen).
//   2. "Use it here instead": tab 1 locks and saves (an address made a moment before is in tab 2),
//      stops its engine and says "moved"; tab 2 unlocks wallet A.
//   3. Tab 2 creates wallet B. Tab 1's save (what used to run every 15 s) is refused, and both
//      wallets' files are still in IndexedDB, unchanged by tab 1.
//   4. A holder that does not answer (its page paused in the debugger: Chrome does not freeze a
//      visible page, and a paused page runs no task, as a frozen one): "Take over anyway" after the
//      wait; once it runs again it handles the late request without saving, says it moved, has
//      stopped, and writes nothing; both wallets open.
//   5. The holder closes: a tab showing "open in another tab" goes on by itself to Unlock.
//   6. A browser whose lock manager cannot be asked (query() rejects; re-audit RE1-1): the tab fails
//      closed - no IndexedDB, no engine, "Close your other Beam PWA tabs", and the lock let go.
//   Both screens at 390 px, light and dark; the primary button fits a 375 x 667 phone.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PWA, startServer, launch, recordedPage, waitScreen, shot, sleep, SHOTS } from './harness.mjs';
import { createWallet, waitHome, unlockWithPassword } from './flows.mjs';

const PORT = Number(process.env.CAMPFIRE_ONETAB_PORT || 8991);
const tid = (id) => `[data-testid="${id}"]`;
const pw = (tag) => `${tag}-${randomBytes(6).toString('hex')}`;
const PA = pw('ot-a');
const PB = pw('ot-b');

let tmp, srv, browser, ctx, p1, p2, rec2;

const screenOf = (p) => p.evaluate(() => document.getElementById('app').dataset.screen);
const tabState = (p) => p.evaluate(() => window.__campfire.oneTab());

/** The engine's IndexedDB file store, read directly: path -> {timestamp, sha256} or {dir: true}. */
function idbFiles(p) {
  return p.evaluate(
    () =>
      new Promise((resolve, reject) => {
        const r = indexedDB.open('/beam_wallet');
        r.onerror = () => reject(r.error);
        r.onsuccess = () => {
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

/** Only the wallets' databases: '/beam_wallet/wallet.db' (the first slot), '/beam_wallet/<id>/wallet.db'. */
const dbsOf = (files) => Object.fromEntries(Object.entries(files).filter(([k]) => /\/wallet\.db$/.test(k)));

async function both(p, name) {
  for (const scheme of ['light', 'dark']) {
    await p.emulateMedia({ colorScheme: scheme });
    await sleep(300);
    await shot(p, `${name}-${scheme}`);
  }
  await p.emulateMedia({ colorScheme: 'light' });
}

async function fitsSmallPhone(p, selector, label) {
  const size = p.viewportSize();
  await p.setViewportSize({ width: 375, height: 667 });
  await sleep(300);
  const box = await p.locator(selector).first().boundingBox();
  await p.setViewportSize(size);
  assert.ok(box && box.y >= 0 && box.y + box.height <= 667, `${label}: the primary button is visible at 375 x 667 (${JSON.stringify(box)})`);
}

async function ownAddresses(p) {
  await p.waitForFunction(() => window.__campfire.running(), null, { timeout: 60000 });
  return p.evaluate(() => window.__campfire.addresses());
}

before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-onetab-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  ({ page: p1 } = await recordedPage(ctx, { label: 'tab1' }));
  console.log(`# screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close().catch(() => {});
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

test('1. a second tab shows "open in another tab": no IndexedDB, no engine, no node, no way into a wallet', { timeout: 15 * 60000 }, async () => {
  await p1.goto(srv.url);
  await createWallet(p1, { password: PA });
  await waitHome(p1, { timeout: 10 * 60000 });
  await p1.waitForFunction(() => window.__campfire.running(), null, { timeout: 60000 });
  const t1 = await tabState(p1);
  assert.equal(t1.state, 'held');
  assert.equal(t1.mode, 'locks');
  assert.ok(t1.clientId, 'the holder knows its client id (writes look the lock up by it)');

  ({ page: p2, rec: rec2 } = await recordedPage(ctx, { label: 'tab2' }));
  // Every IndexedDB database the page itself opens or deletes, from its first script on.
  await p2.addInitScript(() => {
    window.__idbUsed = [];
    const f = window.indexedDB;
    const open = f.open.bind(f);
    const del = f.deleteDatabase.bind(f);
    const where = () => String(new Error().stack).split('\n').slice(2, 6).join(' | ');
    f.open = (n, v) => (window.__idbUsed.push(`${n} <- ${where()}`), v === undefined ? open(n) : open(n, v));
    f.deleteDatabase = (n) => (window.__idbUsed.push(`delete ${n} <- ${where()}`), del(n));
  });
  await p2.goto(srv.url);
  await waitScreen(p2, 'otherTab', 60000);
  await sleep(1500);
  assert.equal((await tabState(p2)).state, 'busy');
  assert.deepEqual(await p2.evaluate(() => window.__idbUsed), [], 'tab 2 opened no IndexedDB database (neither /beam_wallet nor the app store)');
  assert.equal(await p2.evaluate(() => typeof window.BeamModule), 'undefined', 'the wallet engine was not loaded');
  assert.deepEqual(rec2.websockets, [], 'no node contacted');
  assert.equal(await p2.textContent('.one-tab h1'), 'Beam PWA is open in another tab');
  assert.equal(await p2.textContent('.one-tab .hero p'), 'It works in one tab at a time, so your wallet data stays intact.');
  assert.equal(await p2.textContent(tid('one-tab-use-here')), 'Use it here instead');
  // No way around it: Welcome (create, restore, import) and the words screen land on the same screen.
  for (const s of ['welcome', 'backup', 'unlock', 'home']) {
    await p2.evaluate((n) => window.__campfire.go(n), s);
    assert.equal(await screenOf(p2), 'otherTab', `asking for ${s} in tab 2`);
  }
  assert.deepEqual(await p2.evaluate(() => window.__idbUsed), []);
  await both(p2, 'onetab-01-other-tab');
  await fitsSmallPhone(p2, tid('one-tab-use-here'), 'open in another tab');
  assert.equal(await screenOf(p1), 'home', 'tab 1 carries on');
});

let addrA;
test('2. "Use it here instead": tab 1 locks and saves (what it just did is kept), stops, says it moved; tab 2 opens wallet A', { timeout: 10 * 60000 }, async () => {
  // A change in tab 1 that is not saved yet (the address-changed save waits 1.2 s), then the move at once.
  const made = await p1.evaluate(() => window.__campfire.createAddress('regular'));
  assert.ok(made.ok, 'an address was made in tab 1');
  addrA = await p1.evaluate(() => window.__campfire.addresses());
  await p2.click(tid('one-tab-use-here'));
  await waitScreen(p1, 'movedTab', 60000);
  const t1 = await tabState(p1);
  assert.equal(t1.state, 'gone');
  assert.equal(t1.how, 'handed');
  assert.equal(await p1.evaluate(() => window.__campfire.running()), false, "tab 1's engine stopped");
  assert.equal(await p1.textContent('.one-tab h1'), 'Beam PWA moved to another tab');
  assert.equal(await p1.textContent('.one-tab .hero p'), 'It works in one tab at a time. Your wallet was locked and saved here before it moved.');
  await both(p1, 'onetab-02-moved');
  await fitsSmallPhone(p1, tid('one-tab-use-here'), 'moved to another tab');
  // Tab 1 opens nothing any more.
  for (const s of ['unlock', 'welcome', 'home']) {
    await p1.evaluate((n) => window.__campfire.go(n), s);
    assert.equal(await screenOf(p1), 'movedTab', `asking for ${s} in tab 1`);
  }

  await waitScreen(p2, 'unlock', 60000);
  assert.equal((await tabState(p2)).state, 'held');
  await unlockWithPassword(p2, PA);
  await waitHome(p2, { timeout: 5 * 60000 });
  assert.deepEqual(await ownAddresses(p2), addrA, 'the address tab 1 made just before the move is in tab 2: tab 1 saved before letting go');
});

let files2;
test('3. the reported case: tab 2 creates wallet B; tab 1 can no longer save over it, and nothing is deleted or reverted', { timeout: 10 * 60000 }, async () => {
  const before = dbsOf(await idbFiles(p2));
  assert.ok(before['/beam_wallet/wallet.db'], "wallet A's file is stored");
  // Wallet B, added in tab 2.
  await p2.click(tid('wallet-chip'));
  await p2.waitForSelector(tid('switcher'));
  await p2.click(tid('switch-add'));
  await waitScreen(p2, 'addWallet');
  await p2.click(tid('add-create'));
  await waitScreen(p2, 'backup');
  await p2.waitForSelector('[data-testid="words"] .word');
  await p2.click(tid('reveal'));
  const words = await p2.$$eval('[data-testid="words"] .word span:last-child', (els) => els.map((e) => e.textContent));
  await p2.click(tid('wrote-down'));
  await waitScreen(p2, 'confirmWords');
  for (const pos of await p2.$$eval('[data-position]', (els) => els.map((e) => Number(e.dataset.position)))) await p2.click(`[data-position="${pos}"] [data-word="${words[pos - 1]}"]`);
  words.fill('');
  await p2.click(tid('confirm-words'));
  await waitScreen(p2, 'setPassword');
  await p2.fill(tid('pw1'), PB);
  await p2.fill(tid('pw2'), PB);
  await p2.click(tid('save-password'));
  await p2.waitForFunction(() => ['passkeySetup', 'home'].includes(document.getElementById('app').dataset.screen), null, { timeout: 120000 });
  if ((await screenOf(p2)) === 'passkeySetup') await p2.click(tid('passkey-skip'));
  await waitScreen(p2, 'home', 120000);
  await p2.waitForFunction(() => document.querySelector('[data-testid="wallet-name"]')?.textContent === 'Wallet 2', null, { timeout: 30000 });
  await ownAddresses(p2);
  assert.equal((await p2.evaluate(() => window.__campfire.saveNow())), true, 'tab 2 saves');
  files2 = dbsOf(await idbFiles(p2));
  const bPath = Object.keys(files2).find((k) => /^\/beam_wallet\/[0-9a-f]{16}\/wallet\.db$/.test(k));
  assert.ok(bPath, `wallet B has its own file: ${JSON.stringify(Object.keys(files2))}`);
  assert.ok(files2['/beam_wallet/wallet.db'].timestamp >= before['/beam_wallet/wallet.db'].timestamp, "wallet A's file is still there");

  // What used to happen every 15 s in tab 1: its copy of the mount (without B, with A as it was) written back.
  const refusedBefore = (await tabState(p1)).refusedSaves;
  assert.equal(await p1.evaluate(() => window.__campfire.saveNow()), false, "tab 1's save is refused");
  assert.ok((await tabState(p1)).refusedSaves > refusedBefore);
  await sleep(1000);
  const after = dbsOf(await idbFiles(p2));
  assert.ok(after[bPath], "wallet B's file is still there (IDBFS would have deleted it: tab 1's copy does not have it)");
  assert.deepEqual(after['/beam_wallet/wallet.db'], files2['/beam_wallet/wallet.db'], "wallet A's file was not written over by tab 1's older copy");
  assert.ok(after[bPath].timestamp >= files2[bPath].timestamp, "wallet B's file did not go back in time");
  const list = await p2.evaluate(() => window.__campfire.wallets());
  assert.deepEqual(list.map((w) => w.name).sort(), ['Wallet 1', 'Wallet 2']);
});

test('4. a holder that does not answer: "Take over anyway"; once it runs again it says it moved, has stopped, and writes nothing; both wallets open', { timeout: 10 * 60000 }, async () => {
  const cdp2 = await ctx.newCDPSession(p2);
  const refusedBefore = (await tabState(p2)).refusedSaves;
  // Tab 2 stops running anything (as a frozen background tab): the next script it would run waits.
  await cdp2.send('Debugger.enable');
  await cdp2.send('Debugger.pause');
  try {
    // The wait (lib/one_tab.js NO_ANSWER_MS, 10 s) starts with the tap: measured from just before it, so a
    // slow screenshot in between (a loaded machine) cannot eat into it.
    const t0 = Date.now();
    await p1.click(tid('one-tab-use-here'));
    await p1.waitForSelector(tid('one-tab-status'));
    assert.match(await p1.textContent(tid('one-tab-status')), /Waiting for the other tab to lock your wallet and save it/);
    await shot(p1, 'onetab-03-waiting-light');
    await p1.waitForSelector(tid('one-tab-steal'), { timeout: 30000 });
    const waited = Date.now() - t0;
    assert.ok(waited >= 9500, `"Take over anyway" came after the wait (${waited} ms after the tap)`);
    assert.match(await p1.textContent(tid('one-tab-note')), /The other tab isn't answering\. It may be asleep in the background\./);
    assert.equal(await p1.textContent(tid('one-tab-steal')), 'Take over anyway');
    await both(p1, 'onetab-04-not-answering');
    await fitsSmallPhone(p1, tid('one-tab-steal'), 'not answering');
    await p1.click(tid('one-tab-steal'));
    // Tab 1 let go before: it reloads (its memory held the old copy) and starts at Unlock.
    await waitScreen(p1, 'unlock', 120000);
    assert.equal((await tabState(p1)).state, 'held');
    assert.equal((await tabState(p1)).spent, false);
  } finally {
    await cdp2.send('Debugger.resume');
    await cdp2.send('Debugger.disable').catch(() => {});
  }
  await waitScreen(p2, 'movedTab', 60000);
  const t2 = await tabState(p2);
  assert.equal(t2.how, 'stolen');
  assert.equal(await p2.getAttribute('[data-testid="one-tab-moved"]', 'data-how'), 'stolen');
  assert.equal(await p2.textContent('.one-tab .hero p'), 'It works in one tab at a time. Another tab took it over, so your wallet is locked here.');
  await p2.waitForFunction(() => !window.__campfire.running(), null, { timeout: 60000 });
  // Stopping its engine saves on the way out (as every lock does): refused, not written.
  await p2.waitForFunction((n) => window.__campfire.oneTab().refusedSaves > n, refusedBefore, { timeout: 60000 });
  assert.equal(await p2.evaluate(() => window.__campfire.saveNow()), false, 'the tab whose lock was taken saves nothing');
  await both(p2, 'onetab-05-moved-stolen');
  const after = dbsOf(await idbFiles(p1));
  assert.deepEqual(Object.keys(after).sort(), Object.keys(files2).sort(), 'both wallets are still stored');

  // Both wallets open in tab 1: the last opened (B) first, then A from the switcher.
  await unlockWithPassword(p1, PB);
  await waitHome(p1, { timeout: 5 * 60000 });
  await p1.waitForFunction(() => document.querySelector('[data-testid="wallet-name"]')?.textContent === 'Wallet 2', null, { timeout: 30000 });
  assert.ok((await ownAddresses(p1)).length >= 1);
  await p1.click(tid('wallet-chip'));
  await p1.click('[data-testid="switch-row"][data-name="Wallet 1"]');
  await unlockWithPassword(p1, PA);
  await waitHome(p1, { timeout: 5 * 60000 });
  assert.deepEqual(await ownAddresses(p1), addrA, 'wallet A has every address it had');
});

test('5. the tab holding the wallet closes: a tab showing "open in another tab" goes on by itself (to Unlock)', { timeout: 3 * 60000 }, async () => {
  const { page: p3 } = await recordedPage(ctx, { label: 'tab3' });
  await p3.goto(srv.url);
  await waitScreen(p3, 'otherTab', 60000);
  await p1.close();
  // A free lock is taken only with ifAvailable (never a place in a queue), checked every 2 s.
  await waitScreen(p3, 'unlock', 30000);
  assert.equal((await tabState(p3)).state, 'held');
  assert.equal(await screenOf(p2), 'movedTab', 'the tab that lost the wallet earlier stays as it is (it reloads only when asked)');
});

test('6. a lock manager that cannot be asked: the tab runs no wallet and says to close the other tabs (fails closed)', { timeout: 3 * 60000 }, async () => {
  const { page: p4 } = await recordedPage(ctx, { label: 'tab4' });
  await p4.addInitScript(() => {
    window.__idbUsed = [];
    const f = window.indexedDB;
    const open = f.open.bind(f);
    f.open = (n, v) => (window.__idbUsed.push(n), v === undefined ? open(n) : open(n, v));
    // As a browser whose lock manager refuses to say who holds what.
    LockManager.prototype.query = function query() {
      return Promise.reject(new DOMException('The operation is insecure.', 'SecurityError'));
    };
  });
  const p3 = ctx.pages().find((p) => p !== p2 && p !== p4 && !p.isClosed());
  if (p3) await p3.close(); // the wallet is free: p4 gets the lock, then cannot check it
  await p4.goto(srv.url);
  await waitScreen(p4, 'movedTab', 60000);
  const t4 = await tabState(p4);
  assert.equal(t4.how, 'unchecked');
  assert.equal(t4.spent, true);
  assert.equal(await p4.getAttribute('[data-testid="one-tab-moved"]', 'data-how'), 'unchecked');
  assert.equal(await p4.textContent('.one-tab h1'), 'Close your other Beam PWA tabs');
  assert.equal(await p4.textContent('.one-tab .hero p'), 'This browser cannot keep Beam PWA to one tab. Close every other Beam PWA tab, then reload.');
  assert.equal(await p4.textContent(tid('one-tab-reload')), 'Reload');
  assert.deepEqual(await p4.evaluate(() => window.__idbUsed), [], 'no IndexedDB database opened');
  assert.equal(await p4.evaluate(() => typeof window.BeamModule), 'undefined', 'the wallet engine was not loaded');
  for (const s of ['welcome', 'unlock', 'home']) {
    await p4.evaluate((n) => window.__campfire.go(n), s);
    assert.equal(await screenOf(p4), 'movedTab', `asking for ${s}`);
  }
  // The lock it could not check was let go: a page of a browser that answers takes it at once.
  const held = await p2.evaluate(async () => (await navigator.locks.query()).held.map((l) => l.name));
  assert.deepEqual(held, [], 'nobody holds the lock');
  // Release audit RE3-1: the way out of a browser that can never say, under the button the first time...
  const wayOut = 'If this keeps happening, this browser cannot run Beam PWA safely: open it in another browser and restore your wallet there from its 12 words (or its wallet.db file).';
  assert.equal(await p4.textContent(`.actions ${tid('one-tab-way-out')}`), wayOut);
  await both(p4, 'onetab-06-unchecked');
  await fitsSmallPhone(p4, tid('one-tab-reload'), 'cannot keep to one tab');
  // ...and above it when Reload brought the same screen back.
  await p4.reload();
  await waitScreen(p4, 'movedTab', 60000);
  assert.equal(await p4.getAttribute(`${tid('one-tab-way-out')}[data-again="true"]`, 'data-again'), 'true');
  assert.equal(await p4.textContent(`${tid('one-tab-way-out')} .grow`), wayOut);
  assert.equal(await p4.$$eval(tid('one-tab-way-out'), (e) => e.length), 1, 'said once');
  assert.deepEqual(await p4.evaluate(() => window.__idbUsed), [], 'still no IndexedDB database opened');
  await both(p4, 'onetab-06b-unchecked-again');
  await fitsSmallPhone(p4, tid('one-tab-reload'), 'cannot keep to one tab, again');
});

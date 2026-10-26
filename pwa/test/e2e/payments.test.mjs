// Payments around a payment (no money moves): contacts, Send's Scan with a camera, the note,
// Your addresses, the payment proof check, and removing a finished payment from the list.
// One throwaway wallet on BEAM mainnet, its own build and port.
//
//   npm run e2e:payments
//
// The camera is Chrome's fake camera playing a picture of a QR code (a y4m file made here from
// Beam PWA's own QR encoder): the real getUserMedia → video → canvas → worker → jsQR path,
// under the app's real headers (Permissions-Policy camera=(self)).
// A failed payment with a note is made by sending from the empty wallet: the engine builds no
// transaction without coins, so nothing can leave it; the record that is left is "Not sent",
// carries the note, and can be removed from the list.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { chromium } from 'playwright-core';
import { startServer, recordedPage, waitScreen, shot, sleep, PWA, CHROME, foreignHosts, NODE_CERTS_ARGS } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';
import { encodeQr } from '../../src/lib/qr.js';

const PORT = 8920;
const tid = (id) => `[data-testid="${id}"]`;
const PASSWORD = `pay-${Math.random().toString(36).slice(2, 10)}`;
// BEAM's LightWallet test address (an old-style address, public in its docs): a valid address of
// another wallet, known before the browser starts, so the fake camera can show it.
const OTHER = '3f25d94eac4a95f4ff2b764f844aa588254982c6bcc83e02f157218d698c9df9477';
const SCANNED = `beam:${OTHER}?amount=0.5`;

/** A y4m video (one frame, looped by Chrome) of a QR code, black on white, in the middle of 640x480. */
function qrY4m(text, file) {
  const W = 640;
  const H = 480;
  const qr = encodeQr(text, { ecl: 'M' });
  const border = 4;
  const n = qr.size + border * 2;
  const scale = Math.floor(400 / n);
  const side = n * scale;
  const x0 = Math.floor((W - side) / 2);
  const y0 = Math.floor((H - side) / 2);
  const Y = Buffer.alloc(W * H, 235);
  for (let y = 0; y < side; y++)
    for (let x = 0; x < side; x++) {
      const mx = Math.floor(x / scale) - border;
      const my = Math.floor(y / scale) - border;
      if (mx >= 0 && my >= 0 && mx < qr.size && my < qr.size && qr.modules[my][mx]) Y[(y0 + y) * W + x0 + x] = 16;
    }
  const UV = Buffer.alloc((W / 2) * (H / 2), 128);
  writeFileSync(file, Buffer.concat([Buffer.from(`YUV4MPEG2 W${W} H${H} F10:1 Ip A1:1 C420jpeg\nFRAME\n`), Y, UV, UV]));
}

let tmp, srv, browser, ctx, page, rec;

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-payments-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  qrY4m(SCANNED, join(tmp, 'qr.y4m'));
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await chromium.launch({
    executablePath: CHROME,
    headless: process.env.HEADED ? false : true,
    args: ['--disable-features=AutofillServerCommunication', ...NODE_CERTS_ARGS, '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', `--use-file-for-fake-video-capture=${join(tmp, 'qr.y4m')}`],
  });
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  await ctx.grantPermissions(['camera', 'clipboard-read', 'clipboard-write'], { origin: srv.url });
  ({ page, rec } = await recordedPage(ctx, { label: 'payments' }));
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page, { timeout: 5 * 60000 });
  await waitSynced(page, 5 * 60000);
});
test.after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

const go = async (name, params) => {
  await page.evaluate(([n, p]) => window.__campfire.go(n, p), [name, params || {}]);
  await waitScreen(page, name);
};
/** The engine, as the page's own module (same URL, same instance): test-only reach-ins. */
const call = (method, params) => page.evaluate(async ([m, p]) => (await import('./lib/wallet.js')).wallet.session.call(m, p), [method, params]);
async function shots(name) {
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(250);
    await shot(page, `payments-${name}-${scheme}`);
  }
  await page.emulateMedia({ colorScheme: 'light' });
}
/** The primary action is on screen at 375x667 without scrolling. */
async function primaryAboveFold(selector) {
  await page.setViewportSize({ width: 375, height: 667 });
  await sleep(200);
  const box = await page.locator(selector).boundingBox();
  await page.setViewportSize({ width: 390, height: 844 });
  assert.ok(box && box.y + box.height <= 667, `${selector} is below the fold at 375x667 (${box && Math.round(box.y + box.height)})`);
}
async function closeSheets() {
  await page.evaluate(() => document.querySelectorAll('.overlay').forEach((o) => o.dispatchEvent(new Event('campfire:dismiss'))));
}

let X1, X2, X3, X4;

test('Your addresses: the one Receive shows, rename, show another on Receive, delete, expired folded away', { timeout: 10 * 60000 }, async () => {
  await go('receive');
  await page.waitForFunction(() => document.querySelector('[data-testid="receive-address"]').textContent.length > 20, null, { timeout: 60000 });
  const R0 = await page.textContent(tid('receive-address'));
  const before = (await call('addr_list', { own: true })).filter((a) => !a.expired).length; // Receive's, and any the wallet made for itself
  const made = [];
  for (const _ of [1, 2, 3, 4]) made.push((await page.evaluate(() => window.__campfire.createAddress('regular'))).r);
  [X1, X2, X3, X4] = made;
  assert.ok(made.every((a) => typeof a === 'string' && a.length > 40), 'four more addresses');
  await sleep(2500); // BEAM refuses to expire an address in the second it was made
  await call('edit_address', { address: X3, expiration: 'expired' });

  await page.click(tid('your-addresses'));
  await waitScreen(page, 'addresses');
  await page.waitForSelector(tid('addresses-active'));
  assert.equal(await page.locator(`${tid('addresses-active')} ${tid('address-tile')}`).count(), before + 3, 'the ones before, and X1, X2, X4');
  const cur = page.locator(`[data-address="${R0}"]`);
  assert.equal(await cur.locator(tid('address-current')).count(), 1, 'Receive’s address is marked');
  assert.match(await cur.textContent(), /Created .* · Never expires/);
  assert.match(await page.textContent(tid('addresses-expired-toggle')), /Expired \(1\)/);
  assert.equal(await page.locator(`[data-address="${X3}"]`).count(), 0, 'expired ones are folded');
  await shots('01-addresses');
  await page.click(tid('addresses-expired-toggle'));
  await page.waitForSelector(`${tid('addresses-expired')} [data-address="${X3}"]`);
  assert.match(await page.textContent(`[data-address="${X3}"] ${tid('address-life')}`), /Expired/);
  assert.equal(await page.locator(`[data-address="${X3}"] ${tid('address-make-current')}`).count(), 0, 'an expired address cannot be shown on Receive');
  await shot(page, 'payments-02-addresses-expired');

  // Rename X1, then make it the one Receive shows.
  const t1 = page.locator(`[data-address="${X1}"]`);
  await t1.locator(tid('address-rename')).click();
  await page.fill(tid('address-label-input'), 'From Alex');
  await shot(page, 'payments-03-address-label');
  await page.click(tid('address-label-save'));
  await page.waitForFunction((a) => document.querySelector(`[data-address="${a}"] [data-testid="address-label"]`)?.textContent === 'From Alex', X1);
  assert.equal((await call('addr_list', { own: true })).find((a) => a.address === X1).comment, 'From Alex', 'the label is the engine’s');
  await page.locator(`[data-address="${X1}"] ${tid('address-make-current')}`).click();
  await page.waitForSelector(`[data-address="${X1}"] ${tid('address-current')}`);
  // Delete X2 (it becomes another wallet's address for the contacts below: valid, not ours).
  await page.locator(`[data-address="${X2}"] ${tid('address-delete')}`).click();
  await page.waitForSelector(tid('address-delete-confirm'));
  await shots('04-address-delete');
  await page.click(tid('address-delete-confirm'));
  await page.waitForFunction((a) => !document.querySelector(`[data-address="${a}"]`), X2);
  assert.ok(!(await call('addr_list', { own: true })).some((a) => a.address === X2), 'deleted in the engine');

  // Receive now shows X1, also after leaving and coming back, and after its label changed.
  await go('receive');
  await page.waitForFunction((a) => document.querySelector('[data-testid="receive-address"]').textContent === a, X1, { timeout: 30000 });
  await go('home');
  await go('receive');
  await page.waitForFunction((a) => document.querySelector('[data-testid="receive-address"]').textContent === a, X1, { timeout: 30000 });
  await shots('05-receive');
  await primaryAboveFold(tid('share'));
  // A new address becomes the one shown.
  await page.click(tid('new-address'));
  await page.waitForFunction((a) => { const t = document.querySelector('[data-testid="receive-address"]').textContent; return t && t !== a && t.length > 20; }, X1, { timeout: 30000 });
  const NEW = await page.textContent(tid('receive-address'));
  await go('home');
  await go('receive');
  await page.waitForFunction((a) => document.querySelector('[data-testid="receive-address"]').textContent === a, NEW, { timeout: 30000 });
  // X4 too goes to another wallet: deleted here without the screen.
  await call('delete_address', { address: X4 });
});

test('Contacts: add with the wallet’s own check, refuse a duplicate and own address, edit shows the change, delete', { timeout: 5 * 60000 }, async () => {
  await go('settings');
  await page.waitForSelector(tid('contacts-row'));
  await shots('06-settings');
  await page.click(tid('contacts-row'));
  await waitScreen(page, 'contacts');
  await page.waitForSelector(tid('contacts-empty'));
  await shots('07-contacts-empty');
  await primaryAboveFold(tid('contact-add'));

  await page.click(tid('contact-add'));
  await page.fill(tid('contact-name'), 'Alice');
  await page.fill(tid('contact-address-input'), X1); // one of this wallet's own
  await page.click(tid('contact-save'));
  await page.waitForSelector('.sheet .notice.warn');
  assert.match(await page.textContent('.sheet .notice.warn'), /one of your own addresses/);
  await page.fill(tid('contact-address-input'), `${X2.slice(0, 30)}\n${X2.slice(30)}`); // a paste split over two lines
  await shots('08-contact-form');
  await page.click(tid('contact-save'));
  await page.waitForSelector(tid('contacts-list'));
  assert.match(await page.textContent(tid('contacts-list')), /Alice/);

  await page.click(tid('contact-add'));
  await page.fill(tid('contact-name'), 'Bob');
  await page.fill(tid('contact-address-input'), X2);
  await page.click(tid('contact-save'));
  await page.waitForSelector('.sheet .notice.info');
  assert.match(await page.textContent('.sheet .notice.info'), /already saved as Alice/);
  await page.fill(tid('contact-address-input'), X4);
  await page.click(tid('contact-save'));
  await page.waitForFunction(() => document.querySelectorAll('[data-testid="contacts-list"] .row').length === 2);
  await shots('09-contacts-list');

  // Edit Alice: the new address is spelt out before it is saved.
  await page.click('[data-contact="Alice"]');
  await page.waitForSelector(tid('contact-address'));
  assert.equal(await page.textContent(tid('contact-address')), X2, 'the full address');
  await shots('10-contact-sheet');
  await page.click(tid('contact-edit'));
  await page.fill(tid('contact-name'), 'Alice S');
  await page.fill(tid('contact-address-input'), OTHER);
  await page.waitForSelector(`${tid('contact-change')} .notice.warn`);
  assert.match(await page.textContent(tid('contact-change')), /The address changes/);
  await shot(page, 'payments-11-contact-edit-change');
  await page.fill(tid('contact-address-input'), X2);
  assert.equal(await page.locator(`${tid('contact-change')} .notice`).count(), 0, 'no change, no warning');
  await page.click(tid('contact-save'));
  await page.waitForSelector('[data-contact="Alice S"]');

  // Delete Bob.
  await page.click('[data-contact="Bob"]');
  await page.click(tid('contact-delete'));
  await page.click(tid('contact-delete-confirm'));
  await page.waitForFunction(() => !document.querySelector('[data-contact="Bob"]'));

  // Sealed in IndexedDB under this wallet's key, nothing in the clear.
  const stored = await page.evaluate(async () => {
    const { store } = await import('./lib/store.js');
    const rec = await store.get('wallet');
    const env = await store.get(`w:${rec.id}:payments`);
    return { keyOk: Boolean(env), json: JSON.stringify(env) };
  });
  assert.ok(stored.keyOk, 'kept under payments:<wallet id>');
  assert.ok(!stored.json.includes('Alice') && !stored.json.includes(X2.slice(5, 25)), 'sealed');
});

test('Send: pick a contact (its address shown), a look-alike called out, Scan with the camera, camera refused → Paste', { timeout: 5 * 60000 }, async () => {
  await go('send');
  await page.click(tid('send-contacts'));
  await page.waitForSelector(tid('pick-list'));
  assert.match(await page.textContent(tid('pick-list')), new RegExp(`Alice S.*${X2.slice(0, 16)}`));
  await shots('12-send-pick');
  await page.click(tid('pick-contact'));
  await page.waitForFunction((a) => document.querySelector('[data-testid="send-address"]').value === a, X2);
  await page.waitForSelector(tid('send-contact-name'));
  assert.match(await page.textContent(tid('send-contact-name')), /Alice S · your contact/);
  await page.fill(tid('send-amount'), '0.01');
  await page.click(tid('send-add-note'));
  await page.fill(tid('send-note'), 'Rent for March');
  assert.match(await page.textContent(tid('send-note-hint')), /doesn't send it to the receiver/);
  await shots('13-send-contact-note');
  await primaryAboveFold(tid('review'));

  // An address that starts and ends like Alice's but is not hers.
  const mid = Math.floor(X2.length / 2);
  const look = `${X2.slice(0, mid)}${X2[mid] === 'a' ? 'b' : 'a'}${X2.slice(mid + 1)}`;
  await page.fill(tid('send-address'), look);
  await page.waitForSelector(tid('send-lookalike'));
  assert.match(await page.textContent(tid('send-lookalike')), /Not Alice S's saved address/);
  await shot(page, 'payments-14-send-lookalike');
  await primaryAboveFold(tid('review')); // the warning and the note push the content down; the button stays

  // Scan: the fake camera shows beam:<OTHER>?amount=0.5.
  await page.fill(tid('send-address'), '');
  await page.fill(tid('send-amount'), '');
  await page.click(tid('send-scan'));
  await page.waitForSelector(tid('scan-video'));
  await page.waitForFunction((a) => document.querySelector('[data-testid="send-address"]').value === a, OTHER, { timeout: 30000 });
  assert.equal(await page.inputValue(tid('send-amount')), '0.5', 'the amount from the beam: link');
  assert.equal(await page.locator('.overlay').count(), 0, 'the scanner closed itself');
  await page.waitForFunction(() => /Regular address|isn't a BEAM address|own addresses/.test(document.querySelector('[data-testid="address-hint"]').textContent), null, { timeout: 20000 });
  await shot(page, 'payments-16-send-scanned');
  // A picture of the scanner itself, with the camera on: its reader is held back for it (a
  // worker that never answers), or the sheet would close on the first frame it reads.
  await page.evaluate(() => {
    window.__RealWorker = window.Worker;
    window.Worker = class { postMessage() {} terminate() {} };
  });
  await page.click(tid('send-scan'));
  await page.waitForFunction(() => { const v = document.querySelector('[data-testid="scan-video"]'); return v && v.videoWidth > 0; }, null, { timeout: 20000 });
  assert.match(await page.textContent(tid('scan-status')), /Point the camera/);
  await shots('15-scanner');
  await closeSheets();
  await page.evaluate(() => (window.Worker = window.__RealWorker));

  // Camera refused: says so, offers Paste, which pastes.
  await page.evaluate(() => {
    window.__realGum = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
    navigator.mediaDevices.getUserMedia = () => Promise.reject(Object.assign(new Error('denied'), { name: 'NotAllowedError' }));
  });
  await page.evaluate((a) => navigator.clipboard.writeText(a), X4);
  await page.click(tid('send-scan'));
  await page.waitForSelector(tid('scan-problem'));
  assert.equal(await page.getAttribute(tid('scan-problem'), 'data-code'), 'denied');
  assert.match(await page.textContent(tid('scan-problem')), /allow the camera/);
  await shots('17-scan-refused');
  await page.click(tid('scan-problem-paste'));
  await page.waitForFunction((a) => document.querySelector('[data-testid="send-address"]').value === a, X4, { timeout: 10000 });
  await page.evaluate(() => (navigator.mediaDevices.getUserMedia = window.__realGum));
  // A checked new address can be saved as a contact from here.
  await page.waitForSelector(tid('send-save-contact'), { timeout: 20000 });
  await page.click(tid('send-save-contact'));
  await page.fill(tid('contact-name'), 'Carol');
  assert.equal(await page.inputValue(tid('contact-address-input')), X4, 'the address from Send, pre-filled');
  await page.click(tid('contact-save'));
  await page.waitForSelector(tid('send-contact-name'));
  assert.match(await page.textContent(tid('send-contact-name')), /Carol/);
});

test('A note reaches Review and the engine; the failed record shows it, and is removed from the list; proof check refuses junk', { timeout: 5 * 60000 }, async () => {
  // The wallet is empty: Send would stop at "more than you have". Show it a balance it does not
  // have, so the whole path runs; the engine itself has no coins and builds nothing.
  await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    wallet.refreshStatus = async () => {};
    wallet.state.totals.set(0, { available: 100000000n, receiving: 0n, sending: 0n, maturing: 0n });
    wallet.emit();
  });
  await go('send');
  await page.fill(tid('send-address'), '');
  await page.click(tid('send-contacts'));
  await page.click(`${tid('pick-list')} [data-contact="Alice S"]`);
  await page.fill(tid('send-amount'), '0.01');
  if (await page.isVisible(tid('send-add-note'))) await page.click(tid('send-add-note'));
  await page.fill(tid('send-note'), '  Rent\nfor March  ');
  await page.waitForFunction(() => !document.querySelector('[data-testid="review"]').disabled, null, { timeout: 20000 });
  await page.click(tid('review'));
  await waitScreen(page, 'review');
  assert.equal(await page.textContent(tid('review-note')), 'Rent for March');
  assert.equal(await page.textContent(tid('review-contact')), 'Alice S');
  await shots('18-review-note');
  await primaryAboveFold(tid('confirm-send'));
  await page.click(tid('confirm-send'));
  await page.fill(tid('auth-pw'), PASSWORD);
  await page.click(tid('auth-submit'));
  await page.waitForFunction(() => ['txStatus', 'review'].includes(window.__campfire.screen()) && (window.__campfire.screen() === 'txStatus' || document.querySelector('.notice.error')), null, { timeout: 60000 });
  let tx = null;
  for (let i = 0; i < 30 && !tx; i++) {
    tx = (await call('tx_list', { count: 50 })).find((t) => t.comment === 'Rent for March');
    if (!tx) await sleep(1000);
  }
  assert.ok(tx, 'the engine kept the note as the payment’s comment');
  for (let i = 0; i < 60 && ![2, 4].includes(Number(tx.status)); i++) {
    await sleep(1000);
    tx = (await call('tx_list', { count: 50 })).find((t) => t.txId === tx.txId);
  }
  assert.ok([2, 4].includes(Number(tx.status)), `not sent (status ${tx.status}): an empty wallet sends nothing`);

  await go('activity', { txId: tx.txId });
  await page.waitForSelector(tid('tx-note'));
  assert.match(await page.textContent(tid('tx-note')), /Note.*Rent for March/);
  assert.match(await page.textContent(tid('tx-contact')), /To your contact Alice S/);
  assert.equal(await page.locator(tid('tx-get-proof')).count(), 0, 'no proof for a payment that never happened');
  assert.equal(await page.locator(tid('tx-explorer')).count(), 0, 'no kernel, no explorer link');
  await shots('19-failed-with-note');
  await page.click(tid('tx-remove'));
  await page.waitForSelector(tid('tx-remove-confirm'));
  assert.match(await page.locator('.sheet').last().textContent(), /Nothing changes on the blockchain/);
  await shots('20-remove-confirm');
  await page.click(tid('tx-remove-confirm'));
  await page.waitForSelector('.toast');
  assert.match(await page.textContent('.toast'), /Removed from your list/);
  assert.ok(!(await call('tx_list', { count: 50 })).some((t) => t.txId === tx.txId), 'gone from the engine’s list');
  await page.waitForFunction((id) => !document.querySelector(`[data-txid="${id}"]`), tx.txId);

  // Check a payment proof: junk is "not a proof", and so is hex the engine cannot parse.
  await go('settings');
  await page.click(tid('check-proof-row'));
  await waitScreen(page, 'checkProof');
  await shots('21-check-proof');
  await primaryAboveFold(tid('proof-check'));
  await page.fill(tid('proof-input'), 'hello, this is my proof');
  await page.click(tid('proof-check'));
  await page.waitForSelector(`${tid('proof-result')} .notice.warn`);
  assert.match(await page.textContent(tid('proof-result')), /not a payment proof/);
  await page.fill(tid('proof-input'), 'ab'.repeat(80));
  await page.click(tid('proof-check'));
  await page.waitForSelector(`${tid('proof-not-a-proof')}, ${tid('proof-invalid')}`, { timeout: 20000 });
  await shot(page, 'payments-22-proof-junk');
});

test('privacy: only this origin and the node; no CSP violation; the camera worker and jsQR load from the app', async () => {
  assert.deepEqual(foreignHosts(rec, srv.url), []);
  const csp = await page.evaluate(() => window.__cspViolations);
  assert.deepEqual(csp, []);
  assert.ok(rec.requests.some((u) => u.endsWith('/lib/qr_worker.js')));
  assert.ok(rec.requests.some((u) => u.endsWith('/vendor/jsqr/jsQR.js')));
  assert.deepEqual(rec.errors, []);
});

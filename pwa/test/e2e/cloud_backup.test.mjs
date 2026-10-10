// Settings -> Backup -> "Keep a copy in iCloud Drive" (optional). A new wallet (mainnet, no money)
// on an iPhone-like browser with a short password: the copy asks for a password of at least 12
// characters for itself, refuses a wrong BEAM Campfire password, a mismatch and a short one, and
// hands out wallet.db. That file is imported in a fresh browser: the short app password does not
// open it, the copy's password does, and it is the same wallet (same addresses). There, with a
// long password, the copy needs no second password.
//   npm run e2e:cloud-backup   (own build and port, so it can run beside the other suites)
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen, shot, sleep, PWA } from './harness.mjs';
import { createWallet, waitHome } from './flows.mjs';

const PORT = 8821;
const tid = (id) => `[data-testid="${id}"]`;
const IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
const SHORT = `cb-${Math.random().toString(36).slice(2, 9)}`; // 10 characters: allowed to unlock, short for the cloud
const FILE_PW = `cloud-copy-${Math.random().toString(36).slice(2, 10)}`; // 19 characters

let tmp, srv, browser, savedFile, addrsA;

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-cloud-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await launch();
});
test.after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

const openCloud = async (page) => {
  await page.evaluate(() => window.__campfire.go('backup'));
  await waitScreen(page, 'backup');
  await page.locator(tid('cloud-card')).scrollIntoViewIfNeeded();
};

test('iPhone, short password: a longer one for the copy, wrong and weak ones refused, the file handed out', { timeout: 10 * 60000 }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, userAgent: IPHONE, hasTouch: true, isMobile: true, acceptDownloads: true });
  const { page } = await recordedPage(ctx, { label: 'cloud-a' });
  await page.goto(srv.url);
  await createWallet(page, { password: SHORT });
  await waitHome(page, { timeout: 5 * 60000 });
  addrsA = await page.evaluate(() => window.__campfire.addresses());
  await openCloud(page);
  const card = await page.textContent(tid('cloud-card'));
  assert.match(card, /Keep a copy in iCloud Drive/);
  assert.match(card, /^Keep a copy in iCloud DriveOptional\./);
  assert.match(card, /at least 12 characters/);
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(300);
    await shot(page, `cloud-01-card-${scheme}`);
  }
  await page.emulateMedia({ colorScheme: 'light' });
  await page.click(tid('cloud-start'));
  await page.fill(tid('cloud-pw'), `${SHORT}-nope`);
  await page.click(tid('cloud-continue'));
  await page.waitForSelector('.sheet .notice.error');
  assert.match(await page.textContent('.sheet .notice.error'), /didn't match/);
  await page.fill(tid('cloud-pw'), SHORT);
  await page.click(tid('cloud-continue'));
  await page.waitForSelector(tid('cloud-pw1'));
  assert.match(await page.textContent(tid('cloud-choose-lead')), /short for a file kept in iCloud Drive/);
  await shot(page, 'cloud-02-choose');
  await page.fill(tid('cloud-pw1'), 'short-one');
  await page.fill(tid('cloud-pw2'), 'short-one');
  await page.click(tid('cloud-prepare'));
  assert.match(await page.textContent('.sheet .notice.warn'), /at least 12 characters/);
  await page.fill(tid('cloud-pw1'), FILE_PW);
  await page.fill(tid('cloud-pw2'), `${FILE_PW}x`);
  await page.click(tid('cloud-prepare'));
  assert.match(await page.textContent('.sheet .notice.warn'), /don't match/);
  await page.fill(tid('cloud-pw1'), FILE_PW);
  await page.fill(tid('cloud-pw2'), FILE_PW);
  await page.click(tid('cloud-prepare'));
  await page.waitForSelector(tid('cloud-save'), { timeout: 180000 });
  assert.match(await page.textContent(tid('cloud-opens-with')), /the password you chose/);
  const steps = await page.textContent(tid('cloud-steps'));
  assert.match(steps, /Save to Files/);
  assert.match(steps, /iCloud Drive/);
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(300);
    await shot(page, `cloud-03-ready-${scheme}`);
  }
  // Headless Chrome has no share sheet for files: the download is the same file.
  const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 30000 }), page.click(tid('cloud-save'))]);
  savedFile = join(tmp, 'copy.db');
  await dl.saveAs(savedFile);
  assert.match(dl.suggestedFilename(), /^beam-campfire-wallet-\d{4}-\d{2}-\d{2}\.db$/);
  assert.ok(statSync(savedFile).size > 10000);
  await page.waitForSelector('.toast');
  assert.match(await page.textContent('.toast'), /iCloud Drive in Files/);
  // The wallet still runs after the copy (the export pauses it for a moment).
  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await page.waitForFunction(() => window.__campfire.running(), null, { timeout: 60000 });
  await ctx.close();
});

test('the copy comes back in a fresh browser with its own password, not the short one; it is the same wallet', { timeout: 10 * 60000 }, async () => {
  assert.ok(savedFile, 'the first test saved the copy');
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  const { page } = await recordedPage(ctx, { label: 'cloud-b' });
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 60000);
  await page.click(tid('import'));
  await waitScreen(page, 'importWallet');
  await page.setInputFiles(tid('import-file'), savedFile);
  await page.fill(tid('import-pw'), SHORT);
  await page.click(tid('import-submit'));
  await page.waitForSelector('.notice.error', { timeout: 120000 });
  assert.equal(await page.evaluate(() => window.__campfire.record()), null, 'nothing added with the wrong password');
  await page.fill(tid('import-pw'), FILE_PW);
  await page.click(tid('import-submit'));
  await page.waitForFunction(() => ['passkeySetup', 'fastStart', 'home'].includes(window.__campfire.screen()), null, { timeout: 180000 });
  if ((await page.evaluate(() => window.__campfire.screen())) === 'passkeySetup') await page.click(tid('passkey-skip'));
  await waitHome(page, { timeout: 5 * 60000 });
  const addrsB = await page.evaluate(() => window.__campfire.addresses());
  for (const a of addrsA) assert.ok(addrsB.includes(a), 'the copy is the same wallet');

  // A long password needs no second one; off Apple devices the card names "your cloud storage"
  // (headless Chrome on a Mac reports a Mac: iCloud Drive through Downloads and Finder).
  await openCloud(page);
  assert.match(await page.textContent(tid('cloud-card')), /iCloud Drive/);
  await page.click(tid('cloud-start'));
  await page.fill(tid('cloud-pw'), FILE_PW);
  await page.click(tid('cloud-continue'));
  await page.waitForSelector(tid('cloud-save'), { timeout: 180000 });
  assert.equal(await page.isVisible(tid('cloud-pw1')), false, 'no second password');
  assert.match(await page.textContent(tid('cloud-opens-with')), /your BEAM Campfire password/);
  assert.match(await page.textContent(tid('cloud-steps')), /Finder/);
  await shot(page, 'cloud-04-ready-mac');
  await page.click(tid('cloud-cancel')).catch(() => page.keyboard.press('Escape'));
  await ctx.close();
});

// UI flows shared by the e2e tests and the live money test. They drive the
// real screens by their data-testid hooks.
import { waitScreen, shot, sleep } from './harness.mjs';

const tid = (id) => `[data-testid="${id}"]`;

/**
 * Welcome -> words -> confirm -> password -> (passkey) -> IP notice -> Connect.
 * A new wallet then opens by itself (no snapshot download, no block scan).
 * Returns the words (throwaway wallets only) and when Connect was tapped.
 */
export async function createWallet(page, { password, passkey = false, shots = null }) {
  await waitScreen(page, 'welcome', 60000);
  if (shots) await shot(page, `${shots}-01-welcome`);
  await page.click(tid('create'));
  await waitScreen(page, 'backup');
  await page.waitForSelector('[data-testid="words"] .word');
  if (shots) await shot(page, `${shots}-02-backup-hidden`);
  await page.click(tid('reveal'));
  const words = await page.$$eval('[data-testid="words"] .word span:last-child', (els) => els.map((e) => e.textContent));
  if (words.length !== 12) throw new Error(`expected 12 words, got ${words.length}`);
  if (shots) await shot(page, `${shots}-03-backup-shown-THROWAWAY`);
  await page.click(tid('wrote-down'));
  await waitScreen(page, 'confirmWords');
  if (shots) await shot(page, `${shots}-04-confirm`);
  const positions = await page.$$eval('[data-position]', (els) => els.map((e) => Number(e.dataset.position)));
  for (const pos of positions) {
    await page.click(`[data-position="${pos}"] [data-word="${words[pos - 1]}"]`);
  }
  await page.click(tid('confirm-words'));
  await finishProtect(page, { password, passkey, shots });
  const connectedAt = Date.now();
  return { words, connectedAt };
}

/** Restore -> paste words -> password -> (skip passkey) -> IP notice -> download the snapshot. */
export async function restoreWallet(page, { words, password, shots = null }) {
  await waitScreen(page, 'welcome', 60000);
  await page.click(tid('restore'));
  await waitScreen(page, 'restore');
  if (shots) await shot(page, `${shots}-01-restore-empty`); // before any word is typed
  await page.fill(tid('word-1'), words.join(' '));
  await page.waitForFunction(() => !document.querySelector('[data-testid="restore-submit"]').disabled, null, { timeout: 30000 });
  await page.click(tid('restore-submit'));
  await finishProtect(page, { password, passkey: false, shots: null });
  await waitScreen(page, 'fastStart');
  await page.waitForSelector(tid('fast-download'));
  if (shots) await shot(page, `${shots}-02-restore-download-choice`);
  await page.click(tid('fast-download'));
}

async function finishProtect(page, { password, passkey, shots }) {
  await waitScreen(page, 'setPassword');
  await page.fill(tid('pw1'), password);
  await page.fill(tid('pw2'), password);
  if (shots) await shot(page, `${shots}-05-password`);
  await page.click(tid('save-password'));
  await page.waitForFunction(() => ['passkeySetup', 'ipNotice', 'fastStart'].includes(document.getElementById('app').dataset.screen), null, { timeout: 30000 });
  if ((await page.evaluate(() => document.getElementById('app').dataset.screen)) === 'passkeySetup') {
    if (shots) await shot(page, `${shots}-06-passkey`);
    if (passkey) await page.click(tid('passkey-on'));
    else await page.click(tid('passkey-skip'));
  }
  await waitScreen(page, 'ipNotice', 30000);
  if (shots) await shot(page, `${shots}-07-ip-notice`);
  await page.click(tid('ip-how'));
  if (shots) await shot(page, `${shots}-08-ip-notice-details`);
  await page.click(tid('ip-connect'));
}

export async function waitHome(page, { timeout = 15 * 60000, shots = null } = {}) {
  let shotTaken = false;
  const t0 = Date.now();
  while (Date.now() - t0 < timeout) {
    const screen = await page.evaluate(() => document.getElementById('app').dataset.screen);
    if (screen === 'home') return;
    if (shots && !shotTaken && screen === 'fastStart' && Date.now() - t0 > 8000) {
      await shot(page, `${shots}-10-fast-start-progress`);
      shotTaken = true;
    }
    await sleep(250);
  }
  throw new Error('home did not appear');
}

export async function waitSynced(page, timeout = 10 * 60000) {
  await page.waitForFunction(() => window.__campfire && window.__campfire.sync().state === 'synced', null, { timeout, polling: 1000 });
  return page.evaluate(() => ({ sync: window.__campfire.sync(), height: window.__campfire.height() }));
}

export async function unlockWithPassword(page, password) {
  await waitScreen(page, 'unlock', 60000);
  const pwVisible = await page.isVisible(tid('unlock-pw'));
  if (!pwVisible) await page.click(tid('use-password'));
  await page.fill(tid('unlock-pw'), password);
  await page.click(tid('unlock-submit'));
}

export async function lock(page) {
  await page.click(tid('lock'));
  await waitScreen(page, 'unlock');
}

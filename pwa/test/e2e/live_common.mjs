// Shared by the live mainnet tests: the test wallet's words (read at run time,
// never printed or screenshotted) and restoring it through the real screens.
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { shot, waitScreen, sleep } from './harness.mjs';

export const tid = (id) => `[data-testid="${id}"]`;
export const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

export function readEnv(file) {
  const out = {};
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#') || !t.includes('=')) continue;
    const i = t.indexOf('=');
    out[t.slice(0, i)] = t.slice(i + 1).trim().replace(/^["']|["']$/g, '');
  }
  return out;
}

/** FUNDER2's 12 words from ~/.config/campfire-beam/test_wallets.env. */
export function funderWords() {
  const env = readEnv(join(homedir(), '.config', 'campfire-beam', 'test_wallets.env'));
  const words = (env.FUNDER2_WALLET_SEED || '').split(/[\s;]+/).filter(Boolean);
  if (words.length !== 12) throw new Error('FUNDER2_WALLET_SEED is missing or not 12 words (not printed)');
  return words;
}

/** Restores [words] through Welcome → Restore → password → recovery snapshot. */
export async function restoreFunder(page, words, password, prefix = 'live-A') {
  await waitScreen(page, 'welcome', 60000);
  await page.click(tid('restore'));
  await waitScreen(page, 'restore');
  await shot(page, `${prefix}-01-restore-empty`); // before any word is typed
  await page.fill(tid('word-1'), words.join(' '));
  await page.waitForFunction(() => !document.querySelector('[data-testid="restore-submit"]').disabled, null, { timeout: 30000 });
  await page.click(tid('restore-submit'));
  await waitScreen(page, 'setPassword');
  await page.fill(tid('pw1'), password);
  await page.fill(tid('pw2'), password);
  await page.click(tid('save-password'));
  await page.waitForFunction(() => ['passkeySetup', 'ipNotice'].includes(document.getElementById('app').dataset.screen), null, { timeout: 30000 });
  if ((await page.evaluate(() => document.getElementById('app').dataset.screen)) === 'passkeySetup') await page.click(tid('passkey-skip'));
  await waitScreen(page, 'ipNotice');
  await page.click(tid('ip-connect'));
  await waitScreen(page, 'fastStart');
  await shot(page, `${prefix}-02-fast-start-restore`);
  await page.click(tid('fast-download'));
}

export const total = (page, assetId) =>
  page.evaluate((id) => window.__campfire.totals()[id] || { available: '0', receiving: '0', sending: '0' }, assetId);

/** Waits for the first transaction matching [pred] to complete (status 3). */
export async function waitTx(page, pred, label, timeoutMs = 20 * 60000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    const txs = await page.evaluate(() => window.__campfire.txs());
    const t = txs.find(pred);
    if (t && Number(t.status) === 3) return t;
    if (t && (Number(t.status) === 4 || Number(t.status) === 2)) throw new Error(`${label}: status ${t.status}`);
    await sleep(5000);
  }
  throw new Error(`${label}: not completed in time`);
}

// LIVE MONEY TEST on BEAM mainnet, tiny amounts only: a payment while one
// wallet is away, the way it happens on a phone (you leave the wallet to send
// from another app, and iOS suspends or closes the page).
//
//   npm run e2e:live:away
//
// A = FUNDER2 restored from its 12 words (read at run time, never printed);
// B = a fresh throwaway wallet. Three rounds, each away for AWAY_MS:
//   1. B suspended (page frozen and offline) while A pays it 0.01 BEAM; B comes back.
//   2. B closed while A pays it 0.01 BEAM; B is opened again and unlocked.
//   3. B pays everything back to A (0.019 BEAM) and is closed at once; B comes back.
// Each round prints what both wallets showed while the other was away, and how
// long the payment took once it was back. A wallet that locks itself meanwhile (5
// minutes without a tap) must keep a payment under way going behind the lock
// screen: the test then waits, locked, for the engine to stop by itself, unlocks,
// and checks the payment completed.
//
// B's words are appended to ~/.config/campfire-beam/test_wallets.env (AWAYB_WALLET_SEED,
// never printed), so nothing can be stranded in it.
//
// Hard limits: refuses any payment above 0.02 BEAM; refuses to start if A has
// less than 0.025 BEAM.
import { appendFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, shot, waitScreen, sleep } from './harness.mjs';
import { createWallet, waitHome, waitSynced, unlockWithPassword } from './flows.mjs';
import { tid, log, funderWords as readFunderWords, restoreFunder as restore, total } from './live_common.mjs';

const MAX_GROTH = 2000000n;
const PORT = 8798;
const AWAY_MS = Number(process.env.AWAY_MS || 3 * 60000);
const funderWords = readFunderWords();
const pwA = `away-a-${Math.random().toString(36).slice(2, 10)}`;
const pwB = `away-b-${Math.random().toString(36).slice(2, 10)}`;
const STATUS = { 0: 'pending', 1: 'in progress', 2: 'canceled', 3: 'completed', 4: 'failed', 5: 'registering' };

async function pay(page, who, address, amountText, password) {
  await page.evaluate(() => window.__campfire.go('send'));
  await waitScreen(page, 'send');
  await page.fill(tid('send-address'), address);
  await page.waitForFunction(() => /Regular address/.test(document.querySelector('[data-testid="address-hint"]').textContent), null, { timeout: 30000 });
  if (amountText === 'max') await page.click(tid('max'));
  else await page.fill(tid('send-amount'), amountText);
  const typed = await page.inputValue(tid('send-amount'));
  if (BigInt(Math.round(Number(typed) * 1e8)) > MAX_GROTH) throw new Error(`refusing to send ${typed} BEAM (limit 0.02)`);
  await page.waitForFunction(() => !document.querySelector('[data-testid="review"]').disabled, null, { timeout: 60000 });
  await page.click(tid('review'));
  await waitScreen(page, 'review');
  await page.click(tid('confirm-send'));
  await page.waitForSelector(tid('auth-pw'), { timeout: 20000 });
  await page.fill(tid('auth-pw'), password);
  await page.click(tid('auth-submit'));
  await waitScreen(page, 'txStatus', 60000);
  log(`${who} sent ${typed} BEAM`);
  return BigInt(Math.round(Number(typed) * 1e8));
}

const txs = (page) => page.evaluate(() => window.__campfire.txs());

/** The tx matching [pred] in [page], or null. */
async function find(page, pred) {
  return (await txs(page)).find(pred) || null;
}

const screenOf = (page) => page.evaluate(() => window.__campfire.screen());
const lockEvents = [];

/** Unlocks [page] when it locked itself; returns whether it had. */
async function ensureOpen(page, who, pw) {
  if ((await screenOf(page)) !== 'unlock') return false;
  await unlockWithPassword(page, pw);
  await waitHome(page, { timeout: 5 * 60000 });
  log(`  ${who}: unlocked`);
  return true;
}

/**
 * Polls until the tx matching [pred] completes; logs every status change. A wallet
 * that locked itself with the payment under way must keep its engine running until
 * the payment settles (then the engine stops by itself); it is then unlocked and
 * the payment must be completed.
 */
async function until(page, who, pw, pred, timeoutMs = 15 * 60000) {
  const t0 = Date.now();
  let last = 'none';
  const note = (s) => {
    if (s !== last) {
      log(`  ${who}: ${s} (+${Math.round((Date.now() - t0) / 1000)} s)`);
      last = s;
    }
  };
  while (Date.now() - t0 < timeoutMs) {
    if ((await screenOf(page)) === 'unlock') {
      const running = await page.evaluate(() => window.__campfire.running());
      const t = running ? await find(page, pred) : null;
      if (t && [0, 1, 5].includes(Number(t.status))) {
        const said = await page.textContent('[data-testid="locked-notice"]').catch(() => '');
        note(`locked, payment ${STATUS[t.status]}, engine running`);
        if (!/keeps going/.test(said || '')) throw new Error(`${who}: locked with a payment under way but the lock screen does not say it keeps going`);
        await sleep(3000);
        continue;
      }
      note(`locked, engine ${running ? 'running' : 'stopped'}`);
      lockEvents.push({ who, at: Math.round((Date.now() - t0) / 1000), engine: running ? 'running' : 'stopped' });
      await ensureOpen(page, who, pw);
      continue;
    }
    const t = await find(page, pred);
    note(t ? STATUS[t.status] || String(t.status) : 'not listed');
    if (t && Number(t.status) === 3) return { ms: Date.now() - t0, tx: t };
    if (t && [2, 4].includes(Number(t.status))) throw new Error(`${who}: ${last}`);
    await sleep(3000);
  }
  throw new Error(`${who}: not completed in ${timeoutMs / 60000} min (last: ${last})`);
}

/** Watches [page] while the other wallet is away, logging what it shows. */
async function watchAway(page, who, pred, ms) {
  const t0 = Date.now();
  let last = '';
  while (Date.now() - t0 < ms) {
    const t = await find(page, pred);
    const s = t ? STATUS[t.status] || String(t.status) : 'not listed';
    if (s !== last) {
      log(`  ${who} while the other is away: ${s} (+${Math.round((Date.now() - t0) / 1000)} s)`);
      last = s;
    }
    await sleep(5000);
  }
  return last;
}

async function openB(ctx) {
  const B = await recordedPage(ctx, { label: 'B' });
  await B.page.goto(srv.url);
  await unlockWithPassword(B.page, pwB);
  await waitHome(B.page, { timeout: 5 * 60000 });
  return B;
}

const results = [];
const extra = process.env.BEAM_RECOVERY_FILE ? ['--recovery-file', process.env.BEAM_RECOVERY_FILE] : [];
const srv = await startServer({ port: PORT, extra });
const browser = await launch();
const ctxA = await browser.newContext({ viewport: { width: 375, height: 667 }, deviceScaleFactor: 2 });
const ctxB = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
const A = await recordedPage(ctxA, { label: 'A' });
let B = await recordedPage(ctxB, { label: 'B' });
let exit = 0;
try {
  log('A: restoring FUNDER2 through the Restore screen + recovery snapshot');
  await A.page.goto(srv.url);
  await restore(A.page, funderWords, pwA, 'away-A');
  await waitHome(A.page, { timeout: 20 * 60000 });
  await waitSynced(A.page, 15 * 60000);
  await sleep(8000);
  const a0 = await total(A.page, 0);
  log('A synced; BEAM available (groth):', a0.available);
  if (BigInt(a0.available) < 2500000n) throw new Error(`A has ${a0.available} groth; need 0.025 BEAM`);

  log('B: creating a throwaway wallet');
  await B.page.goto(srv.url);
  const { words: wordsB } = await createWallet(B.page, { password: pwB, passkey: false });
  appendFileSync(join(homedir(), '.config', 'campfire-beam', 'test_wallets.env'), `\n# AWAYB: web wallet away-payment live test throwaway (${new Date().toISOString()})\nAWAYB_WALLET_SEED=${wordsB.join(' ')}\n`, { mode: 0o600 });
  log('B: words saved to test_wallets.env as AWAYB_WALLET_SEED (not printed)');
  await waitHome(B.page, { timeout: 20 * 60000 });
  await waitSynced(B.page, 15 * 60000);
  await B.page.click(tid('receive'));
  await waitScreen(B.page, 'receive');
  await B.page.waitForFunction(() => document.querySelector('[data-testid="receive-address"]').textContent.length > 20, null, { timeout: 60000 });
  const addrB = await B.page.textContent(tid('receive-address'));
  await B.page.evaluate(() => window.__campfire.go('home'));
  await A.page.evaluate(() => window.__campfire.go('receive'));
  await A.page.waitForFunction(() => document.querySelector('[data-testid="receive-address"]').textContent.length > 20, null, { timeout: 60000 });
  const addrA = await A.page.textContent(tid('receive-address'));
  await A.page.evaluate(() => window.__campfire.go('home'));
  await A.page.waitForFunction(() => window.__campfire.sync().canSend, null, { timeout: 300000 });

  // ---- Round 1: B suspended (frozen and offline) while A pays it
  log(`ROUND 1: B suspended for ${AWAY_MS / 1000} s while A pays it 0.01 BEAM`);
  const cdp = await ctxB.newCDPSession(B.page);
  await ctxB.setOffline(true);
  await cdp.send('Page.setWebLifecycleState', { state: 'frozen' });
  const before1 = new Set((await txs(A.page)).map((t) => t.txId));
  const v1 = await pay(A.page, 'A', addrB, '0.01', pwA);
  const id1 = (await txs(A.page)).find((t) => !before1.has(t.txId) && !t.income).txId;
  const away1 = await watchAway(A.page, 'A', (t) => t.txId === id1, AWAY_MS);
  await cdp.send('Page.setWebLifecycleState', { state: 'active' });
  await ctxB.setOffline(false);
  log('  B back');
  const r1b = await until(B.page, 'B', pwB, (t) => t.income && String(t.value) === String(v1));
  const r1a = await until(A.page, 'A', pwA, (t) => t.txId === id1);
  results.push({ round: 'B suspended', senderWhileAway: away1, receiverMsAfterBack: r1b.ms, kernel: r1a.tx.kernel, txId: id1 });
  await shot(B.page, 'away-1-B-received');

  // ---- Round 2: B closed while A pays it; opened again and unlocked
  log(`ROUND 2: B closed for ${AWAY_MS / 1000} s while A pays it 0.01 BEAM`);
  await B.page.close();
  const before2 = new Set((await txs(A.page)).map((t) => t.txId));
  await ensureOpen(A.page, 'A', pwA);
  const v2 = await pay(A.page, 'A', addrB, '0.01', pwA);
  const id2 = (await txs(A.page)).find((t) => !before2.has(t.txId) && !t.income).txId;
  const away2 = await watchAway(A.page, 'A', (t) => t.txId === id2, AWAY_MS);
  B = await openB(ctxB);
  log('  B opened and unlocked');
  const r2b = await until(B.page, 'B', pwB, (t) => t.income && String(t.value) === String(v2) && t.txId === id2);
  const r2a = await until(A.page, 'A', pwA, (t) => t.txId === id2);
  results.push({ round: 'B closed', senderWhileAway: away2, receiverMsAfterBack: r2b.ms, kernel: r2a.tx.kernel, txId: id2 });
  await shot(B.page, 'away-2-B-received');

  // ---- Round 3: B pays everything back and is closed at once
  log(`ROUND 3: B pays everything back to A, then is closed for ${AWAY_MS / 1000} s`);
  await ensureOpen(B.page, 'B', pwB);
  await B.page.waitForFunction(() => window.__campfire.sync().canSend && BigInt(window.__campfire.totals()[0].available) >= 1900000n, null, { timeout: 600000, polling: 2000 });
  const before3 = new Set((await txs(B.page)).map((t) => t.txId));
  const v3 = await pay(B.page, 'B', addrA, 'max', pwB);
  const id3 = (await txs(B.page)).find((t) => !before3.has(t.txId) && !t.income).txId;
  await sleep(1500); // a person reads the status screen before switching away
  await B.page.close();
  const away3 = await watchAway(A.page, 'A', (t) => t.txId === id3, AWAY_MS);
  B = await openB(ctxB);
  log('  B opened and unlocked');
  const r3b = await until(B.page, 'B', pwB, (t) => t.txId === id3);
  const r3a = await until(A.page, 'A', pwA, (t) => t.txId === id3);
  results.push({ round: 'sender B closed', receiverWhileAway: away3, senderMsAfterBack: r3b.ms, receiverDoneMs: r3a.ms, value: String(v3), kernel: r3b.tx.kernel, txId: id3 });

  await ensureOpen(A.page, 'A', pwA);
  await ensureOpen(B.page, 'B', pwB);
  const b = await total(B.page, 0);
  log('final B (should be 0):', JSON.stringify(b), 'final A:', JSON.stringify(await total(A.page, 0)));
} catch (e) {
  exit = 1;
  log('LIVE TEST FAILED:', e.message);
  await shot(A.page, 'away-A-failure').catch(() => {});
  if (!B.page.isClosed()) await shot(B.page, 'away-B-failure').catch(() => {});
  const tail = (r) => r.rec.console.slice(-40).map((c) => `[${r.rec.label}] ${c.text.slice(0, 200)}`).join('\n');
  console.log(tail(A));
  if (!B.page.isClosed()) console.log(tail(B));
} finally {
  log('RESULTS', JSON.stringify(results, null, 1));
  log('LOCKS', JSON.stringify(lockEvents));
  for (const [n, p] of [['A', A.page], ['B', B.page]]) {
    if (p.isClosed()) continue;
    log(`${n} node switches`, JSON.stringify(await p.evaluate(() => window.__campfire.nodeSwitches()).catch(() => null)));
  }
  for (const r of [A, B]) console.log(r.rec.console.filter((c) => /\[campfire\]|Abort|RuntimeError/.test(c.text)).map((c) => `[${r.rec.label}] ${c.text.slice(0, 200)}`).join('\n'));
  await browser.close();
  srv.stop();
}
process.exit(exit);

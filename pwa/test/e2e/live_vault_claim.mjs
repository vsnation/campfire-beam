// LIVE MONEY TEST on BEAM mainnet: a payment into BEAM names' vault, built exactly as a payment to a
// name is, then found by the BEAM names inbox and claimed back. Small amounts only.
//
//   npm run e2e:live:vault-claim                              (deposit, then claim)
//   LIVE_VAULT_CLAIM_ONLY=1 npm run e2e:live:vault-claim      (claim a deposit made by an earlier run)
//   (both need the owner's go-ahead: they spend real BEAM)
//
// What it proves (audit D-1): a payment to a name is now built by BEAM's Anon-Vault app shader
// (vault_anon, user send_anon) into the pinned vault for the owner key the wallet checked
// (lib/bans.js pay() -> deposit()), instead of by BANS's own pay. The owner of a name must still
// find and claim it. No test wallet owns a .beam name, so the payment goes to this wallet's OWN
// BEAM names key: a payment to a name is a deposit for its owner's key (the name only rides along,
// encrypted, as its message), the names program derives that key for every wallet (my_key), and
// the inbox scans the vault with it whether the wallet owns a name or not (bans/app.cpp user view
// -> vault_anon OnUser_view_anon). Finding the deposit there with its message decrypted, and
// claiming it with the wallet's own claim (BANS receive_all at privilege 1), is what a name's owner
// does.
//
// Steps, as test wallet FUNDER2, restored through the real Restore screen:
//   1. The names inbox must be readable and empty (a claim takes everything waiting).
//   2. 0.05 BEAM to this wallet's own names key, message "campfire-vault-test", through
//      lib/bans.js deposit() - the code pay() runs once a name's owner is known - and the real
//      approve sheet. The build must be the Anon-Vault app (15,969-byte shader) with
//      cid = the pinned vault and pkOwner = this wallet's names key.
//   3. Once confirmed: the inbox lists exactly that deposit (its one-time key), 0.05 BEAM, sent to
//      campfire-vault-test; BEAM names shows it waiting.
//   4. Claim it from BEAM names through the real approve sheet.
// At each step BEAM must move by exactly what the sheets said: -(0.05 + 0.011), then +(0.05 - 0.011).
//
// Claim only (LIVE_VAULT_CLAIM_ONLY=1): steps 3 and 4 for a deposit already on chain. The inbox
// must hold exactly that deposit - its one-time key (LIVE_VAULT_ONE_TIME_KEY, default the one the
// run of 2026-10-12 made, block 4,077,092), 0.05 BEAM, message campfire-vault-test - and nothing
// else, or the test stops before spending anything.
//
// Hard limits (any sheet outside them is cancelled and the test stops):
//   - deposit: pays exactly 0.05 BEAM, receives nothing, to campfire-vault-test.beam; fee exactly 0.011 BEAM;
//   - claim: receives exactly 0.05 BEAM, pays nothing; fee exactly 0.011 BEAM.
// Spends at most 0.061 BEAM (claim only: at most the 0.011 claim fee, taken from the 0.05 claimed).
// If it stops after the deposit, 0.05 BEAM waits in the vault for FUNDER2's names key: run it again
// with LIVE_VAULT_CLAIM_ONLY=1 (or BEAM names → Claim, here or in BEAM's desktop wallet).
//
// Every wait follows its own transaction by id, and keeps the app in use: Beam PWA locks after
// 5 minutes without a tap, and once the payment it kept going behind the lock is done it stops the
// engine and forgets the list this test reads (what made the first run's deposit look unfinished).
// If the lock screen shows anyway, the test unlocks with its password, as a person would.
import { startServer, launch, recordedPage, shot, waitScreen, sleep, foreignHosts } from './harness.mjs';
import { waitHome, waitSynced, unlockWithPassword } from './flows.mjs';
import { tid, log, funderWords, restoreFunder, total } from './live_common.mjs';

const PORT = Number(process.env.LIVE_PORT || 8824);
const CLAIM_ONLY = process.env.LIVE_VAULT_CLAIM_ONLY === '1';
const KNOWN_DEPOSIT = (process.env.LIVE_VAULT_ONE_TIME_KEY || 'c007d37858411c5258f5adef61025cb306d77540605a69a140628a3abaad8fef00').toLowerCase();
const VAULT = 'a3385e50cf33afc9f769ee1d82d56b73046d680d343977f36d9a303d7bcdc4da';
const MESSAGE_NAME = 'campfire-vault-test';
const AMOUNT = 5000000n; // 0.05 BEAM
const DEPOSIT_FEE = 1100000n; // 0.011 BEAM
const CLAIM_FEE = 1100000n; // 0.011 BEAM
const VAULT_SHADER_SIZE = 15969;
const password = `live-v-${Math.random().toString(36).slice(2, 10)}`;
const groth = (text) => {
  const m = /^\s*([0-9][0-9,]*)(?:\.([0-9]{1,8}))?\b/.exec(String(text));
  if (!m) throw new Error(`not an amount: ${text}`);
  return BigInt(m[1].replace(/,/g, '')) * 100000000n + BigInt((m[2] || '').padEnd(8, '0'));
};
if (!/^[0-9a-f]{64}0[01]$/.test(KNOWN_DEPOSIT)) throw new Error('LIVE_VAULT_ONE_TIME_KEY is not a 33-byte key');

const extra = process.env.BEAM_RECOVERY_FILE ? ['--recovery-file', process.env.BEAM_RECOVERY_FILE] : [];
const srv = await startServer({ port: PORT, extra });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, locale: 'en-GB' });
const { page, rec } = await recordedPage(ctx, { label: 'V' });

/** Reads the open approve sheet. */
async function readSheet() {
  await page.waitForSelector(tid('consent'), { timeout: 180000 });
  const text = async (id) => ((await page.$(tid(id))) ? (await page.textContent(tid(id))).trim() : null);
  return {
    title: (await page.textContent('.consent h2')).trim(),
    app: await text('consent-app'),
    pay: await text('consent-pay-0'),
    pay2: await text('consent-pay-1'),
    get: await text('consent-get-0'),
    get2: await text('consent-get-1'),
    to: await text('consent-to'),
    fee: await text('consent-fee'),
    notEnough: await text('consent-not-enough'),
    button: await text('consent-approve'),
  };
}

/** Approves the sheet only if `problem(sheet)` finds nothing; otherwise cancels it and stops. */
async function approveIf(label, problem) {
  const sheet = await readSheet();
  log(`${label} sheet:`, JSON.stringify(sheet));
  await shot(page, `live-vc-${label}-sheet`);
  const why = !/Beam PWA/.test(sheet.app || '') ? 'the sheet does not name this wallet' : sheet.notEnough ? `the wallet says: ${sheet.notEnough}` : !sheet.button ? 'no approve button' : problem(sheet);
  if (why) {
    await page.click(tid('consent-cancel')).catch(() => {});
    throw new Error(`refusing the ${label} sheet: ${why}`);
  }
  await page.click(tid('consent-approve'));
  await page.waitForSelector(tid('auth-pw'), { timeout: 20000 });
  await page.fill(tid('auth-pw'), password);
  await page.click(tid('auth-submit'));
  return sheet;
}

/**
 * The app in use, as a person keeps it while a payment goes through: a tap's worth of activity
 * (the auto-lock counts pointer and key events), and, should it be locked anyway, the password.
 */
async function stayOpen() {
  const screen = await page.evaluate(() => {
    window.dispatchEvent(new PointerEvent('pointerdown'));
    return window.__campfire.screen();
  });
  if (screen !== 'unlock') return;
  log('the app locked; unlocking with the password');
  await unlockWithPassword(page, password);
  await waitHome(page, { timeout: 10 * 60000 });
  await waitSynced(page, 15 * 60000);
}

/** Waits for transaction `txId` to complete (status 3), saying where it is every minute. */
async function waitTxId(txId, label, timeoutMs = 25 * 60000) {
  const t0 = Date.now();
  let said = 0;
  while (Date.now() - t0 < timeoutMs) {
    await stayOpen();
    const now = await page.evaluate((id) => {
      const t = window.__campfire.txs().find((x) => x.txId === id);
      return { status: t ? Number(t.status) : null, kernel: t ? t.kernel : null, height: window.__campfire.height(), sync: window.__campfire.sync().state, screen: window.__campfire.screen() };
    }, txId);
    if (now.status === 3) return now;
    if (now.status === 2 || now.status === 4) throw new Error(`${label}: status ${now.status}`);
    if (Date.now() - said > 60000) {
      log(`${label} ${txId}: ${JSON.stringify(now)}`);
      said = Date.now();
    }
    await sleep(5000);
  }
  throw new Error(`${label}: not completed in time`);
}

/** BEAM available, once it equals `want` (a confirmed transaction's change can take a moment); throws if it never does. */
async function waitBeam(want, label, timeoutMs = 5 * 60000) {
  const t0 = Date.now();
  let now = null;
  while (Date.now() - t0 < timeoutMs) {
    await stayOpen();
    now = BigInt((await total(page, 0)).available);
    if (now === want) return now;
    await sleep(5000);
  }
  throw new Error(`${label}: BEAM available is ${now} groth, the sheets say it should be ${want}`);
}

/** The names inbox, read now through the wallet's own path (lib/bans.js inbox(), what BEAM names shows). */
const readInbox = () =>
  page.evaluate(async () => {
    const { bans } = await import('./screens/names.js');
    try {
      const ib = await bans().inbox();
      return {
        payments: ib.payments.map((p) => ({ oneTimeKey: p.oneTimeKey, assetId: p.assetId, amount: String(p.amount), name: p.name })),
        saleProceeds: ib.saleProceeds.map((p) => ({ assetId: p.assetId, amount: String(p.amount) })),
      };
    } catch (e) {
      return { error: `${e && e.code}: ${e && e.message}` };
    }
  });

/** True when the inbox holds exactly the deposit `oneTimeKey` (0.05 BEAM, message campfire-vault-test) and nothing else. */
function onlyThatDeposit(ib, oneTimeKey) {
  if (ib.error || ib.saleProceeds.length || ib.payments.length !== 1) return false;
  const p = ib.payments[0];
  return p.oneTimeKey === oneTimeKey && p.assetId === 0 && p.amount === String(AMOUNT) && p.name === MESSAGE_NAME;
}

/** The deposit through deposit() and the real approve sheet; resolves its one-time key once it is confirmed. */
async function depositStep(beam0) {
  const before = await readInbox();
  log('names inbox before:', JSON.stringify(before));
  if (before.error) throw new Error(`refusing: the names inbox could not be read (${before.error})`);
  if (before.payments.length || before.saleProceeds.length) throw new Error("refusing: payments already wait for this wallet's names; claim them first (LIVE_VAULT_CLAIM_ONLY=1 for this test's own deposit)");
  const need = AMOUNT + DEPOSIT_FEE + 1000000n;
  if (beam0 < need) throw new Error(`FUNDER2 has ${beam0} groth available; this test needs at least ${need}`);

  // The build is recorded (arguments, shader size, one-time key) and then goes on unchanged.
  const key = await page.evaluate(async () => {
    const { nativeApp } = await import('./lib/contracts.js');
    const { readContractTx, ArgsReader } = await import('./lib/contract_tx.js');
    const app = await nativeApp();
    const real = app.transact.bind(app);
    app.transact = (args, shader, opts) => {
      window.__build = { args: String(args), shaderBytes: shader.length };
      return real(args, shader, {
        ...opts,
        inspect: async (raw, output) => {
          const e = readContractTx(raw).entries[0];
          if (e) {
            const r = new ArgsReader(e.args);
            r.u64();
            r.u32();
            window.__build.oneTimeKey = r.pubKey();
          }
          return opts.inspect(raw, output);
        },
      });
    };
    const { bans } = await import('./screens/names.js');
    return bans().myKey();
  });
  log(`this wallet's names key: ${key.slice(0, 8)}…${key.slice(-10)}`);
  await page.evaluate(
    async ([k, name, amount]) => {
      const { bans } = await import('./screens/names.js');
      window.__deposit = null;
      bans()
        .deposit(k, name, 0, BigInt(amount))
        .then(
          (r) => (window.__deposit = { ok: true, txId: r.txId, fee: String(r.fee) }),
          (e) => (window.__deposit = { ok: false, code: e && e.code, message: e && e.message }),
        );
    },
    [key, MESSAGE_NAME, String(AMOUNT)],
  );
  await page.waitForSelector(tid('consent'), { timeout: 180000 });
  const build = await page.evaluate(() => window.__build);
  log('built:', JSON.stringify(build));
  const wantArgs = `role=user,action=send_anon,cid=${VAULT},pkOwner=${key},aid=0,amount=${AMOUNT}`;
  if (!build || build.shaderBytes !== VAULT_SHADER_SIZE || !build.args.startsWith(`${wantArgs},msg=`)) {
    await page.click(tid('consent-cancel')).catch(() => {});
    throw new Error("refusing: the deposit was not built by the Anon-Vault app for this wallet's names key");
  }
  const sheet = await approveIf('deposit', (s) => {
    if (s.title !== 'Approve this payment') return `its title is ${s.title}`;
    if (s.pay2 || s.get || s.get2) return 'it moves more than one amount';
    if (s.pay !== '0.05 BEAM') return `it pays ${s.pay}`;
    if (s.to !== `${MESSAGE_NAME}.beam`) return `it pays to ${s.to}`;
    if (groth(s.fee) !== DEPOSIT_FEE) return `it charges ${s.fee}`;
    if (s.button !== `Send 0.05 BEAM to ${MESSAGE_NAME}.beam`) return `the button says ${s.button}`;
    return null;
  });
  await page.waitForFunction(() => window.__deposit, null, { timeout: 120000 });
  const deposit = await page.evaluate(() => window.__deposit);
  log('deposit:', JSON.stringify(deposit));
  if (!deposit.ok) throw new Error(`the deposit was not sent: ${deposit.code} ${deposit.message}`);
  log(`one-time key of the deposit (LIVE_VAULT_ONE_TIME_KEY for a claim-only run): ${build.oneTimeKey}`);
  const done = await waitTxId(deposit.txId, 'deposit');
  log('deposit confirmed:', JSON.stringify({ txId: deposit.txId, kernel: done.kernel, height: done.height }));
  const beam1 = await waitBeam(beam0 - groth(sheet.pay) - groth(sheet.fee), 'after the deposit');
  log('after the deposit: BEAM available', String(beam1));
  return { oneTimeKey: build.oneTimeKey, beam1, sheet };
}

/** Finds exactly the deposit `oneTimeKey` in the inbox and on BEAM names, claims it, and checks the balance. */
async function claimStep(oneTimeKey, beamBefore, { waitMs }) {
  // Read at least once; after a deposit, until it shows (the vault is read at the node's newest block).
  const t0 = Date.now();
  let ib = null;
  for (;;) {
    await stayOpen();
    ib = await readInbox();
    if ((!ib.error && ib.payments.some((p) => p.oneTimeKey === oneTimeKey)) || Date.now() - t0 >= waitMs) break;
    await sleep(20000);
  }
  log('inbox:', JSON.stringify(ib));
  if (!ib || ib.error) throw new Error(`refusing: the names inbox could not be read (${ib && ib.error})`);
  if (!onlyThatDeposit(ib, oneTimeKey)) throw new Error(`refusing: the inbox does not hold exactly the deposit ${oneTimeKey.slice(0, 8)}… (0.05 BEAM, message ${MESSAGE_NAME}) and nothing else`);

  await page.evaluate(() => window.__campfire.go('names'));
  await waitScreen(page, 'names');
  await page.waitForSelector(tid('names-money'), { timeout: 180000 });
  const title = (await page.textContent(tid('names-money-title'))).trim();
  log('BEAM names says:', title);
  if (title !== 'People paid your names: 0.05 BEAM is waiting') throw new Error(`refusing: BEAM names says "${title}"`);
  await shot(page, 'live-vc-02-waiting');
  if ((await page.textContent(tid('names-claim'))).trim() !== 'Claim 0.05 BEAM') throw new Error(`refusing: the button says ${await page.textContent(tid('names-claim'))}`);

  // The claim's transaction id, from the wallet's own privileged app (BEAM names' claims), recorded on its way out.
  await page.evaluate(async () => {
    const { privilegedApp } = await import('./lib/contracts.js');
    const app = await privilegedApp();
    const real = app.transact.bind(app);
    window.__claimTx = null;
    app.transact = async (...a) => {
      const id = await real(...a);
      window.__claimTx = id;
      return id;
    };
  });
  await page.click(tid('names-claim'));
  const sheet = await approveIf('claim', (s) => {
    if (s.pay || s.pay2 || s.get2) return 'it moves something other than the deposit';
    if (s.get !== '0.05 BEAM') return `it gives ${s.get}`;
    if (groth(s.fee) !== CLAIM_FEE) return `it charges ${s.fee}`;
    if (s.button !== 'Claim 0.05 BEAM') return `the button says ${s.button}`;
    return null;
  });
  await page.waitForSelector(`${tid('names-claim-msg')}[data-code="sent"]`, { timeout: 120000 });
  await shot(page, 'live-vc-03-claim-sent');
  const claimTx = await page.evaluate(() => window.__claimTx);
  if (!claimTx) throw new Error('the claim was sent, but its transaction id was not seen');
  const done = await waitTxId(claimTx, 'claim');
  log('claim confirmed:', JSON.stringify({ txId: claimTx, kernel: done.kernel, height: done.height }));
  const beamAfter = await waitBeam(beamBefore + groth(sheet.get) - groth(sheet.fee), 'after the claim');
  return { beamAfter, sheet };
}

let exit = 0;
try {
  log(`restoring FUNDER2 through the Restore screen + recovery snapshot${CLAIM_ONLY ? ' (claim only)' : ''}`);
  // A person watching the screen: a tap's worth of activity every minute, on every page load, so the
  // 5-minute auto-lock never stops the engine mid-test (stayOpen() unlocks should it happen anyway).
  await page.addInitScript(() => setInterval(() => window.dispatchEvent(new PointerEvent('pointerdown')), 60000));
  await page.goto(srv.url);
  await restoreFunder(page, funderWords(), password, 'live-vc');
  await waitHome(page, { timeout: 20 * 60000 });
  await waitSynced(page, 15 * 60000);
  await page.waitForFunction(() => window.__campfire.sync().canSend, null, { timeout: 300000 });
  await sleep(8000);
  await stayOpen();
  const beam0 = BigInt((await total(page, 0)).available);
  log('before: BEAM available', String(beam0));

  if (CLAIM_ONLY) {
    // Nothing is spent unless the inbox holds exactly the earlier run's deposit.
    const { beamAfter, sheet } = await claimStep(KNOWN_DEPOSIT, beam0, { waitMs: 0 });
    const gained = beamAfter - beam0;
    const want = groth(sheet.get) - groth(sheet.fee);
    log(`after: BEAM available ${beamAfter}; in ${gained} groth; the claim sheet said ${want}`);
    if (gained !== want) throw new Error('BEAM did not move by exactly what the claim sheet said');
  } else {
    const dep = await depositStep(beam0);
    const { beamAfter, sheet } = await claimStep(dep.oneTimeKey, dep.beam1, { waitMs: 20 * 60000 });
    const moved = beam0 - beamAfter;
    const want = groth(dep.sheet.pay) + groth(dep.sheet.fee) - groth(sheet.get) + groth(sheet.fee);
    log(`after: BEAM available ${beamAfter}; out ${moved} groth; the sheets said ${want}`);
    if (moved !== want) throw new Error('BEAM did not move by exactly what the sheets said');
  }
  const after = await readInbox();
  log('names inbox after:', JSON.stringify(after));
  await page.evaluate(() => window.__campfire.go('activity'));
  await sleep(1500);
  await shot(page, 'live-vc-04-activity');
  log('foreign hosts', JSON.stringify(foreignHosts(rec, srv.url)));
  log('LIVE VAULT CLAIM PASSED');
} catch (e) {
  exit = 1;
  log('LIVE VAULT CLAIM FAILED:', e.message);
  await shot(page, 'live-vc-failure').catch(() => {});
} finally {
  await browser.close();
  srv.stop();
}
process.exit(exit);

// Settings -> Backup -> "Move names, notes and history" (issue #55), on mainnet, no money moves.
//   1. A new wallet A gets a named address, a contact (brought in through the card, from a file
//      that has only a contact), a hidden token and a payment that fails (no coins) with a note.
//      "Save wallet data" asks who it is, then hands out BEAM's wallet data file (export<s>.dat).
//   2. BEAM's native CLI, restored from the same 12 words, imports that file (exit 0) and exports
//      it again with everything in it; it then names a new address and exports its own file.
//   3. The same 12 words restored in a fresh browser: a garbage file is refused, a file of other
//      12 words adds nothing and says so, A's file brings the names, the contact, the note and
//      the payment, a second time adds nothing (and BEAM itself does not duplicate either), and
//      the CLI's file brings the CLI's new name.
// Wallet passwords and seeds stay in memory and 0600 config files; nothing prints them, no
// screenshot shows them.
//   BEAM_WASM_OUT=… npm run e2e:wallet-data   (own build and port 8961)
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { startServer, launch, recordedPage, waitScreen, shot, sleep, PWA } from './harness.mjs';
import { createWallet, waitHome } from './flows.mjs';
import { BEAM_CLI, cliVersion, WANT_CORE } from './walletdb.mjs';

const PORT = 8961;
const tid = (id) => `[data-testid="${id}"]`;
const PASSWORD = `wd-${randomBytes(6).toString('hex')}`;
const NOTE = 'Dinner, Friday';
const LABEL = 'Rent from Ana';
const CLI_LABEL = 'Made in the CLI';
const HIDDEN = 190;

let tmp, srv, browser;
let words = null; // the throwaway's 12 words, in memory only
const s = {}; // files and facts handed from test to test

// ---------------------------------------------------------------- BEAM's native CLI
function cli(dir, args, cfgLines) {
  const cfg = join(dir, `.${randomBytes(6).toString('hex')}.cfg`);
  writeFileSync(cfg, `${cfgLines.join('\n')}\n`, { mode: 0o600 });
  try {
    return spawnSync(BEAM_CLI, [...args, `--wallet_path=${join(dir, 'wallet.db')}`, `--config_file=${cfg}`, '--log_level=info', '--file_log_level=error'], { cwd: dir, encoding: 'utf8', timeout: 120000 });
  } finally {
    rmSync(cfg, { force: true });
  }
}
/** export_data: BEAM appends a timestamp to the name (TimestampFile); the newest such file. */
function cliExport(dir, pass, stem) {
  const r = cli(dir, ['export_data', `--file_location=${join(dir, `${stem}.dat`)}`], [`pass=${pass}`]);
  assert.equal(r.status, 0, `export_data exit ${r.status}`);
  const f = readdirSync(dir).filter((n) => n.startsWith(stem) && n.endsWith('.dat')).sort().pop();
  assert.ok(f, 'export_data wrote its file');
  return join(dir, f);
}
const labels = (j) => j.OwnAddresses.map((a) => a.Label);
const hex = (b) => b.map((x) => x.toString(16).padStart(2, '0')).join('');

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-data-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await launch();
  assert.equal(cliVersion(join(tmp, 'v')), WANT_CORE, `BEAM's ${WANT_CORE} CLI at ${BEAM_CLI}`);
  // Wallet D: other 12 words (made by the CLI, never shown). Its file is "another wallet's".
  const d = join(tmp, 'cli-d');
  mkdirSync(d);
  s.passD = `d-${randomBytes(9).toString('hex')}`;
  const init = cli(d, ['init'], [`pass=${s.passD}`]);
  assert.ok(init.status === 0 && /wallet successfully created/i.test(`${init.stdout}${init.stderr}`), 'beam-wallet init (output withheld: it holds a seed phrase)');
  s.fileD = cliExport(d, s.passD, 'other');
  const jd = JSON.parse(readFileSync(s.fileD, 'utf8'));
  assert.equal(jd.OwnAddresses.length, 1);
  s.peer = jd.OwnAddresses[0].Address; // D's address: the failed payment goes "to" it, and it is A's contact
  // A file that holds only a contact (D's address, named Ana), BEAM's shape.
  s.contactFile = join(tmp, 'contact.dat');
  writeFileSync(s.contactFile, JSON.stringify({ Contacts: [{ ...jd.OwnAddresses[0], Index: 0, Label: 'Ana' }] }));
  s.garbage = join(tmp, 'garbage.dat');
  writeFileSync(s.garbage, 'hello, these are not wallet data\n');
});

test.after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  words = null;
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

const openCard = async (page) => {
  await page.evaluate(() => window.__campfire.go('backup'));
  await waitScreen(page, 'backup');
  await page.locator(tid('data-card')).scrollIntoViewIfNeeded();
};
const pick = async (page, file) => {
  await page.setInputFiles(tid('data-file'), file);
};
const both = async (page, name) => {
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(250);
    await shot(page, `${name}-${scheme}`);
  }
  await page.emulateMedia({ colorScheme: 'light' });
};
/** The wallet as the engine has it: own addresses' names, contacts, payments (id, status, note). */
const snapshot = (page) =>
  page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const s = wallet.session;
    const own = await s.call('addr_list', { own: true });
    const others = await s.call('addr_list', { own: false });
    const txs = await s.call('tx_list', {});
    return { own: own.map((a) => a.comment), ownIds: own.map((a) => a.wallet_id), others: others.map((a) => a.comment), txs: txs.map((t) => ({ txId: t.txId, status: t.status, comment: t.comment })) };
  });

test('A: a named address, a contact brought in, a hidden token and a failed payment with a note go into the file', { timeout: 10 * 60000 }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, acceptDownloads: true });
  const { page, rec } = await recordedPage(ctx, { label: 'data-a' });
  await page.goto(srv.url);
  ({ words } = await createWallet(page, { password: PASSWORD }));
  await waitHome(page, { timeout: 5 * 60000 });

  // The card on Backup, light and dark.
  await openCard(page);
  const card = await page.textContent(tid('data-card'));
  assert.match(card, /^Move names, notes and history/);
  assert.match(card, /12 words bring back your coins, not/);
  assert.match(await page.textContent(tid('data-reveals')), /anyone who gets it.*no keys: nobody can spend/);
  await both(page, 'data-01-card');

  // A contact through the card itself: a file with only a contact (BEAM's own shape).
  await pick(page, s.contactFile);
  await page.waitForSelector(tid('data-bring'), { timeout: 60000 });
  assert.deepEqual(await page.$$eval(`${tid('data-summary')} .kv`, (els) => els.map((e) => e.textContent)), ['Contacts1', 'Payments0']);
  assert.match(await page.textContent(tid('data-new')), /New here: 1 contact\. Nothing already in this wallet is changed\./);
  await page.click(tid('data-bring'));
  await page.waitForSelector(tid('data-result'), { timeout: 60000 });
  assert.match(await page.textContent(tid('data-result')), /Added 1 contact\./);
  await page.click(tid('data-done'));

  // The rest through the wallet, as a person would make it: a named address, a hidden token, a payment.
  const made = await page.evaluate(
    async ({ label, note, peer, hidden }) => {
      const { wallet } = await import('./lib/wallet.js');
      const { app } = await import('./app.js');
      const { setTokenHidden } = await import('./lib/hidden_tokens.js');
      const { loadContacts } = await import('./lib/contacts.js');
      const s = wallet.session;
      await s.call('create_address', { type: 'regular', expiration: 'never', comment: label });
      await setTokenHidden(app, hidden, true);
      const { txId } = await s.call('tx_send', { address: peer, value: 100000000, fee: 100000, comment: note });
      let st = null;
      for (let i = 0; i < 60 && st !== 4; i++) {
        await new Promise((r) => setTimeout(r, 500));
        st = (await s.call('tx_status', { txId })).status;
      }
      return { txId, status: st, book: (await loadContacts(app)).map((c) => c.name) };
    },
    { label: LABEL, note: NOTE, peer: s.peer, hidden: HIDDEN },
  );
  assert.equal(made.status, 4, 'the payment failed (no coins): a record with a note, nothing moved');
  assert.deepEqual(made.book, ['Ana'], 'the contact from the file is in the address book');
  s.txId = made.txId;
  s.before = await snapshot(page);
  assert.ok(s.before.own.includes(LABEL));
  // BEAM keeps the address it paid in its own list, named after the payment's note (wallet.cpp,
  // SavePeerAddress): the contact 'Ana' brought in a moment ago is now called by the note there.
  assert.deepEqual(s.before.others, [NOTE], 'BEAM’s own list: the payee, named after the note');

  // Save wallet data: who is it (the warning first), then the file.
  await openCard(page);
  await page.click(tid('data-save'));
  await page.waitForSelector(tid('auth-pw'));
  assert.match(await page.textContent('.sheet'), /anyone who gets it/);
  await shot(page, 'data-02-confirm');
  await page.fill(tid('auth-pw'), `${PASSWORD}-no`);
  await page.click(tid('auth-submit'));
  await page.waitForSelector('.sheet .notice.error');
  await page.fill(tid('auth-pw'), PASSWORD);
  await page.click(tid('auth-submit'));
  await page.waitForSelector(tid('data-save-file'), { timeout: 120000 });
  assert.match(await page.textContent(tid('data-name')), /^export\d{10}\.dat$/);
  const nOwn = s.before.own.length; // the engine's default address and this app's, and the named one
  assert.ok(nOwn >= 2);
  assert.match(await page.textContent(tid('data-what')), new RegExp(`${nOwn} addresses, 1 contact, 1 payment and 1 hidden token`));
  await both(page, 'data-03-ready');
  const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 30000 }), page.click(tid('data-save-file'))]);
  s.fileA = join(tmp, 'a.dat');
  await dl.saveAs(s.fileA);
  assert.match(dl.suggestedFilename(), /^export\d{10}\.dat$/);
  await page.waitForSelector('.toast');
  assert.match(await page.textContent('.toast'), /Wallet data saved to your downloads/);

  const j = JSON.parse(readFileSync(s.fileA, 'utf8'));
  assert.deepEqual(Object.keys(j), ['Contacts', 'OwnAddresses', 'TransactionParameters', 'BeamCampfire'], 'BEAM’s three lists, then Beam PWA’s part');
  assert.ok(labels(j).includes(LABEL));
  assert.deepEqual(j.Contacts.map((c) => c.Label), [NOTE]);
  const mine = j.TransactionParameters.filter((p) => hex(p.TransactionId) === s.txId);
  assert.ok(mine.length > 5, 'the payment with its parameters');
  // BEAM writes this failed payment with its address's key index but not the address, and BEAM's own
  // reader refuses that: the file carries it without the index (lib/wallet_data.js groupTxs).
  const raw = JSON.parse(await page.evaluate(async () => (await import('./lib/wallet.js')).wallet.session.exportData()));
  assert.ok(raw.TransactionParameters.some((p) => hex(p.TransactionId) === s.txId && p.ParameterId === 158), 'BEAM’s own export has the index');
  assert.ok(!raw.TransactionParameters.some((p) => hex(p.TransactionId) === s.txId && p.ParameterId === 6), 'and not the address');
  assert.ok(!mine.some((p) => p.ParameterId === 158), 'the file does not');
  assert.equal(mine.length, raw.TransactionParameters.filter((p) => hex(p.TransactionId) === s.txId).length - 1, 'nothing else differs');
  assert.equal(Buffer.from(mine.find((p) => p.ParameterId === 5 && p.SubTransactionId === 1).Value).toString('utf8'), NOTE);
  assert.deepEqual(j.BeamCampfire, { v: 1, contacts: [{ name: 'Ana', address: s.peer }], hiddenTokens: [HIDDEN] });
  assert.deepEqual(rec.errors, []);
  await ctx.close();
});

test('BEAM’s CLI, same 12 words: imports the web wallet’s file and exports it again; its own file goes the other way', { timeout: 5 * 60000 }, async () => {
  assert.ok(s.fileA && words, 'the first test saved the file');
  const c = join(tmp, 'cli-s');
  mkdirSync(c);
  s.passC = `c-${randomBytes(9).toString('hex')}`;
  const restore = cli(c, ['restore'], [`pass=${s.passC}`, `seed_phrase=${words.join(';')}`]);
  assert.equal(restore.status, 0, `beam-wallet restore exit ${restore.status} (output withheld)`);
  const imp = cli(c, ['import_data', `--file_location=${s.fileA}`], [`pass=${s.passC}`]);
  assert.equal(imp.status, 0, 'BEAM’s CLI takes the web wallet’s file (its BeamCampfire part ignored)');
  const back = JSON.parse(readFileSync(cliExport(c, s.passC, 'back'), 'utf8'));
  assert.ok(labels(back).includes(LABEL), 'the name is in the CLI wallet');
  assert.deepEqual(back.Contacts.map((x) => x.Label), [NOTE]);
  assert.ok(back.TransactionParameters.some((p) => hex(p.TransactionId) === s.txId && p.ParameterId === 5 && Buffer.from(p.Value).toString('utf8') === NOTE), 'the payment and its note are in the CLI wallet');
  assert.equal(back.BeamCampfire, undefined, 'BEAM keeps only its own lists');
  const na = cli(c, ['new_addr', `--comment=${CLI_LABEL}`, '--expiration_time=never'], [`pass=${s.passC}`]);
  assert.equal(na.status, 0);
  s.fileCli = cliExport(c, s.passC, 'cli');
  assert.ok(labels(JSON.parse(readFileSync(s.fileCli, 'utf8'))).includes(CLI_LABEL));
});

test('B: the same 12 words in a fresh browser: garbage and another wallet’s file add nothing; A’s file and the CLI’s bring everything, once', { timeout: 15 * 60000 }, async () => {
  assert.ok(s.fileA && s.fileCli && words);
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  const { page, rec } = await recordedPage(ctx, { label: 'data-b' });
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 60000);
  await page.click(tid('restore'));
  await waitScreen(page, 'restore');
  await page.fill(tid('word-1'), words.join(' '));
  await page.waitForFunction(() => !document.querySelector('[data-testid="restore-submit"]').disabled, null, { timeout: 30000 });
  await page.click(tid('restore-submit'));
  await waitScreen(page, 'setPassword');
  await page.fill(tid('pw1'), PASSWORD);
  await page.fill(tid('pw2'), PASSWORD);
  await page.click(tid('save-password'));
  await page.waitForFunction(() => ['passkeySetup', 'fastStart'].includes(window.__campfire.screen()), null, { timeout: 30000 });
  if ((await page.evaluate(() => window.__campfire.screen())) === 'passkeySetup') await page.click(tid('passkey-skip'));
  await waitScreen(page, 'fastStart');
  await page.click(tid('fast-skip'));
  await waitHome(page, { timeout: 5 * 60000 });
  await page.waitForFunction(() => window.__campfire.running(), null, { timeout: 60000 });
  const fresh = await snapshot(page);
  assert.ok(!fresh.own.includes(LABEL), 'the 12 words alone do not bring the names back');
  assert.ok(!fresh.txs.some((t) => t.txId === s.txId), 'nor the payment');

  // Garbage.
  await openCard(page);
  await pick(page, s.garbage);
  await page.waitForSelector(tid('data-problem'), { timeout: 30000 });
  assert.match(await page.textContent(tid('data-problem')), /isn’t a BEAM wallet data file/);
  await both(page, 'data-04-garbage');
  await page.click(tid('data-close'));

  // Another wallet's file (other 12 words): BEAM refuses its addresses, so nothing comes in.
  await pick(page, s.fileD);
  await page.waitForSelector(tid('data-bring'), { timeout: 60000 });
  await page.click(tid('data-bring'));
  await page.waitForSelector(tid('data-other-wallet'), { timeout: 60000 });
  assert.match(await page.textContent(tid('data-other-wallet')), /Nothing was added.*different 12 words/);
  await both(page, 'data-05-other-wallet');
  await page.click(tid('data-close'));
  assert.deepEqual(await snapshot(page), fresh, 'nothing changed');

  // A's file: what it holds first, then everything comes in.
  await pick(page, s.fileA);
  await page.waitForSelector(tid('data-bring'), { timeout: 60000 });
  const rows = await page.$$eval(`${tid('data-summary')} .kv`, (els) => els.map((e) => e.textContent));
  const nOwn = s.before.own.length;
  assert.deepEqual(rows, [`Your addresses${nOwn} · 1 with a name`, 'Contacts1', 'Payments1 · 1 with a note', 'Hidden tokens1']);
  assert.match(await page.textContent(tid('data-new')), new RegExp(`^New here: ${nOwn} addresses, 1 contact, 1 payment and 1 hidden token\\.`));
  await both(page, 'data-06-preview');
  await page.click(tid('data-bring'));
  await page.waitForSelector(tid('data-result'), { timeout: 120000 });
  assert.match(await page.textContent(tid('data-result')), new RegExp(`Added ${nOwn} addresses, 1 contact, 1 payment and 1 hidden token\\. Nothing already in this wallet is changed\\.`));
  assert.equal(await page.isVisible(tid('data-refused')), false);
  await both(page, 'data-07-done');
  const after = await snapshot(page);
  assert.ok(after.own.includes(LABEL), 'the name came in');
  assert.deepEqual(after.others, [NOTE], 'BEAM’s own list came in too');
  const t = after.txs.find((x) => x.txId === s.txId);
  assert.ok(t, 'the payment came in');
  assert.equal(t.comment, NOTE);
  assert.equal(t.status, 4);
  const extras = await page.evaluate(async () => {
    const { app } = await import('./app.js');
    const { loadContacts } = await import('./lib/contacts.js');
    const { loadHidden } = await import('./lib/hidden_tokens.js');
    return { book: (await loadContacts(app)).map((c) => c.name), hidden: [...(await loadHidden(app))] };
  });
  assert.deepEqual(extras, { book: ['Ana'], hidden: [HIDDEN] });

  // The payment and its note in Activity.
  await page.click(tid('data-see-activity'));
  await waitScreen(page, 'activity');
  await page.waitForSelector(tid('activity-list'), { timeout: 30000 });
  const row = page.locator(`[data-txid="${s.txId}"]`);
  assert.match(await row.textContent(), /Ana · Dinner, Friday/, 'the row names the contact and the note');
  await row.click();
  await page.waitForSelector(tid('tx-detail-title'));
  assert.match(await page.textContent(tid('tx-note')), /Note\s*Dinner, Friday/);
  await both(page, 'data-08-activity-note');
  await page.keyboard.press('Escape').catch(() => {});
  await page.evaluate(() => document.querySelectorAll('.overlay').forEach((o) => o.dispatchEvent(new Event('campfire:dismiss'))));

  // The same file again: nothing new, nothing doubled. BEAM itself does not double either.
  await openCard(page);
  await pick(page, s.fileA);
  await page.waitForSelector(tid('data-all-here'), { timeout: 60000 });
  assert.match(await page.textContent(tid('data-all-here')), /Everything in this file is already in this wallet/);
  await shot(page, 'data-09-all-here');
  await page.click(tid('data-done'));
  const raw = await page.evaluate(async (text) => {
    const { wallet } = await import('./lib/wallet.js');
    return [await wallet.session.importData(text), await wallet.session.importData(text)];
  }, readFileSync(s.fileA, 'utf8'));
  assert.deepEqual(raw, [true, true]);
  const twice = await snapshot(page);
  assert.equal(twice.own.length, after.own.length);
  assert.equal(twice.others.length, after.others.length);
  assert.equal(twice.txs.length, after.txs.length);

  // BEAM's CLI's own file: its new name comes in, the rest is already here.
  await pick(page, s.fileCli);
  await page.waitForSelector(tid('data-bring'), { timeout: 60000 });
  // New: the CLI's named address and the default address its restore made (a key index of its own).
  const cliNew = JSON.parse(readFileSync(s.fileCli, 'utf8')).OwnAddresses.filter((a) => !twice.ownIds.includes(a.WalletID));
  assert.equal(cliNew.length, 2);
  assert.match(await page.textContent(tid('data-new')), /^New here: 2 addresses\./);
  await page.click(tid('data-bring'));
  await page.waitForSelector(tid('data-result'), { timeout: 60000 });
  assert.match(await page.textContent(tid('data-result')), /Added 2 addresses\./);
  await page.click(tid('data-done'));
  assert.ok((await snapshot(page)).own.includes(CLI_LABEL));

  // A crafted file: A's, plus a copy of its payment made a contract call that is still "in progress".
  // BEAM resumes such a transaction at the next start and builds and signs it from the file, unasked;
  // it is left out, said in the preview, and never reaches the engine (lib/wallet_data.js).
  const evilFile = join(tmp, 'evil.dat');
  {
    const j = JSON.parse(readFileSync(s.fileA, 'utf8'));
    const copy = j.TransactionParameters.filter((p) => hex(p.TransactionId) === s.txId).map((p) => ({ ...p, TransactionId: [0xee, ...p.TransactionId.slice(1)] }));
    for (const p of copy) {
      if (p.ParameterId === 151) p.Value = [129]; // in progress
      if (p.ParameterId === 0 && p.SubTransactionId === 1) p.Value = [1, 12]; // a contract call
    }
    j.TransactionParameters.push(...copy);
    writeFileSync(evilFile, JSON.stringify(j));
    s.evilId = hex(copy[0].TransactionId);
  }
  await pick(page, evilFile);
  await page.waitForSelector(tid('data-unfinished'), { timeout: 60000 });
  assert.match(await page.textContent(tid('data-unfinished')), /^Left out: 1 payment still under way in that file\./);
  assert.equal(await page.isVisible(tid('data-all-here')), true, 'the rest is already here: nothing to bring in');
  await shot(page, 'data-09b-unfinished-left-out');
  await page.click(tid('data-done'));
  assert.ok(!(await snapshot(page)).txs.some((x) => x.txId === s.evilId), 'never reached the wallet');

  // Saved in the browser's storage: a reload and unlock still has it.
  await page.reload();
  await waitScreen(page, 'unlock', 60000);
  if (!(await page.isVisible(tid('unlock-pw')))) await page.click(tid('use-password'));
  await page.fill(tid('unlock-pw'), PASSWORD);
  await page.click(tid('unlock-submit'));
  await waitHome(page, { timeout: 5 * 60000 });
  await page.waitForFunction(() => window.__campfire.running(), null, { timeout: 60000 });
  const reloaded = await snapshot(page);
  assert.ok(reloaded.own.includes(LABEL) && reloaded.own.includes(CLI_LABEL));
  assert.ok(reloaded.txs.some((x) => x.txId === s.txId && x.comment === NOTE));
  assert.ok(!reloaded.txs.some((x) => x.txId === s.evilId), 'nothing was resumed at the next start');
  assert.deepEqual(rec.errors, []);
  await ctx.close();
});

test('a small phone (375x667): each sheet’s main button is on screen without scrolling', { timeout: 10 * 60000 }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 375, height: 667 }, deviceScaleFactor: 2, acceptDownloads: true });
  const { page } = await recordedPage(ctx, { label: 'data-small' });
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page, { timeout: 5 * 60000 });
  const inView = async (id) => {
    const b = await page.locator(tid(id)).boundingBox();
    return Boolean(b) && b.y >= 0 && b.y + b.height <= 667;
  };
  await openCard(page);
  await pick(page, s.fileA); // another wallet's file here, but the preview comes first
  await page.waitForSelector(tid('data-bring'), { timeout: 60000 });
  assert.ok(await inView('data-bring'), 'Bring it in');
  await shot(page, 'data-10-preview-375');
  await page.click(tid('data-close'));
  await page.click(tid('data-save'));
  await page.fill(tid('auth-pw'), PASSWORD);
  await page.click(tid('auth-submit'));
  await page.waitForSelector(tid('data-save-file'), { timeout: 120000 });
  assert.ok(await inView('data-save-file'), 'Save the file');
  await shot(page, 'data-11-ready-375');
  await page.click('.sheet .btn-text');

  // More history than the engine could export in one piece: with wasm patch 0111 (in this engine)
  // it is saved in pages, and the file is offered; the wallet keeps running.
  const n = await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const s = wallet.session;
    const peer = await s.call('create_address', { type: 'regular', expiration: 'never', comment: 'peer' });
    const { txId } = await s.call('tx_send', { address: peer, value: 100000000, fee: 100000 });
    for (let i = 0; i < 60 && (await s.call('tx_status', { txId })).status !== 4; i++) await new Promise((r) => setTimeout(r, 500));
    const tpl = JSON.parse(await s.exportData()).TransactionParameters.filter((p) => p.TransactionId.map((b) => b.toString(16).padStart(2, '0')).join('') === txId);
    const rows = [];
    for (let k = 1; k <= 210; k++) for (const p of tpl) if (p.ParameterId !== 158) rows.push({ ...p, TransactionId: [k & 255, k >> 8, ...p.TransactionId.slice(2)] });
    await s.importData(JSON.stringify({ TransactionParameters: rows }));
    return (await s.call('tx_list', {})).length;
  });
  assert.ok(n > 200, `${n} payments`);
  if (!(await page.locator(tid('data-save')).isVisible())) await openCard(page);
  await page.click(tid('data-save'));
  await page.fill(tid('auth-pw'), PASSWORD);
  await page.click(tid('auth-submit'));
  await page.waitForSelector(`${tid('data-save-file')}, ${tid('data-export-problem')}`, { timeout: 120000 });
  assert.equal(await page.isVisible(tid('data-export-problem')), false, 'a long history is saved in pages (0111), not refused');
  await shot(page, 'data-12-long-history-375');
  assert.equal(await page.evaluate(() => window.__campfire.running()), true, 'the wallet keeps running');
  await page.click('.sheet .btn-text').catch(() => page.keyboard.press('Escape'));

  // A file larger than the engine can read at once (14.7 MB stopped it, measured) goes in, in pieces.
  const base = JSON.parse(await page.evaluate(async () => (await import('./lib/wallet.js')).wallet.session.exportData()));
  const tpl = base.TransactionParameters.filter((p) => p.TransactionId[0] === 1 && p.TransactionId[1] === 0);
  assert.ok(tpl.length > 5);
  const rows = [];
  for (let k = 1000; k < 6500; k++) for (const p of tpl) rows.push({ ...p, TransactionId: [k & 255, k >> 8, 0x5a, ...p.TransactionId.slice(3)] });
  const big = join(tmp, 'big.dat');
  writeFileSync(big, JSON.stringify({ ...base, TransactionParameters: [...base.TransactionParameters, ...rows] }));
  const mb = statSync(big).size / 1e6;
  assert.ok(mb > 15, `${mb.toFixed(1)} MB`);
  await openCard(page);
  await pick(page, big);
  await page.waitForSelector(tid('data-bring'), { timeout: 120000 });
  assert.match(await page.textContent(tid('data-new')), /^New here: 5,500 payments\./);
  const t0 = Date.now();
  await page.click(tid('data-bring'));
  await page.waitForSelector(tid('data-result'), { timeout: 600000 });
  assert.match(await page.textContent(tid('data-result')), /Added 5,500 payments\./);
  assert.equal(await page.evaluate(() => window.__campfire.running()), true);
  assert.equal(await page.evaluate(async () => (await (await import('./lib/wallet.js')).wallet.session.call('tx_list', {})).length), n + 5500);
  console.log(`a ${mb.toFixed(1)} MB file brought in, in pieces, in ${Date.now() - t0} ms`);
  await ctx.close();
});

// BEAM names and airdrop codes end-to-end: the installed Google Chrome
// (headless), the dev server, BEAM mainnet. Spends nothing: a throwaway wallet
// that holds nothing, and no approve button is ever pressed.
//
//   npm run e2e:names-airdrop   (stages the engine, builds dist/, runs this file)
//
// Lookups run on the wallet's own node through the pinned shaders. To reach the
// approve sheet the test shows the screens a balance the wallet does not have
// (the page's state only); the engine still knows the truth, and the sheet must
// show what the engine reports - "Not enough", no approve button - and Cancel
// must send nothing.
//
// A claim needs a code someone issued, and this wallet can issue none. So the
// claim test answers two things the way the chain would for a 5 FOMO code: the
// read-only voucher lookup, and the bytes the app shader builds for the claim
// (its arguments, BVM charge, kernel comment and funds, as the desktop's
// recordings show). Everything after - the library's byte checks, the engine's
// process_invoke_data, its consent - is real.
//
// Screenshots of every screen go to CAMPFIRE_SHOTS (390x844 and 1280x800,
// light and dark). Never of a seed.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startServer, launch, recordedPage, shot, waitScreen, foreignHosts, sleep, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced, lock, unlockWithPassword } from './flows.mjs';

const PORT = Number(process.env.E2E_PORT || 8820);
const PASSWORD = `names-${Math.random().toString(36).slice(2, 10)}`;
const NODE = 'eu-nodes.mainnet.beam.mw:8200';
const tid = (id) => `[data-testid="${id}"]`;
const groth = (text) => {
  const m = /([\d,]+(?:\.\d+)?)/.exec(text);
  const [w, f = ''] = m[1].replace(/,/g, '').split('.');
  return BigInt(w) * 100000000n + BigInt((f + '00000000').slice(0, 8));
};
const FREE_NAME = `cf${Math.random().toString(36).slice(2, 10)}${Math.random().toString(36).slice(2, 6)}`;
const BEAM_OWNER_SHORT = '72e3…51ef';

let srv, browser, ctx, page, rec;

/** One picture per size and colour scheme; back to the phone in light after. */
async function shots(name) {
  for (const [w, hgt, tag] of [
    [390, 844, 'phone'],
    [1280, 800, 'desktop'],
  ]) {
    for (const scheme of ['light', 'dark']) {
      await page.setViewportSize({ width: w, height: hgt });
      await page.emulateMedia({ colorScheme: scheme });
      await sleep(250);
      await shot(page, `${name}-${tag}-${scheme}`);
    }
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: 'light' });
}

/** The screens see `beam` groth of BEAM (and `tokens`) available; the engine still holds nothing. */
async function pretendBalance(beam, tokens = {}) {
  await page.evaluate(
    async ([g, t]) => {
      const { wallet } = await import('./lib/wallet.js');
      if (!wallet.__realRefresh) wallet.__realRefresh = wallet.refreshStatus.bind(wallet);
      wallet.refreshStatus = async function () {
        await this.__realRefresh();
        this.state.totals.set(0, { available: BigInt(g), receiving: 0n, sending: 0n, maturing: 0n });
        for (const [id, v] of Object.entries(t)) this.state.totals.set(Number(id), { available: BigInt(v), receiving: 0n, sending: 0n, maturing: 0n });
        this.emit();
      };
      await wallet.refreshStatus();
    },
    [String(beam), Object.fromEntries(Object.entries(tokens).map(([k, v]) => [k, String(v)]))],
  );
}

async function realBalance() {
  await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    if (wallet.__realRefresh) {
      wallet.refreshStatus = wallet.__realRefresh;
      wallet.__realRefresh = null;
    }
    for (const id of [...wallet.state.totals.keys()]) if (id !== 0) wallet.state.totals.delete(id);
    await wallet.refreshStatus();
  });
}

/**
 * Taps a button the pretended balance enabled, then shows the page the engine's
 * truth again before the approve sheet opens: its "not enough" words are
 * measured against this wallet's real balance. A second `taps` is a double tap
 * (a disabled button takes no second click).
 */
async function tapWithRealBalance(testid, taps = 1) {
  await page.evaluate(
    async ([id, n]) => {
      const { wallet } = await import('./lib/wallet.js');
      const el = document.querySelector(`[data-testid="${id}"]`);
      for (let i = 0; i < n; i++) el.click();
      if (wallet.__realRefresh) {
        wallet.refreshStatus = wallet.__realRefresh;
        wallet.__realRefresh = null;
      }
      for (const k of [...wallet.state.totals.keys()]) wallet.state.totals.delete(k);
      wallet.emit();
      wallet.refreshStatus();
    },
    [testid, taps],
  );
}

/** What the engine itself holds: no transaction, nothing available. */
async function engineTruth() {
  return page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const txs = await wallet.session.call('tx_list', { count: 100, skip: 0 });
    const st = await wallet.session.call('wallet_status', { nz_totals: true });
    return { allTxs: txs.length, available: String(st.available) };
  });
}

const lastConsent = async () => (await page.evaluate(() => window.__campfire.consents())).at(-1);

async function readSheet() {
  await page.waitForSelector(tid('consent'), { timeout: 120000 });
  const text = async (id) => ((await page.$(tid(id))) ? (await page.textContent(tid(id))).trim() : null);
  return {
    title: (await page.textContent('.consent h2')).trim(),
    app: await text('consent-app'),
    pay: await text('consent-pay-0'),
    get: await text('consent-get-0'),
    to: await text('consent-to'),
    fee: await text('consent-fee'),
    total: await text('consent-total'),
    short: await text('consent-not-enough'),
    add: await text('consent-receive'),
    approve: await text('consent-approve'),
  };
}

before(async () => {
  srv = await startServer({ root: 'dist', port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, locale: 'en-GB' });
  await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: srv.url });
  ({ page, rec } = await recordedPage(ctx, { label: 'names-airdrop' }));
  console.log(`# screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
});

test('a new wallet, synced; Home has BEAM names and airdrop codes on the dApps line, and scrolls no further', { timeout: 15 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  await waitSynced(page);
  assert.equal((await page.textContent(tid('names'))).trim(), 'BEAM names');
  assert.equal((await page.textContent(tid('airdrop'))).trim(), 'Airdrop codes');
  const shaderLoads = await page.evaluate(() => performance.getEntriesByType('resource').filter((e) => e.name.includes('/shaders/')).length);
  assert.equal(shaderLoads, 0, 'no shader is loaded before a feature needs it');

  // How far Home scrolls on a 390x844 phone. The dApps row this line took over was 64 px tall
  // (12 px padding, a 36 px icon, 2 lines of text); the line is no taller, so Home scrolls no further.
  const overflow = () =>
    page.evaluate(() => {
      const row = document.querySelector('.more-entry');
      return { overflow: Math.max(0, document.scrollingElement.scrollHeight - window.innerHeight), rowHeight: Math.round(row.getBoundingClientRect().height), tiles: [...row.querySelectorAll('.tile')].map((t) => t.textContent) };
    });
  const empty = await overflow();
  console.log(`# Home, empty wallet, 390x844: ${JSON.stringify(empty)}`);
  assert.deepEqual(empty.tiles, ['dApps', 'BEAM names', 'Airdrop codes']);
  assert.ok(empty.rowHeight <= 64, `the line is ${empty.rowHeight} px`);
  assert.equal(empty.overflow, 0, "an empty wallet's Home fits a 390x844 phone");
  await shots('home-01-empty');

  // Every row Home can have: the chain switcher, balance, actions, dApps, this line, tokens, payments.
  await pretendBalance(123456789000n, { 174: 250000000000n, 7: 1200000000n });
  await page.waitForSelector(tid('tokens'));
  const full = await overflow();
  console.log(`# Home, every row, 390x844: ${JSON.stringify(full)}`);
  assert.ok(full.overflow <= 68, 'no further than the same Home with the dApps row alone (68 px measured)');
  await shots('home-02-every-row');
  await realBalance();
});

test("names: a taken name, a free one with its price, and the button's reason on an empty wallet", { timeout: 10 * 60000 }, async () => {
  await page.click(tid('names'));
  await waitScreen(page, 'names');
  await page.waitForSelector(tid('names-mine-empty'), { timeout: 120000 });
  assert.match(await page.textContent(tid('names-hint')), /\$10 a year for 5 or more characters, \$120 for 4 and \$320 for 3/);
  await shots('names-01-empty');

  await page.fill(tid('names-input'), 'beam');
  await page.waitForSelector(`${tid('names-result')}[data-state="taken"]`, { timeout: 120000 });
  const taken = await page.textContent(tid('names-result'));
  console.log(`# beam: ${taken}`);
  assert.match(taken, /^beam\.beam is taken/);
  assert.match(taken, /Registered until \d{1,2} \w{3,4} \d{4}/);
  assert.equal(await page.isDisabled(tid('names-cta')), true);
  assert.match(await page.textContent(tid('names-reason')), /beam\.beam is taken\. Try another name\./);
  await shots('names-02-taken');

  await page.fill(tid('names-input'), FREE_NAME.toUpperCase());
  await page.waitForSelector(`${tid('names-result')}[data-state="available"]`, { timeout: 120000 });
  assert.equal(await page.textContent(tid('names-result-title')), `${FREE_NAME}.beam is available`, 'typed upper case, looked up in the canonical lower case');
  assert.equal(await page.inputValue(tid('names-input')), FREE_NAME, 'shown in lower case as typed');
  await page.waitForFunction(() => /≈ [\d,]+ BEAM/.test(document.querySelector('[data-testid="names-beam"]')?.textContent || ''), null, { timeout: 60000 });
  console.log(`# ${FREE_NAME}: ${await page.textContent(tid('names-usd'))} a year = ${await page.textContent(tid('names-beam'))}; ${await page.textContent(tid('names-price-note'))}`);
  assert.equal(await page.textContent(tid('names-usd')), '$10');
  assert.equal(await page.textContent(tid('names-fee')), '0.011 BEAM');
  assert.equal(await page.isDisabled(tid('names-cta')), true);
  assert.match(await page.textContent(tid('names-reason')), /^Not enough BEAM\. .* costs about [\d,]+ BEAM for 1 year, network fee included\. You have 0 BEAM\./);
  assert.equal(await page.isVisible(tid('names-receive')), true, 'the way out is one tap: Receive BEAM');
  await shots('names-03-available-not-enough');

  await page.click(tid('names-years-plus'));
  assert.equal(await page.textContent(tid('names-years')), '2 years');
  assert.equal(await page.textContent(tid('names-usd')), '$20');
  await page.click(tid('names-years-minus'));
  const shaderLoads = await page.evaluate(() => performance.getEntriesByType('resource').filter((e) => e.name.endsWith('/shaders/bans_app.wasm')).length);
  assert.equal(shaderLoads, 1, 'the names shader loads once, when Names needs it');
});

test("names: Register reaches the approve sheet with the engine's figures; not enough; Cancel sends nothing", { timeout: 10 * 60000 }, async () => {
  const estimate = groth(await page.textContent(tid('names-beam')));
  await pretendBalance(500000000000n); // 5,000 BEAM on screen only
  await page.waitForFunction(() => !document.querySelector('[data-testid="names-cta"]').disabled, null, { timeout: 30000 });
  assert.equal(await page.textContent(tid('names-cta')), `Register ${FREE_NAME} for 1 year`);
  await shots('names-04-ready');

  await tapWithRealBalance('names-cta');
  const sheet = await readSheet();
  console.log(`# register sheet: ${JSON.stringify(sheet)}`);
  await shots('names-05-consent-not-enough');
  assert.equal(sheet.title, 'Confirm your name');
  assert.match(sheet.app, /BEAM Campfire/);
  assert.match(sheet.pay, /^[\d,]+\.?\d* BEAM$/);
  const pay = groth(sheet.pay);
  assert.ok(pay * 100n >= estimate * 98n && pay * 100n <= estimate * 102n, `sheet ${pay} within 2% of the screen's estimate ${estimate}`);
  assert.equal(sheet.fee, '0.011 BEAM');
  assert.match(sheet.short, /^Not enough BEAM\. You need [\d,.]+ BEAM, including the 0\.011 BEAM network fee\. You have 0\. Add BEAM to this wallet, then try again\.$/);
  assert.equal(sheet.add, 'Add BEAM');
  assert.equal(sheet.approve, null, 'no approve button when the engine says it is not enough');

  await page.click(tid('consent-cancel'));
  await page.waitForSelector(tid('names-notice'), { timeout: 30000 });
  const result = await page.$eval(tid('names-notice'), (el) => ({ code: el.dataset.code, text: el.textContent }));
  console.log(`# after Cancel: ${JSON.stringify(result)}`);
  assert.equal(result.code, 'rejected');
  assert.match(result.text, /Cancelled\. Nothing was sent\./);
  await shots('names-06-cancelled');
  const last = await lastConsent();
  console.log(`# consent log: ${JSON.stringify(last)}`);
  assert.equal(last.decision, 'rejected');
  assert.equal(last.isEnough, false);
  assert.equal(last.fee, '0.011');
  assert.deepEqual(last.spends.map((a) => a.assetId), [0]);
  assert.equal(last.receives.length, 0);
});

test('pay a name from Send: resolved to its owner before Review, shown on Review and the sheet, Cancel sends nothing', { timeout: 10 * 60000 }, async () => {
  await pretendBalance(500000000000n);
  await page.evaluate(() => window.__campfire.go('send'));
  await waitScreen(page, 'send');
  await page.fill(tid('send-address'), 'beam.beam');
  await page.waitForFunction(() => /registered name, owner key/.test(document.querySelector('[data-testid="address-hint"]').textContent), null, { timeout: 120000 });
  const hint = await page.textContent(tid('address-hint'));
  console.log(`# send hint: ${hint}`);
  assert.ok(hint.startsWith(`beam.beam: registered name, owner key ${BEAM_OWNER_SHORT}`), hint);
  await page.fill(tid('send-amount'), '0.001');
  assert.equal(await page.textContent(tid('fee')), '0.011 BEAM');
  await shots('send-01-name');
  await page.click(tid('review'));
  await waitScreen(page, 'review');
  assert.equal(await page.textContent(tid('review-to')), 'beam.beam');
  assert.equal(await page.textContent(tid('review-owner')), '72e3 68c0 … 570d 51ef');
  assert.equal(await page.textContent(tid('review-total')), '0.012 BEAM');
  assert.equal(await page.textContent(tid('confirm-send')), 'Send 0.001 BEAM to beam');
  await shots('send-02-review-name');
  await tapWithRealBalance('confirm-send');
  const sheet = await readSheet();
  console.log(`# name payment sheet: ${JSON.stringify(sheet)}`);
  assert.equal(sheet.title, 'Approve this payment');
  assert.equal(sheet.pay, '0.001 BEAM');
  assert.equal(sheet.to, 'beam.beam');
  assert.equal(sheet.fee, '0.011 BEAM');
  assert.match(sheet.short, /^Not enough BEAM\./);
  assert.equal(sheet.approve, null);
  await shots('send-03-consent-name');
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(tid('review-name-result'), { timeout: 30000 });
  assert.match(await page.textContent(tid('review-name-result')), /Cancelled\. Nothing was sent\./);
  assert.equal((await lastConsent()).decision, 'rejected');

  // A name nobody owns, and text that is neither: plain words, no button.
  await page.click('button[aria-label="Back"]');
  await waitScreen(page, 'send');
  await page.fill(tid('send-address'), FREE_NAME);
  await page.waitForFunction(() => /No one owns/.test(document.querySelector('[data-testid="address-hint"]').textContent), null, { timeout: 120000 });
  assert.match(await page.textContent(tid('address-hint')), new RegExp(`^No one owns ${FREE_NAME}\\.beam, and it isn't a BEAM address\\. Check the spelling, or ask for their address\\.$`));
  assert.equal(await page.isDisabled(tid('review')), true);
  await shots('send-04-name-unknown');
  await page.fill(tid('send-address'), 'hi there');
  await page.waitForFunction(() => /isn't a BEAM address or a name/.test(document.querySelector('[data-testid="address-hint"]').textContent), null, { timeout: 30000 });
  await page.evaluate(() => window.__campfire.go('home'));
});

test('airdrop: a code nobody issued gets a clear message', { timeout: 10 * 60000 }, async () => {
  await realBalance();
  await waitScreen(page, 'home');
  await page.click(tid('airdrop'));
  await waitScreen(page, 'airdrop');
  assert.match(await page.textContent(tid('airdrop-reason')), /Paste the code you were given above\./);
  await shots('airdrop-01-empty');
  await page.fill(tid('airdrop-code'), 'abcdefghjkmnpqrs');
  assert.equal(await page.inputValue(tid('airdrop-code')), 'ABCD-EFGH-JKMN-PQRS', 'grouped as typed');
  await page.waitForSelector(`${tid('airdrop-result')}[data-state="notFound"]`, { timeout: 120000 });
  const msg = await page.textContent(tid('airdrop-result'));
  console.log(`# unknown code: ${msg}`);
  assert.match(msg, /No voucher has this code\. Check it letter by letter; codes never contain I, O, 0 or 1\./);
  assert.equal(await page.isDisabled(tid('airdrop-cta')), true);
  await shots('airdrop-02-not-found');
  await page.fill(tid('airdrop-code'), '-- --');
  assert.match(await page.textContent(tid('airdrop-reason')), /Paste the code you were given above\./);
});

test('airdrop: claiming a 5 FOMO code reaches the approve sheet with the normalised code as the preimage; not enough BEAM for the fee; Cancel', { timeout: 10 * 60000 }, async () => {
  const setup = await page.evaluate(async () => {
    const { app } = await import('./app.js');
    const { airdrop } = await import('./screens/airdrop.js');
    const { nativeApp } = await import('./lib/contracts.js');
    const { AIRDROP_CID, METHOD, CHARGE, KERNEL } = await import('./lib/airdrop.js');
    const svc = airdrop(app);
    const key = await svc.myKey();
    const native = await nativeApp();
    // The chain's answer for an issued, unclaimed 5 FOMO code (read-only lookup).
    window.__stubs = { check: svc.checkVoucherHash, call: native.call, args: [] };
    svc.checkVoucherHash = async (h) => ({ hash: h, batchId: 7n, assetId: 174, value: 500000000n, redeemed: false, redeemerKey: null, redeemedAtHeight: null });
    // What the app shader builds for that claim: yas, compacted integers.
    const u = (v) => {
      v = BigInt(v);
      if (v < 128n) return [0x80 | Number(v)];
      const b = [];
      for (let x = v; x > 0n; x >>= 8n) b.push(Number(x & 0xffn));
      return [b.length, ...b];
    };
    const sgn = (v) => {
      v = BigInt(v);
      const a = v < 0n ? -v : v;
      const sign = v < 0n ? 0x80 : 0;
      if (a < 64n) return [sign | 0x40 | Number(a)];
      const b = [];
      for (let x = a; x > 0n; x >>= 8n) b.push(Number(x & 0xffn));
      return [sign | b.length, ...b];
    };
    const hex = (s) => s.match(/../g).map((x) => parseInt(x, 16));
    const le4 = (n) => [n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >>> 24) & 255];
    const buf = (b) => [...u(b.length), ...b];
    const enc = (s) => [...new TextEncoder().encode(s)];
    const real = native.call.bind(native);
    native.call = (method, params, opts) => {
      if (method === 'invoke_contract' && /action=redeem/.test(params.args)) {
        window.__stubs.args.push(params.args);
        const code = /(?:^|,)code=([^,]*)/.exec(params.args)[1];
        const args = [...hex(key), ...le4(code.length), ...enc(code)];
        const raw = [...u(1), ...u(METHOD.redeem), ...buf(args), ...u(1), ...Array(32).fill(0x11), ...u(CHARGE.redeem), ...buf(enc(KERNEL.redeem)), ...u(1), ...u(174), ...sgn(-500000000n), ...hex(AIRDROP_CID)];
        return Promise.resolve({ output: '{}', raw_data: raw });
      }
      return real(method, params, opts);
    };
    return { key: key.slice(0, 6) };
  });
  console.log(`# claim stubs ready (key ${setup.key}…)`);
  await pretendBalance(500000000000n);
  await page.fill(tid('airdrop-code'), 'wxyz-2345 6789-abcd');
  await page.waitForSelector(`${tid('airdrop-result')}[data-state="found"]`, { timeout: 60000 });
  assert.equal(await page.textContent(tid('airdrop-gets')), '5 FOMO');
  assert.equal(await page.textContent(tid('airdrop-fee')), '0.121 BEAM');
  assert.deepEqual(await page.$$eval(`${tid('airdrop-net')} > div`, (els) => els.map((e) => e.textContent)), ['+5 FOMO', '−0.121 BEAM']);
  await page.waitForFunction(() => !document.querySelector('[data-testid="airdrop-cta"]').disabled, null, { timeout: 30000 });
  assert.equal(await page.textContent(tid('airdrop-cta')), 'Claim 5 FOMO');
  await shots('airdrop-03-claim-found');

  await tapWithRealBalance('airdrop-cta');
  const sheet = await readSheet();
  console.log(`# claim sheet: ${JSON.stringify(sheet)}`);
  await shots('airdrop-04-claim-consent-not-enough');
  const sent = await page.evaluate(() => window.__stubs.args);
  assert.equal(sent.length, 1);
  assert.match(sent[0], /(^|,)code=WXYZ23456789ABCD(,|$)/, 'the normalised code itself');
  assert.ok(!/[0-9a-f]{64}/.test(sent[0].replace(/cid=[0-9a-f]{64}/, '')), 'never its hash');
  assert.equal(sheet.title, 'Confirm your claim');
  assert.equal(sheet.get, '5 FOMO');
  assert.equal(sheet.pay, null);
  assert.equal(sheet.fee, '0.121 BEAM');
  assert.match(sheet.short, /^Not enough BEAM\. You need 0\.121 BEAM for the network fee\. You have 0\. Add BEAM to this wallet, then try again\.$/);
  assert.equal(sheet.add, 'Add BEAM');
  assert.equal(sheet.approve, null);

  await page.click(tid('consent-cancel'));
  await page.waitForSelector(`${tid('airdrop-notice')}[data-code="rejected"]`, { timeout: 30000 });
  assert.match(await page.textContent(tid('airdrop-notice')), /Cancelled\. Nothing was sent\./);
  const last = await lastConsent();
  console.log(`# consent log: ${JSON.stringify(last)}`);
  assert.equal(last.decision, 'rejected');
  assert.equal(last.fee, '0.121');
  assert.deepEqual(last.receives, [{ assetId: 174, amount: '5' }]);
  assert.deepEqual(last.spends, []);
  await page.evaluate(async () => {
    const { app } = await import('./app.js');
    const { airdrop } = await import('./screens/airdrop.js');
    const { nativeApp } = await import('./lib/contracts.js');
    airdrop(app).checkVoucherHash = window.__stubs.check;
    (await nativeApp()).call = window.__stubs.call;
  });
});

test('airdrop: create 2 codes of 0.001 BEAM: the fee math, the sheet, the codes saved first and kept after Cancel; one batch per tap', { timeout: 10 * 60000 }, async () => {
  await realBalance();
  await page.click(tid('airdrop-create'));
  await waitScreen(page, 'airdropCreate');
  await page.fill(tid('drop-amount'), '0.001');
  await page.fill(tid('drop-count'), '2');
  const summary = async () => ({
    locked: await page.textContent(tid('drop-locked')),
    fee: await page.textContent(tid('drop-fee')),
    network: await page.textContent(tid('drop-network-fee')),
    total: await page.textContent(tid('drop-total')),
  });
  const s1 = await summary();
  console.log(`# create summary: ${JSON.stringify(s1)}`);
  assert.deepEqual(s1, { locked: '0.002 BEAM', fee: '0.00002 BEAM', network: '0.121 BEAM', total: '0.12302 BEAM' });
  assert.equal(await page.isDisabled(tid('drop-cta')), true);
  assert.match(await page.textContent(tid('drop-reason')), /^Not enough BEAM\. This needs 0\.12302 BEAM, network fee included\. You have 0 BEAM\./);
  await shots('airdrop-05-create-not-enough');
  // The 1%: floored, never below 1 groth.
  for (const [amount, count, fee] of [
    ['0.00000150', '1', '0.00000001 BEAM'],
    ['0.00000001', '3', '0.00000001 BEAM'],
    ['1.23456789', '7', '0.08641975 BEAM'],
    ['250', '100', '250 BEAM'],
  ]) {
    await page.fill(tid('drop-amount'), amount);
    await page.fill(tid('drop-count'), count);
    assert.equal(await page.textContent(tid('drop-fee')), fee, `${count} x ${amount}`);
  }
  await page.fill(tid('drop-amount'), '0.001');
  await page.fill(tid('drop-count'), '2');

  const before = await page.evaluate(async () => {
    const { app } = await import('./app.js');
    const { airdrop } = await import('./screens/airdrop.js');
    return (await airdrop(app).savedBatches()).length;
  });
  await pretendBalance(100000000n); // 1 BEAM on screen only
  await page.waitForFunction(() => !document.querySelector('[data-testid="drop-cta"]').disabled, null, { timeout: 30000 });
  assert.equal(await page.textContent(tid('drop-cta')), 'Create 2 codes');
  await shots('airdrop-06-create-ready');
  // A double tap: one batch.
  await tapWithRealBalance('drop-cta', 2);
  const sheet = await readSheet();
  console.log(`# create sheet: ${JSON.stringify(sheet)}`);
  await shots('airdrop-07-create-consent-not-enough');
  assert.equal(sheet.title, 'Confirm your codes');
  assert.equal(sheet.pay, '0.00202 BEAM');
  assert.equal(sheet.fee, '0.121 BEAM');
  assert.equal(sheet.total, '0.12302 BEAM');
  assert.match(sheet.short, /^Not enough BEAM\. You need 0\.12302 BEAM, including the 0\.121 BEAM network fee\. You have 0\. Add BEAM to this wallet, then try again\.$/);
  assert.equal(sheet.add, 'Add BEAM');
  assert.equal(sheet.approve, null);
  // While the sheet is open, the library refuses a second airdrop transaction outright.
  const second = await page.evaluate(async () => {
    const { app } = await import('./app.js');
    const { airdrop } = await import('./screens/airdrop.js');
    const svc = airdrop(app);
    const a = await svc.createBatch({ assetId: 0, values: [100000n] }).then(() => 'went through', (e) => e.code);
    const b = await svc.redeem('ABCD-EFGH-JKMN-PQRS').then(() => 'went through', (e) => e.code);
    return { busy: svc.busy, a, b, saved: (await svc.savedBatches()).map((x) => ({ n: x.codes.length, status: x.txStatus })) };
  });
  console.log(`# while the sheet is open: ${JSON.stringify(second)}`);
  assert.deepEqual({ busy: second.busy, a: second.a, b: second.b }, { busy: true, a: 'busy', b: 'busy' });
  assert.equal(second.saved.length, before + 1, 'one batch saved for a double tap');
  assert.deepEqual(second.saved[0], { n: 2, status: 'unconfirmed' }, 'saved before the sheet opened');
  assert.equal((await page.$$(tid('consent'))).length, 1, 'one sheet');

  await page.click(tid('consent-cancel'));
  await page.waitForSelector(tid('drop-result'), { timeout: 30000 });
  const result = await page.$eval(tid('drop-result'), (el) => ({ code: el.dataset.code, text: el.textContent }));
  console.log(`# after Cancel: ${JSON.stringify(result)}`);
  assert.equal(result.code, 'rejected');
  assert.match(result.text, /Nothing was sent/);
  await shots('airdrop-08-create-cancelled');
  const last = await lastConsent();
  assert.equal(last.decision, 'rejected');
  assert.equal(last.fee, '0.121');
  assert.deepEqual(last.spends, [{ assetId: 0, amount: '0.00202' }]);
  const saved = await page.evaluate(async () => {
    const { app } = await import('./app.js');
    const { airdrop } = await import('./screens/airdrop.js');
    const { store } = await import('./lib/store.js');
    const raw = JSON.stringify(await store.get('airdropCodes'));
    const svc = airdrop(app);
    const list = await svc.savedBatches();
    return {
      busy: svc.busy,
      batches: list.map((b) => ({ n: b.codes.length, status: b.txStatus })),
      hashes: list[0].codes.map((c) => c.hash),
      clear: list.some((b) => b.codes.some((c) => raw.includes(c.code.replace(/-/g, '')) || raw.includes(c.code))),
    };
  });
  console.log(`# saved after Cancel: ${JSON.stringify({ ...saved, hashes: saved.hashes.length })}`);
  assert.equal(saved.busy, false);
  assert.deepEqual(saved.batches[0], { n: 2, status: 'failed' }, 'kept, marked as never sent');
  assert.equal(saved.clear, false, 'no code is stored in the clear');
  const truth = await engineTruth();
  console.log(`# engine: ${JSON.stringify(truth)}`);
  assert.deepEqual(truth, { allTxs: 0, available: '0' });
  const state = await page.evaluate(() => window.__campfire.contracts());
  assert.equal(state.consents, 0, 'no consent left pending');
  assert.equal(state.inflight, 0, 'no call left waiting');

  // The codes outlive a lock: unlock again and they are all there.
  await page.evaluate(() => window.__campfire.go('home'));
  await lock(page);
  await unlockWithPassword(page, PASSWORD);
  await waitHome(page);
  const after = await page.evaluate(async () => {
    const { app } = await import('./app.js');
    const { airdrop } = await import('./screens/airdrop.js');
    return { draft: app.dropDraft, hashes: (await airdrop(app).savedBatches())[0].codes.map((c) => c.hash) };
  });
  assert.deepEqual(after.hashes, saved.hashes, 'every code still saved after lock and unlock');
  assert.equal(after.draft, null, 'a typed code is forgotten on lock');
  await waitSynced(page);
  await page.click(tid('airdrop'));
  await waitScreen(page, 'airdrop');
  await page.click(tid('airdrop-batches'));
  await waitScreen(page, 'airdropBatches');
  await page.waitForSelector(tid('batches-empty'), { timeout: 120000 });
  await shots('airdrop-09-batches-empty');
});

// Pictures only. Screens that need data an empty wallet cannot have (a claimed
// code, a batch on chain, a registered name) are shown by replacing the
// read-only lookups of this page's service objects. No money path is touched:
// nothing here reaches the engine's signing.
test('screens with data, for the screenshots (lookups replaced in the page)', { timeout: 5 * 60000 }, async () => {
  const local = await page.evaluate(async () => {
    const { app } = await import('./app.js');
    const { airdrop } = await import('./screens/airdrop.js');
    const svc = airdrop(app);
    const saved = (await svc.savedBatches())[0];
    svc.checkVoucherHash = async (h) => ({ hash: h, batchId: 7n, assetId: 0, value: 50000000n, redeemed: false, redeemerKey: null, redeemedAtHeight: null });
    svc.myBatches = async () => [
      { id: 7n, assetId: 0, valuePerVoucher: 100000n, totalCount: 2, redeemedCount: 1, unclaimedCount: 1, createdAtHeight: 4073000n },
      { id: 3n, assetId: 174, valuePerVoucher: 500000000n, totalCount: 10, redeemedCount: 10, unclaimedCount: 0, createdAtHeight: 4051000n },
    ];
    svc.batchVouchers = async (id) => (id === 7n ? saved.codes.map((c, i) => ({ hash: c.hash, value: 100000n, redeemed: i === 0 })) : []);
    svc.redeem = async () => ({ txId: '00'.repeat(16) });
    return saved.localId;
  });
  await pretendBalance(500000000000n);
  await page.evaluate(() => window.__campfire.go('airdrop'));
  await waitScreen(page, 'airdrop');
  await page.fill(tid('airdrop-code'), 'WXYZ-WXYZ-WXYZ-WXYZ');
  await page.waitForSelector(`${tid('airdrop-result')}[data-state="found"]`);
  assert.equal(await page.textContent(tid('airdrop-net')), '+0.379 BEAM');
  assert.equal(await page.textContent(tid('airdrop-cta')), 'Claim 0.5 BEAM');
  await shots('airdrop-10-claim-found-beam');
  await page.click(tid('airdrop-cta'));
  await page.waitForSelector(tid('airdrop-done'));
  await shots('airdrop-11-claim-sent');
  await page.evaluate((id) => window.__campfire.go('airdropCodes', { localId: id, justCreated: true }), local);
  await page.waitForSelector(tid('code'));
  assert.ok(await page.isVisible(tid('codes-copy-all')), 'Copy all is above the fold');
  await shots('airdrop-12-codes-just-created');
  await page.evaluate((id) => window.__campfire.go('airdropCodes', { localId: id }), local);
  await page.waitForSelector(tid('code'));
  await shots('airdrop-13-codes-never-sent');
  await page.evaluate(() => window.__campfire.go('airdropBatches'));
  await page.waitForSelector(tid('batch'));
  assert.equal(await page.textContent(`[data-batch-id="7"] ${tid('batch-counts')}`), '1 claimed · 1 not claimed');
  assert.equal(await page.textContent(`[data-batch-id="7"] ${tid('batch-cancel')}`), 'Take back 0.001 BEAM');
  await shots('airdrop-14-batches');

  await page.evaluate(async () => {
    const { bans } = await import('./screens/names.js');
    const svc = bans();
    const real = svc.myNames.bind(svc);
    svc.myNames = async () => {
      const r = await real();
      const t = r.tipHeight;
      return { ...r, names: [{ name: 'campfire-test', ownerKey: r.key, expireHeight: t + 300000, salePrice: null, status: 'active' }, { name: 'oldname', ownerKey: r.key, expireHeight: t - 20000, salePrice: null, status: 'onHold' }] };
    };
  });
  await page.evaluate(() => window.__campfire.go('names'));
  await page.waitForSelector(tid('names-mine'));
  await shots('names-07-my-names');
  await page.click(`[data-name="oldname"] ${tid('names-renew')}`);
  await page.waitForSelector(tid('renew-cta'));
  await page.waitForFunction(() => /≈/.test(document.querySelector('[data-testid="renew-beam"]').textContent));
  await shots('names-08-renew-sheet');
  await realBalance();
  await page.evaluate(() => window.__campfire.go('home'));
});

test('IP privacy: only this origin and the chosen node', async () => {
  assert.deepEqual(foreignHosts(rec, srv.url, [NODE]), []);
  assert.deepEqual(rec.csp, []);
  assert.deepEqual(rec.errors, []);
});

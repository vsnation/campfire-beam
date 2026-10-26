// BEAM names beyond registering: a name's own screen, transfer, sell, stop selling,
// buy, "Receive a name", and the money waiting for names (Home's line, the claim).
// The installed Google Chrome (headless), its own build and port, BEAM mainnet, a
// throwaway wallet that holds nothing. No approve button that could send is ever
// pressed; nothing is spent.
//
//   npm run e2e:names-more   (port 8950, CAMPFIRE_NAMES_PORT; screenshots to CAMPFIRE_SHOTS)
//
// Real, on the wallet's own node and engine: the inbox read at privilege 1 (an
// empty one for this wallet), its name key, the claim of nothing ("nothing to
// withdraw" from the shader), a name listed for sale on mainnet found and its
// purchase built by the shader up to the approve sheet with the engine's own
// figures ("Not enough BEAM": this wallet holds none).
// Answered by the test, because a throwaway wallet owns no name and nobody paid
// it: that it owns a name (the read of its names, and the name's record), what
// waits for its names (the inbox), and the kernels the shader would build for an
// owner's transfer, listing and stop-selling and for a claim (byte for byte as
// vault_anon/app_impl.h and bans/app.cpp build them). Everything after that - the
// library's byte checks, the engine's process_invoke_data and its approve sheet -
// is real.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, shot, waitScreen, foreignHosts, sleep, PWA, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';

const PORT = Number(process.env.CAMPFIRE_NAMES_PORT || 8950);
const PASSWORD = `names-more-${Math.random().toString(36).slice(2, 10)}`;
const tid = (id) => `[data-testid="${id}"]`;
const OTHER_KEY = '72e368c016bec94e0aa0274aae5b6e9ef4bbb64d0ce1436acb134488570d51ef01';
const MINE = 'campfire-test';

let tmp, srv, browser, ctx, page, rec;

async function shots(name) {
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(250);
    await shot(page, `names-more-${name}-${scheme}`);
  }
  await page.emulateMedia({ colorScheme: 'light' });
}

/** On a 375x667 phone the screen's primary button is in sight without scrolling. */
async function primaryInSight(selector) {
  await page.setViewportSize({ width: 375, height: 667 });
  await sleep(200);
  const r = await page.evaluate((sel) => {
    const el = document.querySelector(sel);
    if (!el) return null;
    const b = el.getBoundingClientRect();
    return { top: b.top, bottom: b.bottom, h: window.innerHeight, w: window.innerWidth, scrollW: document.scrollingElement.scrollWidth };
  }, selector);
  await page.setViewportSize({ width: 390, height: 844 });
  assert.ok(r, `${selector} on screen`);
  assert.ok(r.bottom <= r.h && r.top >= 0, `${selector} in sight at 375x667: ${JSON.stringify(r)}`);
  assert.ok(r.scrollW <= r.w, 'no sideways scroll');
}

/** Screens see `beam` groth available; the engine still holds nothing (as names_airdrop.test.mjs). */
async function pretendBalance(beam) {
  await page.evaluate(async (g) => {
    const { wallet } = await import('./lib/wallet.js');
    if (!wallet.__realRefresh) wallet.__realRefresh = wallet.refreshStatus.bind(wallet);
    wallet.refreshStatus = async function () {
      await this.__realRefresh();
      this.state.totals.set(0, { available: BigInt(g), receiving: 0n, sending: 0n, maturing: 0n });
      this.emit();
    };
    await wallet.refreshStatus();
  }, String(beam));
}

/** Taps a button the pretended balance enabled, then gives the page the engine's truth back. */
async function tapWithRealBalance(testid) {
  await page.evaluate(async (id) => {
    const { wallet } = await import('./lib/wallet.js');
    document.querySelector(`[data-testid="${id}"]`).click();
    if (wallet.__realRefresh) {
      wallet.refreshStatus = wallet.__realRefresh;
      wallet.__realRefresh = null;
    }
    for (const k of [...wallet.state.totals.keys()]) wallet.state.totals.delete(k);
    wallet.emit();
    wallet.refreshStatus();
  }, testid);
}

async function readSheet() {
  await page.waitForSelector(tid('consent'), { timeout: 120000 });
  const text = async (id) => ((await page.$(tid(id))) ? (await page.textContent(tid(id))).trim() : null);
  const extras = await page.$$eval('[data-testid^="consent-extra-"]', (els) => els.map((e) => [e.previousElementSibling.textContent, e.textContent]));
  const notes = await page.$$eval('[data-testid^="consent-note-"]', (els) => els.map((e) => e.textContent));
  return {
    title: (await page.textContent('.consent h2')).trim(),
    app: await text('consent-app'),
    pay: await text('consent-pay-0'),
    get: await text('consent-get-0'),
    fee: await text('consent-fee'),
    short: await text('consent-not-enough'),
    warn: await text('consent-warn'),
    ack: await text('consent-ack'),
    approve: await text('consent-approve'),
    approveDisabled: (await page.$(tid('consent-approve'))) ? await page.isDisabled(tid('consent-approve')) : null,
    extras,
    notes,
  };
}

const lastConsent = async () => (await page.evaluate(() => window.__campfire.consents())).at(-1);

/** In the page: yas helpers and the kernels an owner's shader builds (bans/app.cpp, vault_anon/app_impl.h). */
async function installKernels() {
  await page.evaluate(async () => {
    const { BANS_CID } = await import('./lib/bans.js');
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
    const le = (v, n) => {
      v = BigInt(v);
      const o = [];
      for (let i = 0; i < n; i++) o.push(Number((v >> BigInt(8 * i)) & 0xffn));
      return o;
    };
    const buf = (b) => [...u(b.length), ...b];
    const enc = (s) => [...new TextEncoder().encode(s)];
    const nameB = (n) => [n.length, ...enc(n)];
    const entry = ({ cid, method, args, sigs = 1, charge = 50000, comment, spend = {}, adv = null }) => [
      ...(adv ? [...u(0x80000000 + 0x11), ...u(method)] : u(method)),
      ...buf(args),
      ...u(sigs),
      ...Array(32 * sigs).fill(0x11),
      ...u(charge),
      ...buf(enc(comment)),
      ...u(Object.keys(spend).length),
      ...Object.entries(spend).flatMap(([k, v]) => [...u(k), ...sgn(v)]),
      ...hex(cid),
      // HeightRange, fee, signature (nonce point X + parity, scalar), key preimage, then the commitment (X + parity).
      ...(adv ? [...u(adv.h0), ...u(15), ...u(adv.fee), ...Array(32).fill(1), 0, ...Array(32).fill(1), ...Array(32).fill(2), ...Array(32).fill(3), 0] : []),
    ];
    window.__k = {
      setOwner: (name, key) => [...u(1), ...entry({ cid: BANS_CID, method: 3, args: [...hex(key), ...nameB(name)], comment: 'BANS: setting the domain owner' })],
      setPrice: (name, aid, amount) => [...u(1), ...entry({ cid: BANS_CID, method: 5, args: [...le(aid, 4), ...le(amount, 8), ...nameB(name)], comment: 'BANS: setting the domain price' })],
      claim: (vault, h0, oneTime, items) =>
        [...u(items.length), ...items.flatMap(({ aid, amount }) => entry({ cid: vault, method: 3, args: [...le(amount, 8), ...le(97, 4), ...hex(oneTime), ...le(aid, 4), ...Array(97).fill(7)], sigs: 0, charge: 0, comment: 'vault_anon receive', spend: { [aid]: -BigInt(amount) }, adv: { h0, fee: 1100000 } }))],
      // Amounts arrive as text (BigInt does not cross into the page).
      setPriceText: (name, aid, amount) => window.__k.setPrice(name, aid, BigInt(amount)),
    };
  });
}

/** Makes this wallet look like the owner of `MINE` (and `listed`, for sale) to the screens and the library. */
async function pretendOwner({ listedAt = null } = {}) {
  await page.evaluate(async ([name, listedAt]) => {
    const { bans } = await import('./screens/names.js');
    const svc = bans();
    if (!window.__real) window.__real = { resolve: svc.resolve, myNames: svc.myNames, inbox: svc.inbox };
    const key = await svc.myKey();
    const st = await window.__campfire.height();
    const domain = { name, ownerKey: key, expireHeight: st + 300000, salePrice: listedAt ? { assetId: 0, amount: BigInt(listedAt) } : null };
    svc.myNames = async () => {
      const r = await window.__real.myNames.call(svc);
      return { ...r, names: [{ ...domain, status: listedAt ? 'forSale' : 'active' }, { name: 'oldname', ownerKey: key, expireHeight: r.tipHeight - 20000, salePrice: null, status: 'onHold' }] };
    };
    svc.resolve = async (n) => {
      const r = await window.__real.resolve.call(svc, n);
      if (n !== name) return r;
      return { ...r, domain, ownerKey: key, status: listedAt ? 'forSale' : 'active' };
    };
  }, [MINE, listedAt == null ? null : String(listedAt)]);
}

/**
 * The wallet's apps answer invoke_contract for `action` with what an owner's shader builds
 * (window.__k[kernel](...kargs)); every other call is real.
 */
async function answerKernel(action, kernel, kargs) {
  await page.evaluate(
    async ([action, kernel, kargs]) => {
      const { nativeApp, privilegedApp } = await import('./lib/contracts.js');
      for (const app of [await nativeApp(), await privilegedApp()]) {
        if (!app.__realCall) app.__realCall = app.call.bind(app);
        const real = app.__realCall;
        app.call = (method, params, opts) => {
          if (method === 'invoke_contract' && new RegExp(`action=${action}(,|$)`).test(params.args)) {
            window.__asked = (window.__asked || []).concat(params.args);
            return Promise.resolve({ output: '{}', raw_data: window.__k[kernel](...kargs) });
          }
          return real(method, params, opts);
        };
      }
    },
    [action, kernel, kargs],
  );
}

async function realCalls() {
  await page.evaluate(async () => {
    const { nativeApp, privilegedApp } = await import('./lib/contracts.js');
    for (const app of [await nativeApp(), await privilegedApp()]) if (app.__realCall) app.call = app.__realCall;
    window.__asked = [];
  });
}

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-names-more-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, locale: 'en-GB' });
  await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: srv.url });
  ({ page, rec } = await recordedPage(ctx, { label: 'names-more' }));
  console.log(`# screenshots: ${SHOTS}`);
});

test.after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

test('a new wallet: Home reads no inbox (it can own no name), Names reads it at privilege 1 and finds nothing', { timeout: 15 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  await waitSynced(page);
  await sleep(9000); // past the first-read delay a wallet that may hold names would have
  const home = await page.evaluate(async () => {
    const { nameInbox, namesHint } = await import('./screens/names_claim.js');
    const { app } = await import('./app.js');
    return { shaders: performance.getEntriesByType('resource').filter((e) => e.name.includes('/shaders/')).length, latest: nameInbox().latest, hint: await namesHint(app), line: document.querySelector('[data-testid="names-home-line"]') !== null };
  });
  console.log(`# Home of a new wallet: ${JSON.stringify(home)}`);
  assert.equal(home.shaders, 0, 'no shader, no contract read');
  assert.equal(home.latest, null);
  assert.equal(home.line, false);
  assert.equal(home.hint && home.hint.owns, false, 'remembered: a wallet made here owns no name');

  await page.click(tid('names'));
  await waitScreen(page, 'names');
  await page.waitForSelector(tid('names-mine-empty'), { timeout: 120000 });
  let s = null;
  for (let i = 0; i < 240 && !s; i++) {
    s = await page.evaluate(async () => {
      const { nameInbox } = await import('./screens/names_claim.js');
      const x = nameInbox().latest;
      return x ? { visibility: x.visibility, entries: x.entryCount, owns: x.owns } : null;
    });
    if (!s) await sleep(500);
  }
  console.log(`# the inbox at privilege 1: ${JSON.stringify(s)}`);
  assert.deepEqual(s, { visibility: 'visible', entries: 0, owns: false }, 'this engine runs role=user view (get_PkEx) for the pinned shader');
  assert.equal(await page.$(tid('names-claim-unsupported')), null);
  assert.equal(await page.$(tid('names-money')), null, 'nothing waits: no card');
  assert.equal(await page.isVisible(tid('names-receive-name')), true);
  const apps = await page.evaluate(() => window.__campfire.contracts());
  console.log(`# apps open: ${JSON.stringify(apps)}`);
  await shots('01-names-empty');
});

test('Receive a name: this wallet’s name key, its 16-character check, Copy', { timeout: 5 * 60000 }, async () => {
  await page.click(tid('names-receive-name'));
  await waitScreen(page, 'nameKey');
  await page.waitForSelector(tid('name-key-check'), { timeout: 120000 });
  const key = (await page.textContent(tid('name-key'))).trim();
  const check = (await page.textContent(tid('name-key-check'))).trim();
  assert.match(key, /^[0-9a-f]{64}0[01]$/);
  assert.equal(check, `${key.slice(0, 4)} ${key.slice(4, 8)} … ${key.slice(56, 60)} ${key.slice(60, 64)}`);
  await primaryInSight(tid('name-key-copy'));
  await shots('02-receive-a-name');
  await page.click(tid('name-key-copy'));
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), key);
  await page.click('button[aria-label="Back"]');
  await waitScreen(page, 'names');
});

test('buy a name listed on mainnet: its price, then the shader’s purchase on the approve sheet with the engine’s figures; Cancel', { timeout: 10 * 60000 }, async (t) => {
  // A name someone sells now: every listed name, still active, cheapest first.
  const listed = await page.evaluate(async () => {
    const { nativeApp } = await import('./lib/contracts.js');
    const { loadShader } = await import('./lib/shaders.js');
    const { args, parseViewDomain, statusOf, STATUS } = await import('./lib/bans.js');
    const out = await (await nativeApp()).view(args.viewDomain(), await loadShader('bans'), { timeoutMs: 90000 });
    const tip = window.__campfire.height();
    return parseViewDomain(out)
      .filter((d) => d.salePrice && d.salePrice.assetId === 0 && statusOf({ expireHeight: d.expireHeight, tipHeight: tip, listed: true }) !== STATUS.availableAgain)
      .sort((a, b) => (a.salePrice.amount < b.salePrice.amount ? -1 : 1))
      .map((d) => ({ name: d.name, price: String(d.salePrice.amount) }));
  });
  console.log(`# listed on mainnet now: ${JSON.stringify(listed)}`);
  if (!listed.length) {
    t.skip('no name is listed for sale on mainnet right now');
    return;
  }
  const { name, price } = listed[0];
  await page.fill(tid('names-input'), name);
  await page.waitForSelector(`${tid('names-result')}[data-state="forSale"]`, { timeout: 120000 });
  const title = await page.textContent(tid('names-result-title'));
  console.log(`# ${name}: ${title} / ${await page.textContent(tid('names-sale-detail'))}`);
  assert.match(title, new RegExp(`^${name}\\.beam is for sale: [\\d,.]+ BEAM$`));
  assert.match(await page.textContent(tid('names-sale-detail')), /Buying it gives you the time left on it, until .+\. It does not renew it\./);
  assert.equal(await page.isDisabled(tid('names-cta')), true);
  assert.match(await page.textContent(tid('names-reason')), /^Not enough BEAM\. .* costs [\d,.]+ BEAM, plus the 0\.011 BEAM network fee\. You have 0 BEAM\./);
  await shots('03-buy-not-enough');

  await pretendBalance(BigInt(price) + 10n ** 9n);
  await page.waitForFunction(() => !document.querySelector('[data-testid="names-cta"]').disabled, null, { timeout: 30000 });
  assert.match(await page.textContent(tid('names-cta')), new RegExp(`^Buy ${name} for [\\d,.]+ BEAM$`));
  await primaryInSight(tid('names-cta'));
  await shots('04-buy-ready');
  await tapWithRealBalance('names-cta');
  const sheet = await readSheet();
  console.log(`# buy sheet: ${JSON.stringify(sheet)}`);
  await shots('05-buy-consent');
  assert.equal(sheet.title, 'Confirm your purchase');
  assert.match(sheet.app, /Beam PWA, this wallet/);
  assert.equal(sheet.pay.replace(/,/g, ''), `${BigInt(price) / 100000000n} BEAM`.replace(/,/g, ''));
  assert.equal(sheet.fee, '0.011 BEAM');
  assert.deepEqual(sheet.extras.map(([k]) => k), ['Name', 'Yours until']);
  assert.match(sheet.notes[0], /^Buying does not renew the name/);
  assert.match(sheet.short, /^Not enough BEAM\./, 'the engine knows this wallet holds nothing');
  assert.equal(sheet.approve, null);
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(`${tid('names-notice')}[data-code="rejected"]`, { timeout: 30000 });
  const last = await lastConsent();
  console.log(`# consent log: ${JSON.stringify(last)}`);
  assert.equal(last.decision, 'rejected');
  assert.equal(last.fee, '0.011');
  assert.deepEqual(last.spends.map((a) => a.assetId), [0]);
  assert.equal(last.receives.length, 0);
  await page.fill(tid('names-input'), '');
});

test('my names: a row opens the name; renew, transfer and sell are there; the key check before a transfer', { timeout: 10 * 60000 }, async () => {
  await installKernels();
  await pretendOwner();
  await page.evaluate(() => window.__campfire.go('home'));
  await page.evaluate(() => window.__campfire.go('names'));
  await page.waitForSelector(`${tid('names-mine-row')}[data-name="${MINE}"]`, { timeout: 120000 });
  assert.match(await page.textContent(tid('names-renew-warning')), /^oldname has expired\. Renew it by .+ to keep it\./);
  await shots('06-my-names');
  await page.click(`${tid('names-mine-row')}[data-name="${MINE}"]`);
  await waitScreen(page, 'nameDetail');
  await page.waitForSelector(tid('name-renew-box'), { timeout: 60000 });
  assert.equal(await page.textContent(tid('name-title')), `${MINE}.beam`);
  assert.match(await page.textContent(tid('name-until')), /^≈ \d{1,2} \w{3,4} \d{4}$/);
  assert.equal(await page.textContent(tid('name-usd')), '$10');
  await page.waitForFunction(() => /≈ [\d,]+ BEAM/.test(document.querySelector('[data-testid="name-beam"]').textContent), null, { timeout: 60000 });
  assert.match(await page.textContent(tid('name-reason')), /^Not enough BEAM\./);
  await primaryInSight(tid('name-renew-cta'));
  await shots('07-name-detail');

  await page.click(tid('name-transfer'));
  await waitScreen(page, 'nameTransfer');
  await sleep(2000); // the name and this wallet's key are read first
  assert.match(await page.textContent(tid('transfer-reason')), /Paste the key of the wallet that should get campfire-test\./);
  const own = await page.evaluate(async () => (await import('./screens/names.js')).bans().myKey());
  await page.fill(tid('transfer-key'), own);
  assert.match(await page.textContent(tid('transfer-key-error')), /That is this wallet's own key\./);
  await page.fill(tid('transfer-key'), 'not a key');
  assert.match(await page.textContent(tid('transfer-key-error')), /^That is not a name key\./);
  await page.fill(tid('transfer-key'), OTHER_KEY.toUpperCase());
  assert.equal(await page.textContent(tid('transfer-check')), '72e3 68c0 … 570d 51ef');
  assert.match(await page.textContent(tid('transfer-final')), /This can't be undone\./);
  assert.match(await page.textContent(tid('transfer-reason')), /You need 0\.011 BEAM for the network fee/);
  await pretendBalance(10n ** 8n);
  await page.waitForFunction(() => !document.querySelector('[data-testid="transfer-cta"]').disabled, null, { timeout: 30000 });
  assert.equal(await page.textContent(tid('transfer-cta')), `Transfer ${MINE}`);
  await primaryInSight(tid('transfer-cta'));
  await shots('08-transfer');

  await answerKernel('domain_set_owner', 'setOwner', [MINE, OTHER_KEY]);
  await tapWithRealBalance('transfer-cta');
  const sheet = await readSheet();
  console.log(`# transfer sheet: ${JSON.stringify(sheet)}`);
  await shots('09-transfer-consent');
  const asked = await page.evaluate(() => window.__asked);
  assert.deepEqual(asked, [`role=user,action=domain_set_owner,cid=af4550f1f8a6051ffeffea06e0cb978f8076fdfc2101d2273d4e62c86540bc5e,name=${MINE},pkOwner=${OTHER_KEY}`], 'the key as pasted, lower-cased');
  assert.equal(sheet.title, 'Confirm the transfer');
  assert.equal(sheet.pay, null);
  assert.equal(sheet.get, null);
  assert.equal(sheet.fee, '0.011 BEAM');
  assert.deepEqual(sheet.extras, [['Name', `${MINE}.beam`], ['New owner', '72e3 68c0 … 570d 51ef']]);
  assert.match(sheet.warn, /^This can't be undone\. Only the new owner can give campfire-test back\./);
  assert.match(sheet.short, /^Not enough BEAM\. You need 0\.011 BEAM for the network fee\./);
  assert.equal(sheet.approve, null);
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(`${tid('transfer-msg')}[data-code="rejected"]`, { timeout: 30000 });
  assert.equal((await lastConsent()).decision, 'rejected');
  await realCalls();
});

test('the transfer’s approve sheet when the wallet can pay: the button waits for the tick (pictures and the rule)', { timeout: 5 * 60000 }, async () => {
  // The engine reports "not enough" for this empty wallet, so the sheet is shown with a request
  // as the engine reports it for a wallet that can pay (and the screens see a balance); nothing is behind it.
  await pretendBalance(10n ** 8n);
  const p = page.evaluate(async ([name, check]) => {
    const { app } = await import('./app.js');
    const { presentConsent } = await import('./screens/consent.js');
    return presentConsent(app, {
      id: 'x', kind: 'contract', native: true, appName: 'BEAM Campfire', isEnough: true, fee: 1100000n, feeText: '0.011', spends: [], receives: [],
      intent: { action: 'nameTransfer', name, rows: [['Name', `${name}.beam`], ['New owner', check]], warn: `This can't be undone. Only the new owner can give ${name} back.`, ack: 'I checked all 16 characters with the new owner' },
    });
  }, [MINE, '72e3 68c0 … 570d 51ef']);
  await page.waitForSelector(tid('consent-ack'));
  const sheet = await readSheet();
  assert.equal(sheet.approve, `Transfer ${MINE}`);
  assert.equal(sheet.approveDisabled, true, 'not before the tick');
  assert.equal(sheet.ack, 'I checked all 16 characters with the new owner');
  await shots('10-transfer-consent-tick');
  await page.click(tid('consent-ack-box'));
  assert.equal(await page.isDisabled(tid('consent-approve')), false);
  await page.click(tid('consent-cancel'));
  assert.equal(await p, false);
  await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    if (wallet.__realRefresh) {
      wallet.refreshStatus = wallet.__realRefresh;
      wallet.__realRefresh = null;
    }
    for (const k of [...wallet.state.totals.keys()]) wallet.state.totals.delete(k);
    await wallet.refreshStatus();
  });
});

test('sell and stop selling: the listing’s words, the shader’s kernel through the engine’s approve sheet; Cancel', { timeout: 10 * 60000 }, async () => {
  await page.evaluate((n) => window.__campfire.go('nameDetail', { name: n }), MINE);
  await page.waitForSelector(tid('name-sell'), { timeout: 60000 });
  await page.click(tid('name-sell'));
  await waitScreen(page, 'nameSell');
  assert.match(await page.textContent(tid('sell-lead')), /^Anyone can buy campfire-test\.beam at once at the price you set, without asking you\./);
  await page.fill(tid('sell-amount'), '0');
  assert.equal(await page.textContent(tid('sell-amount-error')), 'The price must be more than zero.');
  await page.fill(tid('sell-amount'), '500');
  await pretendBalance(10n ** 8n);
  await page.waitForFunction(() => !document.querySelector('[data-testid="sell-cta"]').disabled, null, { timeout: 30000 });
  assert.equal(await page.textContent(tid('sell-cta')), `List ${MINE} for 500 BEAM`);
  await page.waitForFunction(() => /until about/.test(document.querySelector('[data-testid="sell-buyer-gets"]').textContent), null, { timeout: 60000 });
  assert.match(await page.textContent(tid('sell-buyer-gets')), /^campfire-test until about /);
  await primaryInSight(tid('sell-cta'));
  await shots('11-sell');
  await answerKernel('domain_set_price', 'setPriceText', [MINE, 0, '50000000000']);
  await tapWithRealBalance('sell-cta');
  let sheet = await readSheet();
  console.log(`# sell sheet: ${JSON.stringify(sheet)}`);
  await shots('12-sell-consent');
  assert.equal(sheet.title, 'Confirm the listing');
  assert.deepEqual(sheet.extras.slice(0, 2), [['Name', `${MINE}.beam`], ['Price', '500 BEAM']]);
  assert.match(sheet.notes[0], /^Anyone can buy campfire-test at this price at any moment/);
  assert.equal(sheet.fee, '0.011 BEAM');
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(`${tid('sell-msg')}[data-code="rejected"]`, { timeout: 30000 });
  await realCalls();

  // Listed: the name's screen offers Stop selling, which goes straight to the approve sheet.
  await pretendOwner({ listedAt: 50000000000n });
  await page.evaluate((n) => window.__campfire.go('nameDetail', { name: n }), MINE);
  await page.waitForSelector(tid('name-unlist'), { timeout: 60000 });
  assert.equal(await page.textContent(tid('name-price')), '500 BEAM');
  await shots('13-detail-listed');
  await answerKernel('domain_set_price', 'setPriceText', [MINE, 0, '0']);
  await page.click(tid('name-unlist'));
  sheet = await readSheet();
  console.log(`# stop-selling sheet: ${JSON.stringify(sheet)}`);
  assert.equal(sheet.title, 'Stop selling');
  assert.deepEqual(sheet.extras, [['Name', `${MINE}.beam`], ['Price', 'Not for sale']]);
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(`${tid('name-msg')}[data-code="rejected"]`, { timeout: 30000 });
  await realCalls();
});

test('money waiting for my names: the Home line; a claim of nothing is the shader’s own answer; a claim reaches the approve sheet', { timeout: 10 * 60000 }, async () => {
  // What waits (answered by the test): 2.5 BEAM paid to campfire-test.beam and 1,000 FOMO.
  await page.evaluate(async (name) => {
    const { bans } = await import('./screens/names.js');
    const { nameInbox } = await import('./screens/names_claim.js');
    const { app } = await import('./app.js');
    const { setNamesHint } = await import('./screens/names_claim.js');
    const svc = bans();
    svc.inbox = async () => ({ domains: [{ name }], saleProceeds: [], payments: [{ oneTimeKey: '3c'.repeat(32) + '01', assetId: 0, amount: 250000000n, name }, { oneTimeKey: '3d'.repeat(32) + '01', assetId: 174, amount: 100000000000n, name }] });
    await setNamesHint(app, true);
    await nameInbox().refresh({ force: true });
  }, MINE);
  await page.evaluate(() => window.__campfire.go('home'));
  await page.waitForSelector(tid('names-home-line'), { timeout: 60000 });
  await page.evaluate(() => document.fonts.ready);
  const line = await page.textContent(tid('names-home-line'));
  console.log(`# Home line: ${line}`);
  assert.match(line, /^Sent to your name campfire-test\.beam: 2\.5 BEAM \+ 1,000 FOMOClaim$/);
  const overflow = await page.evaluate(() => Math.max(0, document.scrollingElement.scrollHeight - window.innerHeight));
  console.log(`# Home overflow at 390x844 with the line: ${overflow}`);
  await shots('14-home-line');

  // The real engine and shader: nothing waits for this wallet.
  await page.click(tid('names-home-claim'));
  await page.waitForSelector(tid('names-home-msg'), { timeout: 120000 });
  assert.equal(await page.textContent(tid('names-home-msg')), 'There is nothing waiting to be claimed.');
  assert.equal(await page.getAttribute(tid('names-home-msg'), 'data-code'), 'refused');
  await shots('15-home-claim-nothing');

  // As the shader builds the claim for the two payments: two vault withdrawals, the fee fixed in each kernel.
  const vault = await page.evaluate(async () => (await (await import('./screens/names.js')).bans().params()).vaultCid);
  const h0 = await page.evaluate(() => window.__campfire.height());
  await answerKernel('receive_all', 'claim', [vault, h0, `${'3c'.repeat(32)}01`, [{ aid: 0, amount: '250000000' }, { aid: 174, amount: '100000000000' }]]);
  await page.click(tid('names-home-claim'));
  const sheet = await readSheet();
  console.log(`# claim sheet: ${JSON.stringify(sheet)}`);
  await shots('16-claim-consent');
  assert.equal(sheet.title, 'Confirm your claim');
  assert.equal(sheet.pay, null);
  assert.equal(sheet.get, '2.5 BEAM');
  assert.equal(sheet.fee, '0.022 BEAM', 'two kernels, 0.011 each, as fixed in them');
  assert.deepEqual(sheet.extras, [['Sent to', `${MINE}.beam`], ['Your balance changes by', '+2.478 BEAM, +1,000 FOMO']]);
  assert.match(sheet.notes.join(' '), /Pays its own fee/);
  assert.match(sheet.notes.join(' '), /can be linked on the blockchain/);
  assert.equal(sheet.approve, 'Claim all', 'the BEAM claimed pays the fee: an empty wallet can claim');
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(`${tid('names-home-msg')}[data-code="rejected"]`, { timeout: 30000 });
  assert.equal(await page.textContent(tid('names-home-msg')), 'Cancelled. Nothing was claimed; it is still waiting for you.');
  const last = await lastConsent();
  console.log(`# consent log: ${JSON.stringify(last)}`);
  assert.equal(last.decision, 'rejected');
  assert.deepEqual(last.receives, [{ assetId: 0, amount: '2.5' }, { assetId: 174, amount: '1000' }]);
  assert.deepEqual(last.spends, []);
  await realCalls();

  // The same money on the Names screen, with Claim one tap away.
  await page.click(tid('names'));
  await waitScreen(page, 'names');
  await page.waitForSelector(tid('names-money'), { timeout: 60000 });
  assert.equal(await page.textContent(tid('names-money-title')), 'People paid your names: 2.5 BEAM + 1,000 FOMO is waiting');
  await shots('17-names-money');
});

test('nothing was sent; nothing left waiting; only this origin and the node', async () => {
  // The last test's declined claim ends its contract call a moment after its sheet closes: give the engine up
  // to 10 s to finish it, so "nothing left waiting" is the settled state, not a race with the previous test.
  await page.waitForFunction(() => window.__campfire.contracts().inflight === 0, null, { timeout: 10000 }).catch(() => {});
  const truth = await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const txs = await wallet.session.call('tx_list', { count: 100, skip: 0 });
    const st = await wallet.session.call('wallet_status', { nz_totals: true });
    return { txs: txs.length, available: String(st.available), contracts: window.__campfire.contracts() };
  });
  console.log(`# engine at the end: ${JSON.stringify(truth)}`);
  assert.equal(truth.txs, 0);
  assert.equal(truth.available, '0');
  assert.equal(truth.contracts.consents, 0);
  assert.equal(truth.contracts.inflight, 0);
  assert.deepEqual(foreignHosts(rec, srv.url), []);
  assert.deepEqual(rec.csp, []);
  assert.deepEqual(rec.errors, []);
});

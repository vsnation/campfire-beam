// Your own token, end to end: the installed Google Chrome (headless), the dev server, BEAM
// mainnet. Spends nothing: a throwaway wallet that holds nothing, and no approve button is ever
// pressed (there is none: the engine knows the wallet cannot pay).
//
//   npm run e2e:minter   (its own build folder and port 8930, so it runs beside other suites)
//
// Create a token reads the Minter's issuance fee from mainnet and builds the real create_token
// with the pinned shader; burns are built by the real BlackHole shader. To reach the approve
// sheet the screens are shown a balance the wallet does not have (the page's state only); the
// engine still knows the truth and the sheet must show its figures. Mint more needs a token this
// wallet created, which a throwaway cannot have, so for it the Minter's answers (view_owned,
// view_token) and the bytes its shader would build are given in the page, as the desktop's
// recordings show them. The real Minter with a wallet that owns tokens: npm run
// e2e:live:minter (read-only, a copy of a funded test wallet).
//
// Screenshots go to CAMPFIRE_SHOTS (390x844, light and dark; the forms also at 375x667).
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, shot, waitScreen, foreignHosts, sleep, SHOTS, PWA } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';

const PORT = Number(process.env.E2E_PORT || 8930);
const PASSWORD = `minter-${Math.random().toString(36).slice(2, 10)}`;
const tid = (id) => `[data-testid="${id}"]`;
const META = 'STD:SCH_VER=1;N=Campfire build check;SN=CFBC;UN=CFBC;NTHUN=groth;NTH_RATIO=100000000;OPT_SHORT_DESC=Built and decoded by a test, never sent.;OPT_COLOR=#25C2A0';

let tmp, srv, browser, ctx, page, rec;

async function shots(name, { small = false } = {}) {
  const sizes = small ? [[390, 844, 'phone'], [375, 667, 'se']] : [[390, 844, 'phone']];
  for (const [w, hgt, tag] of sizes) {
    for (const scheme of ['light', 'dark']) {
      await page.setViewportSize({ width: w, height: hgt });
      await page.emulateMedia({ colorScheme: scheme });
      await sleep(200);
      await shot(page, `minter-${name}-${tag}-${scheme}`);
    }
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: 'light' });
}

/** The primary button is on screen without scrolling on a 375x667 phone. */
async function ctaInView(testid) {
  await page.setViewportSize({ width: 375, height: 667 });
  await page.evaluate(() => window.scrollTo(0, 0));
  await sleep(150);
  const box = await page.$eval(tid(testid), (el) => {
    const r = el.getBoundingClientRect();
    return { top: r.top, bottom: r.bottom, h: window.innerHeight };
  });
  await page.setViewportSize({ width: 390, height: 844 });
  assert.ok(box.top >= 0 && box.bottom <= box.h, `${testid} at ${JSON.stringify(box)} on a 375x667 phone`);
}

/** The screens see `beam` groth of BEAM (and `tokens`) available; the engine still holds nothing. */
async function pretendBalance(beam, tokens = {}) {
  await page.evaluate(
    async ([gr, t]) => {
      const { wallet } = await import('./lib/wallet.js');
      if (!wallet.__realRefresh) wallet.__realRefresh = wallet.refreshStatus.bind(wallet);
      wallet.refreshStatus = async function () {
        await this.__realRefresh();
        this.state.totals.set(0, { available: BigInt(gr), receiving: 0n, sending: 0n, maturing: 0n });
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

/** Taps a button the pretended balance enabled, then shows the page the engine's truth again before the sheet opens. */
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

/** A fresh test profile is not promised its storage, so Create codes / Move first says the record is kept only here (screens/storage_warning.js): go on. */
async function passKeptHere(p = page) {
  const go = await p.waitForSelector('[data-testid="kept-here-go"]', { timeout: 5000 }).catch(() => null);
  if (go) await go.click();
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
    payLabel: (await page.$('.consent .consent-row .k')) ? (await page.textContent('.consent .consent-row .k')).trim() : null,
    pay: await text('consent-pay-0'),
    get: await text('consent-get-0'),
    fee: await text('consent-fee'),
    total: await text('consent-total'),
    note: await text('consent-intent-note'),
    short: await text('consent-not-enough'),
    add: await text('consent-receive'),
    approve: await text('consent-approve'),
  };
}

const shaderLoads = (name) => page.evaluate((n) => performance.getEntriesByType('resource').filter((e) => e.name.endsWith(`/shaders/${n}`)).length, name);

before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-minter-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, locale: 'en-GB', acceptDownloads: true });
  await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: srv.url });
  ({ page, rec } = await recordedPage(ctx, { label: 'minter' }));
  console.log(`# screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

test('Home: Tokens at the end of the dApps line, every label whole on a 360 px phone; the menu', { timeout: 15 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  await waitSynced(page);
  const row = async (w) => {
    await page.setViewportSize({ width: w, height: 844 });
    await sleep(150);
    return page.evaluate(() => {
      const r = document.querySelector('.more-entry');
      return { overflow: Math.max(0, document.scrollingElement.scrollHeight - window.innerHeight), height: Math.round(r.getBoundingClientRect().height), tiles: [...r.querySelectorAll('.tile .t')].map((t) => ({ text: t.textContent, cut: t.scrollWidth > t.clientWidth })) };
    });
  };
  for (const w of [390, 375, 360]) {
    const r = await row(w);
    console.log(`# Home at ${w}: ${JSON.stringify(r)}`);
    assert.deepEqual(r.tiles.map((t) => t.text), ['dApps', 'BEAM names', 'Airdrop codes', 'Tokens']);
    assert.deepEqual(r.tiles.filter((t) => t.cut), [], `no label cut at ${w} px`);
    assert.ok(r.height <= 64, `the line is ${r.height} px`);
    if (w === 390) assert.equal(r.overflow, 0, "an empty wallet's Home still fits a 390x844 phone");
  }
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await shaderLoads('minter_app.wasm'), 0, 'no shader before a feature needs it');
  await shots('01-home');
  await page.click(tid('tokens-entry'));
  await page.waitForSelector(tid('tokens-menu'));
  assert.deepEqual(await page.$$eval(`${tid('tokens-menu')} .row .t`, (els) => els.map((e) => e.textContent)), ['Create a token', 'My tokens', 'Burn tokens']);
  assert.deepEqual(await page.$$eval(`${tid('tokens-menu')} .row .s`, (els) => els.map((e) => e.textContent)), ['Your own asset on BEAM, named by you', 'Tokens you created: see them, mint more', 'Destroy tokens you hold, for good']);
  await shots('02-menu');
});

test("create a token: the cost from the Minter itself, the rules as you type, the review, the engine's figures on the approve sheet; Cancel sends nothing", { timeout: 10 * 60000 }, async () => {
  await page.click(tid('tokens-create'));
  await waitScreen(page, 'minterCreate');
  await page.waitForFunction(() => /BEAM$/.test(document.querySelector('[data-testid="mint-cost-dao"]')?.textContent || ''), null, { timeout: 120000 });
  const params = await page.evaluate(async () => {
    const { minter } = await import('./screens/minter.js');
    const p = await minter().params();
    return { issueFee: String(p.issueFee), vault: p.daoVaultCid };
  });
  console.log(`# view_params on mainnet: ${JSON.stringify(params)}`);
  assert.equal(params.issueFee, '5000000000', 'the Minter asks 50 BEAM (read, not assumed)');
  assert.equal(await page.textContent(tid('mint-cost-dao')), '50 BEAM');
  assert.equal(await page.textContent(tid('mint-cost-deposit')), '10 BEAM');
  assert.equal(await page.textContent(tid('mint-cost-fee')), '0.0167 BEAM');
  assert.equal(await page.textContent(tid('mint-cost-total')), '60.0167 BEAM');
  assert.equal(await page.isDisabled(tid('mint-cta')), true);
  assert.equal(await page.textContent(tid('mint-reason')), 'Give your token a name and a ticker.');
  await ctaInView('mint-cta');
  await shots('03-create-empty', { small: true });

  // The rules, as the desktop and BEAM's wallet core read them, said under each field.
  await page.fill(tid('mint-name'), 'Bad;Name');
  await page.fill(tid('mint-ticker'), 'toolongx');
  assert.equal(await page.inputValue(tid('mint-ticker')), 'TOOLONGX', 'upper case as typed');
  await page.fill(tid('mint-supply'), '1.5');
  await page.fill(tid('mint-color'), 'red');
  await page.fill(tid('mint-site'), 'www.example.org');
  assert.equal(await page.textContent(tid('mint-name-hint')), 'Name can use English letters, digits, spaces and . , - _ only.');
  assert.equal(await page.textContent(tid('mint-ticker-hint')), 'Ticker can be at most 6 characters.');
  assert.equal(await page.textContent(tid('mint-supply-hint')), 'Enter a whole number above zero, like 1000000');
  assert.equal(await page.textContent(tid('mint-color-hint')), 'Use a colour like #25C2A0.');
  assert.match(await page.textContent(tid('mint-site-hint')), /^Use a full web address that starts with https/);
  assert.equal(await page.isDisabled(tid('mint-cta')), true);
  await page.click(tid('mint-more'));
  await page.fill(tid('mint-nth'), '');
  assert.equal(await page.textContent(tid('mint-nth-hint')), 'Smallest unit name cannot be empty or start or end with a space.');
  await shots('04-create-rules');
  // A name or ticker that copies a verified asset is marked as other wallets will mark it.
  await page.fill(tid('mint-name'), 'My token');
  await page.fill(tid('mint-ticker'), 'fomo');
  await page.waitForFunction(() => /Not the verified FOMO/.test(document.querySelector('[data-testid="mint-copies-box"]').textContent));

  await page.fill(tid('mint-name'), 'Campfire build check');
  await page.fill(tid('mint-ticker'), 'cfbc');
  await page.fill(tid('mint-supply'), '1,000');
  await page.fill(tid('mint-short-desc'), 'Built and decoded by a test, never sent.');
  await page.fill(tid('mint-color'), '#25c2a0');
  await page.fill(tid('mint-site'), '');
  await page.fill(tid('mint-nth'), 'groth');
  await page.click(tid('mint-more'));
  assert.equal(await page.textContent(tid('mint-copies-box')), '');
  assert.equal(await page.textContent(tid('mint-supply-hint')), 'At most 1,000 CFBC can ever exist');
  assert.equal(await page.textContent(tid('mint-cta')), 'Create CFBC');
  assert.equal(await page.isDisabled(tid('mint-cta')), true);
  assert.match(await page.textContent(tid('mint-reason')), /^Creating a token needs 60\.0167 BEAM, and this wallet has 0 BEAM\. Receive BEAM$/);
  await shots('05-create-not-enough', { small: true });

  await pretendBalance(10000000000n); // 100 BEAM on screen only
  await page.waitForFunction(() => !document.querySelector('[data-testid="mint-cta"]').disabled, null, { timeout: 30000 });
  await page.click(tid('mint-cta'));
  await page.waitForSelector(tid('review-cta'));
  assert.equal(await page.textContent(tid('review-name')), 'Campfire build check');
  assert.equal(await page.textContent(tid('review-ticker')), 'CFBC · new token');
  assert.equal(await page.textContent(tid('review-supply')), '1,000 CFBC');
  assert.equal(await page.textContent(tid('review-color')), '#25C2A0');
  assert.equal(await page.textContent(tid('review-dao')), '50 BEAM');
  assert.equal(await page.textContent(tid('review-total')), '60.0167 BEAM');
  assert.equal(await page.textContent(tid('review-cta')), 'Create CFBC for 60.0167 BEAM');
  await page.click(tid('review-show-metadata'));
  assert.equal(await page.textContent(tid('review-metadata')), META, 'exactly what goes on the chain');
  await ctaInView('review-cta');
  await shots('06-review', { small: true });
  // Back keeps what was typed.
  await page.click('button[aria-label="Back"]');
  await page.waitForSelector(tid('mint-cta'));
  assert.equal(await page.inputValue(tid('mint-name')), 'Campfire build check');
  await page.click(tid('mint-cta'));
  await page.waitForSelector(tid('review-cta'));

  await tapWithRealBalance('review-cta', 2);
  const sheet = await readSheet();
  console.log(`# create sheet: ${JSON.stringify(sheet)}`);
  await shots('07-create-consent');
  assert.equal(sheet.title, 'Confirm your new token');
  assert.match(sheet.app, /Beam PWA/);
  assert.equal(sheet.pay, '60 BEAM');
  assert.equal(sheet.fee, '0.0167 BEAM', "the engine's fee for create_token's declared charge");
  assert.equal(sheet.total, '60.0167 BEAM');
  assert.equal(sheet.note, '60 BEAM do not come back. 50 BEAM go to the BEAM DAO as the issuance fee and 10 BEAM stay locked with the token, even if you never mint it.');
  assert.match(sheet.short, /^Not enough BEAM\. You need 60\.0167 BEAM, including the 0\.0167 BEAM network fee\. You have 0\./);
  assert.equal(sheet.approve, null, 'no approve button when the engine says it is not enough');
  assert.equal((await page.$$(tid('consent'))).length, 1, 'a double tap opens one sheet');
  const busy = await page.evaluate(async () => {
    const { minter } = await import('./screens/minter.js');
    return minter()
      .createToken({ metadata: 'STD:SCH_VER=1;N=A;SN=A;UN=A;NTHUN=groth;NTH_RATIO=100000000', limit: 1n })
      .then(() => 'went through', (e) => e.code);
  });
  assert.equal(busy, 'busy', 'a second token cannot be prepared while one waits on the sheet');

  await page.click(tid('consent-cancel'));
  await page.waitForSelector(`${tid('review-result')}[data-code="rejected"]`, { timeout: 30000 });
  assert.equal(await page.textContent(tid('review-result')), 'Cancelled. Nothing was sent.');
  await shots('08-create-cancelled');
  const last = await lastConsent();
  console.log(`# consent log: ${JSON.stringify(last)}`);
  assert.equal(last.decision, 'rejected');
  assert.equal(last.fee, '0.0167');
  assert.equal(last.isEnough, false);
  assert.deepEqual(last.spends, [{ assetId: 0, amount: '60' }]);
  assert.deepEqual(last.receives, []);
  assert.deepEqual(await engineTruth(), { allTxs: 0, available: '0' });
  assert.equal(await shaderLoads('minter_app.wasm'), 1, 'the Minter shader loads once, when needed');
});

test('My tokens: the empty list, from the Minter itself', { timeout: 5 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('minterTokens'));
  await waitScreen(page, 'minterTokens');
  await page.waitForSelector(tid('tokens-empty'), { timeout: 120000 });
  assert.match(await page.textContent(tid('tokens-empty')), /You haven't created a token yet/);
  await ctaInView('tokens-create');
  await shots('09-my-tokens-empty');
});

test('My tokens, a token page and Mint more with the Minter answering for a token this wallet created (given in the page); the approve sheet; Cancel', { timeout: 10 * 60000 }, async () => {
  // view_owned / view_token as the Minter answers for its owner, CTO #44's real metadata; and
  // the bytes the shader builds for withdraw (method 4, aid + value, the owner's key, no charge).
  await page.evaluate(async () => {
    const { minter } = await import('./screens/minter.js');
    const { nativeApp } = await import('./lib/contracts.js');
    const { MINTER_CID, METHOD, KERNEL } = await import('./lib/minter.js');
    const { app } = await import('./app.js');
    const svc = minter();
    const meta = 'STD:SCH_VER=1;N=CTO;UN=CTO;SN=CTO;NTHUN=groth;NTH_RATIO=100000000;OPT_SHORT_DESC=CTO';
    const tok = { assetId: 44, minted: 25000000000000n, limit: 100000000000000n, mintable: 75000000000000n, isOwner: true, ownerKey: '5a'.repeat(32) + '00', ownerCid: null, metadata: meta };
    const big = { assetId: 186, minted: 1000000000000000n, limit: (1n << 128n) - 1n, mintable: (1n << 128n) - 1n - 1000000000000000n, isOwner: true, ownerKey: '5a'.repeat(32) + '00', ownerCid: null, metadata: null };
    const native = await nativeApp();
    window.__stubs = { owned: svc.owned, token: svc.token, call: native.call, args: [] };
    svc.owned = async () => [tok, big];
    svc.token = async (id) => (id === 44 ? tok : id === 186 ? big : null);
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
    const le = (v, n) => Array.from({ length: n }, (_, i) => Number((BigInt(v) >> BigInt(8 * i)) & 0xffn));
    const hex = (s) => s.match(/../g).map((x) => parseInt(x, 16));
    const buf = (b) => [...u(b.length), ...b];
    const enc = (s) => [...new TextEncoder().encode(s)];
    const real = native.call.bind(native);
    native.call = (method, params, opts) => {
      if (method === 'invoke_contract' && /action=withdraw/.test(params.args)) {
        window.__stubs.args.push(params.args);
        const aid = Number(/aid=(\d+)/.exec(params.args)[1]);
        const value = BigInt(/value=(\d+)/.exec(params.args)[1]);
        const raw = [...u(1), ...u(METHOD.withdraw), ...buf([...le(aid, 4), ...le(value, 8)]), ...u(1), ...Array(32).fill(0x11), ...u(0), ...buf(enc(KERNEL.mint)), ...u(1), ...u(aid), ...sgn(-value), ...hex(MINTER_CID)];
        return Promise.resolve({ output: '{}', raw_data: raw });
      }
      return real(method, params, opts);
    };
    // A token created in this session and still waiting for the network.
    app.minterPending = [{ txId: 'f0'.repeat(16), ticker: 'CFBC', name: 'Campfire build check', at: Date.now() }];
  });
  await page.evaluate(() => window.__campfire.go('minterTokens'));
  await waitScreen(page, 'minterTokens');
  await page.waitForSelector(`${tid('token-card')}[data-asset-id="44"]`, { timeout: 60000 });
  const cards = await page.$$eval(tid('token-card'), (els) => els.map((e) => ({ id: e.dataset.assetId, name: e.querySelector('[data-testid="token-title-name"]').textContent, minted: e.querySelector('[data-testid="token-minted"]').textContent })));
  console.log(`# my tokens: ${JSON.stringify(cards)}`);
  assert.deepEqual(cards, [
    { id: '44', name: 'CTO', minted: 'Minted 250,000 of 1,000,000 CTO #44' },
    { id: '186', name: 'Giga', minted: 'Minted 10,000,000 GIGA · no maximum' },
  ]);
  assert.match(await page.textContent(tid('token-pending')), /CFBC is being created\. It shows here once the network confirms it/);
  await shots('10-my-tokens');

  await page.click(tid('token-open-44'));
  await waitScreen(page, 'minterToken');
  await page.waitForSelector(tid('token-facts'));
  assert.equal(await page.textContent(tid('token-minted')), '250,000 CTO #44');
  assert.equal(await page.textContent(tid('token-limit')), '1,000,000 CTO #44');
  assert.equal(await page.textContent(tid('token-mintable')), '750,000 CTO #44');
  assert.equal(await page.textContent(tid('token-held')), '0 CTO #44');
  assert.equal(await page.textContent(tid('token-owner')), 'This wallet');
  assert.equal(await page.textContent(tid('token-desc')), 'CTO');
  assert.equal(await page.$(tid('token-burn')), null, 'nothing held, nothing to burn');
  await ctaInView('token-mint');
  await shots('11-token-page');

  await page.click(tid('token-mint'));
  await waitScreen(page, 'minterMint');
  await page.waitForFunction(() => /You can still mint 750,000 CTO #44/.test(document.querySelector('.minter-mint .token-title').textContent), null, { timeout: 30000 });
  await page.fill(tid('mint-more-amount'), '1000');
  assert.equal(await page.textContent(tid('mint-more-cta')), 'Mint 1,000 CTO #44');
  assert.equal(await page.textContent(tid('mint-more-fee')), '0.011 BEAM');
  assert.equal(await page.isDisabled(tid('mint-more-cta')), true);
  assert.match(await page.textContent(tid('mint-more-reason')), /^The network fee is paid in BEAM: 0\.011 BEAM\. You have 0 BEAM\./);
  await page.click(tid('mint-more-most'));
  assert.equal(await page.inputValue(tid('mint-more-amount')), '750000');
  await page.fill(tid('mint-more-amount'), '750000.00000001');
  assert.equal(await page.textContent(tid('mint-more-hint')), 'At most 750,000 CTO #44');
  await page.fill(tid('mint-more-amount'), '1000');
  await pretendBalance(100000000n);
  await page.waitForFunction(() => !document.querySelector('[data-testid="mint-more-cta"]').disabled, null, { timeout: 30000 });
  await ctaInView('mint-more-cta');
  await shots('12-mint-more', { small: true });
  await tapWithRealBalance('mint-more-cta');
  const sheet = await readSheet();
  console.log(`# mint sheet: ${JSON.stringify(sheet)}`);
  await shots('13-mint-consent');
  const sent = await page.evaluate(() => window.__stubs.args);
  assert.deepEqual(sent, ['action=withdraw,cid=295fe749dc12c55213d1bd16ced174dc8780c020f59cb17749e900bb0c15d868,aid=44,value=100000000000']);
  assert.equal(sheet.title, 'Confirm the mint');
  assert.equal(sheet.get, '1,000 CTO #44');
  assert.equal(sheet.pay, null);
  assert.equal(sheet.fee, '0.011 BEAM');
  assert.match(sheet.short, /^Not enough BEAM\. You need 0\.011 BEAM for the network fee\. You have 0\./);
  assert.equal(sheet.approve, null);
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(`${tid('mint-more-result')}[data-code="rejected"]`, { timeout: 30000 });
  assert.equal(await page.textContent(tid('mint-more-result')), 'Cancelled. Nothing was sent.');
  const last = await lastConsent();
  assert.equal(last.decision, 'rejected');
  assert.equal(last.fee, '0.011');
  assert.deepEqual(last.receives, [{ assetId: 44, amount: '1000' }]);
  assert.deepEqual(last.spends, []);
  assert.deepEqual(await engineTruth(), { allTxs: 0, available: '0' });

  // No maximum: the page and Mint more say so.
  await page.evaluate(() => window.__campfire.go('minterMint', { assetId: 186 }));
  await page.waitForFunction(() => /No maximum: mint as much as you like/.test(document.querySelector('.minter-mint .token-title')?.textContent || ''), null, { timeout: 30000 });
  await page.evaluate(async () => {
    const { minter } = await import('./screens/minter.js');
    const { nativeApp } = await import('./lib/contracts.js');
    const svc = minter();
    svc.owned = window.__stubs.owned;
    svc.token = window.__stubs.token;
    (await nativeApp()).call = window.__stubs.call;
    const { app } = await import('./app.js');
    app.minterPending = null;
  });
  await realBalance();
});

test("burn: the BlackHole's own build for a token shown as held, typed confirmation, the approve sheet; Cancel; BEAM never", { timeout: 10 * 60000 }, async () => {
  await pretendBalance(100000000n, { 44: 500000000n });
  await page.evaluate(() => window.__campfire.go('burn', { assetId: 44 }));
  await waitScreen(page, 'burn');
  assert.match(await page.textContent(tid('burn-intro')), /^Burning cannot be undone\. Burned tokens are destroyed for good/);
  assert.match(await page.textContent(tid('burn-token')), /CTO.*You have 5 CTO #44/);
  await page.fill(tid('burn-amount'), '6');
  assert.equal(await page.textContent(tid('burn-hint')), 'You have 5 CTO #44');
  assert.equal(await page.isDisabled(tid('burn-cta')), true);
  await page.click(tid('burn-all'));
  assert.equal(await page.inputValue(tid('burn-amount')), '5');
  await page.fill(tid('burn-amount'), '2');
  assert.equal(await page.textContent(tid('burn-cta')), 'Burn 2 CTO #44');
  assert.equal(await page.textContent(tid('burn-fee')), '0.011 BEAM');
  await ctaInView('burn-cta');
  await shots('14-burn', { small: true });
  await page.click(tid('burn-cta'));
  await page.waitForSelector(tid('burn-warning'));
  assert.equal(await page.textContent(tid('burn-warning')), 'This destroys 2 CTO #44 forever. Nobody can undo it: not you, not the token creator, not us. The tokens are locked in a contract that has no way to give anything back.');
  assert.equal(await page.textContent(tid('burn-confirm-amount')), '2 CTO #44');
  assert.equal(await page.isDisabled(tid('burn-confirm-cta')), true);
  assert.equal(await page.textContent(tid('burn-confirm-reason')), 'Type CTO above to confirm.');
  await page.fill(tid('burn-type'), 'ct');
  assert.equal(await page.isDisabled(tid('burn-confirm-cta')), true);
  await page.fill(tid('burn-type'), 'cto');
  assert.equal(await page.isDisabled(tid('burn-confirm-cta')), false);
  assert.equal(await page.textContent(tid('burn-confirm-cta')), 'Burn 2 CTO #44 forever');
  await ctaInView('burn-confirm-cta');
  await shots('15-burn-confirm', { small: true });

  await tapWithRealBalance('burn-confirm-cta');
  const sheet = await readSheet();
  console.log(`# burn sheet: ${JSON.stringify(sheet)}`);
  await shots('16-burn-consent');
  assert.equal(sheet.title, 'Burn for good');
  assert.equal(sheet.payLabel, 'Destroyed for good');
  assert.equal(sheet.pay, '2 CTO #44');
  assert.equal(sheet.fee, '0.011 BEAM');
  assert.equal(sheet.note, 'Nobody can undo this. The tokens are locked in a contract that has no way to give anything back.');
  assert.match(sheet.short, /^Not enough CTO #44\. You need 2 CTO #44\. You have 0\./);
  assert.equal(sheet.approve, null);
  await pretendBalance(100000000n, { 44: 500000000n });
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(`${tid('burn-confirm-result')}[data-code="rejected"]`, { timeout: 30000 });
  assert.equal(await page.textContent(tid('burn-confirm-result')), 'Cancelled. Nothing was sent.');
  assert.equal(await page.inputValue(tid('burn-type')), 'cto', 'what was typed stays after Cancel');
  const last = await lastConsent();
  console.log(`# consent log: ${JSON.stringify(last)}`);
  assert.equal(last.decision, 'rejected');
  assert.equal(last.fee, '0.011');
  assert.deepEqual(last.spends, [{ assetId: 44, amount: '2' }]);
  assert.deepEqual(last.receives, []);
  assert.equal(await shaderLoads('blackhole_app.wasm'), 1);
  const refusals = await page.evaluate(async () => {
    const { burner } = await import('./screens/minter.js');
    const b = burner();
    const beam = await b.burn({ assetId: 0, amount: 1n, acknowledged: true }).then(() => 'went through', (e) => e.name);
    const unack = await b.burn({ assetId: 44, amount: 1n }).then(() => 'went through', (e) => e.code);
    return { beam, unack };
  });
  assert.deepEqual(refusals, { beam: 'RangeError', unack: 'notAcknowledged' });
  assert.deepEqual(await engineTruth(), { allTxs: 0, available: '0' });

  await realBalance();
  await page.evaluate(() => window.__campfire.go('burn'));
  await page.waitForSelector(tid('burn-empty'));
  assert.match(await page.textContent(tid('burn-empty')), /This wallet holds no tokens other than BEAM, and BEAM cannot be burned\./);
  await shots('17-burn-empty');
});

test("airdrop codes: Save as CSV gives the desktop's columns, to the share sheet where there is one, else a download", { timeout: 10 * 60000 }, async () => {
  // A batch saved on this device (its sheet cancelled: never sent, kept anyway).
  await page.evaluate(() => window.__campfire.go('airdropCreate'));
  await waitScreen(page, 'airdropCreate');
  await page.fill(tid('drop-amount'), '0.001');
  await page.fill(tid('drop-count'), '3');
  await pretendBalance(100000000n);
  await page.waitForFunction(() => !document.querySelector('[data-testid="drop-cta"]').disabled, null, { timeout: 30000 });
  await tapWithRealBalance('drop-cta');
  await passKeptHere();
  await readSheet();
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(tid('drop-result'), { timeout: 30000 });
  // Airdrop v3 shows a batch's codes only once its check has passed (codes of a batch never sent hold
  // nothing): the check is answered "ready" here, as the network would for a confirmed batch.
  const batch = await page.evaluate(async () => {
    const { app } = await import('./app.js');
    const { airdrop } = await import('./screens/airdrop.js');
    const svc = airdrop(app);
    const b = (await svc.savedBatches())[0];
    const ready = { ...b, codes: b.codes.map((c) => ({ ...c, status: 'available' })) };
    svc.verifyBatch = async () => ({ state: 'ready', batch: ready });
    return { localId: b.localId, createdAt: b.createdAt, codes: ready.codes.map((c) => ({ code: c.code, value: c.value, status: c.status })) };
  });
  await page.evaluate((id) => window.__campfire.go('airdropCodes', { localId: id }), batch.localId);
  await page.waitForSelector(tid('codes-csv'));
  assert.equal(await page.textContent(tid('codes-csv')), 'Save as CSV file');
  await ctaInView('codes-copy-all');
  await shots('18-codes-csv');

  const want = ['Number,Code,Value,Asset,Status', ...batch.codes.map((c, i) => `${i + 1},${c.code},0.001,BEAM,${c.status}`), ''].join('\r\n');
  const name = `airdrop-codes-${batch.createdAt.slice(0, 10)}-3.csv`;
  // No share sheet for files here: a download.
  await page.evaluate(() => {
    navigator.canShare = () => false;
  });
  const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 30000 }), page.click(tid('codes-csv'))]);
  assert.equal(dl.suggestedFilename(), name);
  const text = readFileSync(await dl.path(), 'utf8');
  assert.equal(text, want);
  await page.waitForSelector('.toast');
  assert.equal(await page.textContent('.toast'), `Saved ${name}. Anyone who opens it can claim the codes: keep it private.`);
  // An iPhone: the share sheet gets the file (Save to Files, AirDrop).
  await page.evaluate(() => {
    navigator.canShare = (d) => Boolean(d && d.files && d.files.length === 1);
    navigator.share = async (d) => {
      window.__shared = { title: d.title, name: d.files[0].name, type: d.files[0].type, text: await d.files[0].text() };
    };
  });
  await page.click(tid('codes-csv'));
  await page.waitForFunction(() => window.__shared, null, { timeout: 10000 });
  const shared = await page.evaluate(() => window.__shared);
  assert.deepEqual(shared, { title: 'Airdrop codes', name, type: 'text/csv', text: want });
  await realBalance();
});

// Pictures of what follows a sent transaction, which this test never sends: the services' send
// calls are replaced in the page (no engine, no signing), the screens are real.
test('after sending (the send calls replaced in the page): created, minted, burned', { timeout: 5 * 60000 }, async () => {
  await page.evaluate(async () => {
    const { minter, burner } = await import('./screens/minter.js');
    const m = minter();
    const b = burner();
    const meta = 'STD:SCH_VER=1;N=CTO;UN=CTO;SN=CTO;NTHUN=groth;NTH_RATIO=100000000;OPT_SHORT_DESC=CTO';
    const tok = { assetId: 44, minted: 25000000000000n, limit: 100000000000000n, mintable: 75000000000000n, isOwner: true, ownerKey: null, ownerCid: null, metadata: meta };
    window.__real = { createToken: m.createToken, mint: m.mint, owned: m.owned, token: m.token, burn: b.burn };
    m.createToken = async () => ({ txId: 'e0'.repeat(16) });
    m.mint = async () => ({ txId: 'e1'.repeat(16) });
    m.owned = async () => [tok];
    m.token = async (id) => (id === 44 ? tok : null);
    b.burn = async () => ({ txId: 'e2'.repeat(16) });
  });
  await pretendBalance(10000000000n, { 44: 500000000n });
  await page.evaluate(() => window.__campfire.go('minterCreate'));
  await waitScreen(page, 'minterCreate');
  await page.fill(tid('mint-name'), 'Campfire build check');
  await page.fill(tid('mint-ticker'), 'CFBC');
  await page.waitForFunction(() => !document.querySelector('[data-testid="mint-cta"]').disabled, null, { timeout: 60000 });
  await page.click(tid('mint-cta'));
  await page.click(tid('review-cta'));
  await page.waitForSelector(tid('mint-done'));
  assert.equal(await page.textContent(tid('mint-done')), 'CFBC is being created');
  await shots('19-created');
  await page.click(tid('mint-done-tokens'));
  await waitScreen(page, 'minterTokens');
  await page.waitForSelector(`${tid('token-pending')}[data-state="pending"]`);
  assert.ok(!(await page.evaluate(() => window.__campfire.backStack())).includes('minterCreate'), 'Back from My tokens skips the finished form');

  await page.click(tid('token-mint-44'));
  await waitScreen(page, 'minterMint');
  await page.fill(tid('mint-more-amount'), '1000');
  await page.waitForFunction(() => !document.querySelector('[data-testid="mint-more-cta"]').disabled, null, { timeout: 30000 });
  await page.click(tid('mint-more-cta'));
  await waitScreen(page, 'minterTokens');
  await page.waitForSelector(tid('tokens-done'));
  assert.match(await page.textContent(tid('tokens-done')), /^Mint sent\. 1,000 CTO #44 reach your wallet once the network confirms it/);
  await shots('20-minted');

  await page.evaluate(() => window.__campfire.go('burn', { assetId: 44 }));
  await waitScreen(page, 'burn');
  await page.fill(tid('burn-amount'), '1');
  await page.click(tid('burn-cta'));
  await page.fill(tid('burn-type'), 'CTO');
  await page.click(tid('burn-confirm-cta'));
  await page.waitForSelector(tid('burn-done'));
  assert.equal(await page.textContent(tid('burn-done')), '1 CTO #44 sent to be burned');
  await shots('21-burned');
  await page.evaluate(async () => {
    const { minter, burner } = await import('./screens/minter.js');
    const { app } = await import('./app.js');
    Object.assign(minter(), { createToken: window.__real.createToken, mint: window.__real.mint, owned: window.__real.owned, token: window.__real.token });
    burner().burn = window.__real.burn;
    app.minterPending = null;
  });
  await realBalance();
});

test('privacy and hygiene: only this origin and the node; no CSP violation, no page error; nothing left pending', async () => {
  const foreign = foreignHosts(rec, srv.url);
  assert.deepEqual(foreign, [], `foreign hosts: ${foreign.join(', ')}`);
  assert.deepEqual(rec.csp, []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
  const state = await page.evaluate(() => window.__campfire.contracts());
  assert.equal(state.consents, 0);
  assert.equal(state.inflight, 0);
  assert.deepEqual(await engineTruth(), { allTxs: 0, available: '0' });
});

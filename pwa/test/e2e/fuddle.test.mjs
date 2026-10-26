// Fuddle end to end: the installed Google Chrome (headless), the dev server, a throwaway mainnet
// wallet that holds nothing. Nothing is ever approved: every approve sheet is read and cancelled.
//
//   npm run e2e:fuddle   (stages the engine; port 8907, and 8908 for the build as it ships)
//
// Fuddle v9 is not deployed, so:
// - The build as it ships (FUDDLE_CID null) is checked for the gate: dApps lists Fuddle as opening
//   soon, every Fuddle screen says so, and the pinned shader is never even fetched.
// - A second build, from a copy of src/ whose lib/fuddle_id.js names the simulator's contract and
//   answer service (test/fixtures/fuddle9_sim.json), runs the real screens and the real Fuddle
//   library. Its contract calls are answered in the page with the REAL app shader's outputs and
//   built transactions from the simulator (the fixture: v9 app.wasm and contract.wasm in BEAM
//   7.5.14493's BVM, every build accepted by the contract there): a stubbed engine for Fuddle's
//   invoke_contract only. Everything after a build - the library's byte checks, the engine's
//   process_invoke_data and the approve sheet with the engine's own figures - is real.
//
// Screenshots of every screen go to CAMPFIRE_SHOTS: 390x844 and 1280x800, light and dark, Campfire
// red and BEAM (Settings -> Appearance -> Colours), named fuddle-<state>-<size>-<scheme>-<skin>.png.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, cpSync, symlinkSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, shot, waitScreen, foreignHosts, sleep, SHOTS, PWA } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';

const PORT = Number(process.env.E2E_PORT || 8907);
const PORT_GATE = PORT + 1;
const FX = JSON.parse(readFileSync(join(PWA, 'test', 'fixtures', 'fuddle9_sim.json'), 'utf8'));
const tid = (id) => `[data-testid="${id}"]`;
const PASSWORD = `fuddle-${Math.random().toString(36).slice(2, 10)}`;
const REPO = join(PWA, '..');

let tmp, srvGate, srvLive, browser;
let gate = null;
let live = null;

/** The fixture's output text of view `name`, optionally changed. */
function viewText(name, change = null) {
  if (!change) return FX.views[name].output;
  const o = JSON.parse(FX.views[name].output);
  change(o);
  return JSON.stringify(o);
}
/** view_my_games' answer for these view_game answers (AddGameShort's fields). */
function myGamesOf(...games) {
  const keys = ['idx', 'player', 'len', 'status', 'verdict', 'attempts', 'solved_at', 'deadline_h', 'refunded'];
  return JSON.stringify({ games: games.map((text) => Object.fromEntries(keys.map((k) => [k, JSON.parse(text).game[k]]))) });
}
/** The game view `name` as game `idx`. */
const gameAs = (name, idx) => viewText(name, (o) => (o.game.idx = idx));
const stockOf = (letters) =>
  viewText('my_tournament_open', (o) => {
    o.me.letters = new Array(26).fill(0);
    for (const c of letters) o.me.letters[c.charCodeAt(0) - 97]++;
  });

/** A copy of the PWA whose lib/fuddle_id.js names the simulator's contract; built into dir. */
function buildLive(dir) {
  const root = join(dir, 'live');
  mkdirSync(join(root, 'pwa'), { recursive: true });
  for (const p of ['src', 'tools', 'keys', 'deploy']) cpSync(join(PWA, p), join(root, 'pwa', p), { recursive: true });
  for (const f of ['package.json', 'engine.lock.json']) cpSync(join(PWA, f), join(root, 'pwa', f));
  symlinkSync(join(PWA, 'vendor'), join(root, 'pwa', 'vendor'));
  // tools/shader_check.mjs reads the shaders and their Dart pins from the repository around pwa/.
  symlinkSync(join(REPO, 'assets'), join(root, 'assets'));
  symlinkSync(join(REPO, 'lib'), join(root, 'lib'));
  const idFile = join(root, 'pwa', 'src', 'lib', 'fuddle_id.js');
  const src = readFileSync(idFile, 'utf8');
  const patched = src.replace('export const FUDDLE_CID = null;', `export const FUDDLE_CID = '${FX.cid}';`).replace('export const FUDDLE_SERVICE_PK = null;', `export const FUDDLE_SERVICE_PK = '${FX.service_pk}';`);
  assert.notEqual(patched, src, 'lib/fuddle_id.js has the two constants this test sets');
  writeFileSync(idFile, patched);
  execFileSync(process.execPath, [join(root, 'pwa', 'tools', 'build.mjs'), '--out', join(dir, 'dist-live'), '--quiet'], { cwd: join(root, 'pwa') });
  return join(dir, 'dist-live');
}

before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-fuddle-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist-gate'), '--quiet'], { cwd: PWA });
  const distLive = buildLive(tmp);
  srvGate = await startServer({ root: join(tmp, 'dist-gate'), port: PORT_GATE });
  srvLive = await startServer({ root: distLive, port: PORT });
  browser = await launch();
  console.log(`# screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close();
  if (srvGate) srvGate.stop();
  if (srvLive) srvLive.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

async function newPage(label) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, locale: 'en-GB', colorScheme: 'light' });
  const { page, rec } = await recordedPage(ctx, { label });
  return { ctx, page, rec };
}

/** Every screenshot of the current screen: 390x844 and 1280x800, light and dark, Campfire red and BEAM. */
async function shots(page, name) {
  for (const skin of ['campfire', 'beam']) {
    await page.evaluate(async (s) => (await import('./lib/theme.js')).applyLook({ theme: 'system', skin: s }), skin);
    for (const [w, hgt, size] of [
      [390, 844, 'phone'],
      [1280, 800, 'desktop'],
    ]) {
      for (const scheme of ['light', 'dark']) {
        await page.setViewportSize({ width: w, height: hgt });
        await page.emulateMedia({ colorScheme: scheme });
        await sleep(200);
        await shot(page, `fuddle-${name}-${size}-${scheme}-${skin}`);
      }
    }
  }
  await page.evaluate(async () => (await import('./lib/theme.js')).applyLook({ theme: 'system', skin: 'campfire' }));
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: 'light' });
}

/** The primary button is on screen without scrolling on a 375x667 phone. */
async function inView(page, testid) {
  await page.setViewportSize({ width: 375, height: 667 });
  await page.evaluate(() => window.scrollTo(0, 0));
  await sleep(150);
  const box = await page.$eval(tid(testid), (el) => {
    const r = el.getBoundingClientRect();
    return { top: r.top, bottom: r.bottom, h: window.innerHeight };
  });
  await page.setViewportSize({ width: 390, height: 844 });
  return box.top >= 0 && box.bottom <= box.h;
}

// ---------------------------------------------------------------- as it ships: the gate

test('as it ships (no contract id): dApps lists Fuddle as opening soon, its screens say so, nothing is fetched or called', { timeout: 15 * 60000 }, async () => {
  gate = await newPage('fuddle-gate');
  const { page, rec } = gate;
  await page.goto(srvGate.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  // The first install downloads and checks every file of the signed release, the shader too; from
  // here on the page itself must never ask for it.
  const before = rec.requests.length;
  await page.click(tid('open-dapps'));
  await waitScreen(page, 'dapps');
  // Paused (owner, 2026-10-14): while the contract id is unset, dApps does not list Fuddle at all.
  await page.waitForSelector(tid('dapp-list'));
  assert.equal(await page.$(tid('dapp-fuddle')), null, 'no Fuddle row while it is paused');
  assert.equal(await page.$(tid('dapp-builtin')), null);
  await shots(page, '00-dapps-no-fuddle');
  // Its screen, reached any other way (an old link), still only says it is not open.
  await page.evaluate(() => window.__campfire.go('fuddle'));
  await waitScreen(page, 'fuddle');
  await page.waitForSelector(tid('fuddle-soon'));
  assert.match(await page.textContent(tid('fuddle-soon')), /Fuddle opens soon/);
  await shots(page, '01-opens-soon');
  await page.click(tid('fuddle-soon-back'));
  await waitScreen(page, 'dapps');
  for (const [name, params] of [
    ['fuddleTournament', { tid: 0 }],
    ['fuddleGame', { tid: 0, idx: 0 }],
    ['fuddleGames', {}],
  ]) {
    await page.evaluate(([n, p]) => window.__campfire.go(n, p), [name, params]);
    await waitScreen(page, name);
    await page.waitForSelector(tid('fuddle-soon'));
  }
  assert.deepEqual(rec.requests.slice(before).filter((u) => /fuddle_app\.wasm/.test(u)), [], 'the page never loads the shader while Fuddle is not deployed');
  assert.deepEqual(await page.evaluate(() => window.__campfire.consents()), [], 'nothing asked for approval');
  assert.deepEqual(rec.errors, []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(foreignHosts(rec, srvGate.url), []);
});

// ---------------------------------------------------------------- deployed (the simulator's contract)

/** In the page: Fuddle's contract calls answered from window.__fuddle (views by action|tid|idx, builds by action). */
async function installStubs(page) {
  await page.evaluate(async (cid) => {
    const { nativeApp } = await import('./lib/contracts.js');
    const native = await nativeApp();
    const real = native.call;
    const S = (window.__fuddle = { views: {}, builds: {}, height: 0, calls: [] });
    const argsOf = (s) => Object.fromEntries(String(s).split(',').map((kv) => [kv.slice(0, kv.indexOf('=')), kv.slice(kv.indexOf('=') + 1)]));
    const BUILDS = new Set(['enter_game', 'buy_letters', 'submit_guess', 'claim_timeout', 'claim_refund', 'finalize', 'claim']);
    native.call = function (method, params, opts) {
      if (method === 'invoke_contract' && params && String(params.args).includes(`cid=${cid}`)) {
        const a = argsOf(params.args);
        S.calls.push(params.args);
        if (BUILDS.has(a.action)) {
          const b = S.builds[a.action];
          return Promise.resolve(b ? { output: '{}', raw_data: b.match(/../g).map((x) => parseInt(x, 16)) } : { output: JSON.stringify({ error: 'no build in this test' }) });
        }
        if (a.action === 'view_state') {
          const o = JSON.parse(S.views.view_state);
          o.height = S.height;
          return Promise.resolve({ output: JSON.stringify(o) });
        }
        const key = [a.action, a.tid, a.idx].filter((x) => x !== undefined).join('|');
        const v = S.views[key] !== undefined ? S.views[key] : S.views[a.action];
        return Promise.resolve({ output: v !== undefined ? v : JSON.stringify({ error: `no answer for ${key}` }) });
      }
      return real.call(native, method, params, opts);
    };
  }, FX.cid);
}

/** Sets the contract the page sees: views (key -> output text), builds (action -> raw hex), height. */
async function setChain(page, { views = {}, builds = {}, height }) {
  await page.evaluate(
    ([v, b, h]) => {
      Object.assign(window.__fuddle.views, v);
      Object.assign(window.__fuddle.builds, b);
      window.__fuddle.height = h;
    },
    [views, builds, height],
  );
}

/** The screens see these balances (groth); the engine still holds nothing. Approve sheets then show their button. */
async function pretendFunds(page, beam, tokens = {}) {
  await page.evaluate(
    async ([g, tk]) => {
      const { wallet } = await import('./lib/wallet.js');
      const { setConsentPresenter } = await import('./lib/contracts.js');
      const { presentConsent } = await import('./screens/consent.js');
      const { app } = await import('./app.js');
      if (!wallet.__realRefresh) wallet.__realRefresh = wallet.refreshStatus.bind(wallet);
      wallet.refreshStatus = async function () {
        await this.__realRefresh();
        this.state.totals.set(0, { available: BigInt(g), receiving: 0n, sending: 0n, maturing: 0n });
        for (const [id, v] of Object.entries(tk)) this.state.totals.set(Number(id), { available: BigInt(v), receiving: 0n, sending: 0n, maturing: 0n });
        this.emit();
      };
      // The engine counts this empty wallet's coins and says "not enough"; the sheets are shown as a funded wallet sees them.
      setConsentPresenter((req) => presentConsent(app, { ...req, isEnough: true }));
      await wallet.refreshStatus();
    },
    [String(beam), Object.fromEntries(Object.entries(tokens).map(([k, v]) => [k, String(v)]))],
  );
}

async function realFunds(page) {
  await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const { setConsentPresenter } = await import('./lib/contracts.js');
    const { presentConsent } = await import('./screens/consent.js');
    const { app } = await import('./app.js');
    if (wallet.__realRefresh) {
      wallet.refreshStatus = wallet.__realRefresh;
      wallet.__realRefresh = null;
    }
    for (const id of [...wallet.state.totals.keys()]) if (id !== 0) wallet.state.totals.delete(id);
    setConsentPresenter((req) => presentConsent(app, req));
    await wallet.refreshStatus();
  });
}

async function readSheet(page) {
  await page.waitForFunction(() => document.querySelector('[data-testid="consent"]') || document.querySelector('[data-testid="fuddle-note"].error'), null, { timeout: 60000 });
  const failed = await page.$('[data-testid="fuddle-note"].error');
  if (failed && !(await page.$(tid('consent')))) throw new Error(`no approve sheet: ${(await failed.textContent()).trim()}`);
  const text = async (id) => ((await page.$(tid(id))) ? (await page.textContent(tid(id))).trim() : null);
  return {
    title: (await page.textContent('.consent h2')).trim(),
    pay0: await text('consent-pay-0'),
    pay1: await text('consent-pay-1'),
    get0: await text('consent-get-0'),
    get1: await text('consent-get-1'),
    fee: await text('consent-fee'),
    extra0: await text('consent-extra-0'),
    extra1: await text('consent-extra-1'),
    extra2: await text('consent-extra-2'),
    note0: await text('consent-note-0'),
    short: await text('consent-not-enough'),
    approve: await text('consent-approve'),
  };
}

async function cancelSheet(page) {
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(tid('consent'), { state: 'detached' });
}

const go = (page, name, params = {}) => page.evaluate(([n, p]) => window.__campfire.go(n, p), [name, params]);

// The chain as the home screen sees it: a game waiting for a guess, a failed game owing a refund, two
// finished ones; tournament 0 (BEAM) and 1 (a token) taking entries, 2 not accepted by its service.
const HOME_HEIGHT = 4100030;
const HOME = {
  my_key: viewText('my_key'),
  view_state: viewText('view_state'),
  view_tournaments: JSON.stringify({ tournaments: ['tournament_beam', 'tournament_token', 'tournament_unaccepted'].map((n) => JSON.parse(viewText(n)).tournament) }),
  view_answerer: viewText('answerer'),
  'view_tournament|0': viewText('tournament_beam'),
  'view_tournament|1': viewText('tournament_token'),
  'view_tournament|2': viewText('tournament_unaccepted'),
  'view_my_tournament|0': viewText('my_tournament_open'),
  'view_my_tournament|1': viewText('my_tournament_open', (o) => {
    o.me.tid = 1;
    o.me.joined = 0;
    o.me.score = 0;
    delete o.me.prize_estimate;
  }),
  'view_my_games|0': myGamesOf(viewText('game_hinted'), viewText('game_failed_silent'), viewText('game_revealed_unsolved_six'), viewText('game_revealed_idle')),
  'view_my_games|1': JSON.stringify({ games: [] }),
  'view_game|0|0': viewText('game_hinted'),
  'view_game|0|4': viewText('game_failed_silent'),
  'view_game|0|2': viewText('game_revealed_unsolved_six'),
  'view_game|0|3': viewText('game_revealed_idle'),
  view_claimable: JSON.stringify({ claimable: [] }),
};

test('deployed (the simulator\'s contract): a new wallet, synced, with Fuddle answered from the real shader\'s outputs', { timeout: 15 * 60000 }, async () => {
  live = await newPage('fuddle-live');
  const { page } = live;
  await page.goto(srvLive.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  await waitSynced(page);
  await installStubs(page);
  await setChain(page, { views: HOME, height: HOME_HEIGHT });
});

test('dApps -> Fuddle: the game waiting for a guess first, then the tournaments with entry, pool, places and who answers', { timeout: 10 * 60000 }, async () => {
  const { page } = live;
  await go(page, 'dapps');
  await page.waitForSelector(tid('dapp-fuddle'));
  assert.match(await page.textContent(tid('dapp-fuddle-state')), /Built into Beam PWA/);
  await shots(page, '02-dapps-live');
  await page.click(tid('dapp-fuddle'));
  await waitScreen(page, 'fuddle');
  await page.waitForSelector(tid('fuddle-next'), { timeout: 60000 });
  assert.match(await page.textContent(tid('fuddle-next')), /Make your next guess within about 51 minutes/);
  assert.ok(await inView(page, 'fuddle-continue'), 'Continue your game is in sight on a 375x667 phone');
  const rows = await page.$$eval(`${tid('fuddle-tournaments')} .row`, (els) => els.map((e) => ({ id: e.dataset.testid, text: e.textContent })));
  assert.deepEqual(rows.map((r) => r.id), ['fuddle-tour-1', 'fuddle-tour-0'], 'newest first; the one its service never accepted is not listed');
  assert.match(rows[1].text, /Entry 1 BEAM · prize pool 3\.8541 BEAM/);
  assert.match(rows[1].text, /Entries close in about 5 hours · ends in about 12 hours/);
  assert.match(rows[1].text, /\d of 4 places free/);
  assert.match(rows[1].text, /Answers by the Beam PWA service/);
  const mine = await page.$$eval(`${tid('fuddle-mine')} .row`, (els) => els.map((e) => [e.dataset.testid, e.dataset.outcome, e.querySelector('.s').textContent]));
  assert.deepEqual(mine.map((m) => m[1]), ['playing', 'failed'], 'what is in play or owes money; finished games are under All your games');
  assert.match(mine[1][2], /Take back 1\.68 BEAM/);
  assert.equal(await page.$$eval('.btn-primary', (b) => b.length), 1, 'one primary button');
  await shots(page, '03-home');
});

test('a tournament: the rules from its own figures, the cost, then the entry sheet with the entry and answering fee (cancelled)', { timeout: 10 * 60000 }, async () => {
  const { page } = live;
  await setChain(page, { builds: { enter_game: FX.builds.enter_beam.raw }, height: HOME_HEIGHT });
  await go(page, 'fuddleTournament', { tid: 0 });
  await page.waitForSelector(tid('fuddle-rules'), { timeout: 60000 });
  const rules = Object.fromEntries(await page.$$eval(`${tid('fuddle-rules')} li`, (els) => els.map((e) => [e.dataset.rule, e.textContent])));
  assert.match(rules.length, /A game takes about 15–20 minutes/);
  assert.match(rules.idle, /After each hint you have about an hour to make your next guess\. If you don't, the game ends unsolved and your entry stays in the prize pool\./);
  assert.match(rules.firstGuess, /within about 40 minutes, the game ends and your entry and answering fee come back to you/);
  assert.match(rules.entriesClose, /Entries close about 7 hours before the tournament ends/);
  assert.match(rules.lettersAhead, /stops taking new games you can't start another game to use them/);
  assert.match(rules.fee, /1% of what was paid in goes to Fuddle as its fee/);
  assert.match(rules.compensation, /plus 0\.5 BEAM from its bond/);
  assert.equal(await page.getAttribute(tid('fuddle-len-5'), 'aria-checked'), 'true', '5 letters picked');
  assert.equal((await page.textContent(tid('fuddle-cost-total'))).trim(), '1.143 BEAM');
  assert.equal((await page.textContent(tid('fuddle-enter'))).trim(), 'Enter and pay 1.143 BEAM');
  await shots(page, '04-tournament');
  // An empty wallet: the reason replaces the button.
  assert.equal(await page.isDisabled(tid('fuddle-enter')), true);
  assert.match(await page.textContent(tid('fuddle-enter-reason')), /This needs 1\.143 BEAM and the wallet has 0 BEAM/);
  await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
  await shots(page, '05-tournament-empty-wallet');
  await pretendFunds(page, 500000000n);
  await page.waitForFunction(() => !document.querySelector('[data-testid="fuddle-enter"]').disabled);
  await page.click(tid('fuddle-enter'));
  const sheet = await readSheet(page);
  console.log(`# entry sheet: ${JSON.stringify(sheet)}`);
  assert.equal(sheet.title, 'Confirm your game');
  assert.equal(sheet.pay0, '1.12 BEAM', 'the entry and the answering fee, one BEAM amount');
  assert.equal(sheet.fee, '0.023 BEAM', 'the fee the declared charge sets');
  assert.equal(sheet.extra0, '1 BEAM');
  assert.equal(sheet.extra1, '0.12 BEAM');
  assert.match(sheet.note0, /you get back the entry, its letters and the answering fee, plus 0\.5 BEAM/);
  assert.equal(sheet.approve, 'Pay 1.12 BEAM and play');
  await shots(page, '06-entry-sheet');
  await cancelSheet(page);
  await page.waitForSelector(tid('fuddle-note'));
  assert.match(await page.textContent(tid('fuddle-note')), /Cancelled\. Nothing was sent\./);
  // The token tournament: the entry in its asset and the answering fee in BEAM, two amounts.
  await setChain(page, { builds: { enter_game: FX.builds.enter_token.raw }, height: HOME_HEIGHT });
  await pretendFunds(page, 500000000n, { 7: 1000000000n });
  await go(page, 'fuddleTournament', { tid: 1 });
  await page.waitForSelector(tid('fuddle-rules'), { timeout: 60000 });
  assert.deepEqual(await page.$$eval('[data-testid^="fuddle-len-"]', (els) => els.map((e) => e.dataset.testid)), ['fuddle-len-5'], 'a 5-letter tournament offers 5 letters only');
  await page.click(tid('fuddle-enter'));
  const tok = await readSheet(page);
  console.log(`# token entry sheet: ${JSON.stringify(tok)}`);
  assert.ok(tok.pay0 && tok.pay1, 'two amounts: the token and BEAM');
  assert.equal([tok.pay0, tok.pay1].find((x) => x.endsWith(' BEAM')), '0.12 BEAM');
  assert.equal(tok.fee, '0.023 BEAM');
  await shots(page, '07-entry-sheet-token');
  await cancelSheet(page);
  await realFunds(page);
});

test('a game: typed on the keyboard, the letters it buys and the fee before sending, the guess sheet (cancelled)', { timeout: 10 * 60000 }, async () => {
  const { page } = live;
  const word = Object.fromEntries(FX.builds.guess_buy_missing.args.split(',').map((kv) => kv.split('='))).guess;
  await setChain(page, { views: { 'view_game|0|0': viewText('game_your_move_fresh'), 'view_my_tournament|0': stockOf('qqxzb') }, builds: { submit_guess: FX.builds.guess_buy_missing.raw }, height: FX.views.game_your_move_fresh.height + 2 });
  await pretendFunds(page, 500000000n);
  await go(page, 'fuddleGame', { tid: 0, idx: 0 });
  await page.waitForSelector(tid('fuddle-keys'), { timeout: 60000 });
  assert.match(await page.textContent(tid('fuddle-clock')), /Make your first guess within about 38 minutes, or the game ends and your entry comes back/);
  assert.equal(await page.isDisabled(tid('fuddle-send')), true);
  assert.equal((await page.textContent(tid('fuddle-send'))).trim(), 'Type 5 more letters');
  assert.equal((await page.textContent(tid('fuddle-guess-cost'))).trim(), 'Up to 0.05 BEAM for letters · network fee 0.0166 BEAM');
  await shots(page, '08-game-first-guess');
  for (const c of word.slice(0, 3)) await page.click(`[data-key="${c}"]`);
  await page.keyboard.press(word[3].toUpperCase()); // a computer's keyboard types too
  await page.click(`[data-key="${word[4]}"]`);
  assert.equal((await page.textContent(tid('fuddle-send'))).trim(), 'Send my guess');
  assert.equal((await page.textContent(tid('fuddle-guess-cost'))).trim(), 'Buys 2 letters for 0.02 BEAM · network fee 0.0166 BEAM', 'q, x, z come from the 5 letters bought ahead');
  assert.ok(await inView(page, 'fuddle-send'), 'Send my guess is in sight on a 375x667 phone');
  await shots(page, '09-game-typed');
  await page.click(tid('fuddle-send'));
  const sheet = await readSheet(page);
  console.log(`# guess sheet: ${JSON.stringify(sheet)}`);
  assert.equal(sheet.title, 'Confirm your guess');
  assert.equal(sheet.pay0, '0.02 BEAM', 'the two letters it lacks');
  assert.equal(sheet.fee, '0.0166 BEAM');
  assert.equal(sheet.approve, `Guess ${word.toUpperCase()} and pay 0.02 BEAM for letters`);
  await shots(page, '10-guess-sheet');
  await cancelSheet(page);
  assert.match(await page.textContent(tid('fuddle-note')), /Cancelled\. Nothing was sent\./);
  // Buy letters ahead: what it costs, and why most players never need it.
  await page.click(tid('fuddle-buy'));
  await page.waitForSelector(tid('fuddle-buy-sheet'));
  assert.equal((await page.textContent(tid('fuddle-stock'))).trim(), 'You have 5 letters bought ahead here.');
  await page.fill(tid('fuddle-buy-input'), 'aeiou');
  assert.match(await page.textContent(tid('fuddle-buy-cost')), /5 letters: 0\.05 BEAM, plus a 0\.0163 BEAM network fee/);
  await shots(page, '11-buy-letters');
  await page.click('.fuddle-buy .btn-text');
  await realFunds(page);
});

test('play states: waiting for the hint, hinted, solved, not solved, stopped, the service late, failed and refunded, never played', { timeout: 15 * 60000 }, async () => {
  const { page } = live;
  const states = [
    ['12-waiting-hint', 'game_waiting_hint', 0, 'fuddle-waiting', /The answer service checks it/],
    ['13-hinted', 'game_hinted', 0, 'fuddle-clock', /Make your next guess within about (an hour|\d+ minutes), or the game ends unsolved/],
    ['14-solved', 'game_revealed_solved', 0, 'fuddle-solved', /Solved in 3 guesses\. Score 2,000\./],
    ['15-not-solved', 'game_revealed_unsolved_six', 2, 'fuddle-unsolved', /Not solved in six guesses\./],
    ['16-stopped', 'game_revealed_idle', 3, 'fuddle-stopped', /No guess came within about an hour of the last hint/],
    ['17-service-late', 'game_hint_overdue', 4, 'fuddle-late', /missed its time to answer/],
    ['18-failed', 'game_failed_silent', 4, 'fuddle-failed', /did not answer a guess in time\..*You get back 1\.68 BEAM: the entry, the letters of this game and the answering fee, plus 0\.5 BEAM compensation/],
    ['19-refunded', 'game_refunded', 4, 'fuddle-failed', /Refund taken: 1\.68 BEAM\./],
    ['20-never-played', 'game_ended_unplayed', 5, 'fuddle-unplayed', /You get back 1\.12 BEAM: the entry and the answering fee\./],
  ];
  for (const [name, view, idx, testid, words] of states) {
    await setChain(page, { views: { [`view_game|0|${idx}`]: viewText(view), 'view_my_tournament|0': viewText('my_tournament_open') }, height: FX.views[view].height });
    await go(page, 'fuddleGame', { tid: 0, idx });
    await page.waitForSelector(tid(testid), { timeout: 60000 });
    const said = (await page.textContent(tid(testid))).replace(/\s+/g, ' ');
    assert.match(said, words, `${name}: ${said}`);
    // Every hint is a colour and a mark, and is read out.
    const tiles = await page.$$eval('.grid-row.answered .tile', (els) => els.map((e) => ({ cls: e.className, label: e.getAttribute('aria-label'), mark: Boolean(e.querySelector('.mk svg')) })));
    for (const x of tiles) {
      assert.ok(x.mark, `${name}: a hint tile without its mark`);
      assert.match(x.label, /^[A-Z]: (in the word, right place|in the word, another place|not in the word)$/, `${name}: ${x.label}`);
    }
    await shots(page, name);
  }
  // Waiting for the hint: the guess is on chain, the row waits, the clock says by when.
  await setChain(page, { views: { 'view_game|0|0': viewText('game_waiting_hint') }, height: FX.views.game_waiting_hint.height });
  await go(page, 'fuddleGame', { tid: 0, idx: 0 });
  await page.waitForSelector(tid('fuddle-waiting'));
  assert.equal(await page.getAttribute(tid('fuddle-row-0'), 'data-state'), 'waiting');
  assert.match(await page.textContent(tid('fuddle-waiting')), /usually within a minute or two; it must answer within about \d+ minutes/);
  // The service late: End the game is the next step, then the refund sheet.
  await pretendFunds(page, 500000000n);
  await setChain(page, { views: { 'view_game|0|4': viewText('game_hint_overdue') }, builds: { claim_timeout: FX.builds.claim_timeout_silent.raw }, height: FX.views.game_hint_overdue.height });
  await go(page, 'fuddleGame', { tid: 0, idx: 4 });
  await page.click(tid('fuddle-end'));
  const end = await readSheet(page);
  console.log(`# end-the-game sheet: ${JSON.stringify(end)}`);
  assert.equal(end.title, 'End this game');
  assert.equal(end.pay0, null, 'it moves no money');
  assert.equal(end.fee, '0.0225 BEAM');
  assert.equal(end.approve, 'End the game');
  await shots(page, '21-end-game-sheet');
  await cancelSheet(page);
  await setChain(page, { views: { 'view_game|0|4': viewText('game_failed_silent') }, builds: { claim_refund: FX.builds.claim_refund_failed.raw }, height: FX.views.game_failed_silent.height });
  await go(page, 'fuddleGame', { tid: 0, idx: 4 });
  await page.click(tid('fuddle-refund'));
  const refund = await readSheet(page);
  console.log(`# refund sheet: ${JSON.stringify(refund)}`);
  assert.equal(refund.title, 'Confirm your refund');
  assert.equal(refund.get0, '1.68 BEAM');
  assert.equal(refund.fee, '0.0189 BEAM');
  assert.equal(refund.approve, 'Take back 1.68 BEAM');
  await shots(page, '22-refund-sheet');
  await cancelSheet(page);
  await realFunds(page);
});

test('settled: the result with every amount, the claim sheet (cancelled), and every game in one list', { timeout: 10 * 60000 }, async () => {
  const { page } = live;
  const final0 = JSON.parse(viewText('tournament_beam_final')).tournament;
  const final1 = JSON.parse(viewText('tournament_token_final')).tournament;
  await setChain(page, {
    views: {
      view_tournaments: JSON.stringify({ tournaments: [final0, final1, JSON.parse(viewText('tournament_unaccepted')).tournament] }),
      'view_tournament|0': viewText('tournament_beam_final'),
      'view_tournament|1': viewText('tournament_token_final'),
      'view_my_tournament|0': viewText('my_tournament_final'),
      'view_my_tournament|1': viewText('my_tournament_token_final'),
      view_claimable: viewText('claimable'),
    },
    builds: { claim: FX.builds.claim_beam.raw },
    height: FX.views.my_tournament_final.height,
  });
  await go(page, 'fuddle');
  await page.waitForSelector(tid('fuddle-claim-0'), { timeout: 60000 });
  assert.match(await page.textContent(tid('fuddle-claim-0')), /Collect 6\.50464 BEAM/);
  assert.ok(await page.$(tid('fuddle-none-open')), 'no tournament taking entries: said, with what comes next');
  await shots(page, '23-home-settled');
  await page.click(tid('fuddle-claim-0'));
  await waitScreen(page, 'fuddleTournament');
  await page.waitForSelector(tid('fuddle-result'), { timeout: 60000 });
  const r = async (id) => (await page.textContent(tid(id))).trim();
  assert.equal(await r('fuddle-prize'), '2.60464 BEAM', 'pool x score / total score, computed here and equal to the shader');
  assert.equal(await r('fuddle-refund-asset'), '3.04 BEAM', 'refunds not taken early');
  assert.equal(await r('fuddle-refund-beam'), '0.86 BEAM', 'answering fees and compensation');
  assert.equal(await r('fuddle-claim-fee'), '0.0142 BEAM');
  assert.equal(await r('fuddle-collect-total'), '6.50464 BEAM');
  assert.equal(await r('fuddle-collect'), 'Collect 6.50464 BEAM');
  await shots(page, '24-tournament-settled');
  await page.click(tid('fuddle-collect'));
  const claim = await readSheet(page);
  console.log(`# claim sheet: ${JSON.stringify(claim)}`);
  assert.equal(claim.title, 'Collect your payout');
  assert.equal(claim.get0, '6.50464 BEAM');
  assert.equal(claim.fee, '0.0142 BEAM');
  assert.equal(claim.approve, 'Collect 6.5 BEAM', 'an empty wallet can collect: what arrives pays the fee (the button rounds; the rows carry every digit)');
  assert.equal(claim.extra0, '2.60464 BEAM');
  await shots(page, '25-claim-sheet');
  await cancelSheet(page);
  // The token tournament pays in two assets.
  await setChain(page, { builds: { claim: FX.builds.claim_token.raw }, height: FX.views.my_tournament_final.height });
  await go(page, 'fuddleTournament', { tid: 1 });
  await page.waitForSelector(tid('fuddle-collect'), { timeout: 60000 });
  await page.click(tid('fuddle-collect'));
  const tok = await readSheet(page);
  console.log(`# token claim sheet: ${JSON.stringify(tok)}`);
  assert.ok(tok.get0 && tok.get1, 'two amounts');
  assert.equal([tok.get0, tok.get1].find((x) => x.endsWith(' BEAM')), '0.12 BEAM');
  await cancelSheet(page);
  // Every game, in one list (the home scenario's games).
  await setChain(page, { views: HOME, height: HOME_HEIGHT });
  await go(page, 'fuddleGames');
  await page.waitForSelector(tid('fuddle-games-list'), { timeout: 60000 });
  const outcomes = await page.$$eval(`${tid('fuddle-games-list')} .row`, (els) => els.map((e) => e.dataset.outcome));
  assert.deepEqual(outcomes, ['failed', 'playing', 'stopped', 'unsolved'], 'what owes money first, then what is in play, then finished games, newest first');
  await shots(page, '26-your-games');
});

test('nothing was approved or sent; no foreign host, no CSP violation, no page error', async () => {
  const { page, rec } = live;
  const consents = await page.evaluate(() => window.__campfire.consents());
  assert.ok(consents.length >= 7, `the sheets were real consent requests (${consents.length})`);
  assert.ok(consents.every((c) => c.decision !== 'approved'), JSON.stringify(consents.map((c) => c.decision)));
  const txs = await page.evaluate(async () => (await import('./lib/wallet.js')).wallet.session.call('tx_list', { count: 100, skip: 0 }));
  assert.equal(txs.length, 0, 'no transaction in the wallet');
  const calls = await page.evaluate(() => window.__fuddle.calls);
  assert.ok(calls.every((a) => a.startsWith('role=user,')), 'only the user role is ever asked');
  assert.deepEqual(rec.errors, []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(foreignHosts(rec, srvLive.url), []);
  assert.ok(rec.requests.some((u) => /shaders\/fuddle_app\.wasm/.test(u)), 'the pinned shader was loaded (and checked) from this release');
});

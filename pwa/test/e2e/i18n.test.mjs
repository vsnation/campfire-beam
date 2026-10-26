// Languages, end to end (lib/i18n.js, lang-boot.js, Settings -> Appearance -> Language). The installed
// Google Chrome (headless), its own builds and port, a throwaway mainnet wallet that holds nothing.
//
// 1. Chrome set to Russian, the release as it ships (no catalog translated yet): never asked, <html
//    lang="ru"> from the first paint, English words, only ru.json read, Settings shows "Like this
//    device" chosen with Русский under it; another language at once on the same screen; kept after a reload; like
//    this device again.
// 2. The same app built with a pseudo-Russian catalog (every text "⟦English⟧"): screen after screen,
//    every word on show must come from the catalog. What does not is listed (an English text that does
//    not go through lib/i18n.js), with a screenshot of each screen.
//
//   npm run e2e:i18n   (own build folders and port 8836; CAMPFIRE_IGNORE_NODE_CERTS=1 when BEAM's
//                       node certificates have lapsed)
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen, shot, foreignHosts, PWA, SHOTS } from './harness.mjs';
import { createWallet, waitHome, unlockWithPassword } from './flows.mjs';

const PORT = Number(process.env.CAMPFIRE_I18N_PORT || 8836);
const tid = (id) => `[data-testid="${id}"]`;
const PASSWORD = `i18n-${Math.random().toString(36).slice(2, 10)}`;

let tmp, srv, browser;

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-i18n-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  browser = await launch();
  console.log(`# screenshots: ${SHOTS}`);
});

test.after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

const htmlLang = (page) => page.evaluate(() => document.documentElement.lang);
// The shipped catalogs: what each language must show.
const CAT = (l) => JSON.parse(readFileSync(join(PWA, 'src', 'i18n', `${l}.json`), 'utf8'));
const RU = CAT('ru');
const JA = CAT('ja');

test('Chrome in Russian: never asked, lang="ru", the Russian catalog\'s words; Settings switches at once', { timeout: 20 * 60000 }, async () => {
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, locale: 'ru-RU', colorScheme: 'light' });
  const { page, rec } = await recordedPage(ctx, { label: 'i18n-ru' });
  const catalogs = [];
  // What the app reads (the first install downloads every file of the release, catalogs included).
  ctx.on('request', (r) => {
    const m = /\/i18n\/([A-Za-z-]+)\.json$/.exec(r.url());
    if (m && !r.serviceWorker()) catalogs.push(m[1]);
  });
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 120000);
  assert.deepEqual(await page.evaluate(() => navigator.languages), ['ru-RU'], 'the browser speaks Russian');
  assert.equal(await htmlLang(page), 'ru');
  assert.equal(await page.textContent(tid('create')), RU['Create a new wallet'], 'the Russian catalog');
  assert.equal(await page.textContent(tid('restore')), RU['Restore with 12 words']);
  assert.ok((await page.evaluate(() => document.body.innerText)).match(/[А-я]/), 'Russian on the first screen');
  // Before any module runs: lang-boot.js already set it.
  await page.addInitScript(() => {
    document.addEventListener('readystatechange', () => {
      if (document.readyState === 'interactive' && !window.__langAtInteractive) window.__langAtInteractive = document.documentElement.lang;
    });
  });
  await page.reload();
  await waitScreen(page, 'welcome', 120000);
  assert.equal(await page.evaluate(() => window.__langAtInteractive), 'ru', 'from the first paint');
  await shot(page, 'i18n-01-welcome-ru-device');

  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  assert.equal(await htmlLang(page), 'ru');
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.locator(tid('lang-row')).scrollIntoViewIfNeeded();
  const card = await page.evaluate(() => {
    const row = document.querySelector('[data-testid="lang-row"]');
    return { title: row.parentElement.previousElementSibling.textContent, rowTitle: row.querySelector('.t').textContent, sameCard: row.parentElement === document.querySelector('[data-testid="theme-row"]').parentElement };
  });
  assert.deepEqual(card, { title: RU.Appearance, rowTitle: RU.Language, sameCard: true });
  assert.equal(await page.inputValue(tid('lang-select')), 'system', 'like this device: nothing was asked or saved');
  assert.deepEqual(await page.$$eval(`${tid('lang-select')} option`, (o) => o.map((x) => x.textContent)), [RU['Like this device'], 'English', 'Español', 'Português (Brasil)', 'Français', 'Deutsch', 'Türkçe', 'Русский', '简体中文', '日本語', '한국어', 'Tiếng Việt'], 'each language named in its own script');
  assert.equal(await page.textContent(tid('lang-device')), 'Русский', "the device's language, named under the row");
  assert.equal(await page.getAttribute(tid('lang-device'), 'lang'), 'ru');
  assert.equal(await page.evaluate(() => localStorage.getItem('campfire-lang')), null);
  await shot(page, 'i18n-02-settings-language-ru-device');
  await page.emulateMedia({ colorScheme: 'dark' });
  await shot(page, 'i18n-03-settings-language-ru-device-dark');
  // A computer's window too, light and dark.
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.locator(tid('lang-row')).scrollIntoViewIfNeeded();
  await shot(page, 'i18n-03b-settings-language-desktop-dark');
  await page.emulateMedia({ colorScheme: 'light' });
  await shot(page, 'i18n-03c-settings-language-desktop-light');
  await page.setViewportSize({ width: 390, height: 844 });
  await page.locator(tid('lang-row')).scrollIntoViewIfNeeded();

  // Japanese: at once, the same screen drawn again where it was, the choice kept.
  const rowTop = () => page.evaluate(() => document.querySelector('[data-testid="lang-select"]').getBoundingClientRect().top);
  await page.focus(tid('lang-select'));
  const before = await rowTop();
  await page.evaluate(() => {
    document.querySelector('[data-testid="lang-row"]').dataset.old = '1';
  });
  await page.selectOption(tid('lang-select'), 'ja');
  await page.waitForFunction(() => document.documentElement.lang === 'ja');
  await page.waitForFunction(() => !document.querySelector('[data-testid="lang-row"]').dataset.old);
  assert.equal(await page.evaluate(() => window.__campfire.screen()), 'settings');
  assert.equal(await page.evaluate(() => localStorage.getItem('campfire-lang')), 'ja');
  assert.equal(await page.inputValue(tid('lang-select')), 'ja');
  await page.waitForTimeout(700);
  assert.ok(Math.abs((await rowTop()) - before) < 4, `the select stays where it was on screen (${before} -> ${await rowTop()})`);
  assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.dataset.testid), 'lang-select', 'and keeps the focus');
  assert.equal(await page.textContent(`${tid('lang-row')} .t`), JA.Language, 'Japanese at once');
  assert.equal(await page.$(tid('lang-device')), null, 'a language chosen: no device line');
  assert.ok(catalogs.includes('ja'), 'the Japanese catalog was read once chosen');
  await shot(page, 'i18n-04-settings-japanese-chosen');

  await page.selectOption(tid('lang-select'), 'en');
  await page.waitForFunction(() => document.documentElement.lang === 'en');
  assert.equal(await page.evaluate(() => localStorage.getItem('campfire-lang')), 'en');

  // Kept: after a reload (the wallet locks) English, even on a Russian device.
  await page.reload();
  await waitScreen(page, 'unlock', 120000);
  assert.equal(await page.evaluate(() => window.__langAtInteractive), 'en');
  await unlockWithPassword(page, PASSWORD);
  await waitHome(page);
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.selectOption(tid('lang-select'), 'system');
  await page.waitForFunction(() => document.documentElement.lang === 'ru');
  assert.equal(await page.evaluate(() => localStorage.getItem('campfire-lang')), null, 'like this device: forgotten');
  assert.ok(!catalogs.includes('zh-Hans'), 'a catalog is read only when its language is in use');
  assert.deepEqual(foreignHosts(rec, srv.url), []);
  assert.deepEqual(rec.csp, []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
  await ctx.close();
  srv.stop();
  srv = null;
});

// ---------------------------------------------------------------- 2. every word from the catalog

// Words that are not the app's to translate: names, tickers, units, the language names, values (the
// word Delete wallet asks to type).
const KEEP = /\b(DELETE|WebAssembly|true|false|BEAM|Beam|Campfire|bETH|bUSDT|bWBTC|bDAI|WBEAM|ETH|FOMO|BeamX|Ethereum|Uniswap|NEAR|Intents|CoinGecko|Face|Touch|ID|English|wallet\.db|wss|https?|QR|IPv[46]|HF6|groth)\b/g;

function pseudoCatalog(keys) {
  const out = {};
  for (const [k, info] of Object.entries(keys)) {
    if (info.count) out[k] = { one: `⟦${k}⟧`, few: `⟦${k}⟧`, many: `⟦${k}⟧`, other: `⟦${k}⟧` };
    else out[k] = `⟦${k}⟧`;
  }
  return out;
}

async function wordsOnScreen(page) {
  return page.evaluate(() => {
    const out = [];
    const shown = (el) => {
      for (let e = el; e && e !== document.body; e = e.parentElement) {
        const cs = getComputedStyle(e);
        if (cs.display === 'none' || cs.visibility === 'hidden') return false;
      }
      return true;
    };
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const el = n.parentElement;
      // The 12 words (BEAM's list is English only) and values shown in a code font are not the app's words.
      if (!el || !n.nodeValue.trim() || el.closest('script,style,noscript,[data-testid="words"],[data-word],.mono')) continue;
      if (shown(el)) out.push(n.nodeValue);
    }
    for (const el of document.querySelectorAll('[aria-label],[placeholder],[title],[alt]')) {
      if (!shown(el)) continue;
      for (const a of ['aria-label', 'placeholder', 'title', 'alt']) {
        const v = el.getAttribute(a);
        if (v && v.trim()) out.push(v);
      }
    }
    for (const o of document.querySelectorAll('option')) if (shown(o.parentElement)) out.push(o.textContent);
    return out;
  });
}

/**
 * What is left of a text once the catalog's words and the values are taken out: English words, if any.
 * Translations nest (a sentence with a translated value inside it), and a sentence with an element
 * inside it (tNodes) is split across text nodes, so a part may open or close a bracket only.
 */
/** A text without its catalog parts (⟦…⟧, nested, or cut by an element inside the sentence). */
export function residue(text) {
  let s = String(text);
  while (/⟦[^⟦⟧]*⟧/.test(s)) s = s.replace(/⟦[^⟦⟧]*⟧/g, ' ');
  return s.replace(/^[^⟦]*⟧/, ' ').replace(/⟦[^⟧]*$/, ' ').replace(/\s+/g, ' ').trim();
}

/** For each English key (a count: each form): a test whether a text is that key, or holds it (3 words or more). */
export function englishMatchers(keys) {
  const out = [];
  const esc = (x) => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  for (const [k, info] of Object.entries(keys)) {
    for (const form of info.count ? [info.count.one, info.count.other] : [k]) {
      const pattern = esc(form).replace(/\\\{[A-Za-z_][A-Za-z0-9_]*\\\}/g, '.+?');
      const whole = new RegExp(`^${pattern}$`);
      const words = form.replace(/\{[^}]*\}/g, ' ').split(/\s+/).filter((w) => /[A-Za-z]{2}/.test(w)).length;
      const inside = words >= 3 ? new RegExp(pattern) : null;
      out.push((t) => whole.test(t) || Boolean(inside && inside.test(t)));
    }
  }
  return out;
}

export function leftover(text) {
  let s = String(text);
  while (/⟦[^⟦⟧]*⟧/.test(s)) s = s.replace(/⟦[^⟦⟧]*⟧/g, ' ');
  s = s.replace(/^[^⟦]*⟧/, ' ').replace(/⟦[^⟧]*$/, ' ').replace(KEEP, ' ');
  // Values: addresses, hosts, file names, versions, keys (anything with a digit or a dot, dash, slash…).
  const words = s.split(/\s+/).filter((w) => w && !/[0-9.\-_/:#@=]/.test(w));
  const left = words.join(' ').match(/[A-Za-z]{2,}/g);
  return left;
}

const AUDIT = [
  ['home', {}], ['receive', {}], ['send', {}], ['activity', {}], ['settings', {}], ['nodeSettings', {}], ['ownNode', {}], ['ipNotice', {}], ['about', {}],
  ['changePassword', {}], ['deleteWallet', {}], ['wallets', {}], ['addWallet', {}], ['contacts', {}], ['addresses', {}], ['checkProof', {}], ['notifications', {}],
  ['coins', {}], ['hiddenTokens', {}], ['swap', {}], ['pools', {}], ['poolCreate', {}], ['dapps', {}], ['names', {}], ['airdrop', {}], ['airdropCreate', {}], ['airdropBatches', {}],
  ['minterTokens', {}], ['ownerKey', { from: 'settings' }], ['ethStart', { from: 'settings' }],
];

test('the first screen: a German device opens in German; the language mark changes it at once and keeps it; every language fits a 375x667 phone', { timeout: 20 * 60000 }, async () => {
  if (!srv) srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  const ctx = await browser.newContext({ viewport: { width: 375, height: 667 }, deviceScaleFactor: 2, locale: 'de-DE', colorScheme: 'light' });
  const { page, rec } = await recordedPage(ctx, { label: 'i18n-welcome' });
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 120000);
  assert.equal(await htmlLang(page), 'de');
  assert.equal(await page.inputValue(tid('welcome-lang')), 'de', 'the mark names the language on show');
  assert.equal(await page.textContent(tid('create')), CAT('de')['Create a new wallet']);
  assert.equal(await page.evaluate(() => localStorage.getItem('campfire-lang')), null, 'never asked: nothing saved');
  const names = await page.$$eval(`${tid('welcome-lang')} option`, (o) => o.map((x) => [x.value, x.textContent, x.lang]));
  assert.equal(names.length, 11);
  assert.ok(names.every(([v, , l]) => v === l), 'each name marked with its own language');
  await shot(page, 'i18n-welcome-de');
  await page.selectOption(tid('welcome-lang'), 'es');
  await page.waitForFunction((w) => document.documentElement.lang === 'es' && document.querySelector('[data-testid="create"]')?.textContent === w, CAT('es')['Create a new wallet'], { timeout: 10000 });
  assert.equal(await page.inputValue(tid('welcome-lang')), 'es', 'the mark follows');
  assert.equal(await page.evaluate(() => localStorage.getItem('campfire-lang')), 'es', 'kept');
  await page.reload();
  await waitScreen(page, 'welcome', 120000);
  assert.equal(await htmlLang(page), 'es', 'after a reload too');
  // Every language: the first screen's three choices and the language mark on a 375x667 phone, nothing
  // wider than the screen, no button text cut.
  const LANGS = ['en', 'es', 'pt-BR', 'fr', 'de', 'tr', 'ru', 'zh-Hans', 'ja', 'ko', 'vi'];
  const bad = [];
  for (const l of LANGS) {
    await page.selectOption(tid('welcome-lang'), l);
    const want = l === 'en' ? 'Create a new wallet' : CAT(l)['Create a new wallet'] || 'Create a new wallet';
    await page.waitForFunction(([x, w]) => document.documentElement.lang === x && document.querySelector('[data-testid="create"]')?.textContent === w, [l, want], { timeout: 10000 });
    await page.waitForTimeout(300);
    const m = await page.evaluate(() => {
      const vw = document.documentElement.clientWidth;
      const vh = window.innerHeight;
      const wide = document.documentElement.scrollWidth > vw + 1;
      const below = ['create', 'restore', 'import'].filter((id) => document.querySelector(`[data-testid="${id}"]`).getBoundingClientRect().bottom > vh);
      const cut = [...document.querySelectorAll('button, select')].filter((b) => b.scrollWidth > b.clientWidth + 1).map((b) => b.textContent.trim().slice(0, 40));
      return { wide, below, cut };
    });
    if (m.wide || m.below.length || m.cut.length) bad.push(`${l}: ${JSON.stringify(m)}`);
    await shot(page, `i18n-welcome-375-${l}`);
  }
  assert.deepEqual(bad, []);
  assert.deepEqual(rec.errors, []);
  await ctx.close();
});

test('pseudo-Russian: every word on these screens comes from the catalog', { timeout: 25 * 60000 }, async () => {
  const keys = JSON.parse(readFileSync(join(PWA, 'src', 'i18n', 'keys.json'), 'utf8'));
  const catDir = join(tmp, 'catalogs');
  mkdirSync(catDir);
  writeFileSync(join(catDir, 'ru.json'), JSON.stringify(pseudoCatalog(keys)));
  for (const l of ['es', 'pt-BR', 'fr', 'de', 'tr', 'zh-Hans', 'ja', 'ko', 'vi']) writeFileSync(join(catDir, `${l}.json`), '{}');
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'pseudo'), '--catalogs', catDir, '--quiet'], { cwd: PWA });
  if (srv) srv.stop(); // the first test's server, if it stopped early
  srv = await startServer({ root: join(tmp, 'pseudo'), port: PORT });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1, locale: 'ru-RU' });
  const { page, rec } = await recordedPage(ctx, { label: 'i18n-pseudo' });
  // Fails on the app's own English left on screen: a text that is one of the keys (a tk() constant
  // shown without t(), a sentence glued around a translation). Other Latin words are listed only: on
  // these screens they are chain and dApp data (asset and dApp names), which is never translated.
  const english = englishMatchers(keys);
  // Data that ends like a key or is a name: an LP token's name ("BEAM/bETH LP", like a ticker; the key
  // "{amount} LP" would otherwise match the pool rows) and the built-in dApps' names (a dApp's content
  // is never translated).
  const dappNames = new Set([...readFileSync(join(PWA, 'src', 'lib', 'dapps', 'catalogue.js'), 'utf8').matchAll(/^\s*name: '([^']+)',/gm)].map((m) => m[1]));
  const isData = (text) => /\b[A-Za-z0-9]+\/[A-Za-z0-9]+ LP\b/.test(text) || dappNames.has(text.trim());
  const found = [];
  const listed = [];
  const audit = async (name) => {
    for (const text of await wordsOnScreen(page)) {
      if (!leftover(text)) continue;
      if (isData(text)) {
        listed.push(`${name}: ${JSON.stringify(text.trim()).slice(0, 140)}`);
        continue;
      }
      const rest = residue(text);
      if (english.some((m) => m(rest))) found.push(`${name}: ${JSON.stringify(text.trim()).slice(0, 140)}`);
      else listed.push(`${name}: ${JSON.stringify(text.trim()).slice(0, 140)}`);
    }
    await shot(page, `i18n-pseudo-${name}`);
  };
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 120000);
  await audit('welcome');
  // The setup screens, as a person goes through them.
  await page.click(tid('create'));
  await waitScreen(page, 'backup');
  await audit('backup');
  await page.click(tid('reveal'));
  const words = await page.$$eval('[data-testid="words"] .word span:last-child', (els) => els.map((e) => e.textContent));
  await page.click(tid('wrote-down'));
  await waitScreen(page, 'confirmWords');
  await audit('confirmWords');
  for (const pos of await page.$$eval('[data-position]', (els) => els.map((e) => Number(e.dataset.position)))) await page.click(`[data-position="${pos}"] [data-word="${words[pos - 1]}"]`);
  await page.click(tid('confirm-words'));
  await waitScreen(page, 'setPassword');
  await audit('setPassword');
  await page.fill(tid('pw1'), PASSWORD);
  await page.fill(tid('pw2'), PASSWORD);
  await page.click(tid('save-password'));
  await page.waitForFunction(() => ['passkeySetup', 'home', 'fastStart'].includes(document.getElementById('app').dataset.screen), null, { timeout: 60000 });
  if ((await page.evaluate(() => window.__campfire.screen())) === 'passkeySetup') {
    await audit('passkeySetup');
    await page.click(tid('passkey-skip'));
  }
  await waitHome(page);
  await page.waitForFunction(() => window.__campfire.sync() && window.__campfire.sync().state === 'synced', null, { timeout: 180000 }).catch(() => {});
  for (const [name, params] of AUDIT) {
    await page.evaluate(([n, p]) => window.__campfire.go(n, p), [name, params]);
    await page.waitForTimeout(1500);
    await audit(name);
    await page.keyboard.press('Escape').catch(() => {});
  }
  await page.evaluate(() => window.__campfire.go('settings'));
  await page.evaluate(() => document.querySelector('[data-testid="lock-now"]').click());
  await waitScreen(page, 'unlock');
  await audit('unlock');
  console.log(`# pseudo-Russian: ${found.length} of the app's texts not from the catalog; ${listed.length} other Latin words (data):`);
  for (const f of found) console.log(`#   NOT TRANSLATED ${f}`);
  for (const f of listed) console.log(`#   data? ${f}`);
  assert.deepEqual(rec.errors, [], 'no screen breaks in another language');
  assert.deepEqual(found, [], 'English left on screen: route it through lib/i18n.js');
  await ctx.close();
});

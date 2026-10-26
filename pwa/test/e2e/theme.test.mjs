// Settings -> Appearance, end to end: Colours (BEAM, the default, or Campfire red, issue #80) and
// Theme (like this device, light, dark; BEAM is dark unless one is picked). The installed Google Chrome (headless), its own build and port, a
// throwaway mainnet wallet that holds nothing. The device's own light / dark is emulated. A sweep
// measures the rendered contrast of every visible text on the app's screens in all four palettes.
//
//   npm run e2e:theme   (own build folder and port 8828)
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen, shot, sleep, foreignHosts, PWA, SHOTS } from './harness.mjs';
import { createWallet, waitHome, unlockWithPassword } from './flows.mjs';

const PORT = 8828;
const tid = (id) => `[data-testid="${id}"]`;
const LIGHT_BG = 'rgb(255, 241, 241)';
const DARK_BG = 'rgb(28, 29, 34)';
const BEAM_LIGHT_BG = 'rgb(238, 244, 250)';
const BEAM_DARK_BG = 'rgb(4, 37, 72)';
const PASSWORD = `theme-${Math.random().toString(36).slice(2, 10)}`;

let tmp, srv, browser, ctx, page, rec;

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-theme-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, colorScheme: 'light' });
  ({ page, rec } = await recordedPage(ctx, { label: 'theme' }));
  console.log(`# screenshots: ${SHOTS}`);
});

test.after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

const bg = () => page.evaluate(() => getComputedStyle(document.body).backgroundColor);
const bars = () => page.evaluate(() => [...document.querySelectorAll('meta[name="theme-color"]')].map((m) => m.getAttribute('content')));

test('first screen: BEAM and dark by default, on a light device too; Campfire red follows the device; a saved Light from the first paint', { timeout: 10 * 60000 }, async () => {
  // Before app.js runs: the attributes theme-boot.js (and index.html) set while the page head was read.
  await page.addInitScript(() => {
    document.addEventListener('readystatechange', () => {
      if (document.readyState === 'interactive' && !window.__atInteractive) window.__atInteractive = { theme: document.documentElement.dataset.theme || null, bg: getComputedStyle(document.documentElement).getPropertyValue('--bg').trim() };
    });
  });
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 120000);
  assert.deepEqual(await page.evaluate(() => window.__atInteractive), { theme: 'dark', bg: '#042548' }, 'BEAM dark as soon as the page is read');
  assert.equal(await bg(), BEAM_DARK_BG, 'a light device: BEAM dark all the same');
  assert.equal(await page.evaluate(() => document.documentElement.dataset.skin), 'beam');
  assert.deepEqual(await bars(), ['#04325a', '#04325a'], 'the browser bar too');
  assert.deepEqual(await page.evaluate(() => [localStorage.getItem('campfire-skin'), localStorage.getItem('campfire-theme')]), [null, null], 'the default saves nothing');
  await shot(page, 'theme-01-welcome-beam-dark');

  // Campfire red, no theme picked: like the device.
  await page.evaluate(() => localStorage.setItem('campfire-skin', 'campfire'));
  await page.reload();
  await waitScreen(page, 'welcome', 120000);
  assert.equal(await bg(), LIGHT_BG, 'a light device: light');
  await page.emulateMedia({ colorScheme: 'dark' });
  assert.equal(await bg(), DARK_BG, 'a dark device: dark');
  await page.emulateMedia({ colorScheme: 'light' });

  // BEAM with Light saved: light from the first paint.
  await page.evaluate(() => {
    localStorage.removeItem('campfire-skin');
    localStorage.setItem('campfire-theme', 'light');
  });
  await page.reload();
  await waitScreen(page, 'welcome', 120000);
  assert.deepEqual(await page.evaluate(() => window.__atInteractive), { theme: 'light', bg: '#eef4fa' });
  assert.equal(await bg(), BEAM_LIGHT_BG);
  assert.deepEqual(await bars(), ['#e0ebf4', '#e0ebf4']);

  // 0.2.19 saved Dark with a flag when BEAM was chosen: that reads as no theme picked (BEAM dark).
  await page.evaluate(() => {
    localStorage.setItem('campfire-skin', 'beam');
    localStorage.setItem('campfire-theme', 'dark');
    localStorage.setItem('campfire-theme-auto', '1');
  });
  await page.reload();
  await waitScreen(page, 'welcome', 120000);
  assert.equal(await bg(), BEAM_DARK_BG);
});

test('Settings -> Theme: Dark by default with BEAM; Light and Like this device at once, and kept after a reload', { timeout: 15 * 60000 }, async () => {
  await page.evaluate(() => localStorage.clear());
  await page.reload();
  await waitScreen(page, 'welcome', 120000);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.locator(tid('theme-row')).scrollIntoViewIfNeeded();
  assert.equal(await page.inputValue(tid('theme-select')), 'dark', "BEAM's own: dark");
  assert.deepEqual(await page.$$eval(`${tid('theme-select')} option`, (o) => o.map((x) => x.textContent)), ['Like this device', 'Light', 'Dark']);

  await page.emulateMedia({ colorScheme: 'dark' });
  await page.selectOption(tid('theme-select'), 'light');
  assert.equal(await bg(), BEAM_LIGHT_BG, 'Light on a dark device');
  assert.equal(await page.evaluate(() => localStorage.getItem('campfire-theme')), 'light');
  assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).colorScheme), 'light', 'native controls light too');
  await shot(page, 'theme-02-settings-beam-light-on-dark-device');

  // Kept: after a reload (the wallet locks), the unlock screen is already light.
  await page.reload();
  await waitScreen(page, 'unlock', 120000);
  assert.equal(await bg(), BEAM_LIGHT_BG);
  assert.deepEqual(await bars(), ['#e0ebf4', '#e0ebf4']);

  // Like this device, picked on purpose: follows the (dark) device, and is kept (it is not the default).
  await page.evaluate(async () => (await import('./lib/theme.js')).setTheme('system'));
  assert.equal(await bg(), BEAM_DARK_BG);
  assert.equal(await page.evaluate(() => localStorage.getItem('campfire-theme')), 'system');
  assert.deepEqual(await bars(), ['#e0ebf4', '#04325a'], 'each bar colour for its own device mode');
  await page.emulateMedia({ colorScheme: 'light' });
  assert.equal(await bg(), BEAM_LIGHT_BG);
});

test('Settings -> Colours: BEAM by default; Campfire red at once; a theme nobody picked follows the colours', { timeout: 10 * 60000 }, async () => {
  await unlockWithPassword(page, PASSWORD);
  await waitHome(page);
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  // One card under "Appearance": Theme, then Colours.
  const card = await page.evaluate(() => {
    const t = document.querySelector('[data-testid="theme-row"]');
    const k = document.querySelector('[data-testid="skin-row"]');
    return { same: t.parentElement === k.parentElement, title: t.parentElement.previousElementSibling.textContent, sub: k.querySelector('.s').textContent };
  });
  assert.deepEqual(card, { same: true, title: 'Appearance', sub: 'BEAM or Campfire red' });
  await page.locator(tid('skin-row')).scrollIntoViewIfNeeded();
  assert.equal(await page.inputValue(tid('skin-select')), 'beam', 'BEAM by default');
  assert.deepEqual(await page.$$eval(`${tid('skin-select')} option`, (o) => o.map((x) => x.textContent)), ['BEAM', 'Campfire red']);
  // Like this device was picked (the test before): Campfire red keeps it.
  await page.selectOption(tid('skin-select'), 'campfire');
  assert.equal(await bg(), LIGHT_BG, 'Campfire red, light device');
  assert.equal(await page.inputValue(tid('theme-select')), 'system');
  assert.deepEqual(await page.evaluate(() => [localStorage.getItem('campfire-skin'), localStorage.getItem('campfire-theme')]), ['campfire', 'system']);
  assert.deepEqual(await bars(), ['#fff1f1', '#1c1d22']);
  await shot(page, 'theme-03-settings-campfire-red');
  // The red original stays (the app icon's); the screens draw the flame in the colours on show.
  assert.equal(await page.evaluate(() => fetch('img/logo.svg').then((r) => r.ok)), true);

  // No theme picked: Campfire red follows the device, and BEAM comes back dark.
  await page.evaluate(() => localStorage.removeItem('campfire-theme'));
  await page.reload();
  await waitScreen(page, 'unlock', 120000);
  assert.equal(await bg(), LIGHT_BG);
  await unlockWithPassword(page, PASSWORD);
  await waitHome(page);
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  assert.equal(await page.inputValue(tid('skin-select')), 'campfire', 'kept');
  await page.selectOption(tid('skin-select'), 'beam');
  assert.equal(await bg(), BEAM_DARK_BG, 'BEAM, dark');
  assert.equal(await page.inputValue(tid('theme-select')), 'dark', 'the Theme row follows');
  assert.deepEqual(await page.evaluate(() => [localStorage.getItem('campfire-skin'), localStorage.getItem('campfire-theme')]), [null, null], 'the default leaves nothing saved');
  assert.deepEqual(await bars(), ['#04325a', '#04325a']);
  await shot(page, 'theme-04-settings-beam-dark');
  await page.reload();
  await waitScreen(page, 'unlock', 120000);
  assert.equal(await bg(), BEAM_DARK_BG);
  await shot(page, 'theme-05-unlock-beam-dark');
  await unlockWithPassword(page, PASSWORD);
  await waitHome(page);
});

/**
 * Every visible text on the page: its colour against what it is drawn on (translucent layers, faded
 * ancestors and the band at the top of the page composited), WCAG 2: 4.5:1, or 3:1 for large text. Disabled controls are left
 * out (WCAG exempts them), and so is an asset's own badge colour (it is the asset's, not ours).
 * With a sheet open, only the sheet.
 */
async function lowContrast() {
  return page.evaluate(() => {
    const parse = (c) => {
      const m = /rgba?\(([^)]+)\)/.exec(c || '');
      if (!m) return null;
      const p = m[1].split(/[\s,/]+/).filter(Boolean).map(Number);
      return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
    };
    const over = (t, u, a = t.a) => ({ r: t.r * a + u.r * (1 - a), g: t.g * a + u.g * (1 - a), b: t.b * a + u.b * (1 - a), a: 1 });
    const lin = (c) => ((c /= 255) <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
    const lum = (c) => 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
    const ratio = (a, b) => {
      const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p);
      return (x + 0.05) / (y + 0.05);
    };
    const pageBg = parse(getComputedStyle(document.body).backgroundColor);
    // The page's own colour under a text: --bg, or within the top 230 px the --bg-top band fading into it.
    const hexRgb = (x) => ({ r: parseInt(x.slice(1, 3), 16), g: parseInt(x.slice(3, 5), 16), b: parseInt(x.slice(5, 7), 16), a: 1 });
    const top = hexRgb(getComputedStyle(document.documentElement).getPropertyValue('--bg-top').trim());
    const pageAt = (el) => {
      const y = el.getBoundingClientRect().top + window.scrollY;
      return y >= 230 ? pageBg : over(top, pageBg, 1 - Math.max(0, y) / 230);
    };
    const bgOf = (el) => {
      const layers = [];
      for (let e = el; e && e !== document.documentElement; e = e.parentElement) {
        const c = parse(getComputedStyle(e).backgroundColor);
        if (c && c.a > 0) {
          layers.push(c);
          if (c.a >= 1) break;
        }
      }
      let base = layers.length && layers[layers.length - 1].a >= 1 ? layers.pop() : pageAt(el);
      for (let i = layers.length - 1; i >= 0; i--) base = over(layers[i], base);
      return base;
    };
    const scope = document.querySelector('.sheet') || document.getElementById('app');
    const hex = (c) => `#${[c.r, c.g, c.b].map((v) => Math.round(v).toString(16).padStart(2, '0')).join('')}`;
    const out = [];
    for (const el of scope.querySelectorAll('*')) {
      const own = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim());
      if (!own || !el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) continue;
      if (el.closest(':disabled, .disabled, [aria-disabled="true"], .asset-badge.tinted, .qr, .dapp-layer, option, select')) continue;
      const cs = getComputedStyle(el);
      let fg = parse(cs.color);
      const bgc = bgOf(el);
      let fade = 1;
      for (let e = el; e && e !== document.documentElement; e = e.parentElement) fade *= Number(getComputedStyle(e).opacity);
      fg = over({ ...fg, a: fg.a * fade }, bgc);
      const size = parseFloat(cs.fontSize);
      const large = size >= 24 || (size >= 18.66 && Number(cs.fontWeight) >= 700);
      const r = ratio(fg, bgc);
      if (r < (large ? 3 : 4.5)) out.push(`${el.tagName.toLowerCase()}.${[...el.classList].join('.')} "${el.textContent.trim().slice(0, 40)}" ${hex(fg)} on ${hex(bgc)} ${r.toFixed(2)}`);
    }
    return out;
  });
}

// The app's screens a wallet opens without contacting anything but its node (and this origin).
const SWEEP = ['home', 'receive', 'send', 'activity', 'settings', 'nodeSettings', 'about', 'swap', 'dapps', 'names', 'airdrop', 'airdropCreate', 'airdropBatches', 'contacts', 'addresses', 'checkProof', 'notifications', 'coins', 'minterTokens', 'minterCreate', 'pools', 'hiddenTokens', 'wallets', 'changePassword', 'ethStart'];
const LOOK = [['campfire', 'light'], ['campfire', 'dark'], ['beam', 'light'], ['beam', 'dark']];

test('every visible text on the app\'s screens reads at 4.5:1 (large text 3:1) in Campfire red and BEAM, light and dark', { timeout: 15 * 60000 }, async () => {
  const low = [];
  // Like this device, so the emulated device mode picks each palette (BEAM alone would stay dark).
  await page.evaluate(async () => (await import('./lib/theme.js')).setTheme('system'));
  for (const [skin, scheme] of LOOK) {
    await page.evaluate(async (k) => (await import('./lib/theme.js')).setSkin(k), skin);
    await page.emulateMedia({ colorScheme: scheme });
    for (const name of SWEEP) {
      await page.evaluate((n) => window.__campfire.go(n), name);
      await waitScreen(page, name, 30000);
      await sleep(700);
      for (const l of await lowContrast()) low.push(`${skin} ${scheme} ${name}: ${l}`);
      // The code's box is white in every palette, so whatever stands in for a code is drawn dark on it.
      if (name === 'receive') assert.equal(await page.evaluate(() => getComputedStyle(document.querySelector('.qr')).color), 'rgb(32, 38, 61)', `${skin} ${scheme}`);
      if (['home', 'settings', 'send', 'receive', 'activity', 'airdrop', 'swap', 'about'].includes(name)) await shot(page, `theme-sweep-${skin}-${scheme}-${name}`);
      if (['home', 'settings'].includes(name)) {
        await page.setViewportSize({ width: 1280, height: 800 });
        await sleep(200);
        await shot(page, `theme-sweep-${skin}-${scheme}-${name}-1280`);
        await page.setViewportSize({ width: 390, height: 844 });
      }
    }
  }
  await page.evaluate(async () => (await import('./lib/theme.js')).setSkin('beam'));
  await page.emulateMedia({ colorScheme: 'light' });
  console.log(`# swept ${SWEEP.length} screens x ${LOOK.length} palettes; below the line: ${low.length}`);
  assert.deepEqual(low, []);
});

test('privacy: no host but the origin and BEAM nodes; no CSP violation; no page error', async () => {
  await sleep(200);
  assert.deepEqual(foreignHosts(rec, srv.url), []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
});

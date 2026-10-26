// Settings -> Appearance (lib/theme.js, theme-boot.js, css/app.css): BEAM's colours (the default) or
// Campfire red; like this device, light or dark (BEAM: dark unless one is picked).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { THEMES, THEME_WORDS, SKINS, SKIN_WORDS, BARS, readTheme, readSkin, applyTheme, applyLook, setTheme, setSkin, pickSkin, resetLook, defaultTheme } from '../../src/lib/theme.js';

const src = (p) => readFileSync(new URL(`../../src/${p}`, import.meta.url), 'utf8');

function memoryStorage(init = {}) {
  const m = new Map(Object.entries(init));
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k), m };
}
const blocked = { getItem: () => { throw new Error('blocked'); }, setItem: () => { throw new Error('blocked'); }, removeItem: () => { throw new Error('blocked'); } };

function fakeDoc() {
  const meta = (attrs) => ({ attrs: { ...attrs }, getAttribute(k) { return this.attrs[k] ?? null; }, setAttribute(k, v) { this.attrs[k] = v; } });
  const light = meta({ name: 'theme-color', content: '#fff1f1', media: '(prefers-color-scheme: light)' });
  const dark = meta({ name: 'theme-color', content: '#1c1d22', media: '(prefers-color-scheme: dark)' });
  const scheme = meta({ name: 'color-scheme', content: 'light dark' });
  return {
    documentElement: { dataset: {} },
    querySelectorAll: (sel) => (sel === 'meta[name="theme-color"]' ? [light, dark] : []),
    querySelector: (sel) => (sel === 'meta[name="color-scheme"]' ? scheme : null),
    light,
    dark,
    scheme,
  };
}

test('the theme: the one picked, else the colours\' own (BEAM dark, Campfire red like this device)', () => {
  assert.deepEqual(THEMES, ['system', 'light', 'dark']);
  assert.equal(THEME_WORDS.system, 'Like this device');
  assert.equal(readTheme(memoryStorage()), 'dark', 'a new install: BEAM, dark');
  assert.equal(readTheme(memoryStorage({ 'campfire-theme': 'system' })), 'system', 'like this device, picked on purpose');
  assert.equal(readTheme(memoryStorage({ 'campfire-theme': 'light' })), 'light');
  assert.equal(readTheme(memoryStorage({ 'campfire-theme': 'purple' })), 'dark');
  assert.equal(readTheme(memoryStorage({ 'campfire-skin': 'campfire' })), 'system', 'Campfire red follows the device');
  assert.equal(readTheme(memoryStorage({ 'campfire-skin': 'campfire', 'campfire-theme': 'dark' })), 'dark');
  // 0.2.19 saved Dark with the flag when BEAM was picked: no theme was picked.
  assert.equal(readTheme(memoryStorage({ 'campfire-skin': 'beam', 'campfire-theme': 'dark', 'campfire-theme-auto': '1' })), 'dark');
  assert.equal(readTheme(blocked), 'dark');
  assert.equal(defaultTheme('beam'), 'dark');
  assert.equal(defaultTheme('campfire'), 'system');
});

test('applied: the palette attribute, the native controls and the browser bar', () => {
  const d = fakeDoc();
  applyTheme('dark', d);
  assert.equal(d.documentElement.dataset.theme, 'dark');
  assert.equal(d.light.attrs.content, '#1c1d22', 'the bar is dark whatever the device says');
  assert.equal(d.dark.attrs.content, '#1c1d22');
  assert.equal(d.scheme.attrs.content, 'dark');
  applyTheme('light', d);
  assert.equal(d.documentElement.dataset.theme, 'light');
  assert.equal(d.dark.attrs.content, '#fff1f1');
  assert.equal(d.scheme.attrs.content, 'light');
  applyTheme('system', d);
  assert.equal('theme' in d.documentElement.dataset, false);
  assert.equal(d.light.attrs.content, '#fff1f1');
  assert.equal(d.dark.attrs.content, '#1c1d22', 'each tag its own colour again');
  assert.equal(d.scheme.attrs.content, 'light dark');
});

test('saved and applied at once, like this device too (it is no longer the default); blocked storage still applies', () => {
  const st = memoryStorage();
  const d = fakeDoc();
  assert.equal(setTheme('dark', { storage: st, doc: d }), 'dark');
  assert.equal(st.m.get('campfire-theme'), 'dark');
  assert.equal(d.documentElement.dataset.theme, 'dark');
  setTheme('system', { storage: st, doc: d });
  assert.equal(st.m.get('campfire-theme'), 'system');
  assert.equal('theme' in d.documentElement.dataset, false);
  st.m.set('campfire-theme-auto', '1');
  setTheme('dark', { storage: st, doc: d });
  assert.equal(st.m.has('campfire-theme-auto'), false, 'picked on purpose now');
  const d2 = fakeDoc();
  assert.equal(setTheme('light', { storage: blocked, doc: d2 }), 'light');
  assert.equal(d2.documentElement.dataset.theme, 'light');
});

test('before the first paint: theme-boot.js reads the same key, and index.html loads it before the stylesheets', () => {
  const boot = src('theme-boot.js');
  assert.match(src('lib/theme.js'), /const KEY = 'campfire-theme';/);
  assert.match(boot, /localStorage\.getItem\('campfire-theme'\)/);
  const html = src('index.html');
  assert.ok(html.indexOf('<script src="theme-boot.js"></script>') > 0);
  assert.ok(html.indexOf('theme-boot.js') < html.indexOf('css/app.css'), 'before the colours are read');
  assert.doesNotMatch(boot, /\bimport\b|\bexport\b/, 'a classic script: it runs before the page is drawn');
});

test("css: the dark palette under the device's dark mode and under Dark is one palette", () => {
  const css = src('css/app.css');
  const decls = (body) => body.split('\n').map((l) => l.trim()).filter((l) => l.startsWith('--')).join('\n');
  const sys = /@media \(prefers-color-scheme: dark\) \{\n {2}:root:not\(\[data-theme="light"\]\) \{\n([\s\S]*?)\n {2}\}\n\}/.exec(css);
  const forced = /\n:root\[data-theme="dark"\] \{\n([\s\S]*?)\n\}/.exec(css);
  assert.ok(sys && forced, 'both blocks found');
  assert.ok(decls(sys[1]).split('\n').length >= 20);
  assert.equal(decls(forced[1]), decls(sys[1]));
  // Every dark rule in the file follows the choice: none under the media query alone.
  for (const m of css.matchAll(/@media \(prefers-color-scheme: dark\) \{([\s\S]*?)\n\}/g)) {
    for (const line of m[1].split('\n').filter((l) => /\{/.test(l))) assert.match(line, /:root(\[data-skin="beam"\])?:not\(\[data-theme="light"\]\)/, line.trim());
  }
});

// ---------------------------------------------------------------- colours: BEAM or Campfire red (#80)

const css = src('css/app.css');
const tokens = (body) => Object.fromEntries([...body.matchAll(/--([a-z0-9-]+):\s*([^;]+);/g)].map((x) => [x[1], x[2].trim()]));
const blockOf = (re) => {
  const m = re.exec(css);
  assert.ok(m, `block ${re}`);
  return tokens(m[1]);
};
const PALETTES = {
  'campfire light': blockOf(/\n:root \{\n([\s\S]*?)\n\}/),
  'campfire dark': blockOf(/\n:root\[data-theme="dark"\] \{\n([\s\S]*?)\n\}/),
  'beam light': blockOf(/\n:root\[data-skin="beam"\] \{\n([\s\S]*?)\n\}/),
  'beam dark': blockOf(/\n:root\[data-skin="beam"\]\[data-theme="dark"\] \{\n([\s\S]*?)\n\}/),
};
const COLOUR_KEYS = Object.keys(PALETTES['campfire dark']);

test('colours: BEAM unless Campfire red is saved; anything unknown or unreadable is BEAM', () => {
  assert.deepEqual(SKINS, ['beam', 'campfire']);
  assert.deepEqual(SKIN_WORDS, { beam: 'BEAM', campfire: 'Campfire red' });
  assert.equal(readSkin(memoryStorage()), 'beam');
  assert.equal(readSkin(memoryStorage({ 'campfire-skin': 'beam' })), 'beam', 'as 0.2.19 saved it');
  assert.equal(readSkin(memoryStorage({ 'campfire-skin': 'campfire' })), 'campfire');
  assert.equal(readSkin(memoryStorage({ 'campfire-skin': 'purple' })), 'beam');
  assert.equal(readSkin(blocked), 'beam');
});

test('colours applied with the theme: the attribute, and the browser bar in that palette', () => {
  const d = fakeDoc();
  applyLook({ theme: 'system', skin: 'beam' }, d);
  assert.equal(d.documentElement.dataset.skin, 'beam');
  assert.equal(d.light.attrs.content, '#e0ebf4');
  assert.equal(d.dark.attrs.content, '#04325a');
  applyTheme('dark', d); // the theme changes, the colours stay
  assert.equal(d.documentElement.dataset.skin, 'beam');
  assert.equal(d.light.attrs.content, '#04325a');
  const st = memoryStorage();
  assert.equal(setSkin('campfire', { storage: st, doc: d }), 'campfire');
  assert.equal('skin' in d.documentElement.dataset, false, 'Campfire red: no attribute');
  assert.equal(d.documentElement.dataset.theme, 'dark', 'the theme stays');
  assert.equal(d.light.attrs.content, '#1c1d22');
  assert.equal(st.m.get('campfire-skin'), 'campfire');
  setSkin('beam', { storage: st, doc: d });
  assert.equal(st.m.has('campfire-skin'), false, 'the default leaves nothing saved');
  const d2 = fakeDoc();
  assert.equal(setSkin('beam', { storage: blocked, doc: d2 }), 'beam', 'storage blocked: this page only');
  assert.equal(d2.documentElement.dataset.skin, 'beam');
  // Each bar colour is its palette's colour at the top of the page (Campfire's is its background).
  for (const k of SKINS) for (const m of ['light', 'dark']) assert.equal(BARS[k][m], PALETTES[`${k} ${m}`]['bg-top'], `${k} ${m}`);
  for (const m of ['light', 'dark']) assert.equal(PALETTES[`campfire ${m}`]['bg-top'], PALETTES[`campfire ${m}`].bg, `campfire ${m}: no band`);
});

test('a theme nobody picked follows the colours; one picked on purpose is never changed', () => {
  // Nothing picked: Campfire red follows the device, and BEAM comes back dark. Nothing is saved for either.
  let st = memoryStorage();
  let d = fakeDoc();
  applyLook({ theme: 'dark', skin: 'beam' }, d); // as index.html and theme-boot.js start it
  assert.deepEqual(pickSkin('campfire', { storage: st, doc: d }), { skin: 'campfire', theme: 'system' });
  assert.deepEqual([...st.m.keys()], ['campfire-skin']);
  assert.equal('theme' in d.documentElement.dataset, false);
  assert.equal(d.light.attrs.content, '#fff1f1');
  assert.deepEqual(pickSkin('beam', { storage: st, doc: d }), { skin: 'beam', theme: 'dark' });
  assert.equal(st.m.size, 0);
  assert.equal(d.documentElement.dataset.theme, 'dark');
  assert.equal(d.documentElement.dataset.skin, 'beam');
  assert.equal(d.light.attrs.content, '#04325a', "the bar in BEAM's dark colour");
  // 0.2.19's BEAM-came-dark pair counts as nothing picked: Campfire red follows the device again.
  st = memoryStorage({ 'campfire-skin': 'beam', 'campfire-theme': 'dark', 'campfire-theme-auto': '1' });
  assert.deepEqual(pickSkin('campfire', { storage: st, doc: fakeDoc() }), { skin: 'campfire', theme: 'system' });
  assert.deepEqual([...st.m.entries()], [['campfire-skin', 'campfire']]);
  // Picked on purpose, each of them: kept both ways.
  for (const theme of ['light', 'dark', 'system']) {
    st = memoryStorage({ 'campfire-theme': theme });
    d = fakeDoc();
    applyTheme(theme, d);
    assert.deepEqual(pickSkin('campfire', { storage: st, doc: d }), { skin: 'campfire', theme }, theme);
    assert.deepEqual(pickSkin('beam', { storage: st, doc: d }), { skin: 'beam', theme }, theme);
    assert.equal(st.m.get('campfire-theme'), theme);
  }
  // Storage blocked: the page stands in. Nothing picked follows the colours; a theme picked here stays.
  d = fakeDoc();
  resetLook({ storage: blocked, doc: d }); // a fresh page: earlier tests picked themes on this one
  assert.deepEqual(pickSkin('campfire', { storage: blocked, doc: d }), { skin: 'campfire', theme: 'system' });
  assert.deepEqual(pickSkin('beam', { storage: blocked, doc: d }), { skin: 'beam', theme: 'dark' });
  setTheme('light', { storage: blocked, doc: d });
  assert.deepEqual(pickSkin('campfire', { storage: blocked, doc: d }), { skin: 'campfire', theme: 'light' });
});

test('every wallet deleted: back to a new install, BEAM and dark, nothing saved', () => {
  const st = memoryStorage({ 'campfire-skin': 'campfire', 'campfire-theme': 'light', 'campfire-theme-auto': '1' });
  const d = fakeDoc();
  applyLook({ theme: 'light', skin: 'campfire' }, d);
  resetLook({ storage: st, doc: d });
  assert.equal(st.m.size, 0);
  assert.equal(d.documentElement.dataset.skin, 'beam');
  assert.equal(d.documentElement.dataset.theme, 'dark');
  assert.match(src('lib/wallets.js'), /resetLook\(\{ storage \}\)/);
});

test('before the first paint: theme-boot.js decides as lib/theme.js does, and index.html carries the default', () => {
  const boot = src('theme-boot.js');
  assert.match(src('lib/theme.js'), /const SKIN_KEY = 'campfire-skin';/);
  assert.match(src('lib/theme.js'), /const AUTO_DARK_KEY = 'campfire-theme-auto';/);
  assert.match(boot, /localStorage\.getItem\('campfire-skin'\) === 'campfire'/);
  assert.match(boot, /localStorage\.getItem\('campfire-theme-auto'\) === '1'/);
  assert.match(boot, new RegExp(`skin === 'beam' \\? \\{ light: '${BARS.beam.light}', dark: '${BARS.beam.dark}' \\} : \\{ light: '${BARS.campfire.light}', dark: '${BARS.campfire.dark}' \\}`));
  const html = src('index.html');
  assert.ok(html.indexOf('theme-boot.js') > html.lastIndexOf('name="theme-color"'), 'the bar tags are read before it runs');
  assert.match(html, /<html lang="en" data-skin="beam" data-theme="dark">/);
  assert.equal([...html.matchAll(/name="theme-color" content="([^"]+)"/g)].map((m) => m[1]).join(), `${BARS.beam.dark},${BARS.beam.dark}`);
  assert.match(html, /<meta name="color-scheme" content="dark">/);
  const manifest = JSON.parse(src('manifest.webmanifest'));
  assert.equal(manifest.theme_color, BARS.beam.dark);
  assert.equal(manifest.background_color, PALETTES['beam dark'].bg);
  // Run it: each saved state gives what lib/theme.js reads.
  const cases = [
    [{}, { skin: 'beam', theme: 'dark' }],
    [{ 'campfire-skin': 'campfire' }, { skin: 'campfire', theme: 'system' }],
    [{ 'campfire-skin': 'campfire', 'campfire-theme': 'light' }, { skin: 'campfire', theme: 'light' }],
    [{ 'campfire-skin': 'beam', 'campfire-theme': 'dark', 'campfire-theme-auto': '1' }, { skin: 'beam', theme: 'dark' }],
    [{ 'campfire-theme': 'system' }, { skin: 'beam', theme: 'system' }],
  ];
  for (const [saved, want] of cases) {
    const st = memoryStorage(saved);
    assert.deepEqual({ skin: readSkin(st), theme: readTheme(st) }, want, JSON.stringify(saved));
    const d = fakeDoc();
    const attrs = {};
    const root = { setAttribute: (k, v) => (attrs[k] = v), removeAttribute: (k) => delete attrs[k] };
    const doc = { documentElement: root, querySelectorAll: d.querySelectorAll, querySelector: d.querySelector };
    new Function('localStorage', 'document', boot)(st, doc);
    assert.equal(attrs['data-skin'] ?? 'campfire', want.skin === 'beam' ? 'beam' : 'campfire', JSON.stringify(saved));
    assert.equal(attrs['data-theme'] ?? 'system', want.theme, JSON.stringify(saved));
    const forced = want.theme === 'system' ? null : want.theme;
    assert.equal(d.light.attrs.content, BARS[want.skin][forced || 'light']);
    assert.equal(d.dark.attrs.content, BARS[want.skin][forced || 'dark']);
  }
});

test('css: BEAM gives every colour Campfire has, light and dark, and its two dark blocks are one palette', () => {
  for (const name of ['beam light', 'beam dark']) assert.deepEqual(Object.keys(PALETTES[name]), COLOUR_KEYS, name);
  for (const k of COLOUR_KEYS) assert.ok(k in PALETTES['campfire light'], `campfire light has --${k}`);
  const sys = /@media \(prefers-color-scheme: dark\) \{\n {2}:root\[data-skin="beam"\]:not\(\[data-theme="light"\]\) \{\n([\s\S]*?)\n {2}\}\n\}/.exec(css);
  assert.ok(sys, 'the dark block under the device\'s dark mode');
  assert.deepEqual(tokens(sys[1]), PALETTES['beam dark']);
  // BEAM's own wallet: navy, the turquoise button with its marine label, received blue, sent violet.
  assert.equal(PALETTES['beam dark'].bg, '#042548');
  for (const m of ['light', 'dark']) {
    assert.equal(PALETTES[`beam ${m}`].primary, '#00f6d2', m);
    assert.equal(PALETTES[`beam ${m}`]['on-primary'], '#032e49', m);
  }
  assert.equal(PALETTES['beam dark'].in, '#0bccf7');
  assert.equal(PALETTES['beam dark'].out, '#da68f5');
});

// docs/beam-brand-palette.json: BEAM's colours with their sources, and the skin made from them.
const BRAND = JSON.parse(readFileSync(new URL('../../docs/beam-brand-palette.json', import.meta.url), 'utf8'));

test("css: the BEAM skin is docs/beam-brand-palette.json's, and every value it calls BEAM's own is one of BEAM's", () => {
  const own = new Set([...BRAND.wallet_ui.colors, ...BRAND.brand_kit.colors].map((c) => c.hex.toLowerCase()));
  for (const m of ['light', 'dark']) {
    const skin = BRAND.campfire_skin[m];
    const css = PALETTES[`beam ${m}`];
    const colours = Object.keys(css).filter((k) => k !== 'shadow');
    assert.deepEqual(Object.keys(skin).sort(), colours.sort(), `${m}: the same tokens`);
    for (const k of colours) {
      assert.equal(css[k], skin[k].hex.toLowerCase(), `${m} --${k}`);
      if (skin[k].basis === 'exact') assert.ok(own.has(css[k]), `${m} --${k} ${css[k]} is called BEAM's own`);
      else assert.ok(skin[k].basis === 'derived' && skin[k].how, `${m} --${k}: how it was derived`);
    }
  }
  // Every colour cited has a source with a link.
  for (const c of [...BRAND.wallet_ui.colors, ...BRAND.website.colors]) assert.match(c.url, /^https:\/\/github\.com\/BeamMW\/[\w-]+\/blob\/[0-9a-f]{40}\//, c.name);
});

// WCAG 2 contrast of two opaque colours.
const lin = (c) => ((c /= 255) <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
const lum = (hex) => {
  const n = parseInt(hex.slice(1), 16);
  return 0.2126 * lin(n >> 16) + 0.7152 * lin((n >> 8) & 255) + 0.0722 * lin(n & 255);
};
const ratio = (a, b) => {
  const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
};
// Every text colour, on every background the stylesheet puts it on.
const TEXT_PAIRS = [
  ...['text', 'text-2', 'muted', 'primary-text', 'on-secondary', 'error', 'success'].flatMap((f) => ['bg', 'surface', 'surface-2', 'bg-top'].map((b) => [f, b])),
  // Received and sent amounts: history rows sit in cards, on the page, or under the band.
  ...['in', 'out-text'].flatMap((f) => ['bg', 'surface', 'bg-top'].map((b) => [f, b])),
  ['on-primary', 'primary'], ['on-secondary', 'secondary'], ['bg', 'text'],
  ['success', 'success-bg'], ['error', 'error-bg'], ['info', 'info-bg'], ['warn', 'warn-bg'], ['text', 'secondary'],
];

test('every text colour reads at 4.5:1 or more on what it sits on, in both skins, light and dark', () => {
  const low = [];
  for (const [name, p] of Object.entries(PALETTES)) {
    for (const [f, b] of TEXT_PAIRS) {
      const r = ratio(p[f], p[b]);
      if (r < 4.5) low.push(`${name}: --${f} on --${b} ${r.toFixed(2)}`);
    }
  }
  assert.deepEqual(low, []);
});

// BEAM's skin, beyond what Campfire's palette was built for: its yellow is text too (.tone-wait), and its
// marks and controls read at 3:1 (WCAG 1.4.11): the arrows on their discs (received, sent, swapped), the icon on a done or failed
// step, and the accent (progress, radio, focus) on every surface.
const BEAM_TEXT = [['yellow', 'bg'], ['yellow', 'surface']];
const BEAM_MARKS = [['in', 'in-bg'], ['out', 'out-bg'], ['swap', 'swap-bg'], ['on-green', 'green'], ['on-red', 'red'], ['accent', 'bg'], ['accent', 'surface'], ['accent', 'surface-2'], ['green', 'surface'], ['red', 'surface']];

test('BEAM: its yellow text reads at 4.5:1, and its marks and controls at 3:1, light and dark', () => {
  const low = [];
  for (const m of ['light', 'dark']) {
    const p = PALETTES[`beam ${m}`];
    for (const [f, b] of BEAM_TEXT) if (ratio(p[f], p[b]) < 4.5) low.push(`beam ${m}: --${f} on --${b} ${ratio(p[f], p[b]).toFixed(2)}`);
    for (const [f, b] of BEAM_MARKS) if (ratio(p[f], p[b]) < 3) low.push(`beam ${m}: --${f} on --${b} ${ratio(p[f], p[b]).toFixed(2)}`);
  }
  assert.deepEqual(low, []);
});

test('css: Campfire red looks as it did: the new colours are Campfire\'s own', () => {
  for (const m of ['light', 'dark']) {
    const p = PALETTES[`campfire ${m}`];
    assert.equal(p.accent, p.primary, m);
    assert.deepEqual([p.in, p['in-bg']], [p.success, p['success-bg']], m);
    assert.deepEqual([p.out, p['out-bg'], p['out-text']], [p['on-secondary'], p.secondary, p.text], m);
    assert.deepEqual([p.swap, p['swap-bg']], [p.info, p['info-bg']], m);
    assert.deepEqual([p['on-green'], p['on-red'], p['bg-top']], ['#ffffff', '#ffffff', p.bg], m);
  }
});

test('css: text never takes the icon grey (--subtle) or the button colour (--primary) as its colour', () => {
  for (const m of css.matchAll(/([^{}\n]+)\{([^}]*)\}/g)) {
    const [sel, body] = [m[1].trim(), m[2]];
    if (/(^|[;\s])color: var\(--subtle\)/.test(body)) assert.match(sel, /svg|\.chev|\.off\b/, `${sel} draws text in --subtle`);
    if (/(^|[;\s])color: var\(--primary\)/.test(body)) assert.fail(`${sel} draws text in --primary (use --primary-text)`);
  }
});

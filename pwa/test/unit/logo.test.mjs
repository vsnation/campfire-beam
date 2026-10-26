// The app's mark (lib/logo.js): Campfire's flame drawn into the page, so it takes the colours on show.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { LOGO_PATH } from '../../src/lib/logo.js';

const src = (p) => readFileSync(new URL(`../../src/${p}`, import.meta.url), 'utf8');

test("the flame is img/logo.svg's own drawing, in the splash and in every screen's mark", () => {
  assert.equal(/<path d="([^"]+)"/.exec(src('img/logo.svg'))[1], LOGO_PATH);
  const html = src('index.html');
  assert.equal(/<div class="hero"><svg class="logo-mark"[^>]*>[\s\S]*?<path d="([^"]+)" fill="url\(#logo-0\)"\/><\/svg>/.exec(html)[1], LOGO_PATH, 'the splash draws the same flame');
  for (const f of ['screens/welcome.js', 'screens/unlock.js', 'screens/install.js', 'screens/wallets.js', 'screens/one_tab.js', 'screens/consent.js', 'lib/ui.js']) {
    assert.doesNotMatch(src(f), /img\/logo\.svg/, `${f} draws the mark`);
    assert.match(src(f), /logoMark\(\)/, f);
  }
});

test("css: the flame in Campfire red's gradient, and in BEAM's turquoise to cyan with BEAM's colours", () => {
  const css = src('css/app.css');
  assert.match(css, /\n\.logo-mark \.a \{ stop-color: #f5595c; \}\n\.logo-mark \.b \{ stop-color: #f94167; \}\n:root\[data-skin="beam"\] \.logo-mark \.a \{ stop-color: #00f6d2; \}\n:root\[data-skin="beam"\] \.logo-mark \.b \{ stop-color: #0bccf7; \}/);
  // The red ones are the original image's.
  const svg = src('img/logo.svg');
  assert.match(svg, /<stop stop-color="#F5595C"\/>/);
  assert.match(svg, /<stop offset="1" stop-color="#F94167"\/>/);
  // BEAM's are its wallet's turquoise and received cyan (docs/beam-brand-palette.json).
  const brand = JSON.parse(readFileSync(new URL('../../docs/beam-brand-palette.json', import.meta.url), 'utf8'));
  const own = new Set(brand.wallet_ui.colors.map((c) => c.hex.toLowerCase()));
  assert.ok(own.has('#00f6d2') && own.has('#0bccf7'));
});

// The web wallet names and draws every Confidential Asset as the desktop app
// does. fixtures/asset_parity.json holds every asset on mainnet (its metadata,
// cut to the fields a name is made from), every DEX pool, extra cases taken from
// the desktop's own catalogue tests, and what the desktop's code shows for each:
// tools/asset_parity/run.mjs runs that code (lib/wallets/beam/assets/
// beam_asset_catalog.dart) unchanged to produce it.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { display, frameInset } from '../../src/lib/meta.js';
import { SNAPSHOT, learnPool, resetLpTokens } from '../../src/lib/lp_tokens.js';

const here = dirname(fileURLToPath(import.meta.url));
const pwa = join(here, '..', '..');
const fx = JSON.parse(readFileSync(join(here, 'fixtures', 'asset_parity.json'), 'utf8'));

/** The desktop's bundled path -> this app's (the same file, test/unit/asset_icons.test.mjs). */
const iconPath = (p) => (p === 'assets/beam/icons/beam.svg' ? 'img/beam.svg' : p.replace(/^assets\/beam\/icons\//, 'img/assets/'));

const shown = (d) => ({
  name: d.name,
  symbol: d.symbol,
  label: d.label,
  verified: d.verified,
  icon: d.icon,
  framed: frameInset(d.icon),
  impersonates: d.impersonates,
  pool: d.pool ? { aid1: d.pool.aid1, aid2: d.pool.aid2, kind: d.pool.kind } : null,
});
const expected = (e) => ({ ...e, icon: iconPath(e.icon) });

const rows = [...fx.assets, ...fx.extras];
const meta = new Map(rows.filter((r) => r.metadata != null).map((r) => [r.id, r.metadata]));
const metaOf = (id) => meta.get(id) ?? null;

test('the bundled LP list is the DEX\'s pool list at the fixture\'s height', () => {
  assert.deepEqual(
    Object.fromEntries(fx.pools.map((p) => [p.lpToken, [p.aid1, p.aid2, p.kind]])),
    Object.fromEntries(Object.entries(SNAPSHOT).map(([k, v]) => [k, [...v]])),
    'run tools/asset_parity/run.mjs and update SNAPSHOT in src/lib/lp_tokens.js',
  );
});

test(`every mainnet asset (${fx.assets.length}) shows the desktop's name, ticker, icon and copy warning`, () => {
  resetLpTokens();
  const differ = [];
  for (const r of fx.assets) {
    const want = expected(fx.desktop.withMetadata[r.id]);
    const got = shown(display(r.id, r.metadata, metaOf));
    if (JSON.stringify(got) !== JSON.stringify(want)) differ.push({ id: r.id, got, want });
  }
  assert.deepEqual(differ, []);
});

test(`edge cases (${fx.extras.length}): copycats, invisible characters, long names, pools of pools`, () => {
  resetLpTokens();
  for (const p of fx.extraPools) learnPool(p);
  try {
    const differ = [];
    for (const r of fx.extras) {
      const want = expected(fx.desktop.withMetadata[r.id]);
      const got = shown(display(r.id, r.metadata, metaOf));
      if (JSON.stringify(got) !== JSON.stringify(want)) differ.push({ id: r.id, metadata: r.metadata, got, want });
    }
    assert.deepEqual(differ, []);
  } finally {
    resetLpTokens();
  }
});

test('before any metadata arrives, every asset still looks as on the desktop', () => {
  resetLpTokens();
  for (const p of fx.extraPools) learnPool(p);
  try {
    const differ = [];
    for (const r of rows) {
      const want = expected(fx.desktop.bare[r.id]);
      const got = shown(display(r.id, null));
      if (JSON.stringify(got) !== JSON.stringify(want)) differ.push({ id: r.id, got, want });
    }
    assert.deepEqual(differ, []);
  } finally {
    resetLpTokens();
  }
});

test('every icon either app names for these assets is bundled here', () => {
  const icons = new Set(Object.values(fx.desktop.withMetadata).map((d) => iconPath(d.icon)));
  for (const p of icons) assert.ok(existsSync(join(pwa, 'src', p)), p);
});

test('the owner-reported rows: FOMO, CHAD, GIGA and their pools', () => {
  resetLpTokens();
  const at = (id) => display(id, metaOf(id), metaOf);
  assert.deepEqual([174, 190, 191].map((id) => [at(id).name, at(id).icon]), [
    ['FOMO', 'img/assets/174.png'],
    ['Chad', 'img/assets/187.png'],
    ['GigaChad', 'img/assets/186.png'],
  ]);
  assert.deepEqual([175, 192, 193].map((id) => at(id).name), ['BEAM/FOMO LP', 'BEAM/CHAD LP', 'BEAM/GIGA LP']);
});

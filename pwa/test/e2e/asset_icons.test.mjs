// Asset names and icons on Home's token list, end to end: the installed Google
// Chrome (headless), a build of this tree in its own folder, BEAM mainnet.
// Spends nothing: a throwaway wallet that holds nothing; the page is shown token
// balances it does not have (the page's state only), as names_airdrop.test.mjs does.
//
//   node tools/stage_engine.mjs && node --test test/e2e/asset_icons.test.mjs
//
// Its own port (8890) and build folder, so it runs beside the shared suites.
// ASSET_ICONS_ROOT=<a built folder> ASSET_ICONS_SHOTS=before serves that folder
// instead (an older build) and only takes the pictures, for a before/after.
//
// Checks, for the assets of the owner's report and the cases around them: the
// desktop's names ("BEAM/FOMO LP", not "Unnamed asset"), the bundled icons drawn
// (every picture decoded, from this origin), a pool's two icons for an LP token,
// the copy warning under a fake FOMO, names that need the chain (an LP token's
// unverified side, a held asset the bundled pool list does not know, which makes
// Home read the DEX's pools), and nothing asked of any host but this one and the node.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { PWA, startServer, launch, recordedPage, shot, foreignHosts, sleep, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';

const PORT = Number(process.env.E2E_PORT || 8890);
const ONLY_SHOTS = process.env.ASSET_ICONS_SHOTS || null; // e.g. "before"
const ROOT = process.env.ASSET_ICONS_ROOT || join(tmpdir(), 'campfire-asset-icons-dist');
const TAG = ONLY_SHOTS || 'after';
const PASSWORD = `icons-${Math.random().toString(36).slice(2, 10)}`;
const tid = (id) => `[data-testid="${id}"]`;

// The owner's screenshot (FOMO, CHAD, GIGA and their three pools), plus: a verified asset with
// its own icon (BEAMX) and with the generic one (bETH), NPH's framed icon, a copy of FOMO (#173),
// an LP token with an unverified side (BEAM/RAYS #2, #55), and PEPE (#94), unverified.
const HOLD = { 174: 568_12970000n, 190: 6_477_953_06000000n, 191: 1_250_00000000n, 175: 2_728_25000000n, 192: 12_50000000n, 193: 3_00000000n, 7: 1_20000000n, 36: 50000000n, 47: 10_00000000n, 173: 5_00000000n, 55: 1_00000000n, 94: 42_00000000n };
const WANT = {
  174: { name: 'FOMO', sub: 'FOMO', unit: 'FOMO', icon: 'img/assets/174.png' },
  190: { name: 'Chad', sub: 'CHAD', unit: 'CHAD', icon: 'img/assets/187.png' },
  191: { name: 'GigaChad', sub: 'GIGA', unit: 'GIGA', icon: 'img/assets/186.png' },
  175: { name: 'BEAM/FOMO LP', sub: 'Pool share · 1% fee', unit: 'LP', pair: '0/174' },
  192: { name: 'BEAM/CHAD LP', sub: 'Pool share · 1% fee', unit: 'LP', pair: '0/190' },
  193: { name: 'BEAM/GIGA LP', sub: 'Pool share · 1% fee', unit: 'LP', pair: '0/191' },
  7: { name: 'BeamX', sub: 'BEAMX', unit: 'BEAMX', icon: 'img/assets/7.png' },
  36: { name: 'Wrapped ETH', sub: 'bETH', unit: 'bETH', icon: 'img/assets/generic/asset-16.svg' },
  47: { name: 'Nephrite', sub: 'NPH', unit: 'NPH', icon: 'img/assets/47.svg' },
  173: { name: 'FOMO', sub: 'FOMO · Unverified #173', unit: 'FOMO', icon: 'img/assets/generic/asset-13.svg', warning: 'Not the verified FOMO (#174). Anyone can create an asset with any name.' },
  55: { name: 'BEAM/RAYS #2 LP', sub: 'Pool share · 1% fee', unit: 'LP', pair: '0/2' },
  94: { name: 'PEPE', sub: 'PEPE · Unverified #94', unit: 'PEPE', icon: 'img/assets/generic/asset-14.svg' },
};

let srv, browser, ctx, page, rec;

async function pretendBalance(tokens) {
  await page.evaluate(async (t) => {
    const { wallet } = await import('./lib/wallet.js');
    if (!wallet.__realRefresh) wallet.__realRefresh = wallet.refreshStatus.bind(wallet);
    wallet.refreshStatus = async function () {
      await this.__realRefresh();
      for (const [id, v] of Object.entries(t)) this.state.totals.set(Number(id), { available: BigInt(v), receiving: 0n, sending: 0n, maturing: 0n });
      this.emit();
    };
    await wallet.refreshStatus();
  }, Object.fromEntries(Object.entries(tokens).map(([k, v]) => [k, String(v)])));
}

/** The token list as shown: per row its name, subtitle, warning, balance, and the pictures drawn. */
const readRows = () =>
  page.$$eval('[data-testid="token-row"]', (rows) =>
    rows.map((r) => {
      const text = (id) => r.querySelector(`[data-testid="${id}"]`)?.textContent ?? null;
      const badge = r.querySelector('.asset-badge');
      return {
        id: Number(r.dataset.assetId),
        name: text('token-name'),
        sub: text('token-sub'),
        warning: text('token-warning'),
        balance: text('token-balance'),
        icon: badge?.dataset.icon ?? null,
        pair: badge?.dataset.pair ?? null,
        letters: badge && !badge.querySelector('img') ? badge.textContent : null,
        imgs: [...r.querySelectorAll('.asset-badge img')].map((i) => ({ src: i.getAttribute('src'), ok: i.complete && i.naturalWidth > 0 })),
        box: (() => {
          const b = badge.getBoundingClientRect();
          return [Math.round(b.width), Math.round(b.height)];
        })(),
      };
    }),
  );

// Home re-renders its rows on every wallet update: always find the list afresh.
async function shots(name) {
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(300);
    await page.evaluate(() => document.querySelector('[data-testid="tokens"]').scrollIntoView({ block: 'start' }));
    await sleep(300);
    await shot(page, `${name}-phone-${scheme}`);
    await page.locator(tid('tokens')).screenshot({ path: join(SHOTS, `${name}-list-${scheme}.png`) });
  }
  await page.emulateMedia({ colorScheme: 'light' });
}

before(async () => {
  if (!process.env.ASSET_ICONS_ROOT) execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', ROOT, '--quiet'], { cwd: PWA, stdio: 'inherit' });
  srv = await startServer({ root: ROOT, port: PORT });
  browser = await launch();
  // An iPhone-sized phone: 375 px wide, 3 device pixels per CSS pixel (icons must stay crisp).
  ctx = await browser.newContext({ viewport: { width: 375, height: 812 }, deviceScaleFactor: 3, locale: 'en-GB' });
  ({ page, rec } = await recordedPage(ctx, { label: 'asset-icons' }));
  console.log(`# screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
});

test('Home names and draws every token as the desktop app does', { timeout: 20 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  await waitSynced(page);
  await pretendBalance(HOLD);
  await page.waitForSelector(tid('tokens'));

  if (ONLY_SHOTS) {
    await sleep(20000); // what the old build manages to name in that time
    console.log(`# ${TAG}: ${JSON.stringify(await readRows())}`);
    await shots(`asset-icons-${TAG}`);
    return;
  }

  // Names that need the chain arrive by themselves: PEPE's and RAYS's metadata, and the pool check.
  await page.waitForFunction(
    () => {
      const t = (id) => document.querySelector(`[data-testid="token-row"][data-asset-id="${id}"] [data-testid="token-name"]`)?.textContent;
      return t(94) === 'PEPE' && t(55) === 'BEAM/RAYS #2 LP' && t(173) === 'FOMO';
    },
    null,
    { timeout: 180000, polling: 1000 },
  );
  // Every picture decoded, and laid out (right after the screen appears it may not be yet).
  await page.waitForFunction(() => [...document.querySelectorAll('[data-testid="tokens"] img')].every((i) => i.complete) && [...document.querySelectorAll('[data-testid="token-row"] > .asset-badge')].every((b) => b.getBoundingClientRect().width > 0), null, { timeout: 30000 });
  const rows = await readRows();
  console.log(`# ${TAG}: ${JSON.stringify(rows)}`);
  await shots(`asset-icons-${TAG}`);

  assert.deepEqual(rows.map((r) => r.id), [7, 36, 47, 174, 175, 190, 191, 192, 193, 55, 94, 173], 'verified (and pools of two verified assets) first, then by number');
  for (const r of rows) {
    const w = WANT[r.id];
    assert.equal(r.name, w.name, `#${r.id} name`);
    assert.equal(r.sub, w.sub, `#${r.id} subtitle`);
    assert.equal(r.warning, w.warning ?? null, `#${r.id} warning`);
    assert.ok(r.balance.endsWith(` ${w.unit}`), `#${r.id} balance "${r.balance}"`);
    if (w.pair) assert.equal(r.pair, w.pair, `#${r.id} pair`);
    else assert.equal(r.icon, w.icon, `#${r.id} icon`);
    assert.equal(r.letters, null, `#${r.id} is drawn, not lettered`);
    assert.equal(r.imgs.length, w.pair ? 2 : 1, `#${r.id} pictures`);
    for (const i of r.imgs) assert.ok(i.ok, `#${r.id}: ${i.src} did not decode`);
    assert.deepEqual(r.box, [36, 36], `#${r.id} badge size`);
  }

  // Home read the DEX's pool list (PEPE is not in the bundled list), through this origin's pinned shader.
  const loaded = await page.evaluate(() => performance.getEntriesByType('resource').map((e) => new URL(e.name).pathname));
  assert.ok(loaded.some((p) => p.includes('/shaders/')), 'the AMM shader was loaded for the pool check');
  for (const p of ['img/assets/174.png', 'img/assets/186.png', 'img/assets/187.png', 'img/assets/47.svg']) assert.ok(loaded.some((x) => x.endsWith(p)), p);
  const pools = await page.evaluate(async () => (await (await import('./lib/dex_pools.js')).loadPools()).length);
  assert.ok(pools >= 98, `pools_view answered ${pools} pools`);

  // Every screen that names an asset agrees: the money screens' unit.
  const units = await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    return Object.fromEntries([175, 192, 193, 55, 173, 94].map((id) => [id, wallet.label(id).unit]));
  });
  assert.deepEqual(units, { 175: 'BEAM/FOMO LP', 192: 'BEAM/CHAD LP', 193: 'BEAM/GIGA LP', 55: 'BEAM/RAYS #2 LP #55', 173: 'FOMO #173', 94: 'PEPE #94' });

  assert.deepEqual(foreignHosts(rec, srv.url), [], 'only this origin and the node');
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
  // The list fits a 375 px phone: nothing wider than the screen.
  assert.equal(await page.evaluate(() => document.scrollingElement.scrollWidth), 375);
  await shots(`asset-icons-${TAG}`);
});

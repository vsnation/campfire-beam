// Issue #82: the version in small print on Welcome, Unlock and first-run setup, so a person trying
// another copy of the app sees which release it serves before making or opening a wallet.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { versionText } from '../../src/lib/ui.js';
import { installVersion, doneLine } from '../../src/screens/install.js';

const src = (p) => readFileSync(new URL(`../../src/${p}`, import.meta.url), 'utf8');

test('the words: "Version 0.2.14" for a built release; nothing for an unbuilt tree or anything else', () => {
  assert.equal(versionText('0.2.14', true), 'Version 0.2.14');
  assert.equal(versionText('10.20.300', true), 'Version 10.20.300');
  assert.equal(versionText('0.2.14', false), null, 'serving src/: no version to show');
  assert.equal(versionText('__BUILD_VERSION__', true), null, 'a placeholder never shows');
  for (const v of ['', '0.2', '0.2.14-beta', '<b>1.0.0</b>', null, undefined, 214]) assert.equal(versionText(v, true), null, String(v));
  // Here, unbuilt: the defaults (lib/version.js) say so.
  assert.equal(versionText(), null);
});

test('first-run setup: the version is the one the signed release names, and the last line says it was checked', () => {
  assert.equal(installVersion(null), null, 'nothing before the loader has read release.json');
  assert.equal(installVersion({ state: 'checking', done: 0, total: 0 }), null, 'release.json not verified yet');
  assert.equal(installVersion({ state: 'downloading', version: '0.2.14', total: 40 }), '0.2.14');
  assert.equal(installVersion({ state: 'done', version: '0.2.14' }), '0.2.14');
  assert.equal(installVersion({ version: 'not a version' }), null);
  assert.equal(doneLine('0.2.14'), 'Version 0.2.14 checked. Opening Beam PWA…');
  assert.equal(doneLine(null), 'Checked. Opening Beam PWA…', 'as before when no version came');
});

test('each of the three screens puts the line on itself, last; the style keeps it small and at the bottom', () => {
  for (const f of ['screens/welcome.js', 'screens/unlock.js']) {
    const s = src(f);
    assert.match(s, /const version = versionLine\(\);\n {2}if \(version\) el\.appendChild\(version\);/, f);
  }
  const inst = src('screens/install.js');
  assert.match(inst, /el\.appendChild\(versionEl\);/);
  assert.match(inst, /'data-testid': 'app-version'/);
  // The page shows a version only after the loader verified release.json, never the page's own claim.
  assert.doesNotMatch(inst, /APP_VERSION/);
  const css = src('css/app.css');
  assert.match(css, /\n\.version \{ margin: auto 0 0; [^}]*font-size: 13px; color: var\(--muted\);/);
});

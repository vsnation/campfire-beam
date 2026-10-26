// tools/i18n_extract.mjs writes translations into two classic scripts (lang-boot.js, loader-watch.js) as
// code. Release audit 0.2.20 (BP-3): JSON leaves U+2028/U+2029 raw, the table's end was found by a
// regular expression that reads them as line ends, and a translation with ";" + U+2028 left its tail in
// loader-watch.js as code on the next run. Now they are written escaped, and a raw one is refused.
import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
import { withTable } from '../../tools/i18n_extract.mjs';

const SRC = '(function () {\n  var TEXTS = {};\n  globalThis.__table = TEXTS;\n})();\n';
const run = (code) => {
  const ctx = vm.createContext({});
  vm.runInContext(code, ctx);
  return ctx;
};

test("a translation with a line separator stays a string: escaped, the same after a second run, nothing runs", () => {
  const evil = { de: { 'Stop: unsigned code': 'Halt;\u2028globalThis.PWNED = 1;{/*' } };
  const once = withTable(SRC, evil);
  assert.doesNotMatch(once, /[\u2028\u2029]/, 'escaped');
  const ctx = run(once);
  assert.equal(ctx.PWNED, undefined);
  assert.equal(ctx.__table.de['Stop: unsigned code'], 'Halt;\u2028globalThis.PWNED = 1;{/*', 'the text itself, unchanged');
  // The translation fixed: the whole old table goes, nothing of it stays behind.
  const twice = withTable(once, { de: { 'Stop: unsigned code': 'Halt' } });
  assert.equal(twice, withTable(SRC, { de: { 'Stop: unsigned code': 'Halt' } }));
  assert.equal(run(twice).PWNED, undefined);
  assert.equal(withTable(twice, { de: { 'Stop: unsigned code': 'Halt' } }), twice, 'stable: --check passes only for this');
});

test('a file with a raw line separator is refused, and so is one without a table', () => {
  assert.throws(() => withTable(SRC.replace('{};', '{};\u2028'), {}), /U\+2028/);
  assert.throws(() => withTable('var X = 1;\n', {}), /table/);
});

test('the shipped scripts: no raw line separator, and their tables are what the catalogs give', () => {
  for (const f of ['lang-boot.js', 'loader-watch.js']) {
    const s = readFileSync(new URL(`../../src/${f}`, import.meta.url), 'utf8');
    assert.doesNotMatch(s, /[\u2028\u2029]/, f);
  }
});

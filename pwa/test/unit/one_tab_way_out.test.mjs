// Release audit RE3-1: in a browser whose lock manager cannot say which tab holds the wallet, the
// fail-closed screen ("Close your other Beam PWA tabs, then reload") comes back after every
// reload. Its way out, another browser and the wallet's words or file, is said under the button, and
// above it once the screen comes back in the same tab.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { UNCHECKED_WAY_OUT, UNCHECKED_LEAD, uncheckedSeen } from '../../src/screens/one_tab.js';

function memory() {
  const m = new Map();
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)) };
}

test('the words: another browser, and the 12 words or the wallet.db file', () => {
  assert.equal(UNCHECKED_LEAD, 'This browser cannot keep Beam PWA to one tab. Close every other Beam PWA tab, then reload.');
  assert.equal(UNCHECKED_WAY_OUT, 'If this keeps happening, this browser cannot run Beam PWA safely: open it in another browser and restore your wallet there from its 12 words (or its wallet.db file).');
});

test('counted per tab: the first time, then again after a reload; storage that cannot be used counts as the first', () => {
  const s = memory();
  assert.equal(uncheckedSeen(s), 1);
  assert.equal(uncheckedSeen(s), 2);
  assert.equal(uncheckedSeen(s), 3);
  const blocked = { getItem: () => { throw new Error('blocked'); }, setItem: () => { throw new Error('blocked'); } };
  assert.equal(uncheckedSeen(blocked), 1);
});

test('the screen: under Reload the first time, a notice above it after that', () => {
  const s = readFileSync(new URL('../../src/screens/one_tab.js', import.meta.url), 'utf8');
  assert.match(s, /const again = seenBefore\(\);/);
  assert.match(s, /const seenBefore = \(\) => \(thisLoad === null \? \(thisLoad = uncheckedSeen\(\)\) : thisLoad\) > 1;/, 'counted once per page load, however often it is drawn');
  assert.match(s, /again \? h\('div', \{ 'data-testid': 'one-tab-way-out', 'data-again': 'true' \}, notice\('warn', t\(UNCHECKED_WAY_OUT\)\)\) : null/);
  assert.match(s, /again \? null : h\('p', \{ class: 'small center', 'data-testid': 'one-tab-way-out', text: t\(UNCHECKED_WAY_OUT\) \}\)/);
});

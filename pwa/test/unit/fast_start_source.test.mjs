// Issue #79: on Restore and Rescan, "Use a recovery file I downloaded" is always offered, with one
// plain line on where the snapshot comes from. No address of another copy can be typed in: that
// would widen the page's connect-src, which stays exactly as it was.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { sourceWords, SCAN_TIME } from '../../src/screens/fast_start.js';
import { RECOVERY_OFFICIAL, recoveryConnectSources } from '../../src/lib/recovery.js';
import { CSP } from '../../tools/headers.mjs';

const src = (p) => readFileSync(new URL(`../../src/${p}`, import.meta.url), 'utf8');
const line = (w) => `${w.lead}${w.address}${w.rest}`;

test('the line: BEAM publishes it daily, the same file as its wallets; who passes it on; the engine checks any copy; scanning instead', () => {
  assert.equal(RECOVERY_OFFICIAL, 'mobile-restore.beam.mw/mainnet/mainnet_recovery.bin');
  assert.equal(SCAN_TIME, '1–4 hours');
  assert.equal(
    line(sourceWords()),
    "BEAM publishes this snapshot daily at mobile-restore.beam.mw/mainnet/mainnet_recovery.bin, for its own wallets too. This site only passes it on, and the wallet engine checks any copy against the blockchain's proof of work. Without it, the wallet can scan the chain instead (1–4 hours).",
  );
  assert.equal(sourceWords().address, RECOVERY_OFFICIAL, 'the address is the link between the words');
  assert.match(line(sourceWords({ relay: 'pwa.buybeam.my' })), / pwa\.buybeam\.my only passes it on, /, 'a copy without a relay names the server that passes it on');
  const rescan = line(sourceWords({ rescan: true }));
  assert.ok(!/scan the chain instead/.test(rescan), 'a rescan needs the snapshot: no scanning instead');
  const own = line(sourceWords({ relay: null }));
  assert.ok(!/passes it on/.test(own), 'nobody passes it on when the person brings the file');
  assert.match(own, /The wallet engine checks it against the blockchain's proof of work\./);
});

test('the screen: the file button in every choice, the how-to only when it is the way on, the skip says how long', () => {
  const s = src('screens/fast_start.js');
  assert.match(s, /noRelay \? secondary\(t\('Try the download anyway'\), startDownload, \{ 'data-testid': 'fast-download' \}\) : fileButton\('btn-secondary'\),/, 'always a second button');
  assert.match(s, /const howToFile = Boolean\(errorText\) \|\| noRelay;/);
  assert.match(s, /textButton\(t\('Skip and scan instead \(\{time\}\)', \{ time: t\(SCAN_TIME\) \}\)/);
  assert.match(s, /'data-testid': 'recovery-source'/);
  // Nothing to type an address into: the snapshot comes from this site, Beam PWA's server or a file.
  assert.doesNotMatch(s, /type: 'url'|inputmode: 'url'/);
});

test('the page policy is unchanged: the snapshot only from this site or that one path of Beam PWA\'s server', () => {
  assert.deepEqual(recoveryConnectSources(), ['https://pwa.buybeam.my/recovery/']);
  const connect = /connect-src ([^;]+)/.exec(CSP)[1].split(/\s+/);
  assert.ok(connect.includes('https://pwa.buybeam.my/recovery/'));
  assert.ok(!connect.some((x) => /mobile-restore\.beam\.mw/.test(x)), 'BEAM\'s own host is linked, never contacted by the page');
});

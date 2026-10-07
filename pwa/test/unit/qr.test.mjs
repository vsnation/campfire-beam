// QR encoder checked against an independent decoder (jsQR, dev-only).
import test from 'node:test';
import assert from 'node:assert/strict';
import jsQR from 'jsqr';
import { encodeQr, qrToRgba, qrSvgPath } from '../../src/lib/qr.js';

function roundTrip(text, opts) {
  const qr = encodeQr(text, opts);
  const img = qrToRgba(qr, { scale: 4, border: 4 });
  const res = jsQR(img.data, img.width, img.height, { inversionAttempts: 'dontInvert' });
  assert.ok(res, `jsQR could not read version ${qr.version} (${text.length} chars)`);
  assert.equal(res.data, text);
  return qr;
}

test('short text decodes', () => {
  const qr = roundTrip('hello');
  assert.equal(qr.version, 1);
});

test('a BEAM regular address (≈400 base58 characters) decodes', () => {
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  let s = '';
  let x = 12345;
  for (let i = 0; i < 410; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    s += alphabet[x % alphabet.length];
  }
  const qr = roundTrip(s);
  assert.ok(qr.version >= 13 && qr.version <= 16, `version ${qr.version}`);
});

test('every ECC level and many versions decode', () => {
  for (const ecl of ['L', 'M', 'Q', 'H']) {
    for (const len of [1, 17, 50, 100, 200, 300, 500, 800]) {
      const text = 'x'.repeat(len).replace(/x/g, (_, i) => String.fromCharCode(33 + ((i * 7) % 90)));
      roundTrip(text, { ecl, boostEcl: false });
    }
  }
});

test('versions 1..40 each decode at their own capacity edge', () => {
  for (let v = 1; v <= 40; v += 1) {
    const qr = encodeQr('a', { minVersion: v, maxVersion: v, boostEcl: false });
    assert.equal(qr.version, v);
    const img = qrToRgba(qr, { scale: v > 30 ? 3 : 4 });
    const res = jsQR(img.data, img.width, img.height, { inversionAttempts: 'dontInvert' });
    assert.ok(res && res.data === 'a', `version ${v} not readable`);
  }
});

test('UTF-8 text decodes', () => {
  roundTrip('BEAM Campfire — приватность ✓');
});

test('too much data is refused', () => {
  assert.throws(() => encodeQr('x'.repeat(3000), { ecl: 'H' }), RangeError);
});

test('svg path has one square per dark module', () => {
  const qr = encodeQr('beam');
  let dark = 0;
  for (const row of qr.modules) for (const c of row) if (c) dark++;
  assert.equal((qrSvgPath(qr).match(/M/g) || []).length, dark);
});

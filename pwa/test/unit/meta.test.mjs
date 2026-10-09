import test from 'node:test';
import assert from 'node:assert/strict';
import { parseMetadata, assetLabel, badgeText } from '../../src/lib/meta.js';

test('parses the STD metadata fields', () => {
  const m = parseMetadata('STD:SCH_VER=1;N=Fomo Token;SN=FOMO;UN=FOMO;NTHUN=GROTH;NTH_RATIO=100000000;OPT_SHORT_DESC=Meme coin;OPT_COLOR=#FF00AA');
  assert.equal(m.standard, true);
  assert.equal(m.name, 'Fomo Token');
  assert.equal(m.shortName, 'FOMO');
  assert.equal(m.unit, 'FOMO');
  assert.equal(m.nthUnit, 'GROTH');
  assert.equal(m.shortDesc, 'Meme coin');
  assert.equal(m.color, '#ff00aa');
  assert.equal('nthRatio' in m, false, 'NTH_RATIO is never used: every asset has 8 decimals');
});

test('values may contain "=" and the first key wins', () => {
  const m = parseMetadata('STD:N=a=b;N=other;UN=X');
  assert.equal(m.name, 'a=b');
  assert.equal(m.unit, 'X');
});

test('untrusted text is cleaned and capped', () => {
  const m = parseMetadata('STD:N=Evil‮Name\u0000\u0007;UN=' + 'U'.repeat(50) + ';OPT_COLOR=red;expression(alert(1))');
  assert.equal(m.name, 'EvilName');
  assert.ok(m.unit.length <= 16);
  assert.equal(m.color, '');
});

test('labels: BEAM is asset 0, unknown assets get a number', () => {
  assert.deepEqual(assetLabel(0), { id: 0, name: 'BEAM', unit: 'BEAM', color: '#25c2a0', verified: true });
  assert.equal(assetLabel(250, 'STD:N=Fomo;UN=FOMO').unit, 'FOMO');
  assert.equal(assetLabel(250, 'STD:N=Fomo;UN=FOMO').verified, false);
  assert.equal(assetLabel(12, '').unit, 'Asset #12');
  assert.equal(assetLabel(13, 'garbage').unit, 'Asset #13');
  assert.equal(assetLabel(5, 'STD:SN=Shorty').unit, 'Shorty');
});

test('labels: verified ids keep their checked names whatever their metadata says', () => {
  const l = assetLabel(174, 'STD:SCH_VER=1;N=Something else;UN=SCAM;NTH_RATIO=100000000');
  assert.equal(l.unit, 'FOMO');
  assert.equal(l.name, 'FOMO');
  assert.equal(l.verified, true);
  assert.equal(assetLabel(36).unit, 'bETH');
});

test('labels: an unverified asset never takes its own colour (it could copy a verified one)', () => {
  const l = assetLabel(250, 'STD:N=Fake;UN=FOMO;OPT_COLOR=#60a5fa');
  assert.notEqual(l.color, '#60a5fa');
  assert.match(l.color, /^#[0-9a-f]{6}$/);
});

test('badge letters: first two letters of the unit, a number for unnamed assets', () => {
  assert.equal(badgeText(assetLabel(174)), 'FO');
  assert.equal(badgeText(assetLabel(36)), 'bE');
  assert.equal(badgeText(assetLabel(12, '')), '#12');
  assert.equal(badgeText(assetLabel(7777, '')), 'CA', 'never a cut-off number');
  assert.equal(badgeText(assetLabel(250, 'STD:UN=$—X')), 'X');
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { parseMetadata, assetLabel } from '../../src/lib/meta.js';

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
  assert.deepEqual(assetLabel(0), { id: 0, name: 'BEAM', unit: 'BEAM', color: '' });
  assert.equal(assetLabel(174, 'STD:N=Fomo;UN=FOMO').unit, 'FOMO');
  assert.equal(assetLabel(9, '').unit, 'Asset 9');
  assert.equal(assetLabel(7, 'garbage').unit, 'Asset 7');
  assert.equal(assetLabel(5, 'STD:SN=Shorty').unit, 'Shorty');
});

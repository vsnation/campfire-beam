// The asset icons ship inside the release, pinned: each file here is the desktop
// app's (assets/beam/icons) byte for byte, so the two apps cannot drift apart
// unnoticed, and nothing is ever fetched from an issuer's server.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { VERIFIED, GENERIC_ICON_COUNT, genericIcon, MISSING_ICON } from '../../src/lib/meta.js';

const here = dirname(fileURLToPath(import.meta.url));
const src = join(here, '..', '..', 'src');
const desktop = join(here, '..', '..', '..', 'assets', 'beam', 'icons');
const sha256 = (p) => createHash('sha256').update(readFileSync(p)).digest('hex');

/** Every bundled icon: its path in this app, the desktop's file, its SHA-256. See img/assets/NOTICE.txt. */
const PINNED = {
  'img/beam.svg': ['beam.svg', 'a9b707fa1db1e41ccff69e8a16a93fa90e3432efc7ff9909a15e532ac5d2d5fc'],
  'img/assets/4.png': ['4.png', '4d078ccff3e757742a7de53147223a473109b9bfcb4c43e25571e8a5db7fdce1'],
  'img/assets/7.png': ['7.png', 'de7a38381f3d432e56a5b4754fe1f7347e861309f438d68fb0b733d38aea832a'],
  'img/assets/9.png': ['9.png', '3849aaf163583799c6aa91fb981153ecd974a8417cc5f6fe16a76f3707340cc7'],
  'img/assets/47.svg': ['47.svg', '2d46d4dab17daae71622277156b1d71cb1af53b39e05d9446b07f3476f8071a0'],
  'img/assets/174.png': ['174.png', 'eed995d6a1e1391cb39940eadaec45e16d8ed5d3e04c448ee505ff4b18bb95ef'],
  'img/assets/186.png': ['186.png', '0d5c11bcfdd4c08d2ad1948645477ba9cc6abba529b621dd661cc3f120fd52ca'],
  'img/assets/187.png': ['187.png', 'da297409ae9fc39057bef8a552b5c1409514d12deda8c52426ad52fac26a41b6'],
  'img/assets/generic/asset-0.svg': ['generic/asset-0.svg', 'f6428a3e3fa6d95fbfd3568726316b2e7fbc25d57cc4b060751ca5fab865309e'],
  'img/assets/generic/asset-1.svg': ['generic/asset-1.svg', 'c330bb18cb349527e9b95ec472feb6eb77bb660e6c2641e16b93abf85a5e80fc'],
  'img/assets/generic/asset-2.svg': ['generic/asset-2.svg', 'e19fd2caed6ae98eb508b0d95d40f7ce187add00eb16b3772c616e15db99fb21'],
  'img/assets/generic/asset-3.svg': ['generic/asset-3.svg', '5cf33ffe52270aba8febcaed267d2f9b85af1b6e4d61f214a740ae45bc06c01c'],
  'img/assets/generic/asset-4.svg': ['generic/asset-4.svg', '1ab0bcf5fa17eec30588f7c7e43b9b626ebf0281c063c45f6e3528e5892cdf70'],
  'img/assets/generic/asset-5.svg': ['generic/asset-5.svg', '6263a537c2abedf64ac25ead1aa8384de3627877da877766afb543aed6c5c4ab'],
  'img/assets/generic/asset-6.svg': ['generic/asset-6.svg', '0a3d4507d7e047405ba1a045adf4b8f05ebc784c78e10daccd9e36bf2cd92be3'],
  'img/assets/generic/asset-7.svg': ['generic/asset-7.svg', '75b8989eb6076e267ffe1cb45bb25f66e6e5e6ecf1eb1b83a1f0ebf9fec9feea'],
  'img/assets/generic/asset-8.svg': ['generic/asset-8.svg', 'da753228b4b15d6f7873bf9de6367b6fff9b501191bfa1bf34e91ccf7a68b98a'],
  'img/assets/generic/asset-9.svg': ['generic/asset-9.svg', 'ce7c3ac18e5902f7fb8f9f3ada5fba711c0525108ad13f967770d35bb61329a4'],
  'img/assets/generic/asset-10.svg': ['generic/asset-10.svg', '241719e8ea8b823f2baf4288c630625d8ea4f7ee54ee4d3898bc5925665cff11'],
  'img/assets/generic/asset-11.svg': ['generic/asset-11.svg', '22f200a932b160eb53e6f78e9db91f4a0f0fc37c737c95b77ada38b48dabda86'],
  'img/assets/generic/asset-12.svg': ['generic/asset-12.svg', '584f19a64205e0ef6ad57c944a2e30a11be2d0122ce25697f9dd9a1710605b76'],
  'img/assets/generic/asset-13.svg': ['generic/asset-13.svg', '9e9c007dd753f4bd9990a6a799741d159c8fe507fa5ee4ba05122d006e296a53'],
  'img/assets/generic/asset-14.svg': ['generic/asset-14.svg', 'af755256a0eae2051378271349490bc4f6c9f557fb07eaec2e27430f99b4c1dd'],
  'img/assets/generic/asset-15.svg': ['generic/asset-15.svg', '0f76a7ed8991251874446f03d632ed44b205439727146f8d7cc0d2014b633dc6'],
  'img/assets/generic/asset-16.svg': ['generic/asset-16.svg', '9390520c63694464e93a30418faf4fdb915d03146663691866548412f6129c9e'],
  'img/assets/generic/asset-17.svg': ['generic/asset-17.svg', '7d977f82b5e817a23fa882bf20cddcdbf0ec22d16e7993a705d7a798f5a83b94'],
  'img/assets/generic/asset-18.svg': ['generic/asset-18.svg', '6d61f5f9f8f556e432898c57d78fc3dad2694149e069bdcce9296596bf2f2b87'],
  'img/assets/generic/asset-19.svg': ['generic/asset-19.svg', '75840773611ecc7575d5a745d2ac20d66abbffff87d26244a99dc5d3ddf61fa8'],
  'img/assets/generic/asset-err.svg': ['generic/asset-err.svg', '40beb9912480b9f1c3e4293e94fc785cbfb0e02540f153b9ea1329560a7f0f63'],
};

test('every bundled icon matches its pin, and the desktop app ships the very same bytes', () => {
  for (const [path, [desktopFile, want]] of Object.entries(PINNED)) {
    assert.equal(sha256(join(src, path)), want, `${path} changed: update PINNED (and NOTICE.txt) on purpose`);
    assert.equal(sha256(join(desktop, desktopFile)), want, `the desktop's ${desktopFile} differs from ${path}: the apps would show different icons`);
  }
});

test('the icons folder holds exactly the pinned files and their notice', () => {
  const walk = (d, pre = '') => readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(d, e.name), `${pre}${e.name}/`) : [`${pre}${e.name}`]));
  const here2 = walk(join(src, 'img', 'assets')).map((f) => `img/assets/${f}`).sort();
  const want = [...Object.keys(PINNED).filter((p) => p.startsWith('img/assets/')), 'img/assets/NOTICE.txt'].sort();
  assert.deepEqual(here2, want);
});

test('every icon the catalogue can name is bundled and pinned', () => {
  const named = new Set([...Object.values(VERIFIED).map((k) => k.icon).filter(Boolean), MISSING_ICON]);
  for (let i = 0; i < GENERIC_ICON_COUNT; i++) named.add(genericIcon(i));
  for (const p of named) {
    assert.ok(PINNED[p], `${p} is not pinned`);
    assert.ok(existsSync(join(src, p)), p);
  }
});

test('the SVG icons are pictures only: no script, link, external reference or embedded document', () => {
  for (const path of Object.keys(PINNED).filter((p) => p.endsWith('.svg'))) {
    const s = readFileSync(join(src, path), 'utf8');
    assert.ok(!/<script|<foreignObject|<image|<iframe|<a[\s>]|href\s*=|@import|\bon[a-z]+\s*=|javascript:/i.test(s), `${path}: active content`);
    const urls = [...s.matchAll(/[a-z][a-z0-9+.-]*:\/\/[^\s"'<>)]+/gi)].map((m) => m[0]);
    assert.ok(urls.every((u) => u === 'http://www.w3.org/2000/svg'), `${path}: ${urls.join(' ')}`);
    assert.ok(!/url\(\s*['"]?(?!#)/i.test(s), `${path}: url() to anything but its own gradients`);
  }
});

test('raster icons are small: at most 128 px across and 32 KB', () => {
  for (const path of Object.keys(PINNED).filter((p) => p.endsWith('.png'))) {
    const b = readFileSync(join(src, path));
    assert.equal(b.toString('latin1', 1, 4), 'PNG', path);
    const w = b.readUInt32BE(16);
    const hgt = b.readUInt32BE(20);
    assert.ok(w <= 128 && hgt <= 128, `${path}: ${w}x${hgt}`);
    assert.ok(b.length <= 32 * 1024, `${path}: ${b.length} bytes`);
  }
});

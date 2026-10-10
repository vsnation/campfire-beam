// Refreshes test/unit/fixtures/asset_parity.json: every Confidential Asset on
// mainnet, the DEX's pools, and what the desktop app's own catalogue code shows
// for each. test/unit/asset_parity.test.mjs then checks lib/meta.js shows the same.
//
//   node tools/asset_parity/run.mjs [--explorer https://explorer.0xmx.net/api]
//                                   [--from <dir with assets.json and dex.json>]
//                                   [--dart <dart binary>]  (default: $DART or dart)
//
// Development only: the app itself never asks an explorer. The explorer's answers
// are untrusted data: they are saved in a new temporary folder and only parsed as
// JSON. The desktop code runs unchanged in a plain Dart package (only its Flutter
// import of Characters becomes package:characters, and the DEX-row helper it
// needs no parser for is left out), so no Flutter build is involved.
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, copyFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { SNAPSHOT } from '../../src/lib/lp_tokens.js';
import { DEX_CID } from '../../src/lib/dex.js';

const here = dirname(fileURLToPath(import.meta.url));
const pwa = join(here, '..', '..');
const repo = join(pwa, '..');
const arg = (name, def) => {
  const i = process.argv.indexOf(`--${name}`);
  return i < 0 ? def : process.argv[i + 1];
};
const explorer = arg('explorer', 'https://explorer.0xmx.net/api');
const dart = arg('dart', process.env.DART || 'dart');
const KIND = { Low: 0, Medium: 1, High: 2 };
// Only the fields a name is made from are kept: the rest is the creator's prose.
const KEEP = new Set(['SCH_VER', 'N', 'SN', 'UN']);

// ---- the chain's answers
let dir = arg('from', null);
if (!dir) {
  dir = mkdtempSync(join(tmpdir(), 'asset-parity-dl-'));
  const get = async (path, file) => {
    const r = await fetch(`${explorer}${path}`, { redirect: 'error' });
    if (!r.ok) throw new Error(`${path}: HTTP ${r.status}`);
    writeFileSync(join(dir, file), Buffer.from(await r.arrayBuffer()));
  };
  await get('/assets', 'assets.json');
  await get(`/contract?id=${DEX_CID}&state=1&nMaxTxs=1`, 'dex.json');
}
const cell = (c) => (c && typeof c === 'object' && 'value' in c ? c.value : c);
const assetsTable = JSON.parse(readFileSync(join(dir, 'assets.json'), 'utf8'));
const dex = JSON.parse(readFileSync(join(dir, 'dex.json'), 'utf8'));

const reduce = (raw) => {
  if (typeof raw !== 'string') return '';
  if (!raw.startsWith('STD:')) return raw;
  return `STD:${raw.slice(4).split(';').filter((p) => p.includes('=') && KEEP.has(p.split('=')[0].trim())).join(';')}`;
};
const assets = [];
const lpByMeta = new Map();
for (const row of assetsTable.value.slice(1)) {
  const [aid, owner, , , , meta] = row.map(cell);
  if (!Number.isSafeInteger(aid)) throw new Error('bad asset row');
  assets.push({ id: aid, metadata: reduce(meta) });
  const m = typeof meta === 'string' && /(?:^|;)N=Amm Liquidity Token (\d+)-(\d+)-(\d+)(?:;|$)/.exec(meta);
  if (owner === DEX_CID && m) lpByMeta.set(aid, [Number(m[1]), Number(m[2]), Number(m[3])]);
}
const pools = dex.State.Pools.value.slice(1).map((r) => {
  const [aid1, aid2, vol, lpToken] = r.map(cell);
  if (!(vol in KIND)) throw new Error(`unknown volatility ${vol}`);
  return { lpToken, aid1, aid2, kind: KIND[vol] };
}).sort((a, b) => a.lpToken - b.lpToken);

// Two sources must agree: the DEX's own pool list, and the assets it owns whose
// contract-written metadata names a pool.
const fromPools = new Map(pools.map((p) => [p.lpToken, [p.aid1, p.aid2, p.kind]]));
const same = fromPools.size === lpByMeta.size && [...fromPools].every(([k, v]) => JSON.stringify(lpByMeta.get(k)) === JSON.stringify(v));
if (!same) throw new Error('the DEX pool list and the LP tokens on the asset list disagree');
const newer = pools.filter((p) => JSON.stringify(SNAPSHOT[p.lpToken]) !== JSON.stringify([p.aid1, p.aid2, p.kind]));
if (newer.length) console.log(`lp_tokens.js SNAPSHOT lacks ${newer.length} pool(s): ${newer.map((p) => `${p.lpToken}: [${p.aid1}, ${p.aid2}, ${p.kind}]`).join(', ')}`);

// ---- cases the chain does not have (the desktop's own catalogue tests, and edge cases)
const FIELDS = [
  'N=Moon Rocket;SN=MOON;UN=MOON;NTHUN=m', 'N=Fomo Token;UN=FOMO', 'N=b.e.a.m;UN=B', 'N=bUSDT;UN=bUSDT',
  'N=‮OMOF​;UN=‮OMOF', `N=${'A'.repeat(80)};UN=LONGTICKER1`, 'N=FОМО;UN=FОМО',
  'N=ΒΕΑΜ;UN=X', 'N=Pepe;UN=ＦＯＭＯ', 'N=\u{1D405}\u{1D40E}\u{1D40C}\u{1D40E};UN=X',
  'N=FÖMÖ;UN=X', 'N=F̶O̶M̶O;UN=X', 'N=Ꮯhad;UN=X', 'N=Pepe;UN=F.O.M.O', 'N=Pepe;UN=F0MO',
  'N=Pepe;UN=F0M0', 'N=G1GA;UN=X', 'N=Pepe;UN=TlCO', 'N=Pepe;UN=FORNO', 'N=Pepe;UN=wFOMO', 'N=Pepe;UN=FOMO2', 'N=FOOMO;UN=X',
  'N=FMOO;UN=X', 'N=Gothic Crwn;UN=X', 'N=Official FOMO Token;UN=X', 'N=Giga Inu;UN=X', 'N=Pepe;UN=BEAMX2',
  'N=Pepe #174;UN=PEPE', 'N=Pepe ＃１７４;UN=P#7', 'N=Moon #12345;UN=MOON', 'N=Beatcoin;UN=Beat',
  'N=Pepe Coin;UN=PEPE', 'N=A؜B C⁠D­E͏FㅤG\u{E0041}H⠀I️J;UN=X',
  `N=Z${'́'.repeat(30)}a;UN=X`, `N=${'\u{1F680}'.repeat(40)};UN=X`, 'N=Moon    Rocket;UN=X', 'N=;UN=',
  'UN=ONLYUN', 'SN=Shorty', 'N=Dup;N=Second;UN=D1;UN=D2', ' N=Spaced key;UN=SK',
  'N=Amm Liquidity Token 0-174-2;SN=AmmL;UN=AMML;NTHUN=GROTH', 'N=Rangers Fan Token;UN=RFC',
];
const RAW = ['garbage', '', 'N=No prefix;UN=NOPRE'];
const extras = [];
let next = 1000;
for (const f of FIELDS) extras.push({ id: next++, metadata: `STD:SCH_VER=1;${f}` });
for (const r of RAW) extras.push({ id: next++, metadata: r });
// Ids whose generic icon a verified asset already wears (asset-6, asset-16..19), without metadata.
for (const id of [100026, 100046, 100056, 100066, 100076, 100777, 100016, 2036, 100557]) extras.push({ id, metadata: null });
// LP tokens of made-up pools: an unverified side, LP sides, deeper than names go, a side with no metadata.
const extraPools = [
  { lpToken: 200001, aid1: 0, aid2: 1000, kind: 2 },
  { lpToken: 200002, aid1: 0, aid2: 175, kind: 1 },
  { lpToken: 200003, aid1: 0, aid2: 200002, kind: 0 },
  { lpToken: 200004, aid1: 0, aid2: 200003, kind: 0 },
  { lpToken: 200005, aid1: 0, aid2: 200004, kind: 0 },
  { lpToken: 200006, aid1: 5, aid2: 300000, kind: 2 },
];
for (const p of extraPools) extras.push({ id: p.lpToken, metadata: 'STD:SCH_VER=1;N=Amm Liquidity Token x;SN=AmmL;UN=AMML;NTHUN=GROTH' });

const input = { height: assetsTable.h, assets, pools, extras, extraPools };

// ---- the desktop's code, as a plain Dart package
const pkg = mkdtempSync(join(tmpdir(), 'asset-parity-dart-'));
const copy = (rel, edit = (s) => s) => {
  const dst = join(pkg, rel);
  mkdirSync(dirname(dst), { recursive: true });
  writeFileSync(dst, edit(readFileSync(join(repo, rel), 'utf8')));
};
copy('lib/wallets/beam/assets/beam_asset_catalog.dart', (s) => {
  const out = s.replace("import 'package:flutter/widgets.dart' show Characters;", "import 'package:characters/characters.dart';");
  if (out.includes('package:flutter')) throw new Error('beam_asset_catalog.dart: an unexpected Flutter import');
  return out;
});
copy('lib/wallets/beam/assets/beam_asset_lookalike.dart');
copy('lib/wallets/beam/contracts/dex/beam_lp_tokens.dart', (s0) => {
  const s = s0.replace("import 'beam_pool.dart';\n", '');
  const a = s.indexOf('  /// Records the LP token of every pool in [pools]');
  const b = s.indexOf('  /// Records [pool].');
  if (s === s0 || a < 0 || b < a) throw new Error('beam_lp_tokens.dart changed shape');
  return s.slice(0, a) + s.slice(b);
});
copy('lib/wallets/beam/models/beam_asset_info.dart');
copy('lib/wallets/beam/models/beam_json.dart');
const lock = readFileSync(join(repo, 'pubspec.lock'), 'utf8');
const version = (name) => {
  const m = new RegExp(`\\n  ${name}:\\n(?:    .*\\n)*?    version: "([^"]+)"`).exec(lock);
  if (!m) throw new Error(`pubspec.lock has no ${name}`);
  return m[1];
};
writeFileSync(join(pkg, 'pubspec.yaml'), `name: campfire_parity\nenvironment:\n  sdk: ">=3.5.0 <4.0.0"\ndependencies:\n${['characters', 'meta', 'unorm_dart'].map((n) => `  ${n}: ${version(n)}\n`).join('')}`);
mkdirSync(join(pkg, 'bin'));
copyFileSync(join(here, 'main.dart'), join(pkg, 'bin', 'main.dart'));
writeFileSync(join(pkg, 'input.json'), JSON.stringify(input));
try {
  execFileSync(dart, ['pub', 'get', '--offline'], { cwd: pkg, stdio: 'ignore' });
} catch {
  execFileSync(dart, ['pub', 'get'], { cwd: pkg, stdio: 'inherit' });
}
const desktop = JSON.parse(execFileSync(dart, ['run', 'bin/main.dart', 'input.json'], { cwd: pkg, maxBuffer: 64 << 20 }).toString('utf8'));
rmSync(pkg, { recursive: true, force: true });

const fixture = { source: { explorer, height: input.height, date: new Date().toISOString().slice(0, 10) }, ...input, desktop };
const outPath = join(pwa, 'test', 'unit', 'fixtures', 'asset_parity.json');
// One asset per line, so a refresh reads as a diff of the assets that changed.
const lines = (v) => (Array.isArray(v) ? `[\n${v.map((x) => JSON.stringify(x)).join(',\n')}\n]` : `{\n${Object.entries(v).map(([k, x]) => `${JSON.stringify(k)}:${JSON.stringify(x)}`).join(',\n')}\n}`);
const body = Object.entries(fixture).map(([k, v]) => {
  if (k === 'desktop') return `"desktop":{\n"withMetadata":${lines(v.withMetadata)},\n"bare":${lines(v.bare)}\n}`;
  return `${JSON.stringify(k)}:${Array.isArray(v) ? lines(v) : JSON.stringify(v)}`;
});
writeFileSync(outPath, `{\n${body.join(',\n')}\n}\n`);
console.log(`asset_parity: ${assets.length} assets, ${pools.length} pools at height ${input.height}, ${extras.length} extra cases -> ${outPath}`);

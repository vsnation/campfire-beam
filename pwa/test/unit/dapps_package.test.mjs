// The catalogue, the download check (size + SHA-256 pin) and the manifest rules.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CATALOGUE, sourceUrl, iconPath, byGuid } from '../../src/lib/dapps/catalogue.js';
import { verifyPackage, downloadPackage, openPackage, PackageError } from '../../src/lib/dapps/package.js';
import { makeZip } from './helpers/zipwriter.mjs';

const pwa = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const sha = (b) => createHash('sha256').update(b).digest('hex');

function fakeEntry(bytes, extra = {}) {
  return { fileName: 'test.dapp', name: 'Test', guid: 'ffbec734a0bb4f88a7104357a2680d20', sha256: sha(bytes), size: bytes.length, needsEval: true, remoteOrigins: [], ...extra };
}

test('the catalogue has the 9 mainnet dApps, each with its icon in the release', () => {
  assert.equal(CATALOGUE.length, 9);
  assert.equal(new Set(CATALOGUE.map((e) => e.guid)).size, 9);
  for (const e of CATALOGUE) {
    assert.match(e.sha256, /^[0-9a-f]{64}$/);
    assert.ok(e.size > 0 && e.size < 50 * 1024 * 1024);
    assert.ok(existsSync(join(pwa, 'src', iconPath(e))), iconPath(e));
    assert.ok(sourceUrl(e).startsWith('https://raw.githubusercontent.com/BeamMW/beam-ui/'));
    assert.equal(byGuid(e.guid), e);
  }
});

test('pins, sizes, eval and remote origins are exactly the desktop catalogue', (t) => {
  const dart = join(pwa, '..', 'lib', 'wallets', 'beam', 'dapps', 'dapp_catalogue.dart');
  if (!existsSync(dart)) return t.skip('desktop sources not next to the PWA');
  const src = readFileSync(dart, 'utf8');
  const commit = /sourceCommit = '([0-9a-f]{40})'/.exec(src)[1];
  assert.ok(sourceUrl(CATALOGUE[0]).includes(commit));
  const blocks = src.split('DappCatalogueEntry(').slice(2); // [0] preamble, [1] the class constructor
  assert.equal(blocks.length, 9);
  for (const b of blocks) {
    const get = (k) => (new RegExp(`${k}: '([^']*)'`).exec(b) || [])[1];
    const e = CATALOGUE.find((x) => x.fileName === get('fileName'));
    assert.ok(e, get('fileName'));
    assert.equal(e.guid, get('guid'));
    assert.equal(e.sha256, get('sha256'));
    assert.equal(e.size, Number(/size: (\d+)/.exec(b)[1]));
    assert.equal(e.needsEval, !/needsEval: false/.test(b), e.fileName);
    const remote = (/remoteOrigins: \[([^\]]*)\]/.exec(b) || [, ''])[1].split(',').map((s) => s.trim()).filter(Boolean).map((k) => ({ _coingecko: 'https://api.coingecko.com', _beamExplorerApi: 'https://explorer-api.beam.mw' })[k]);
    assert.deepEqual([...e.remoteOrigins], remote, e.fileName);
    assert.equal(e.iconExt, get('iconExtension') || 'svg');
  }
});

test('the pinned bytes pass; one byte or one length off is refused (SHA-256 refusal)', async () => {
  const bytes = new TextEncoder().encode('a dApp package');
  const e = fakeEntry(bytes);
  assert.equal(await verifyPackage(e, bytes), bytes);
  const flipped = bytes.slice();
  flipped[3] ^= 1;
  await assert.rejects(verifyPackage(e, flipped), (x) => x instanceof PackageError && x.code === 'hash');
  await assert.rejects(verifyPackage(e, bytes.subarray(1)), (x) => x instanceof PackageError && x.code === 'size');
  await assert.rejects(verifyPackage(e, new Uint8Array([...bytes, 0])), (x) => x instanceof PackageError && x.code === 'size');
});

function fakeFetch(body, { status = 200, chunk = 7 } = {}) {
  return async (url, opts) => {
    fakeFetch.last = { url, opts };
    let i = 0;
    return {
      ok: status === 200,
      status,
      body: new ReadableStream({
        pull(c) {
          if (i >= body.length) return c.close();
          c.enqueue(body.subarray(i, i + chunk));
          i += chunk;
        },
      }),
    };
  };
}

test('download: streams with progress, no credentials, no referrer, then verifies', async () => {
  const bytes = new TextEncoder().encode('x'.repeat(100));
  const e = fakeEntry(bytes, { fileName: 'dex-app.dapp' });
  const seen = [];
  const got = await downloadPackage(e, { fetchImpl: fakeFetch(bytes), onProgress: (d, t) => seen.push([d, t]) });
  assert.deepEqual(Array.from(got), Array.from(bytes));
  assert.equal(seen.at(-1)[0], 100);
  assert.equal(fakeFetch.last.url, sourceUrl(e));
  assert.equal(fakeFetch.last.opts.credentials, 'omit');
  assert.equal(fakeFetch.last.opts.referrerPolicy, 'no-referrer');
});

test('download: a different file of the same size is refused; a larger one is cut off', async () => {
  const bytes = new TextEncoder().encode('y'.repeat(100));
  const e = fakeEntry(bytes);
  await assert.rejects(downloadPackage(e, { fetchImpl: fakeFetch(new TextEncoder().encode('z'.repeat(100))) }), (x) => x.code === 'hash');
  await assert.rejects(downloadPackage(e, { fetchImpl: fakeFetch(new TextEncoder().encode('y'.repeat(101))) }), (x) => x.code === 'size');
  await assert.rejects(downloadPackage(e, { fetchImpl: fakeFetch(bytes, { status: 404 }) }), (x) => x.code === 'network');
  await assert.rejects(downloadPackage(e, { fetchImpl: async () => { throw new TypeError('offline'); } }), (x) => x.code === 'network');
});

test('manifest: the guid must be the catalogue one and the start page must exist', async () => {
  const guid = 'ffbec734a0bb4f88a7104357a2680d20';
  const pkg = (manifest, extra = []) => makeZip([{ name: 'manifest.json', data: JSON.stringify(manifest), method: 0 }, { name: 'app/index.html', data: '<html></html>', method: 8 }, ...extra]);
  const ok = await openPackage({ guid, name: 'X' }, pkg({ name: 'BEAM NFT Gallery', guid, url: 'localapp/app/index.html', api_version: '7.0', min_api_version: '7.0' }));
  assert.equal(ok.manifest.startPath, 'app/index.html');
  assert.equal(ok.manifest.apiVersion, '7.0');
  assert.ok(ok.files.has('app/index.html'));
  await assert.rejects(openPackage({ guid, name: 'X' }, pkg({ name: 'x', guid: 'db851322f6674a6da3e84e9953db2ffd', url: 'localapp/app/index.html' })), (e) => e.code === 'manifest');
  await assert.rejects(openPackage({ guid, name: 'X' }, pkg({ name: 'x', guid, url: 'https://evil.example/' })), (e) => e.code === 'manifest');
  await assert.rejects(openPackage({ guid, name: 'X' }, pkg({ name: 'x', guid, url: 'localapp/app/missing.html' })), (e) => e.code === 'manifest');
  await assert.rejects(openPackage({ guid, name: 'X' }, makeZip([{ name: 'app/index.html', data: 'x', method: 0 }])), (e) => e.code === 'manifest');
  await assert.rejects(openPackage({ guid, name: 'X' }, new Uint8Array(30)), (e) => e.code === 'zip');
});

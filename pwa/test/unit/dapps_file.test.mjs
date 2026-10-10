// A dApp installed from a .dapp file: the desktop's package and manifest
// rules (one test per rule), the catalogue's guid and name checks, the
// words for every refusal, the frame policy for a file dApp and the hosts it
// may be allowed, the frame's "blocked" message, and the storage.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { makeZip } from './helpers/zipwriter.mjs';
import { parseManifest, readFilePackage, canonicalGuid, catalogueEntryFor, catalogueNameCopiedBy, installErrorText, InstallError, MANIFEST_LIMITS } from '../../src/lib/dapps/file_package.js';
import { DEFAULT_LIMITS } from '../../src/lib/dapps/zip.js';
import { CATALOGUE } from '../../src/lib/dapps/catalogue.js';
import { remoteOriginFor, remoteHostOk, fileSegment, parsePolicySegment, frameRouteFor, frameCsp, frameHeaders, FRAME_ROUTE, MAX_FILE_ORIGINS, REMOTE_ORIGINS } from '../../src/lib/dapps/frame_policy.js';
import { validateFrameMessage } from '../../src/lib/dapps/messages.js';
import { installedStore, iconDataUrl } from '../../src/lib/dapps/installed.js';

const GUID = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6';
const enc = (o) => new TextEncoder().encode(typeof o === 'string' ? o : JSON.stringify(o));
const base = (extra = {}) => ({ name: 'Tiny dApp', description: 'A tiny test dApp', url: 'localapp/app/index.html', icon: 'localapp/app/icon.svg', guid: GUID, version: '1.0.0', api_version: '7.3', min_api_version: '7.0', ...extra });
const ICON = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10" fill="#25c2a0"/></svg>';
const pkgBytes = (manifest = base(), more = []) =>
  makeZip([
    { name: 'manifest.json', data: typeof manifest === 'string' ? manifest : JSON.stringify(manifest) },
    { name: 'app/', data: '', method: 0 },
    { name: 'app/index.html', data: '<!doctype html><title>t</title><p id="x">tiny</p>' },
    { name: 'app/icon.svg', data: ICON },
    ...more,
  ]);
const manifestRefused = (m, code = 'invalidFile', re = null) =>
  assert.throws(() => parseManifest(enc(m)), (e) => e instanceof InstallError && e.code === code && (!re || re.test(e.message)), JSON.stringify(m).slice(0, 80));
const pkgRefused = async (bytes, code, re = null, limits = undefined) =>
  assert.rejects(readFilePackage(bytes, limits), (e) => e instanceof InstallError && e.code === code && (!re || re.test(e.message)));

// ------------------------------------------------------------ manifest
test('manifest: a valid one reads, with the guid in its canonical form', () => {
  const m = parseManifest(enc(base({ guid: GUID.toUpperCase() })));
  assert.equal(m.guid, GUID);
  assert.equal(m.name, 'Tiny dApp');
  assert.equal(m.startPath, 'app/index.html');
  assert.equal(m.iconPath, 'app/icon.svg');
  assert.equal(m.publisher, null);
  assert.equal(canonicalGuid('A1B2C3D4-E5F6-A7B8-C9D0-E1F2A3B4C5D6'), GUID);
  assert.equal(parseManifest(enc(base({ guid: 'a1b2c3d4-e5f6-a7b8-c9d0-e1f2a3b4c5d6' }))).guid, GUID);
});

test('manifest: guid must be 32 hex digits or a UUID', () => {
  for (const guid of ['', '../..', 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d', 'g1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6', 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a', 'a1b2c3d4-e5f6a7b8-c9d0-e1f2a3b4c5d6', 42]) manifestRefused(base({ guid }));
  manifestRefused((({ guid, ...rest }) => rest)(base()));
});

test('manifest: name is required, 30 characters at most, with no control or bidirectional characters', () => {
  assert.equal(parseManifest(enc(base({ name: 'x'.repeat(MANIFEST_LIMITS.name) }))).name.length, 30);
  manifestRefused(base({ name: 'x'.repeat(31) }), 'invalidFile', /longer than 30/);
  manifestRefused(base({ name: '' }));
  manifestRefused(base({ name: '   ' }));
  manifestRefused(base({ name: 5 }));
  // NUL, tab, newline, DEL, C1, Arabic letter mark, zero-width space, LRM/RLM, LRE..RLO, word joiner..PDI, BOM
  for (const c of ['\u0000', '\t', '\n', '\u007f', '\u0085', '\u061c', '\u200b', '\u200e', '\u200f', '\u202a', '\u202e', '\u2060', '\u2066', '\u2069', '\ufeff']) {
    manifestRefused(base({ name: `Beam${c}DEX` }), 'invalidFile', /control/);
  }
  assert.equal(parseManifest(enc(base({ name: 'Ünïcødé dApp ✓' }))).name, 'Ünïcødé dApp ✓');
});

test('manifest: description is required, 1024 characters at most; tabs and line breaks allowed', () => {
  manifestRefused(base({ description: '' }));
  manifestRefused((({ description, ...rest }) => rest)(base()));
  manifestRefused(base({ description: 'x'.repeat(MANIFEST_LIMITS.description + 1) }));
  manifestRefused(base({ description: 'a\u202eb' }), 'invalidFile', /control/);
  assert.equal(parseManifest(enc(base({ description: 'line one\nline two\ttab\r\n' }))).description, 'line one\nline two\ttab\r\n');
});

test('manifest: url names an .html page inside the package, by a safe relative path', () => {
  for (const url of ['https://evil.example/index.html', 'app/index.html', '/app/index.html', 'localapp/../index.html', 'localapp/app/../../x.html', 'localapp//app.html', 'localapp/app\\x.html', 'localapp/app/index.js', 'localapp/', 'localapp/con.html', 'localapp/app/x.html.']) {
    manifestRefused(base({ url }));
  }
  assert.equal(parseManifest(enc(base({ url: 'localapp/web/Start Page.HTM' }))).startPath, 'web/Start Page.HTM');
});

test('manifest: a remote or data: icon is ignored; a local one must be a safe path, 10240 characters at most', () => {
  assert.equal(parseManifest(enc(base({ icon: 'https://evil.example/i.png' }))).iconPath, null);
  assert.equal(parseManifest(enc(base({ icon: 'data:image/png;base64,AAAA' }))).iconPath, null);
  manifestRefused(base({ icon: 'localapp/../icon.svg' }), 'invalidFile', /icon/);
  manifestRefused(base({ icon: 'x'.repeat(MANIFEST_LIMITS.icon + 1) }));
  manifestRefused(base({ icon: 7 }));
});

test('manifest: version is up to four numeric parts; api versions are major.minor', () => {
  for (const version of ['1', '1.2', '1.2.3.4', '123456789.0']) assert.equal(parseManifest(enc(base({ version }))).version, version);
  for (const version of ['1.2.3.4.5', 'v1', '1.2-beta', '', '1..2', '1234567890']) manifestRefused(base({ version }));
  for (const api_version of ['7', '7.30', '1234.1234']) assert.equal(parseManifest(enc(base({ api_version }))).apiVersion, api_version);
  for (const api_version of ['current', '7.3.1', '7.', 'x', '12345.1']) manifestRefused(base({ api_version }));
  manifestRefused(base({ min_api_version: '6,0' }));
});

test('manifest: category is an unsigned 32-bit integer; publisher is 256 characters at most with no control characters', () => {
  assert.equal(parseManifest(enc(base({ category: 2 }))).category, 2);
  for (const category of [-1, 1.5, '2', 2 ** 32]) manifestRefused(base({ category }));
  assert.equal(parseManifest(enc(base({ publisher: 'BEAM dApp maker' }))).publisher, 'BEAM dApp maker');
  manifestRefused(base({ publisher: 'x'.repeat(MANIFEST_LIMITS.publisher + 1) }));
  manifestRefused(base({ publisher: 'Beam\u202eTeam' }));
  manifestRefused(base({ publisher: 3 }));
});

test('manifest: not UTF-8 JSON, too large, empty or not an object is refused; a UTF-8 BOM is fine', () => {
  manifestRefused('{"name": ', 'cantReadManifest');
  assert.throws(() => parseManifest(new Uint8Array([0x7b, 0xff, 0x7d])), (e) => e.code === 'cantReadManifest');
  assert.throws(() => parseManifest(new Uint8Array(0)), (e) => e.code === 'cantReadManifest');
  assert.throws(() => parseManifest(enc(base({ description: 'x'.repeat(70000) }))), (e) => e.code === 'cantReadManifest');
  for (const m of ['[]', '{}', '"x"', 'null', '5']) manifestRefused(m);
  assert.equal(parseManifest(new Uint8Array([0xef, 0xbb, 0xbf, ...enc(base())])).guid, GUID);
});

// ------------------------------------------------------------ package
test('package: reads the tiny dApp, its start page, its icon, its API version and SHA-256', async () => {
  const bytes = pkgBytes();
  const p = await readFilePackage(bytes);
  assert.equal(p.manifest.name, 'Tiny dApp');
  assert.equal(p.apiVersion, '7.3');
  assert.equal(p.sha256, createHash('sha256').update(bytes).digest('hex'));
  assert.deepEqual([...p.files.keys()], ['manifest.json', 'app/index.html', 'app/icon.svg']);
  assert.ok(p.totalBytes > 0);
});

test('package: manifest.json at the root only, its start page present; a missing icon is dropped', async () => {
  await pkgRefused(makeZip([{ name: 'app/manifest.json', data: JSON.stringify(base()) }, { name: 'app/index.html', data: 'x' }]), 'cantReadManifest');
  await pkgRefused(pkgBytes(base({ url: 'localapp/app/other.html' })), 'invalidFile', /start page/);
  assert.equal((await readFilePackage(pkgBytes(base({ icon: 'localapp/app/missing.png' })))).manifest.iconPath, null);
});

test('package: an API version this wallet cannot serve is refused; the minimum is the fallback', async () => {
  await assert.rejects(readFilePackage(pkgBytes(base({ api_version: '9.0', min_api_version: '8.0' }))), (e) => e.code === 'unsupported' && e.dappName === 'Tiny dApp');
  await pkgRefused(pkgBytes(base({ api_version: '5.0', min_api_version: null })), 'unsupported');
  assert.equal((await readFilePackage(pkgBytes(base({ api_version: '9.0', min_api_version: '6.1' })))).apiVersion, '6.1');
  assert.equal((await readFilePackage(pkgBytes(base({ api_version: undefined, min_api_version: undefined })))).apiVersion, '7.4', 'absent: current');
});

test('package: paths that climb out or are absolute, and symlinks, are refused', async () => {
  for (const name of ['../evil.js', 'app/../../evil.js', '/etc/passwd', 'app//x.js', 'C:\\evil.js']) await pkgRefused(pkgBytes(base(), [{ name, data: 'x' }]), 'unsafePath');
  await pkgRefused(pkgBytes(base(), [{ name: 'app/link', data: '/etc/passwd', method: 0, externalAttr: 0o120777 << 16 }]), 'unsafeEntry');
});

test('package: size and count limits, and the compression ratio (zip bombs), are refused', async () => {
  const small = { ...DEFAULT_LIMITS };
  await pkgRefused(pkgBytes(), 'tooLarge', null, { ...small, maxPackageBytes: 100 });
  await pkgRefused(pkgBytes(), 'tooLarge', /entries/, { ...small, maxEntries: 3 });
  await pkgRefused(pkgBytes(), 'tooLarge', null, { ...small, maxFileBytes: 50 });
  await pkgRefused(pkgBytes(), 'tooLarge', /unpacked/, { ...small, maxTotalBytes: 300 });
  // 2 MB of zeros deflates to about 2 KB: over 100:1 once it is past the 1 MB floor.
  await pkgRefused(pkgBytes(base(), [{ name: 'app/zeros.bin', data: new Uint8Array(2 * 1024 * 1024) }]), 'tooLarge', /compresses/);
  // A header that lies about its size cannot make an entry inflate further.
  await pkgRefused(pkgBytes(base(), [{ name: 'app/bomb.bin', data: new Uint8Array(100000), size: 1000 }]), 'tooLarge');
  await pkgRefused(new Uint8Array(DEFAULT_LIMITS.maxPackageBytes + 1), 'tooLarge');
});

test('package: not a zip, a damaged entry, encryption or another method is refused', async () => {
  await pkgRefused(enc('just some text, not an archive'), 'cantOpenFile');
  await pkgRefused(new Uint8Array(0), 'cantOpenFile');
  await pkgRefused(pkgBytes(base(), [{ name: 'app/a.js', data: 'x', crc: 1 }]), 'invalidFile', /CRC/);
  await pkgRefused(pkgBytes(base(), [{ name: 'app/a.js', data: 'x', method: 0, flags: 0x0001 }]), 'invalidFile', /encrypted/);
  await pkgRefused(pkgBytes(base(), [{ name: 'App/Index.html', data: 'x' }]), 'unsafePath', /case/);
});

// ------------------------------------------------------------ BEAM's own dApps
test("a file may take one of BEAM's guids only when it is that dApp's package byte for byte", async () => {
  const dex = CATALOGUE.find((e) => e.name === 'Beam DEX');
  const p = await readFilePackage(pkgBytes(base({ guid: dex.guid })));
  assert.throws(() => catalogueEntryFor(p), (e) => e instanceof InstallError && e.code === 'reservedGuid' && e.dappName === 'Beam DEX');
  assert.equal(catalogueEntryFor({ ...p, sha256: dex.sha256 }), dex);
  assert.equal(catalogueEntryFor(await readFilePackage(pkgBytes())), null);
});

test("a name that copies one of BEAM's dApps under another guid is named, case and spaces aside", () => {
  assert.equal(catalogueNameCopiedBy({ guid: GUID, name: ' beam dex ' }), 'Beam DEX');
  assert.equal(catalogueNameCopiedBy({ guid: GUID, name: 'BEAM NFT GALLERY' }), 'BEAM NFT Gallery');
  assert.equal(catalogueNameCopiedBy({ guid: GUID, name: 'Beam DEX 2' }), null);
  assert.equal(catalogueNameCopiedBy({ guid: CATALOGUE[0].guid, name: CATALOGUE[0].name }), null);
});

test('every refusal has words that name the next step and blame nobody', () => {
  const t = (code, extra) => installErrorText(new InstallError(code, 'x', extra), 'Tiny dApp');
  assert.equal(t('unsupported'), 'Tiny dApp needs a newer wallet than this version of BEAM Campfire.');
  assert.equal(t('alreadyInstalled'), 'Tiny dApp is already installed.');
  assert.match(t('reservedGuid', { dappName: 'Beam DEX' }), /claims to be Beam DEX, but it is not the package BEAM Campfire checks, so nothing was installed\. Open Beam DEX from the list of dApps instead\./);
  assert.match(t('storage'), /couldn't save Tiny dApp on this device\. Check that there is free space, then try again\./);
  for (const code of ['cantOpenFile', 'cantReadManifest', 'invalidFile', 'tooLarge', 'unsafeEntry', 'unsafePath']) {
    assert.equal(t(code), "This file isn't a dApp package BEAM Campfire can install safely, so nothing was installed. Ask the dApp's publisher for a new copy.");
  }
  assert.match(installErrorText(new Error('x'), 'Tiny dApp'), /Nothing was changed\. Try again\./);
  for (const s of [t('storage'), t('invalidFile'), t('reservedGuid', { dappName: 'Beam DEX' })]) assert.doesNotMatch(s, /\byou (did|made|picked a wrong)\b/i);
});

// ------------------------------------------------------------ frame policy
test('hosts a file dApp may be allowed: https, a public DNS name, an optional port; nothing else', () => {
  const H = 'https:' + '//';
  assert.equal(remoteOriginFor(`${H}explorer.0xmx.net`), `${H}explorer.0xmx.net`);
  assert.equal(remoteOriginFor(`${H}api.example.com:8443`), `${H}api.example.com:8443`);
  assert.equal(remoteOriginFor(`${H}api.example.com:443`), `${H}api.example.com`, 'the default port is not written');
  assert.equal(remoteOriginFor(`${H}xn--80ak6aa92e.com`), `${H}xn--80ak6aa92e.com`);
  for (const bad of [
    'http:' + '//api.example.com', 'wss:' + '//api.example.com', `${H}localhost`, `${H}foo.localhost`, `${H}printer.local`, `${H}intranet`, `${H}1.2.3.4`, `${H}127.0.0.1`, `${H}0x7f.0x1`,
    `${H}[::1]`, `${H}*.example.com`, `${H}API.example.com`, `${H}api.example.com/`, `${H}api.example.com/path`, `${H}user@api.example.com`, `${H}a_b.example.com`, `${H}-a.example.com`,
    `${H}api.example.com.`, `${H}api..example.com`, `${H}api.example.com:0`, `${H}api.example.com:65536`, `${H}api.example.com:080`, `${H}api.example.com;script-src *`, `${H}a.com ${H}b.com`, '', null,
    `${H}${'a'.repeat(64)}.com`,
  ]) assert.equal(remoteOriginFor(bad), null, String(bad));
  assert.ok(remoteHostOk('a.b'));
  assert.ok(remoteHostOk(`${'a'.repeat(60)}.${'b'.repeat(60)}.${'c'.repeat(60)}.${'d'.repeat(60)}.com`), '247 characters');
  assert.ok(!remoteHostOk(`${'a'.repeat(60)}.${'b'.repeat(60)}.${'c'.repeat(60)}.${'d'.repeat(60)}.${'e'.repeat(10)}.com`), 'longer than 253');
});

test('a file dApp frame: its own route, eval and inline scripts, exactly its allowed hosts', () => {
  const H = 'https:' + '//';
  const origins = [`${H}explorer.0xmx.net`, `${H}api.example.com:8443`];
  const seg = fileSegment(origins);
  assert.equal(seg, 'f,explorer.0xmx.net,api.example.com:8443');
  assert.deepEqual(parsePolicySegment(seg), { file: true, evalAllowed: true, inlineAllowed: true, remoteOrigins: origins });
  assert.deepEqual(parsePolicySegment('f'), { file: true, evalAllowed: true, inlineAllowed: true, remoteOrigins: [] });
  assert.deepEqual(frameRouteFor(`${FRAME_ROUTE}${seg}/app/index.html`).remoteOrigins, origins);
  const tooMany = Array.from({ length: MAX_FILE_ORIGINS + 1 }, (_, i) => `h${i}.example.com`);
  for (const bad of ['f,', 'f,,a.com', 'f,a.com,a.com', 'f,localhost', 'f,1.2.3.4', 'f,a.com;script-src *', "f,a.com 'unsafe-inline'", 'f,A.com', 'fx', 'f;a.com', `f,${tooMany.join(',')}`, 'f,*.a.com']) {
    assert.equal(parsePolicySegment(bad), null, bad);
  }
  assert.throws(() => fileSegment([`${H}a.com`, `${H}a.com`]));
  assert.throws(() => fileSegment([`${H}10.0.0.1`]));
  assert.throws(() => fileSegment(tooMany.map((x) => H + x)));
  const nonce = 'abcdefghijklmnop0123';
  const csp = frameCsp({ ...parsePolicySegment(seg), nonce });
  assert.ok(csp.includes("script-src 'unsafe-inline' blob: 'unsafe-eval'"), csp);
  assert.ok(!csp.includes('nonce-'), "next to a nonce, 'unsafe-inline' would be ignored");
  assert.ok(csp.includes(`connect-src blob: data: ${origins.join(' ')};`));
  assert.ok(csp.includes(`img-src blob: data: ${origins.join(' ')};`));
  for (const d of ["style-src blob: 'unsafe-inline'", 'font-src blob: data:', "frame-src 'none'", "worker-src 'none'", "frame-ancestors 'self'", 'sandbox allow-scripts;']) assert.ok(csp.includes(d), d);
  assert.ok(!/allow-same-origin/.test(csp));
  assert.equal(frameHeaders(parsePolicySegment('f'), nonce)['Cross-Origin-Embedder-Policy'], 'require-corp');
  // The catalogue's policies are as they were.
  assert.ok(frameCsp({ evalAllowed: false, remoteOrigins: [], nonce }).includes(`script-src 'nonce-${nonce}' blob:;`));
  assert.ok(frameCsp({ evalAllowed: true, remoteOrigins: REMOTE_ORIGINS, nonce }).includes(`script-src 'nonce-${nonce}' blob: 'unsafe-eval';`));
  assert.throws(() => frameCsp({ evalAllowed: false, remoteOrigins: [`${H}a.com; script-src *`], nonce }));
});

test("the frame's blocked message: an https origin and a directive a host can be allowed for", () => {
  const H = 'https:' + '//';
  assert.deepEqual(validateFrameMessage({ t: 'blocked', origin: `${H}explorer.0xmx.net`, directive: 'connect-src', x: 1 }), { t: 'blocked', origin: `${H}explorer.0xmx.net`, directive: 'connect-src' });
  assert.deepEqual(validateFrameMessage({ t: 'blocked', origin: `${H}a.example.com:8443`, directive: 'img-src' }).origin, `${H}a.example.com:8443`);
  for (const bad of [
    { t: 'blocked', origin: `${H}a.example.com/path`, directive: 'connect-src' },
    { t: 'blocked', origin: 'http:' + '//a.example.com', directive: 'connect-src' },
    { t: 'blocked', origin: `${H}a.example.com`, directive: 'script-src' },
    { t: 'blocked', origin: `${H}a.example.com`, directive: 'style-src' },
    { t: 'blocked', origin: `${H}a.example.com` },
    { t: 'blocked', origin: 5, directive: 'connect-src' },
    { t: 'blocked', origin: `${H}${'a'.repeat(300)}.com`, directive: 'connect-src' },
  ]) assert.equal(validateFrameMessage(bad), null, JSON.stringify(bad).slice(0, 80));
});

// ------------------------------------------------------------ storage
function memoryKv({ failWrites = false } = {}) {
  const m = new Map();
  return {
    m,
    get: async (k) => (m.has(k) ? structuredClone(m.get(k)) : undefined),
    batch: async (ops) => {
      if (failWrites) throw Object.assign(new Error('quota'), { name: 'QuotaExceededError' });
      for (const [op, k, v] of ops) op === 'del' ? m.delete(k) : m.set(k, structuredClone(v));
    },
  };
}

test('storage: install, list, open (checked again), replace keeps what it may reach, remove deletes both', async () => {
  const H = 'https:' + '//';
  const kv = memoryKv();
  const s = installedStore(kv);
  const bytes = pkgBytes();
  const p = await readFilePackage(bytes);
  const rec = await s.install(p, bytes);
  assert.equal(rec.name, 'Tiny dApp');
  assert.match(rec.icon, /^data:image\/svg\+xml;base64,/);
  assert.deepEqual(rec.origins, []);
  assert.equal((await s.list()).length, 1);
  const opened = await s.open(GUID);
  assert.equal(opened.pkg.sha256, p.sha256);
  assert.equal(new TextDecoder().decode(opened.pkg.files.get('app/index.html')).includes('tiny'), true);
  await assert.rejects(s.install(p, bytes), (e) => e.code === 'alreadyInstalled');

  assert.deepEqual((await s.allow(GUID, `${H}explorer.0xmx.net`)).origins, [`${H}explorer.0xmx.net`]);
  assert.deepEqual((await s.allow(GUID, `${H}explorer.0xmx.net`)).origins, [`${H}explorer.0xmx.net`], 'once');
  await assert.rejects(s.allow(GUID, `${H}127.0.0.1`));
  await assert.rejects(s.allow(GUID, 'http:' + '//explorer.0xmx.net'));

  const bytes2 = pkgBytes(base({ version: '1.1.0' }));
  const r2 = await s.install(await readFilePackage(bytes2), bytes2, { replace: true });
  assert.equal(r2.version, '1.1.0');
  assert.deepEqual(r2.origins, [`${H}explorer.0xmx.net`], 'a replace keeps the hosts it was allowed');
  assert.equal((await s.list()).length, 1);
  assert.deepEqual((await s.revoke(GUID, `${H}explorer.0xmx.net`)).origins, []);

  await s.remove(GUID);
  assert.deepEqual(await s.list(), []);
  assert.deepEqual([...kv.m.keys()], ['dapp-files'], 'the package bytes went too');
  await assert.rejects(s.open(GUID), (e) => e.code === 'storage');
});

test('storage: a kept package that changed is refused; a write that fails changes nothing', async () => {
  const kv = memoryKv();
  const s = installedStore(kv);
  const bytes = pkgBytes();
  await s.install(await readFilePackage(bytes), bytes);
  const kept = kv.m.get(`dapp-file:${GUID}`);
  kept[kept.length - 30] ^= 1;
  await assert.rejects(s.open(GUID), (e) => e.code === 'storage' && /changed/.test(e.message));
  const failing = installedStore(memoryKv({ failWrites: true }));
  await assert.rejects(failing.install(await readFilePackage(bytes), bytes), (e) => e.code === 'storage');
  assert.deepEqual(await failing.list(), []);
});

test('storage: only image types become an icon, and only small ones', () => {
  const f = new Map([['a.svg', enc(ICON)], ['a.html', enc('<script>alert(1)</script>')], ['big.png', new Uint8Array(200 * 1024)]]);
  assert.match(iconDataUrl(f, 'a.svg'), /^data:image\/svg\+xml;base64,/);
  assert.equal(iconDataUrl(f, 'a.html'), null);
  assert.equal(iconDataUrl(f, 'big.png'), null);
  assert.equal(iconDataUrl(f, 'missing.png'), null);
  assert.equal(iconDataUrl(f, null), null);
});

// ------------------------------------------------------------ real packages
test("BEAM's 9 packages pass every rule and are recognised as themselves (when the local cache has them)", async (t) => {
  const { existsSync, readFileSync } = await import('node:fs');
  const { homedir } = await import('node:os');
  const { join } = await import('node:path');
  const dir = process.env.CFB_DAPP_PACKAGES || join(homedir(), '.cache', 'campfire-beam', 'dapps');
  if (!existsSync(join(dir, 'dex-app.dapp')) && !existsSync(join(dir, 'dao-core-app.dapp'))) return t.skip('no cached packages');
  let n = 0;
  for (const e of CATALOGUE) {
    const f = join(dir, e.fileName);
    if (!existsSync(f)) continue;
    const p = await readFilePackage(new Uint8Array(readFileSync(f)));
    assert.equal(p.manifest.guid, e.guid, e.fileName);
    assert.equal(catalogueEntryFor(p), e, e.fileName);
    n++;
  }
  assert.ok(n > 0);
});

test('the BEAM Explorer .dapp passes every rule: no publisher, API 7.3, its own icon (when the fixture is here)', async (t) => {
  const { existsSync, readFileSync } = await import('node:fs');
  const { homedir } = await import('node:os');
  const { join } = await import('node:path');
  const f = process.env.CFB_EXPLORER_DAPP || join(homedir(), 'beam-campfire-test', 'fixtures', 'beam-explorer.dapp');
  if (!existsSync(f)) return t.skip('no Explorer package');
  const p = await readFilePackage(new Uint8Array(readFileSync(f)));
  assert.equal(p.manifest.name, 'BEAM Explorer');
  assert.equal(p.manifest.publisher, null);
  assert.equal(p.apiVersion, '7.3');
  assert.equal(p.manifest.iconPath, 'app/appicon.svg');
  assert.equal(catalogueEntryFor(p), null);
  assert.equal(catalogueNameCopiedBy(p.manifest), null);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto, createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifyReleaseSignature, verifyManifest, verifyFile, compareVersions, ReleaseError, RELEASE_APP_ID } from '../../src/lib/release.js';

const s = webcrypto.subtle;
const sha = (b) => createHash('sha256').update(b).digest('hex');
const enc = (o) => Buffer.from(JSON.stringify(o));

async function keypair() {
  const k = await s.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const pub = await s.exportKey('jwk', k.publicKey);
  return { priv: k.privateKey, pub: { kty: pub.kty, crv: pub.crv, x: pub.x, y: pub.y } };
}
async function sign(priv, bytes) {
  return Buffer.from(await s.sign({ name: 'ECDSA', hash: 'SHA-256' }, priv, bytes)).toString('base64');
}

async function makeRelease(priv, { version = '1.0.0', files = { 'index.html': 'hello', 'app.js': 'console.log(1)' } } = {}) {
  const entries = Object.entries(files).map(([path, c]) => ({ path, sha256: sha(Buffer.from(c)), size: Buffer.byteLength(c) }));
  const manifest = enc({ app: RELEASE_APP_ID, version, files: entries });
  const release = enc({ app: RELEASE_APP_ID, version, created: 'now', manifest_sha256: sha(manifest), file_count: entries.length });
  return { manifest, release, sig: await sign(priv, release), entries, files };
}

test('a good release verifies end to end', async () => {
  const k = await keypair();
  const r = await makeRelease(k.priv);
  const rel = await verifyReleaseSignature(r.release, r.sig, k.pub);
  const m = await verifyManifest(rel, r.manifest);
  for (const e of m.files) await verifyFile(e, Buffer.from(r.files[e.path]));
  assert.equal(rel.version, '1.0.0');
});

test('a tampered file is refused', async () => {
  const k = await keypair();
  const r = await makeRelease(k.priv);
  const rel = await verifyReleaseSignature(r.release, r.sig, k.pub);
  const m = await verifyManifest(rel, r.manifest);
  const e = m.files.find((f) => f.path === 'app.js');
  await assert.rejects(verifyFile(e, Buffer.from('console.log(2)')), (x) => x instanceof ReleaseError && x.code === 'file_mismatch');
  await assert.rejects(verifyFile(e, Buffer.from('console.log(1) ')), (x) => x.code === 'file_mismatch');
});

test('a bad signature is refused (edited release.json, garbage, truncated)', async () => {
  const k = await keypair();
  const r = await makeRelease(k.priv);
  const edited = Buffer.from(r.release.toString().replace('1.0.0', '9.9.9'));
  await assert.rejects(verifyReleaseSignature(edited, r.sig, k.pub), (x) => x.code === 'bad_signature');
  await assert.rejects(verifyReleaseSignature(r.release, 'AAAA', k.pub), (x) => x.code === 'bad_signature');
  await assert.rejects(verifyReleaseSignature(r.release, r.sig.slice(0, 40), k.pub), (x) => x.code === 'bad_signature');
});

test('a release signed by another key is refused', async () => {
  const good = await keypair();
  const evil = await keypair();
  const r = await makeRelease(evil.priv);
  await assert.rejects(verifyReleaseSignature(r.release, r.sig, good.pub), (x) => x.code === 'bad_signature');
});

test('the embedded key must be a public P-256 key', async () => {
  const k = await keypair();
  const r = await makeRelease(k.priv);
  await assert.rejects(verifyReleaseSignature(r.release, r.sig, { ...k.pub, crv: 'P-384' }), (x) => x.code === 'malformed');
  await assert.rejects(verifyReleaseSignature(r.release, r.sig, { ...k.pub, d: 'x' }), (x) => x.code === 'malformed');
});

test('manifest must hash to the signed value and be well formed', async () => {
  const k = await keypair();
  const r = await makeRelease(k.priv);
  const rel = await verifyReleaseSignature(r.release, r.sig, k.pub);
  const other = enc({ app: RELEASE_APP_ID, version: '1.0.0', files: [] });
  await assert.rejects(verifyManifest(rel, other), (x) => x.code === 'manifest_mismatch');
  for (const bad of ['../etc/passwd', '/abs', 'a b']) {
    const r2 = await makeRelease(k.priv, { files: { [bad]: 'x' } });
    const rel2 = await verifyReleaseSignature(r2.release, r2.sig, k.pub);
    await assert.rejects(verifyManifest(rel2, r2.manifest), (x) => x.code === 'malformed', bad);
  }
});

test('versions compare numerically', () => {
  assert.equal(compareVersions('0.1.10', '0.1.9'), 1);
  assert.equal(compareVersions('1.0.0', '1.0.0'), 0);
  assert.equal(compareVersions('0.9.9', '1.0.0'), -1);
});

const here = dirname(fileURLToPath(import.meta.url));
const pwa = join(here, '..', '..');
const keyPath = process.env.BEAM_PWA_RELEASE_KEY || join(homedir(), '.config', 'campfire-beam', 'pwa_release_key.jwk');
const haveEngine = existsSync(join(pwa, 'vendor', 'engine', 'wasm-client.wasm'));

test('tools/build.mjs output verifies with the committed public key', { skip: !(existsSync(keyPath) && haveEngine) && 'needs the release key and a staged engine' }, async () => {
  const out = mkdtempSync(join(tmpdir(), 'campfire-build-'));
  try {
    execFileSync(process.execPath, [join(pwa, 'tools', 'build.mjs'), '--out', out, '--version', '0.0.7', '--quiet'], { cwd: pwa });
    const pub = JSON.parse(readFileSync(join(pwa, 'keys', 'release_public.jwk'), 'utf8'));
    const rel = await verifyReleaseSignature(readFileSync(join(out, 'release.json')), readFileSync(join(out, 'release.sig'), 'utf8'), pub);
    const m = await verifyManifest(rel, readFileSync(join(out, 'manifest.json')));
    for (const f of m.files) await verifyFile(f, readFileSync(join(out, f.path)));
    assert.equal(rel.version, '0.0.7');
    const versionJs = readFileSync(join(out, 'lib', 'version.js'), 'utf8');
    const loader = (versionJs.match(/LOADER = "(sw-[0-9a-f]{16}\.js)"/) || [])[1];
    assert.ok(loader, 'version.js names the loader');
    assert.equal(existsSync(join(out, 'sw.js')), false, 'no fixed-name sw.js: the loader is content-addressed');
    const sw = readFileSync(join(out, loader), 'utf8');
    assert.equal(createHash('sha256').update(sw).digest('hex').slice(0, 16), loader.slice(3, 19), 'the name is the hash of the bytes');
    assert.ok(m.files.some((f) => f.path === loader), 'the loader is in the signed manifest');
    assert.ok(sw.includes('async function verifyReleaseSignature'), 'release.js is inlined into the loader');
    assert.ok(sw.includes(pub.x), 'the public key is built into the loader');
    assert.ok(!sw.includes('0.0.7'), 'nothing release-specific in the loader');
    assert.ok(!/__[A-Z_]+__/.test(sw.replace(/__campfire_(state|install)/g, '')), 'no placeholders left');
    assert.ok(!versionJs.includes('/*__') && !versionJs.includes('__LOADER__'));
    // Same loader code, other release: same name (a phone's registered loader URL never changes bytes).
    const out2 = mkdtempSync(join(tmpdir(), 'campfire-build-'));
    try {
      execFileSync(process.execPath, [join(pwa, 'tools', 'build.mjs'), '--out', out2, '--version', '0.0.8', '--quiet'], { cwd: pwa });
      assert.ok(existsSync(join(out2, loader)), 'a later release keeps the same loader name');
      assert.equal(readFileSync(join(out2, loader), 'utf8'), sw);
    } finally {
      rmSync(out2, { recursive: true, force: true });
    }
    const all = m.files.map((f) => readFileSync(join(out, f.path)).toString('latin1')).join('\n');
    const priv = JSON.parse(readFileSync(keyPath, 'utf8'));
    assert.ok(!all.includes(priv.d), 'the private key is not in the release');
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});

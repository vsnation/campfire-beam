// Builds a signed BEAM Campfire release.
//
//   node tools/build.mjs [--out dist] [--version 0.1.0] [--key <private jwk>]
//
// 1. Checks vendor/engine against engine.lock.json (run tools/stage_engine.mjs first).
// 2. Copies src/ and the engine into --out, filling in the version, the
//    engine hashes and the release public key (lib/version.js, sw.js), and
//    inlining lib/release.js into sw.js.
// 3. Writes manifest.json (every file with size and SHA-256), release.json
//    (version, manifest hash) and release.sig (ECDSA P-256 / SHA-256 over
//    release.json, base64 of r||s).
// 4. Writes _headers for static hosts, and fails if deploy/_headers or
//    deploy/nginx.conf disagree with tools/headers.mjs.
// The private key never enters the output and is never printed.
import { webcrypto, createHash } from 'node:crypto';
import { readFile, writeFile, mkdir, rm, readdir, copyFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, dirname, relative, sep, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SECURITY_HEADERS, MIME } from './headers.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  return i < 0 ? def : process.argv[i + 1];
}
const pkg = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
const version = arg('version', pkg.version);
const out = resolve(process.cwd(), arg('out', join(root, 'dist')));
const keyPath = arg('key', process.env.BEAM_PWA_RELEASE_KEY || join(homedir(), '.config', 'campfire-beam', 'pwa_release_key.jwk'));
const pubPath = join(root, 'keys', 'release_public.jwk');
const quiet = process.argv.includes('--quiet');
const log = (...a) => quiet || console.log('build:', ...a);

if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`version must look like 1.2.3, got ${version}`);
const sha256 = (b) => createHash('sha256').update(b).digest('hex');

// ---- engine
const lock = JSON.parse(await readFile(join(root, 'engine.lock.json'), 'utf8'));
for (const [name, want] of Object.entries(lock.files)) {
  let b;
  try {
    b = await readFile(join(root, 'vendor', 'engine', name));
  } catch {
    throw new Error(`vendor/engine/${name} is missing: run node tools/stage_engine.mjs`);
  }
  if (sha256(b) !== want) throw new Error(`vendor/engine/${name} does not match engine.lock.json`);
}

// ---- keys
const publicJwk = JSON.parse(await readFile(pubPath, 'utf8'));
const pub = { kty: publicJwk.kty, crv: publicJwk.crv, x: publicJwk.x, y: publicJwk.y };
let privJwk;
try {
  privJwk = JSON.parse(await readFile(keyPath, 'utf8'));
} catch {
  throw new Error('release private key not found (create it with node tools/keygen.mjs, or pass --key)');
}
if (privJwk.x !== pub.x || privJwk.y !== pub.y) throw new Error('the release private key does not belong to keys/release_public.jwk');
const signKey = await webcrypto.subtle.importKey('jwk', { kty: 'EC', crv: 'P-256', x: privJwk.x, y: privJwk.y, d: privJwk.d, ext: false }, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
privJwk = null;

// ---- copy
async function walk(dir) {
  const outList = [];
  for (const e of await readdir(dir, { withFileTypes: true })) {
    if (e.name.startsWith('.')) continue;
    const p = join(dir, e.name);
    if (e.isDirectory()) outList.push(...(await walk(p)));
    else if (e.isFile()) outList.push(p);
  }
  return outList;
}

await rm(out, { recursive: true, force: true });
await mkdir(out, { recursive: true });
const srcDir = join(root, 'src');
const releaseJs = (await readFile(join(srcDir, 'lib', 'release.js'), 'utf8')).replace(/^export /gm, '');
const engineLockForApp = { beam_tag: lock.beam_tag, files: lock.files, rules_signature_contains: lock.rules_signature_contains };

for (const f of await walk(srcDir)) {
  const rel = relative(srcDir, f).split(sep).join('/');
  const dst = join(out, rel);
  await mkdir(dirname(dst), { recursive: true });
  if (rel === 'sw.js') {
    let s = await readFile(f, 'utf8');
    s = s
      .replace('/*__RELEASE_PUBLIC_JWK__*/ null', JSON.stringify(pub))
      .replace("'__BUILD_VERSION__'", JSON.stringify(version))
      .replace('/*__SECURITY_HEADERS__*/ {}', JSON.stringify(SECURITY_HEADERS))
      .replace('/*__MIME__*/ {}', JSON.stringify(MIME))
      .replace('/*__INLINE_RELEASE_JS__*/', () => `// ---- inlined from lib/release.js\n${releaseJs}\n// ---- end of lib/release.js`);
    if (/__[A-Z_]+__/.test(s.replace(/__campfire_state/g, ''))) throw new Error('sw.js: a placeholder was not filled');
    await writeFile(dst, s);
  } else if (rel === 'lib/version.js') {
    let s = await readFile(f, 'utf8');
    s = s
      .replace("export const APP_VERSION = '__BUILD_VERSION__';", `export const APP_VERSION = ${JSON.stringify(version)};`)
      .replace('/*__ENGINE_LOCK__*/ null', JSON.stringify(engineLockForApp))
      .replace('/*__RELEASE_PUBLIC_JWK__*/ null', JSON.stringify(pub));
    if (s.includes('/*__')) throw new Error('version.js: a placeholder was not filled');
    await writeFile(dst, s);
  } else {
    await copyFile(f, dst);
  }
}
await mkdir(join(out, 'vendor', 'engine'), { recursive: true });
for (const name of Object.keys(lock.files)) await copyFile(join(root, 'vendor', 'engine', name), join(out, 'vendor', 'engine', name));

// ---- manifest, release, signature
const files = [];
for (const f of (await walk(out)).sort()) {
  const rel = relative(out, f).split(sep).join('/');
  const b = await readFile(f);
  files.push({ path: rel, sha256: sha256(b), size: b.length });
}
const manifest = { app: 'beam-campfire-pwa', version, files };
const manifestBytes = Buffer.from(JSON.stringify(manifest, null, 1) + '\n');
await writeFile(join(out, 'manifest.json'), manifestBytes);
const release = {
  app: 'beam-campfire-pwa',
  version,
  created: new Date().toISOString(),
  manifest_sha256: sha256(manifestBytes),
  file_count: files.length,
  engine: lock.files,
};
const releaseBytes = Buffer.from(JSON.stringify(release, null, 1) + '\n');
await writeFile(join(out, 'release.json'), releaseBytes);
const sig = new Uint8Array(await webcrypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, signKey, releaseBytes));
await writeFile(join(out, 'release.sig'), Buffer.from(sig).toString('base64') + '\n');

// ---- static host headers
const headersText = renderHeaders();
await writeFile(join(out, '_headers'), headersText);
const committed = await readFile(join(root, 'deploy', '_headers'), 'utf8').catch(() => '');
if (committed !== headersText) {
  if (process.argv.includes('--write-deploy')) {
    await writeFile(join(root, 'deploy', '_headers'), headersText);
    log('updated deploy/_headers');
  } else throw new Error('deploy/_headers differs from tools/headers.mjs (run with --write-deploy)');
}
const nginx = await readFile(join(root, 'deploy', 'nginx.conf'), 'utf8').catch(() => '');
for (const [k, v] of Object.entries(SECURITY_HEADERS)) {
  if (!nginx.includes(`add_header ${k} "${v}" always;`)) throw new Error(`deploy/nginx.conf is missing: add_header ${k} "${v}" always;`);
}

let total = 0;
for (const f of files) total += f.size;
log(`v${version}: ${files.length} files, ${(total / 1e6).toFixed(2)} MB, manifest ${release.manifest_sha256.slice(0, 16)}…, signed -> ${relative(process.cwd(), out) || '.'}`);

function renderHeaders() {
  const lines = ['# Generated by tools/build.mjs from tools/headers.mjs. Cloudflare Pages / Netlify format.', '/*'];
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) lines.push(`  ${k}: ${v}`);
  lines.push('  Cache-Control: no-cache');
  lines.push('');
  lines.push('/vendor/engine/wasm-client.wasm');
  lines.push('  Content-Type: application/wasm');
  lines.push('');
  lines.push('# /recovery/mainnet_recovery.bin and /explorer/status must be served on this');
  lines.push('# origin (see deploy/nginx.conf). A static host needs a proxy rule or a mirror.');
  return lines.join('\n') + '\n';
}


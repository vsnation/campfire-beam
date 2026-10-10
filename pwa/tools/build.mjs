// Builds a signed BEAM Campfire release.
//
//   node tools/build.mjs [--out dist] [--version 0.1.0] [--key <private jwk>]
//                        [--mirrors <url,url,...>|none]
//   Test-only: [--loader-note <text>] [--loader-api <n>]
//
// 1. Checks vendor/engine against engine.lock.json (run tools/stage_engine.mjs first).
// 2. Copies src/ and the engine into --out, filling in the version, the
//    engine hashes and the release public key (lib/version.js, sw.js), and
//    inlining lib/release.js and lib/update_sources.js into sw.js. The service worker is written under a
//    content-addressed name, sw-<first 16 hex of its SHA-256>.js, and that
//    name goes into lib/version.js (LOADER). It carries nothing per-release,
//    so the name only changes when the loader's code does.
//    The app shaders (assets/beam/shaders/) go into shaders/, only when their
//    bytes match the pins in lib/shaders.js and the desktop's Dart pins
//    (tools/shader_check.mjs).
// 3. Writes manifest.json (every file with size and SHA-256), release.json
//    (version, manifest hash, the loader's name and loader_compat, and the
//    update sources: --mirrors, or BUILTIN_SOURCES of lib/update_sources.js)
//    and release.sig (ECDSA P-256 / SHA-256 over release.json, base64 of r||s).
//    loader_compat hashes what the loader does to pages (security headers,
//    MIME types, dApp frame policy, LOADER_API); a release from a copy other
//    than the app's own address installs only where the running loader has the
//    same value (lib/update_sources.js loaderCompatible()). The build prints it:
//    a release meant to reach installs whose address is gone must keep it.
//    --loader-note adds a comment to the loader (a release whose loader differs
//    only in its bytes) and --loader-api builds another contract level (a
//    release the older loader cannot run): tests use them, releases do not.
// 4. Writes _headers for static hosts, and fails if deploy/_headers or
//    deploy/nginx.conf disagree with tools/headers.mjs.
// The private key never enters the output and is never printed.
import { webcrypto, createHash } from 'node:crypto';
import { readFile, writeFile, mkdir, rm, readdir, copyFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, dirname, relative, sep, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SECURITY_HEADERS, MIME, LOADER_CSP, nginxHeaderLines } from './headers.mjs';
import { BUILTIN_SOURCES, normalizeSource } from '../src/lib/update_sources.js';
import { SHADER_DIR } from '../src/lib/shaders.js';
import { checkShaders } from './shader_check.mjs';

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
const mirrorsArg = arg('mirrors', null);
const updateSourcesList = mirrorsArg === null ? [...BUILTIN_SOURCES] : mirrorsArg === 'none' ? [] : mirrorsArg.split(',').map((u) => {
  const n = normalizeSource(u);
  if (!n.ok || n.url !== u.trim()) throw new Error(`--mirrors: ${u} is not an https folder address ending in /`);
  return n.url;
});
const loaderNote = arg('loader-note', null);
if (loaderNote !== null && !/^[A-Za-z0-9 ._-]{1,80}$/.test(loaderNote)) throw new Error('--loader-note: letters, digits, space . _ - only');
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
const framePolicyJs = (await readFile(join(srcDir, 'lib', 'dapps', 'frame_policy.js'), 'utf8')).replace(/^export /gm, '');
if (/^import /m.test(framePolicyJs)) throw new Error('lib/dapps/frame_policy.js must not import anything: it is inlined into the service worker');
// Inlined after release.js, whose names it imports: that one import line goes.
const updateSourcesJs = (await readFile(join(srcDir, 'lib', 'update_sources.js'), 'utf8')).replace(/^import \{[^}]*\} from '\.\/release\.js';\n/m, '').replace(/^export /gm, '');
if (/^import /m.test(updateSourcesJs)) throw new Error('lib/update_sources.js may import only from ./release.js: it is inlined into the service worker');
const engineLockForApp = { beam_tag: lock.beam_tag, files: lock.files, rules_signature_contains: lock.rules_signature_contains };

// The loader first: its name goes into lib/version.js.
const swRaw = await readFile(join(srcDir, 'sw.js'), 'utf8');
const apiMatch = swRaw.match(/const LOADER_API = \/\*__LOADER_API__\*\/ (\d+);/);
if (!apiMatch) throw new Error('sw.js: LOADER_API placeholder not found');
const loaderApi = Number(arg('loader-api', apiMatch[1]));
if (!Number.isSafeInteger(loaderApi) || loaderApi < 1) throw new Error('--loader-api must be a positive integer');
// What the loader does to the pages it serves. Equal values: a page of one release runs the same under either loader.
const loaderCompat = sha256(Buffer.from(JSON.stringify({ api: loaderApi, headers: SECURITY_HEADERS, mime: MIME, frame: framePolicyJs })));
let swSrc = swRaw
  .replace(apiMatch[0], `const LOADER_API = ${loaderApi};`)
  .replace('/*__LOADER_COMPAT__*/ null', JSON.stringify(loaderCompat))
  .replace('/*__RELEASE_PUBLIC_JWK__*/ null', JSON.stringify(pub))
  .replace('/*__SECURITY_HEADERS__*/ {}', JSON.stringify(SECURITY_HEADERS))
  .replace('/*__MIME__*/ {}', JSON.stringify(MIME))
  .replace('/*__INLINE_RELEASE_JS__*/', () => `// ---- inlined from lib/release.js\n${releaseJs}\n// ---- end of lib/release.js`)
  .replace('/*__INLINE_UPDATE_SOURCES_JS__*/', () => `// ---- inlined from lib/update_sources.js\n${updateSourcesJs}\n// ---- end of lib/update_sources.js`)
  .replace('/*__INLINE_FRAME_POLICY_JS__*/', () => `// ---- inlined from lib/dapps/frame_policy.js\n${framePolicyJs}\n// ---- end of lib/dapps/frame_policy.js`);
if (loaderNote !== null) swSrc += `// ${loaderNote}\n`;
if (/__[A-Z_]+__/.test(swSrc.replace(/__campfire_(state|install)/g, ''))) throw new Error('sw.js: a placeholder was not filled');
const LOADER_NAME = `sw-${sha256(Buffer.from(swSrc)).slice(0, 16)}.js`;
await writeFile(join(out, LOADER_NAME), swSrc);

for (const f of await walk(srcDir)) {
  const rel = relative(srcDir, f).split(sep).join('/');
  const dst = join(out, rel);
  await mkdir(dirname(dst), { recursive: true });
  if (rel === 'sw.js') {
    continue; // written above under its content-addressed name
  } else if (rel === 'lib/version.js') {
    let s = await readFile(f, 'utf8');
    s = s
      .replace("export const APP_VERSION = '__BUILD_VERSION__';", `export const APP_VERSION = ${JSON.stringify(version)};`)
      .replace('/*__ENGINE_LOCK__*/ null', JSON.stringify(engineLockForApp))
      .replace('/*__RELEASE_PUBLIC_JWK__*/ null', JSON.stringify(pub))
      .replace("export const LOADER = '__LOADER__';", `export const LOADER = ${JSON.stringify(LOADER_NAME)};`);
    if (s.includes('/*__') || s.includes('__LOADER__')) throw new Error('version.js: a placeholder was not filled');
    await writeFile(dst, s);
  } else {
    await copyFile(f, dst);
  }
}
await mkdir(join(out, 'vendor', 'engine'), { recursive: true });
for (const name of Object.keys(lock.files)) await copyFile(join(root, 'vendor', 'engine', name), join(out, 'vendor', 'engine', name));

// ---- app shaders: pinned bytes only (src/lib/shaders.js), the same pins as the desktop app
await mkdir(join(out, SHADER_DIR), { recursive: true });
for (const s of await checkShaders()) await writeFile(join(out, SHADER_DIR, s.file), s.bytes);

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
  loader: LOADER_NAME,
  loader_compat: loaderCompat,
  update_sources: updateSourcesList,
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
for (const line of nginxHeaderLines()) {
  if (!nginx.includes(line)) throw new Error(`deploy/nginx.conf is missing: ${line}`);
}

let total = 0;
for (const f of files) total += f.size;
log(`v${version}: ${files.length} files, ${(total / 1e6).toFixed(2)} MB, loader ${LOADER_NAME} (compat ${loaderCompat.slice(0, 16)}…), manifest ${release.manifest_sha256.slice(0, 16)}…, ${updateSourcesList.length} update copies, signed -> ${relative(process.cwd(), out) || '.'}`);


function renderHeaders() {
  const lines = ['# Generated by tools/build.mjs from tools/headers.mjs. Cloudflare Pages format. Netlify reads it too but', '# has no "!": there the loader would get both policies (the stricter wins), so give it its own with a host rule.', '/*'];
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) lines.push(`  ${k}: ${v}`);
  lines.push('  Access-Control-Allow-Origin: *');
  lines.push('  Cache-Control: no-cache');
  lines.push('');
  lines.push('# The loader is a worker: its own policy lets it fetch updates from other copies');
  lines.push('# (pages keep the one above). "!" removes a header for a path (Cloudflare Pages).');
  lines.push('/sw-*.js');
  lines.push('  ! Content-Security-Policy');
  lines.push(`  Content-Security-Policy: ${LOADER_CSP}`);
  lines.push('');
  lines.push('/vendor/engine/wasm-client.wasm');
  lines.push('  Content-Type: application/wasm');
  lines.push('');
  lines.push('# /recovery/mainnet_recovery.bin and /explorer/status must be served on this');
  lines.push('# origin (see deploy/nginx.conf). A static host needs a proxy rule or a mirror.');
  return lines.join('\n') + '\n';
}


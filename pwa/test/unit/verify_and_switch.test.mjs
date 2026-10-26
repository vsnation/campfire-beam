// deploy/verify_and_switch.sh: a server serves a release only after its signature and every file
// checked out, from a folder holding exactly the signed files, switched to atomically (audit E-4:
// pwa.buybeam.my served a `git pull` of the hosting repository as it came).
import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto, createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readlinkSync, readdirSync, rmSync, symlinkSync, existsSync, lstatSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { RELEASE_APP_ID } from '../../src/lib/release.js';

const script = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'deploy', 'verify_and_switch.sh');
const have = (cmd, args) => spawnSync(cmd, args, { stdio: 'ignore' }).status === 0;
const tools = have('python3', ['--version']) && have('openssl', ['version']);
const sha = (b) => createHash('sha256').update(b).digest('hex');
const s = webcrypto.subtle;

async function keyPair() {
  const k = await s.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const j = await s.exportKey('jwk', k.publicKey);
  return { priv: k.privateKey, pub: { kty: j.kty, crv: j.crv, x: j.x, y: j.y } };
}

/** A checkout of the hosting repository: the signed files plus what such a repository also has. */
async function checkout(dir, priv, { version = '1.0.0', files = null } = {}) {
  const body = files || {
    'index.html': '<!doctype html><title>Beam PWA</title>',
    'app.js': 'console.log(1);',
    'lib/version.js': 'export const LOADER = "sw-0000000000000000.js";\n',
    'sw-0000000000000000.js': 'self.x = 1;\n',
  };
  for (const [p, b] of Object.entries(body)) {
    mkdirSync(dirname(join(dir, p)), { recursive: true });
    writeFileSync(join(dir, p), b);
  }
  const entries = Object.entries(body).map(([path, b]) => ({ path, sha256: sha(Buffer.from(b)), size: Buffer.byteLength(b) }));
  const manifest = Buffer.from(JSON.stringify({ app: RELEASE_APP_ID, version, files: entries }, null, 1) + '\n');
  const release = Buffer.from(JSON.stringify({ app: RELEASE_APP_ID, version, created: '2026-10-12T00:00:00.000Z', manifest_sha256: sha(manifest), file_count: entries.length }, null, 1) + '\n');
  writeFileSync(join(dir, 'manifest.json'), manifest);
  writeFileSync(join(dir, 'release.json'), release);
  writeFileSync(join(dir, 'release.sig'), Buffer.from(await s.sign({ name: 'ECDSA', hash: 'SHA-256' }, priv, release)).toString('base64') + '\n');
  // Not part of the app: never served.
  mkdirSync(join(dir, '.git'), { recursive: true });
  writeFileSync(join(dir, '.git', 'config'), '[core]\n');
  mkdirSync(join(dir, 'deploy'), { recursive: true });
  writeFileSync(join(dir, 'deploy', 'nginx.conf'), '# x\n');
  writeFileSync(join(dir, 'README.md'), '# x\n');
  // A DApp Store package kept next to the app (checked by the app against its IPFS hash).
  mkdirSync(join(dir, 'dapp-store'), { recursive: true });
  writeFileSync(join(dir, 'dapp-store', `Qm${'a'.repeat(44)}.dapp`), 'PK');
  writeFileSync(join(dir, 'dapp-store', 'notes.txt'), 'not a package');
}

function run(checkoutDir, site, keyFile, extra = []) {
  const r = spawnSync('sh', [script, checkoutDir, site, '--key', keyFile, ...extra], { encoding: 'utf8' });
  return { code: r.status, out: `${r.stdout}${r.stderr}` };
}

function world() {
  const root = mkdtempSync(join(tmpdir(), 'campfire-vas-'));
  const site = join(root, 'site');
  mkdirSync(site);
  // The pinned key lives outside both the checkout and the served folder (in production
  // /etc/beam-campfire/, root-owned): the deploy user can write <site>, so a key there is not pinned.
  mkdirSync(join(root, 'etc'));
  return { root, site, co: join(root, 'checkout'), key: join(root, 'etc', 'release_public.jwk'), cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

const served = (site) => readlinkSync(join(site, 'current'));
const listed = (dir) => readdirSync(dir, { recursive: true }).filter((p) => lstatSync(join(dir, p)).isFile()).sort();

test('a signed checkout is copied file by file into its own folder and switched to', { skip: !tools && 'needs python3 and openssl' }, async () => {
  const w = world();
  try {
    const k = await keyPair();
    writeFileSync(w.key, JSON.stringify(k.pub));
    await checkout(w.co, k.priv);
    const r = run(w.co, w.site, w.key);
    assert.equal(r.code, 0, r.out);
    const link = served(w.site);
    assert.match(link, /^releases\/1\.0\.0-[0-9a-f]{16}$/);
    // Exactly the signed files and the three release files, plus the DApp Store packages: no .git, no README, no deploy/.
    assert.deepEqual(listed(join(w.site, link)), ['app.js', `dapp-store/Qm${'a'.repeat(44)}.dapp`, 'index.html', 'lib/version.js', 'manifest.json', 'release.json', 'release.sig', 'sw-0000000000000000.js']);
    assert.match(r.out, /now serving 1\.0\.0/);
    // The same release again: nothing to do, still served.
    const again = run(w.co, w.site, w.key);
    assert.equal(again.code, 0, again.out);
    assert.match(again.out, /already serving 1\.0\.0/);
    // A newer one: switched; the older folder is kept for a rollback.
    rmSync(w.co, { recursive: true });
    await checkout(w.co, k.priv, { version: '1.0.1' });
    const next = run(w.co, w.site, w.key);
    assert.equal(next.code, 0, next.out);
    assert.match(served(w.site), /^releases\/1\.0\.1-/);
    assert.ok(existsSync(join(w.site, link)), 'the previous release stays');
  } finally {
    w.cleanup();
  }
});

test('refused, and the served release left as it was: altered file, other key, swapped manifest, older version, a symlink', { skip: !tools && 'needs python3 and openssl' }, async () => {
  const w = world();
  try {
    const k = await keyPair();
    writeFileSync(w.key, JSON.stringify(k.pub));
    await checkout(w.co, k.priv, { version: '1.0.1' });
    assert.equal(run(w.co, w.site, w.key).code, 0);
    const before = served(w.site);
    const refused = async (name, prepare, why) => {
      rmSync(w.co, { recursive: true, force: true });
      await prepare();
      const r = run(w.co, w.site, w.key);
      assert.notEqual(r.code, 0, `${name}: ${r.out}`);
      assert.match(r.out, why, name);
      assert.equal(served(w.site), before, `${name}: still serving the previous release`);
      assert.deepEqual(readdirSync(join(w.site, 'releases')).filter((n) => n.includes('tmp')), [], `${name}: no staging folder left`);
    };
    await refused('altered file', async () => {
      await checkout(w.co, k.priv, { version: '1.0.2' });
      writeFileSync(join(w.co, 'app.js'), 'console.log("not signed");');
    }, /app\.js .*not the signed file/);
    await refused('another key', async () => checkout(w.co, (await keyPair()).priv, { version: '1.0.2' }), /signature/);
    await refused('manifest swapped after signing', async () => {
      await checkout(w.co, k.priv, { version: '1.0.2' });
      writeFileSync(join(w.co, 'manifest.json'), readFileSync(join(w.co, 'manifest.json'), 'utf8').replace('"1.0.2"', '"1.0.2" '));
    }, /manifest/);
    await refused('older version', async () => checkout(w.co, k.priv, { version: '1.0.0' }), /older than the one served/);
    await refused('same version, other files', async () => checkout(w.co, k.priv, { version: '1.0.1', files: { 'index.html': 'other' } }), /different release/);
    await refused('a symlink where a file should be', async () => {
      await checkout(w.co, k.priv, { version: '1.0.2' });
      rmSync(join(w.co, 'app.js'));
      symlinkSync('/etc/hosts', join(w.co, 'app.js'));
    }, /app\.js .*not a plain file/);
    // The key must not come from the checkout it judges.
    rmSync(w.co, { recursive: true, force: true });
    await checkout(w.co, k.priv, { version: '1.0.2' });
    mkdirSync(join(w.co, 'keys'), { recursive: true });
    writeFileSync(join(w.co, 'keys', 'release_public.jwk'), JSON.stringify(k.pub));
    const r = run(w.co, w.site, join(w.co, 'keys', 'release_public.jwk'));
    assert.notEqual(r.code, 0);
    assert.match(r.out, /key .* inside the checkout/);
    assert.equal(served(w.site), before);
  } finally {
    w.cleanup();
  }
});

// Audit UPD-1: the hosting README ran the checker from the checkout it judges, so whoever can push
// to the hosting repository shipped the checker too, served unsigned files and rewrote the pinned
// key (it sat in <site>, writable by the same user). The checker now refuses to run from inside the
// checkout or the served folder, takes its key from outside both, and the docs install it so.
test('refused when the checker itself, or its key, sits inside the checkout or the served folder', { skip: !tools && 'needs python3 and openssl' }, async () => {
  const w = world();
  try {
    const k = await keyPair();
    writeFileSync(w.key, JSON.stringify(k.pub));
    await checkout(w.co, k.priv);
    const from = (copy, args) => {
      mkdirSync(dirname(copy), { recursive: true });
      writeFileSync(copy, readFileSync(script));
      const r = spawnSync('sh', [copy, ...args], { encoding: 'utf8' });
      return { code: r.status, out: `${r.stdout}${r.stderr}` };
    };
    // The hosting README's old command: the checkout's own copy of the script.
    const inCheckout = from(join(w.co, 'deploy', 'verify_and_switch.sh'), [w.co, w.site, '--key', w.key]);
    assert.notEqual(inCheckout.code, 0, inCheckout.out);
    assert.match(inCheckout.out, /REFUSED.*runs from inside the checkout/);
    assert.ok(!existsSync(join(w.site, 'current')), 'nothing served');
    // A copy kept in the served folder is no better: the same user writes it.
    const inSite = from(join(w.site, 'verify_and_switch.sh'), [w.co, w.site, '--key', w.key]);
    assert.notEqual(inSite.code, 0, inSite.out);
    assert.match(inSite.out, /REFUSED.*runs from inside the folder it serves/);
    assert.ok(!existsSync(join(w.site, 'current')), 'nothing served');
    // A key in the served folder: refused (the old default).
    const siteKey = join(w.site, 'release_public.jwk');
    writeFileSync(siteKey, JSON.stringify(k.pub));
    const r = run(w.co, w.site, siteKey);
    assert.notEqual(r.code, 0, r.out);
    assert.match(r.out, /key .* inside the folder it serves/);
    assert.ok(!existsSync(join(w.site, 'current')), 'nothing served');
    // No --key: the default is outside both, /etc/beam-campfire/release_public.jwk.
    const d = spawnSync('sh', [script, w.co, w.site], { encoding: 'utf8' });
    assert.notEqual(d.status, 0);
    if (!existsSync('/etc/beam-campfire/release_public.jwk')) assert.match(`${d.stdout}${d.stderr}`, /no readable release key at (\/private)?\/etc\/beam-campfire\/release_public\.jwk/);
    // Kept outside both (as installed): served.
    const ok = from(join(w.root, 'etc', 'verify_and_switch.sh'), [w.co, w.site, '--key', w.key]);
    assert.equal(ok.code, 0, ok.out);
    assert.match(served(w.site), /^releases\/1\.0\.0-/);
  } finally {
    w.cleanup();
  }
});

test('the hosting README and the release notes install the checker and the key outside the checkout', () => {
  const docs = [join(dirname(script), 'hosting_README.md'), join(dirname(script), '..', '..', 'docs', 'beam', 'RELEASE_NOTES_PWA_0.2.13.md')];
  for (const f of docs) {
    const s = readFileSync(f, 'utf8');
    assert.ok(!/\bsh \S*beam-campfire-pwa\/deploy\/verify_and_switch\.sh/.test(s), `${f}: never runs the checkout's own copy`);
    assert.ok(!s.includes('/srv/beam-campfire/release_public.jwk'), `${f}: the key is not pinned inside the served folder`);
    assert.ok(s.includes('/etc/beam-campfire/verify_and_switch.sh'), `${f}: runs the installed copy`);
    assert.ok(s.includes('/etc/beam-campfire/release_public.jwk'), `${f}: pins the key outside`);
  }
});

test('nginx and Caddy serve the folder it switches, never the checkout', () => {
  const deploy = join(dirname(script));
  assert.match(readFileSync(join(deploy, 'nginx.conf'), 'utf8'), /\n    root \/srv\/beam-campfire\/current;\n/);
  assert.match(readFileSync(join(deploy, 'Caddyfile'), 'utf8'), /\n\troot \* \/srv\/beam-campfire\/current\n/);
});

test("the hosting README pins the same release key as keys/release_public.jwk", () => {
  const readme = readFileSync(join(dirname(script), 'hosting_README.md'), 'utf8');
  const pinned = JSON.parse(readme.match(/echo '(\{"kty":"EC"[^']+\})'/)[1]);
  const key = JSON.parse(readFileSync(join(dirname(script), '..', 'keys', 'release_public.jwk'), 'utf8'));
  assert.deepEqual([pinned.kty, pinned.crv, pinned.x, pinned.y], [key.kty, key.crv, key.x, key.y]);
});

// Creates the release signing key pair (ECDSA P-256).
//
//   node tools/keygen.mjs [--private <path>] [--public <path>]
//
// Defaults: private key ~/.config/campfire-beam/pwa_release_key.jwk (mode
// 0600, outside the repo), public key keys/release_public.jwk (committed).
// Refuses to overwrite an existing private key. Never prints the private key.
import { webcrypto } from 'node:crypto';
import { writeFile, mkdir, access, chmod } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  return i < 0 ? def : process.argv[i + 1];
}
const privPath = arg('private', join(homedir(), '.config', 'campfire-beam', 'pwa_release_key.jwk'));
const pubPath = arg('public', join(here, '..', 'keys', 'release_public.jwk'));

try {
  await access(privPath);
  console.error(`keygen: ${privPath} already exists; not overwriting it.`);
  process.exit(1);
} catch {
  /* good: no key yet */
}

const pair = await webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
const priv = await webcrypto.subtle.exportKey('jwk', pair.privateKey);
const pub = await webcrypto.subtle.exportKey('jwk', pair.publicKey);
const publicJwk = { kty: pub.kty, crv: pub.crv, x: pub.x, y: pub.y, use: 'sig', alg: 'ES256', key_ops: ['verify'] };

await mkdir(dirname(privPath), { recursive: true, mode: 0o700 });
await writeFile(privPath, JSON.stringify({ kty: priv.kty, crv: priv.crv, x: priv.x, y: priv.y, d: priv.d }) + '\n', { mode: 0o600, flag: 'wx' });
await chmod(privPath, 0o600);
await mkdir(dirname(pubPath), { recursive: true });
await writeFile(pubPath, JSON.stringify(publicJwk, null, 2) + '\n');
console.log(`keygen: private key written (0600) to the configured path; public key: ${pubPath}`);

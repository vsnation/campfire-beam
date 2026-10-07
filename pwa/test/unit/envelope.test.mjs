import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { sealWithPassword, openWithPassword, sealWithPrf, openWithPrf, newDbPassword, randomBytes, EnvelopeError, PBKDF2_MIN_ITERATIONS, KEK_INFO } from '../../src/lib/envelope.js';

const secret = newDbPassword();

test('database password: 32 random bytes as hex', () => {
  assert.match(secret, /^[0-9a-f]{64}$/);
  assert.notEqual(newDbPassword(), newDbPassword());
});

test('password envelope: round trip, >= 600k PBKDF2 rounds, fresh salt and IV', async () => {
  const e1 = await sealWithPassword(secret, 'correct horse', 'w1');
  const e2 = await sealWithPassword(secret, 'correct horse', 'w1');
  assert.equal(e1.iterations, PBKDF2_MIN_ITERATIONS);
  assert.ok(e1.iterations >= 600000);
  assert.notEqual(e1.salt, e2.salt);
  assert.notEqual(e1.iv, e2.iv);
  assert.notEqual(e1.ct, e2.ct);
  assert.ok(!JSON.stringify(e1).includes(secret), 'the secret is not in the envelope');
  assert.equal(await openWithPassword(e1, 'correct horse'), secret);
});

test('wrong password is refused', async () => {
  const e = await sealWithPassword(secret, 'correct horse', 'w1');
  await assert.rejects(openWithPassword(e, 'correct horsf'), (x) => x instanceof EnvelopeError && x.code === 'wrong_secret');
  await assert.rejects(openWithPassword(e, ''), (x) => x.code === 'wrong_secret');
});

test('tampering is detected: ciphertext, IV, wallet id, and a lowered round count', async () => {
  const e = await sealWithPassword(secret, 'pw-12345678', 'w1');
  const flip = (b64) => {
    const b = Buffer.from(b64, 'base64');
    b[0] ^= 1;
    return b.toString('base64');
  };
  await assert.rejects(openWithPassword({ ...e, ct: flip(e.ct) }, 'pw-12345678'), (x) => x.code === 'wrong_secret');
  await assert.rejects(openWithPassword({ ...e, iv: flip(e.iv) }, 'pw-12345678'), (x) => x.code === 'wrong_secret');
  await assert.rejects(openWithPassword({ ...e, walletId: 'w2' }, 'pw-12345678'), (x) => x.code === 'wrong_secret');
  await assert.rejects(openWithPassword({ ...e, iterations: 1000 }, 'pw-12345678'), (x) => x.code === 'weak');
  await assert.rejects(openWithPassword({ ...e, iterations: 700000 }, 'pw-12345678'), (x) => x.code === 'wrong_secret');
  await assert.rejects(openWithPassword({ ...e, kind: 'passkey' }, 'pw-12345678'), (x) => x.code === 'malformed');
});

test('refuses to seal with fewer than 600,000 rounds', async () => {
  await assert.rejects(sealWithPassword(secret, 'pw-12345678', 'w1', { iterations: 100000 }), (x) => x.code === 'weak');
});

test('passkey envelope: HKDF(PRF output, info) round trip, wrong PRF refused', async () => {
  const prf = randomBytes(32);
  const prfSalt = randomBytes(32);
  const e = await sealWithPrf(secret, prf, 'w1', 'cred-abc', prfSalt);
  assert.equal(e.kind, 'passkey');
  assert.equal(e.credId, 'cred-abc');
  assert.equal(await openWithPrf(e, prf), secret);
  await assert.rejects(openWithPrf(e, randomBytes(32)), (x) => x.code === 'wrong_secret');
  await assert.rejects(openWithPrf({ ...e, credId: 'cred-other' }, prf), (x) => x.code === 'wrong_secret');
  await assert.rejects(openWithPrf(e, randomBytes(16)), (x) => x.code === 'malformed');
});

test('passkey KEK is HKDF-SHA256 with info "beam-campfire-kek-v1" (independent derivation decrypts it)', async () => {
  const prf = randomBytes(32);
  const e = await sealWithPrf(secret, prf, 'w9', 'c1', randomBytes(32));
  assert.equal(KEK_INFO, 'beam-campfire-kek-v1');
  const s = webcrypto.subtle;
  const base = await s.importKey('raw', prf, 'HKDF', false, ['deriveKey']);
  const kek = await s.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: Buffer.from(e.salt, 'base64'), info: new TextEncoder().encode('beam-campfire-kek-v1') }, base, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
  const aad = new TextEncoder().encode(JSON.stringify([e.v, e.kind, e.walletId, 0, e.credId, e.salt]));
  const pt = await s.decrypt({ name: 'AES-GCM', iv: Buffer.from(e.iv, 'base64'), additionalData: aad }, kek, Buffer.from(e.ct, 'base64'));
  assert.equal(new TextDecoder().decode(pt), secret);
});

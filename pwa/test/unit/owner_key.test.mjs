// "Show owner key": the key's shape, the wording, the engine wrapper (with a
// stand-in for BEAM's engine), and what the sources may and may not do with
// the key. The real engine, BEAM's CLI and beam-node are in
// test/e2e/owner_key.test.mjs.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import { looksLikeOwnerKey, OWNER_KEY_BYTES, OWNER_KEY_TEXT } from '../../src/lib/owner_key.js';
import { WalletSession } from '../../src/lib/engine.js';

const pwa = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (...p) => readFileSync(join(pwa, ...p), 'utf8');

test('owner key shape: BEAM KeyString, standard base64 of 108 bytes (144 characters)', () => {
  assert.equal(OWNER_KEY_BYTES, 108);
  const good = randomBytes(108).toString('base64');
  assert.equal(good.length, 144);
  assert.equal(looksLikeOwnerKey(good), true);
  assert.equal(looksLikeOwnerKey(randomBytes(107).toString('base64')), false, 'one byte short');
  assert.equal(looksLikeOwnerKey(randomBytes(109).toString('base64')), false, 'one byte long');
  assert.equal(looksLikeOwnerKey(randomBytes(108).toString('base64url')), false, 'BEAM uses the standard alphabet, not base64url');
  assert.equal(looksLikeOwnerKey(`${good.slice(0, 143)}!`), false);
  assert.equal(looksLikeOwnerKey(` ${good}`), false);
  for (const v of ['', null, undefined, 42, {}]) assert.equal(looksLikeOwnerKey(v), false);
});

test('wording: what it is for, that it sees but cannot spend, which password; no jargon past "owner key" and "node"', () => {
  const T = OWNER_KEY_TEXT;
  assert.match(T.lead, /node you run/);
  assert.match(T.lead, /offline and max-privacy/);
  assert.match(T.can, /balance/);
  assert.match(T.can, /history/);
  assert.match(T.cannot, /can’t spend/);
  assert.match(T.passwordHint, /node needs the same/);
  assert.match(T.shownLead, /same password/);
  assert.equal(T.cta, 'Show owner key');
  assert.equal(T.copyCta, 'Copy owner key');
  const all = Object.values(T).join(' ');
  for (const jargon of [/UTXO/i, /KeyString/i, /viewer/i, /seed/i, /--/, /pass=/, /kdf/i, /base64/i, /monitor/i]) assert.doesNotMatch(all, jargon);
});

/** A stand-in for BEAM's WasmWalletClient: just what WalletSession touches. */
function fakeClient(exportOwnerKey) {
  return {
    subscribe: () => 1,
    unsubscribe: () => {},
    setSyncHandler: () => {},
    sendRequest: () => {},
    isRunning: () => true,
    stopWallet: (cb) => cb(),
    delete: () => {},
    ...(exportOwnerKey ? { exportOwnerKey } : {}),
  };
}

test('engine wrapper: hands over the key for the password typed; a missing key, an old engine and silence are refused', async () => {
  const key = randomBytes(108).toString('base64');
  const seen = [];
  const s = new WalletSession({ FS: {} }, fakeClient((pw, cb) => {
    seen.push(pw);
    setTimeout(() => cb(key), 5);
  }));
  assert.equal(await s.exportOwnerKey('the person’s password'), key);
  assert.deepEqual(seen, ['the person’s password'], 'the engine gets exactly the password typed');

  const nul = new WalletSession({ FS: {} }, fakeClient((pw, cb) => cb(null)));
  await assert.rejects(nul.exportOwnerKey('pw'), (e) => e.code === 'owner_key');

  const old = new WalletSession({ FS: {} }, fakeClient(null));
  await assert.rejects(old.exportOwnerKey('pw'), (e) => e.code === 'engine' && /0106/.test(e.message));

  const silent = new WalletSession({ FS: {} }, fakeClient(() => {}));
  await assert.rejects(silent.exportOwnerKey('pw', { timeoutMs: 30 }), (e) => e.code === 'timeout');

  const throws = new WalletSession({ FS: {} }, fakeClient(() => {
    throw new Error('embind');
  }));
  await assert.rejects(throws.exportOwnerKey('pw'), (e) => e.code === 'owner_key');

  await assert.rejects(s.exportOwnerKey(''), (e) => e.code === 'owner_key', 'no empty password reaches the engine');
  assert.equal(seen.length, 1);
  s.stopped = true;
  await assert.rejects(s.exportOwnerKey('pw'), (e) => e.code === 'stopped');
});

test('the key is never logged, never stored, and leaves the page on leave and on lock', () => {
  const screen = read('src', 'screens', 'owner_key.js');
  for (const bad of [/console\./, /localStorage/, /sessionStorage/, /setPrefs/, /setWalletRecord/, /\bstore\./, /indexedDB/i, /caches\./, /fetch\(/]) assert.doesNotMatch(screen, bad, `owner_key.js: ${bad}`);
  assert.match(screen, /app\.lockHooks\.add\(forget\)/, 'a lock (auto-lock too) runs forget');
  assert.match(screen, /destroy\(\)\s*{[^}]*forget\(\)/s, 'leaving the screen runs forget');
  assert.match(screen, /keyText\.textContent = ''/, 'forget empties the key element');
  // Password first, then Face ID when it is set up: both through the existing helpers.
  assert.match(screen, /openWithPasswordFor\(app, password\)[\s\S]*openWithPasskeyFor\(app\)[\s\S]*wallet\.ownerKey\(password\)/);
  const engine = read('src', 'lib', 'engine.js');
  const wrapper = engine.slice(engine.indexOf('exportOwnerKey(password'), engine.indexOf('async stop()'));
  assert.ok(wrapper.length > 100);
  assert.doesNotMatch(wrapper, /console\.|onPrint|logLines/, 'the engine wrapper logs nothing');
  const app = read('src', 'app.js');
  assert.match(app, /NEEDS_WALLET = new Set\(\[[^\]]*'ownerKey'/, 'a locked app never opens the owner key screen');
});

test('Backup keeps one primary button: "Show owner key" is secondary', () => {
  const backup = read('src', 'screens', 'backup.js');
  const card = backup.slice(backup.indexOf("'owner-key-card'"), backup.indexOf("'owner-key-start'"));
  assert.match(card, /btn btn-secondary/);
  assert.doesNotMatch(card, /btn-primary|primary\(/);
});

test('engine patch 0106: in the lock, exports as `beam-wallet export_owner_key` does, with the password given', () => {
  const lock = JSON.parse(read('engine.lock.json'));
  const p = 'scripts/beam/wasm/patches/0106-wasm-export-owner-key.patch';
  assert.ok(lock.patches.includes(p));
  const patchPath = join(pwa, '..', p);
  assert.ok(existsSync(patchPath));
  const patch = readFileSync(patchPath, 'utf8');
  // wallet/cli/cli.cpp ExportOwnerKey: KeyString, SetPassword(pass), m_sMeta = "0", ExportP(owner Kdf).
  assert.match(patch, /\+\s+ks\.SetPassword\(Blob\(secret->data\(\)/);
  assert.match(patch, /\+\s+ks\.m_sMeta = std::to_string\(0\);/);
  assert.match(patch, /\+\s+ks\.ExportP\(\*ownerKdf\);/);
  assert.match(patch, /get_OwnerKdf\(\)/);
  assert.match(patch, /\.function\("exportOwnerKey", &WasmWalletClient::ExportOwnerKey\)/, 'the name engine.js calls');
  assert.doesNotMatch(patch.split('\n').filter((l) => l.startsWith('+')).join('\n'), /BEAM_LOG[^;]*(secret|key|pass)/i, 'the patch logs neither the password nor the key');
});

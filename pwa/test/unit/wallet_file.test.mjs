// Importing a wallet.db: the checks made before the engine sees the file.
import test from 'node:test';
import assert from 'node:assert/strict';
import { checkWalletFile, isPlainSqlite, importPasswordProblem, formatFileSize, importedRecord, IMPORT_TEXT, IMPORT_PROBLEM, NO_PHRASE_NOTICE, MAX_WALLET_BYTES, MAX_PASSWORD_BYTES } from '../../src/lib/wallet_file.js';

const SQLITE_HEADER = new TextEncoder().encode('SQLite format 3\0');

test('real BEAM wallet.db sizes pass (measured: desktop 7.5.13840, LightWallet 7.5.13882, CLI 7.5.14493)', () => {
  // Sizes of real files on this Mac: all whole 4096-byte SQLCipher pages.
  for (const size of [196608, 188416, 593920, 843776, 1269760, 1646592, 9388032]) {
    const r = checkWalletFile({ size, head: crypto.getRandomValues(new Uint8Array(16)) });
    assert.equal(r.ok, true, `size ${size}`);
    assert.equal(r.plainSqlite, false);
  }
});

test('every SQLite page size (512..65536) is accepted, so no real database is refused', () => {
  for (let page = 512; page <= 65536; page *= 2) assert.equal(checkWalletFile({ size: page * 3 }).ok, true, `page ${page}`);
});

test('empty, tiny, oversized and non-database files are refused with a plain reason', () => {
  assert.deepEqual(checkWalletFile({ size: 0 }), { ok: false, code: 'empty', problem: IMPORT_PROBLEM.empty });
  assert.equal(checkWalletFile({ size: 1 }).code, 'tooSmall');
  assert.equal(checkWalletFile({ size: 1023 }).code, 'tooSmall');
  assert.equal(checkWalletFile({ size: 1024 }).ok, true);
  assert.equal(checkWalletFile({ size: MAX_WALLET_BYTES }).ok, true, '512 MB itself is allowed');
  assert.equal(checkWalletFile({ size: MAX_WALLET_BYTES + 512 }).code, 'tooBig');
  assert.equal(checkWalletFile({ size: 4097 }).code, 'notDatabase', 'not whole pages: a photo, a PDF, a text file');
  assert.equal(checkWalletFile({ size: 1_234_567 }).code, 'notDatabase');
  assert.equal(checkWalletFile({ size: -1 }).code, 'gone');
  assert.equal(checkWalletFile({ size: NaN }).code, 'gone');
});

test('an unencrypted SQLite header is noticed but not refused (an empty-password wallet would look like that)', () => {
  const head = new Uint8Array(100);
  head.set(SQLITE_HEADER);
  assert.equal(isPlainSqlite(head), true);
  assert.deepEqual(checkWalletFile({ size: 8192, head }), { ok: true, plainSqlite: true });
  assert.equal(isPlainSqlite(new Uint8Array(8)), false);
  assert.equal(isPlainSqlite(null), false);
});

test('password: required, at most what BEAM accepts (4095 UTF-8 bytes), never echoed', () => {
  assert.equal(importPasswordProblem(''), IMPORT_PROBLEM.noPassword);
  assert.equal(importPasswordProblem(undefined), IMPORT_PROBLEM.noPassword);
  assert.equal(importPasswordProblem('a'), null, 'BEAM wallets may have short passwords; the file decides');
  assert.equal(importPasswordProblem('x'.repeat(MAX_PASSWORD_BYTES)), null);
  assert.equal(importPasswordProblem('x'.repeat(MAX_PASSWORD_BYTES + 1)), IMPORT_PROBLEM.passwordTooLong);
  assert.equal(importPasswordProblem('é'.repeat(2048)), IMPORT_PROBLEM.passwordTooLong, 'counted in UTF-8 bytes, not characters');
  const secret = 'hunter2-secret';
  for (const text of Object.values(IMPORT_PROBLEM)) assert.ok(!text.includes(secret));
});

test('file sizes read like people read them', () => {
  assert.equal(formatFileSize(512), '512 bytes');
  assert.equal(formatFileSize(196608), '197 KB');
  assert.equal(formatFileSize(1646592), '1.6 MB');
  assert.equal(formatFileSize(94_000_000), '94 MB');
  assert.equal(formatFileSize(-1), '');
});

test('an imported wallet record: no phrase, no block scan, not a restore', () => {
  const env = { v: 1, kind: 'password' };
  const r = importedRecord('abcd', env, 5);
  assert.deepEqual(r, { id: 'abcd', createdAt: 5, restored: false, imported: true, scan: false, envelopes: { password: env, passkey: null }, setupDone: false });
});

test('the words: outcome-labelled CTA, file and password named, no blame, the backup stated', () => {
  assert.equal(IMPORT_TEXT.cta, 'Import my wallet');
  assert.ok(!/submit|continue|^ok$/i.test(IMPORT_TEXT.cta));
  assert.match(IMPORT_TEXT.intro, /your file is not changed/);
  assert.match(IMPORT_TEXT.copyWarning, /closed/);
  assert.match(IMPORT_TEXT.copyWarning, /newer copy/);
  assert.match(NO_PHRASE_NOTICE, /no recovery phrase/);
  assert.match(NO_PHRASE_NOTICE, /original file and password are its backup/);
  for (const text of Object.values(IMPORT_PROBLEM)) assert.ok(!/your fault|you failed|invalid input/i.test(text), text);
  assert.match(IMPORT_PROBLEM.failed, /Nothing was changed/);
});

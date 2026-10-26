// Re-audit RE1-12: paying another wallet of this device. Beam PWA runs one wallet in one tab at
// a time, and a regular payment needs the receiving wallet open too, so Send says how it goes: the
// other wallet's offline address, or switching to it after sending and then back. Which wallet an
// address belongs to cannot be known while that wallet is locked (its addresses are only in its own
// encrypted file), so the line shows for a regular address whenever this device has another wallet.
import test from 'node:test';
import assert from 'node:assert/strict';
import { otherWalletHint, OTHER_WALLET_HINT } from '../../src/screens/send_extras.js';
import { sendModeFor } from '../../src/lib/wallet.js';

test('a regular address while this device has another wallet: one line on how paying it works', () => {
  assert.equal(OTHER_WALLET_HINT, 'Paying another of your wallets here? A regular payment needs both open, and only one can be: use its offline address, or after sending, switch to it and then back.');
  assert.equal(otherWalletHint({ wallets: 2, mode: sendModeFor('regular') }), OTHER_WALLET_HINT);
  assert.equal(otherWalletHint({ wallets: 3, mode: sendModeFor('regular_new') }), OTHER_WALLET_HINT);
});

test('no line with one wallet, for an address that arrives while the receiver is closed, or when nothing is checked yet', () => {
  assert.equal(otherWalletHint({ wallets: 1, mode: sendModeFor('regular') }), null);
  assert.equal(otherWalletHint({ wallets: 0, mode: sendModeFor('regular') }), null);
  for (const t of ['offline', 'max_privacy', 'public_offline']) assert.equal(otherWalletHint({ wallets: 2, mode: sendModeFor(t) }), null, t);
  assert.equal(otherWalletHint({ wallets: 2, mode: null }), null);
});

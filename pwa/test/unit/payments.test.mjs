// Notes, payment proofs, the explorer link and removing a record (lib/payments.js):
// the desktop's BeamTxActions rules, and the words checked against BEAM's core.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as P from '../../src/lib/payments.js';

const K = 'a'.repeat(63) + 'b';
const sent = (patch = {}) => ({ txId: 't1', status: 3, income: false, tx_type: 0, status_string: 'sent', comment: '', kernel: K, ...patch });

test('a note keeps printable text only, single-spaced, 256 characters at most', () => {
  assert.equal(P.cleanNote('  Rent\n for\tMarch  '), 'Rent for March');
  assert.equal(P.cleanNote('a‮b​c'), 'a b c');
  assert.equal(P.cleanNote(null), '');
  assert.equal([...P.cleanNote('ж'.repeat(300))].length, P.NOTE_MAX);
  assert.equal([...P.cleanNote('😀'.repeat(300))].length, 256, 'counted in characters, not UTF-16 units');
});

test('the note hint says the truth: BEAM does not send it; a name payment keeps none', () => {
  assert.match(P.noteHint(), /doesn't send it to the receiver/);
  assert.match(P.noteHint({ toName: true }), /can't keep a note/);
});

test('the note line: mine on what I sent, my address label on what I received (never Campfire’s own label)', () => {
  assert.deepEqual(P.txNote(sent({ comment: 'Rent' })), { label: 'Note', text: 'Rent' });
  assert.equal(P.txNote(sent({ comment: '' })), null);
  assert.equal(P.txNote(sent({ income: true, comment: 'BEAM Campfire' })), null);
  assert.deepEqual(P.txNote(sent({ income: true, comment: 'From Alex' })), { label: 'Your address label', text: 'From Alex' });
  assert.equal(P.txNote(sent({ tx_type: 12, comment: 'x' })), null, 'contract calls carry no note');
});

test('remove from list: only a finished record (TxDescription::canDelete)', () => {
  for (const [s, ok] of [[0, false], [1, false], [2, true], [3, true], [4, true], [5, false]]) assert.equal(P.canDeleteTx(sent({ status: s })), ok, `status ${s}`);
});

test('a proof is offered for a completed payment I sent to someone else, regular or offline', () => {
  assert.equal(P.canExportProof(sent()), true);
  assert.equal(P.canExportProof(sent({ tx_type: 7 })), true);
  assert.equal(P.canExportProof(sent({ status: 1 })), false);
  assert.equal(P.canExportProof(sent({ income: true })), false);
  assert.equal(P.canExportProof(sent({ tx_type: 12 })), false);
  assert.equal(P.canExportProof(sent({ status_string: 'sent to own address' })), false);
  assert.equal(P.canCheckProof(sent({ income: true, status_string: 'received' })), true);
  assert.equal(P.canCheckProof(sent()), false);
  assert.equal(P.canCheckProof(sent({ income: true, status: 0 })), false);
});

test('the explorer link is BEAM’s explorer by kernel id, as the desktop opens it; none without a kernel', () => {
  assert.equal(P.explorerUrl(K), `https://explorer.beam.mw/block?kernel_id=${K}`);
  assert.equal(P.explorerUrl(K.toUpperCase()), `https://explorer.beam.mw/block?kernel_id=${K}`);
  assert.equal(P.explorerUrl('0'.repeat(64)), null);
  assert.equal(P.explorerUrl('abc'), null);
  assert.equal(P.explorerUrl(`${K}?x=<script>`), null);
  assert.equal(P.explorerUrl(undefined), null);
  assert.match(P.EXPLORER_NOTE, /explorer\.beam\.mw/);
});

test('a pasted proof: spaces and line breaks dropped, anything not hex refused', () => {
  const hex = 'ab'.repeat(150);
  assert.deepEqual(P.parseProofInput(` ${hex.slice(0, 100)}\n${hex.slice(100).toUpperCase()} `), { ok: true, hex });
  assert.deepEqual(P.parseProofInput(''), { ok: false, problem: 'empty' });
  assert.equal(P.parseProofInput('hello there').ok, false);
  assert.equal(P.parseProofInput('abc').ok, false, 'odd length');
  assert.equal(P.parseProofInput('ab'.repeat(10)).ok, false, 'too short to be a proof');
  assert.equal(P.parseProofInput('ab'.repeat(5000)).ok, false, 'too long');
});

test('the verdict: valid in one sentence with amount, both sides and the transaction ID; "you" for this wallet', () => {
  const info = { is_valid: true, sender: 's'.repeat(64), receiver: 'r'.repeat(64), amount: 150000000, kernel: K, asset_id: 0 };
  const v = P.proofVerdict(info, { describe: (a, id) => `${a}/${id}` });
  assert.equal(v.valid, true);
  assert.equal(v.toYou, false);
  assert.equal(v.amount, 150000000n);
  assert.equal(v.sentence, `Valid: 150000000/0 was paid from ssssssss…ssssss to rrrrrrrr…rrrrrr (transaction ID aaaaaaaa…aaaaab).`);
  const mine = P.proofVerdict(info, { mine: ['R'.repeat(64)] });
  assert.equal(mine.toYou, true);
  assert.match(mine.sentence, / to you /);
  const named = P.proofVerdict(info, { names: new Map([['s'.repeat(64), 'Alice']]) });
  assert.match(named.sentence, /paid from Alice to rrrrrrrr/);
  assert.equal(named.senderName, 'Alice');
  assert.equal(P.proofVerdict({ ...info, is_valid: false }).valid, false);
  assert.equal(P.proofVerdict({ ...info, is_valid: false }).sentence, P.PROOF_TEXT.invalid);
  assert.equal(P.proofVerdict({ ...info, amount: 'x' }).valid, false);
  assert.equal(P.proofVerdict(null).valid, false);
  assert.match(P.PROOF_TEXT.howChecked, /on this device/, 'says where it was checked: not on the network');
});

test('the wallet calls: export (empty = none), verify (a parse error = not a proof), delete', async () => {
  const calls = [];
  const session = (answers) => ({
    call: async (m, p) => {
      calls.push([m, p]);
      const a = answers[m];
      if (a instanceof Error) throw a;
      return a;
    },
  });
  assert.equal(await P.exportProof(session({ export_payment_proof: { payment_proof: 'ab12' } }), 't1'), 'ab12');
  assert.equal(await P.exportProof(session({ export_payment_proof: { payment_proof: '' } }), 't1'), null);
  const rpc = Object.assign(new Error('Failed to parse'), { code: 'rpc' });
  assert.deepEqual(await P.verifyProof(session({ verify_payment_proof: rpc }), 'ab'), { parseError: true });
  const down = Object.assign(new Error('locked'), { code: 'stopped' });
  await assert.rejects(P.verifyProof(session({ verify_payment_proof: down }), 'ab'), /locked/);
  assert.equal(await P.deleteTx(session({ tx_delete: true }), 't1'), true);
  assert.deepEqual(await P.ownIdentities(session({ addr_list: [{ identity: 'id1' }, {}, { identity: '' }] })), ['id1']);
  const txs = [{ income: false, sender_identity: 'id2', receiver_identity: 'peer' }, { income: true, sender_identity: 'peer2', receiver_identity: 'id3' }, { income: true }];
  assert.deepEqual(await P.ownIdentities(session({ addr_list: [{ identity: 'id1' }] }), txs), ['id1', 'id2', 'id3'], 'the identities its payments used, never the other side’s');
  const wid = `1bd0${'7c'.repeat(32)}`;
  assert.equal(P.identityOf(wid), '7c'.repeat(32), 'an old-style address names its key in its last 64 hex characters');
  assert.equal(P.identityOf('7c'.repeat(32)), null, 'a bare key is no wallet id');
  assert.equal(P.identityOf('zz'.repeat(40)), null);
  assert.deepEqual(await P.ownIdentities(session({ addr_list: [{ wallet_id: wid }] }), [{ income: false, sender: `ab${'9a'.repeat(32)}`, receiver: `cd${'11'.repeat(32)}` }]), ['7c'.repeat(32), '9a'.repeat(32)]);
  assert.equal(P.paymentWithKernel([{ txId: 'a', kernel: K.toUpperCase() }], K).txId, 'a');
  assert.equal(P.paymentWithKernel([{ txId: 'a', kernel: K }], '0'.repeat(64)), null);
  assert.deepEqual(calls.find((c) => c[0] === 'verify_payment_proof')[1], { payment_proof: 'ab' });
  assert.deepEqual(calls.find((c) => c[0] === 'tx_delete')[1], { txId: 't1' });
});

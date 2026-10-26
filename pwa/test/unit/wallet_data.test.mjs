// "Move names, notes and history" (issue #55): BEAM's wallet data file (storage::ExportDataToJson,
// the desktop wallet's and the CLI's) checked before any of it reaches the engine, what it holds
// counted, an import planned so nothing here is overwritten and nothing is added twice, the engine
// fed in pieces it can hold, Beam PWA's extras added without touching BEAM's bytes, and the
// engine wrapper (wasm patch 0110) refusing, timing out and stopping as it should.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as D from '../../src/lib/wallet_data.js';
import { WalletSession } from '../../src/lib/engine.js';
import { CONTACTS_MAX } from '../../src/lib/contacts.js';

const hex = (n, c) => c.repeat(n);
const WID = (c) => `${hex(3, '1')}${hex(64, c)}`; // 67 hex: BEAM's to_string(WalletID)
const TOKEN = (c) => `${hex(10, c)}${'A'.repeat(40)}${hex(17, c)}`;
const addr = (c, { index = 1791706454000001, label = '', token = TOKEN(c) } = {}) => ({ Address: token, Category: '', CreationTime: 1791706454, Duration: 0, Identity: hex(64, 'e'), Index: index, Label: label, SubIndex: 0, WalletID: WID(c) });
const id16 = (n) => Array.from({ length: 16 }, (_, i) => (i === 0 ? n : 7));
const param = (n, pid, value, sub = 1) => ({ ParameterId: pid, SubTransactionId: sub, TransactionId: id16(n), Value: value });
const bytes = (s) => [...new TextEncoder().encode(s)];
/** A payment as BEAM stores it: type (0), amount (2), create time (10), status (151), and a note (5) if given. */
const tx = (n, note = null) => [param(n, 0, [1, 0]), param(n, 2, [4, 0, 225, 245, 5]), param(n, 10, [4, 143, 70, 203, 106]), param(n, 151, [132]), ...(note ? [param(n, 5, bytes(note))] : [])];
const file = ({ own = [], contacts = [], txs = [], extras } = {}) => JSON.stringify({ Contacts: contacts, OwnAddresses: own, TransactionParameters: txs.flat(), ...(extras ? { [D.EXTRAS_KEY]: extras } : {}) });

test('the file is named the way BEAM names it (desktop and CLI: TimestampFile("export.dat"))', () => {
  assert.equal(D.dataFileName(Date.UTC(2026, 9, 11) + 999), `export${Date.UTC(2026, 9, 11) / 1000}.dat`);
  assert.match(D.dataFileName(), /^export\d{10}\.dat$/);
});

test('a picked file: empty, unreadable and too big are refused before it is read', () => {
  assert.equal(D.checkDataFile({ size: 0 }).code, 'empty');
  assert.equal(D.checkDataFile({ size: undefined }).code, 'gone');
  assert.equal(D.checkDataFile({ size: -1 }).code, 'gone');
  assert.equal(D.checkDataFile({ size: D.DATA_FILE_MAX_BYTES + 1 }).code, 'tooBig');
  assert.equal(D.checkDataFile({ size: D.DATA_FILE_MAX_BYTES }).ok, true);
  assert.match(D.DATA_PROBLEM.tooBig, /64 MB/);
});

test('only BEAM wallet data passes: garbage, other JSON and damaged entries are refused with words that say what to do', () => {
  for (const t of ['', '   ', 'hello', '\u0000\u0001', '[]', '"x"', '42', 'null', '{}', '{"foo":[]}', '{"OwnAddresses":', '<html></html>']) {
    const r = D.parseWalletData(t);
    assert.equal(r.ok, false, JSON.stringify(t));
    assert.ok(['empty', 'notData'].includes(r.code), `${JSON.stringify(t)} -> ${r.code}`);
  }
  assert.match(D.parseWalletData('hello').problem, /isn’t a BEAM wallet data file.*Save wallet data/);
  const damaged = [
    { OwnAddresses: {} },
    { OwnAddresses: [{ ...addr('a'), Label: undefined }] }, // BEAM reads Label unconditionally: C++ undefined behaviour without it
    { OwnAddresses: [{ ...addr('a'), WalletID: 'zz' }] },
    { OwnAddresses: [{ ...addr('a'), Index: -1 }] },
    { OwnAddresses: [{ ...addr('a'), Index: '5' }] },
    { OwnAddresses: [{ ...addr('a'), CreationTime: null }] },
    { OwnAddresses: [{ ...addr('a'), Duration: 1.5 }] },
    { OwnAddresses: [{ ...addr('a'), Identity: 'not hex' }] },
    { OwnAddresses: [{ ...addr('a'), Label: 'x'.repeat(1025) }] },
    { Contacts: [42] },
    { TransactionParameters: [{ ...param(1, 0, [1]), TransactionId: id16(1).slice(1) }] },
    { TransactionParameters: [{ ...param(1, 0, [1]), Value: [256] }] },
    { TransactionParameters: [{ ...param(1, 0, [1]), Value: 'abc' }] },
    { TransactionParameters: [{ ...param(1, 0, [1]), ParameterId: 300 }] },
    { TransactionParameters: [{ ...param(1, 0, [1]), SubTransactionId: undefined }] },
  ];
  for (const d of damaged) {
    const r = D.parseWalletData(JSON.stringify(d));
    assert.equal(r.code, 'damaged', JSON.stringify(d).slice(0, 120));
    assert.match(r.problem, /damaged or was changed/);
  }
  // A key index past 2^53 would change when read in JavaScript and no longer match the seed.
  const big = file({ own: [addr('a')] }).replace('1791706454000001', '18446744073709551615');
  assert.equal(D.parseWalletData(big).code, 'unsafeNumber');
  assert.equal(D.parseWalletData(file()).code, 'nothing');
  assert.match(D.parseWalletData(file()).problem, /nothing to bring in/);
});

test('what a file holds: addresses and the ones a person named, contacts, payments and notes, address book, hidden tokens', () => {
  const text = file({
    own: [addr('a', { label: 'Rent from Ana' }), addr('b', { label: 'default', index: 1791706454000000 }), addr('c', { label: 'BEAM Campfire', index: 1791706454000002 }), addr('d', { label: '', index: 1791706454000003 })],
    contacts: [addr('e', { index: 0, label: 'Ana' }), addr('f', { index: 0, label: '' })],
    txs: [tx(1, 'Dinner, Friday'), tx(2), tx(3, '  ')],
    extras: { v: 1, contacts: [{ name: 'Bob', address: TOKEN('9') }, { name: 'Ana again', address: TOKEN('e') }, { name: '', address: TOKEN('8') }, 'junk'], hiddenTokens: [190, 0, -1, 'x', 190, 47] },
  });
  const r = D.parseWalletData(text);
  assert.equal(r.ok, true);
  assert.deepEqual(r.summary, { own: 4, ownNamed: 1, contacts: 2, txs: 3, notes: 1, book: 2, people: 2, hiddenTokens: 2 });
  assert.deepEqual(r.data.extras.hiddenTokens, [47, 190]);
  assert.deepEqual(D.bookFromData(r.data).map((c) => c.name), ['Bob', 'Ana again'], 'a Beam PWA file: its own address book, not BEAM’s list');
  // BEAM's list names an address after the last payment's note (it saves every address it pays):
  // from Beam PWA it is not the address book. From the desktop wallet it is its Contacts tab.
  const payees = D.parseWalletData(file({ contacts: [addr('e', { index: 0, label: 'Dinner, Friday' })], extras: { v: 1 } }));
  assert.deepEqual(payees.summary, { own: 0, ownNamed: 0, contacts: 1, txs: 0, notes: 0, book: 0, people: 0, hiddenTokens: 0 });
  const desktop = D.parseWalletData(file({ contacts: [addr('e', { index: 0, label: 'Ana' }), addr('f', { index: 0, label: '' })] }));
  assert.deepEqual(D.bookFromData(desktop.data), [{ name: 'Ana', address: TOKEN('e') }], 'a named desktop contact goes into the address book; an unnamed one only into wallet.db');
  assert.equal(desktop.summary.people, 2);
  // A contract call's comment is the app's (a swap, a claim), not a note the person wrote.
  const call = D.parseWalletData(file({ txs: [[param(5, 0, [1, 12]), param(5, 10, [1]), param(5, 5, bytes('dex swap'))], tx(6, 'Rent')] }));
  assert.equal(call.summary.txs, 2);
  assert.equal(call.summary.notes, 1);
  assert.equal(D.txType([1, 12]), 12);
  assert.equal(D.txType([1, 0]), 0);
  assert.equal(D.txType([7]), 7);
  assert.equal(D.txType([1, 2, 3]), null);
  // A parameter set with no type on the main part is not a payment BEAM can take.
  const untyped = D.parseWalletData(file({ txs: [[param(9, 2, [1])]] }));
  assert.equal(untyped.ok, false);
  assert.equal(untyped.code, 'nothing');
  assert.deepEqual(D.summaryRows(r.summary), [
    ['Your addresses', '4 · 1 with a name'],
    ['Contacts', '2'],
    ['Payments', '3 · 1 with a note'],
    ['Hidden tokens', '2'],
  ]);
  assert.deepEqual(D.summaryRows({ own: 1, ownNamed: 0, people: 0, txs: 0, notes: 0, hiddenTokens: 0 }), [['Your addresses', '1'], ['Payments', '0']]);
  assert.equal(D.addedText({ own: 2, people: 1, txs: 5 }), '2 addresses, 1 contact and 5 payments');
  assert.equal(D.addedText({ own: 0, txs: 1 }), '1 payment');
  assert.equal(D.addedText({ txs: 1234 }), '1,234 payments');
  assert.equal(D.addedText({}), 'nothing');
});

test('an import plan adds only what is not here: nothing is overwritten, a second import adds nothing', () => {
  const data = D.parseWalletData(
    file({
      own: [addr('a', { label: 'Rent' }), addr('b', { label: 'Old name' }), addr('c', { token: TOKEN('7') })],
      contacts: [addr('e', { index: 0, label: 'Ana' })],
      txs: [tx(1, 'Dinner'), tx(2), [param(3, 2, [1])]],
    }),
  ).data;
  const local = D.localIndex({
    own: [{ wallet_id: WID('b').toUpperCase(), address: 'x' }, { wallet_id: 'ffff', address: TOKEN('7') }],
    others: [],
    txs: [{ txId: D.txIdHex(id16(2)).toUpperCase() }],
  });
  const plan = D.planImport(data, local);
  assert.deepEqual(plan.own.map((e) => e.Label), ['Rent'], 'b is here (same wallet id), c is here (same address)');
  assert.equal(plan.contacts.length, 1);
  assert.deepEqual(plan.txs.map((t) => t.id), [D.txIdHex(id16(1))], 'payment 2 is here; payment 3 has no type');
  assert.equal(plan.unreadable, 1);
  assert.deepEqual(plan.already, { own: 2, contacts: 0, txs: 1 });
  assert.deepEqual(plan.counts, { own: 1, ownNamed: 1, contacts: 1, txs: 1, notes: 1, book: 1, people: 1, hiddenTokens: 0 });
  assert.equal(plan.campfire, false, 'a desktop file: BEAM’s contacts are the person’s');
  assert.equal(D.planEmpty(plan), false);

  // Everything here already (the same file a second time): nothing to do.
  const all = D.localIndex({ own: data.own.map((e) => ({ wallet_id: e.WalletID })), others: data.contacts.map((e) => ({ wallet_id: e.WalletID })), txs: [1, 2, 3].map((n) => ({ txId: D.txIdHex(id16(n)) })) });
  const again = D.planImport(data, all, { book: [{ id: '0'.repeat(16), name: 'Ana', address: TOKEN('e') }] });
  assert.equal(D.planEmpty(again), true);
  assert.deepEqual(again.counts, { own: 0, ownNamed: 0, contacts: 0, txs: 0, notes: 0, book: 0, people: 0, hiddenTokens: 0 });

  // The address book could not be opened: none of it is planned (it is never written over).
  assert.equal(D.planImport(data, local, { bookBlocked: true }).book.add.length, 0);
  // Hidden tokens: only ones not hidden here yet.
  const withHidden = D.parseWalletData(file({ own: [addr('a')], extras: { hiddenTokens: [5, 6] } })).data;
  assert.deepEqual(D.planImport(withHidden, D.localIndex({}), { hidden: [6] }).hidden, [5]);
});

test('a payment that failed before it started (key index, no address) is repaired so BEAM takes it; nothing else is touched', () => {
  const early = [...tx(1, 'Dinner'), param(1, 158, [7, 130, 187, 142, 159, 140, 93, 6])]; // MyAddressID, no MyID
  const done = [...tx(2), param(2, 6, Array(40).fill(1)), param(2, 158, [7, 1, 2, 3, 4, 5, 6, 7])]; // both: as BEAM checks it
  const g = D.groupTxs([...early, ...done]);
  assert.equal(g.get(D.txIdHex(id16(1))).repair, true);
  assert.equal(g.get(D.txIdHex(id16(1))).params.some((p) => p.ParameterId === 158), false);
  assert.equal(g.get(D.txIdHex(id16(2))).repair, false);
  assert.equal(g.get(D.txIdHex(id16(2))).params.length, done.length);
  const plan = D.planImport(D.parseWalletData(file({ own: [addr('a')], txs: [early, done] })).data, D.localIndex({}));
  assert.equal(plan.repaired, 1);
  const sent = JSON.parse(D.importChunks(plan).find((c) => c.kind === 'txs').json).TransactionParameters;
  assert.equal(sent.filter((p) => p.ParameterId === 158).length, 1, 'only the complete payment keeps its index');

  const clean = file({ own: [addr('a')], txs: [done] });
  assert.deepEqual(D.repairExport(clean), { text: clean, repaired: 0 }, 'byte for byte when nothing needs it');
  const fixed = D.repairExport(file({ own: [addr('a')], txs: [early, done] }));
  assert.equal(fixed.repaired, 1);
  const o = JSON.parse(fixed.text);
  assert.deepEqual(Object.keys(o), ['Contacts', 'OwnAddresses', 'TransactionParameters'], 'BEAM’s order kept');
  assert.equal(o.TransactionParameters.length, early.length + done.length - 1);
  assert.deepEqual(D.repairExport('not json'), { text: 'not json', repaired: 0 });
});

test('address book entries from a file never shadow a saved contact', () => {
  const A1 = `3f25d94eac${'1'.repeat(47)}c9df9477`;
  const LOOK = `3f25d94eac${'9'.repeat(47)}c9df9477`;
  const A2 = `8b11aa20ff${'2'.repeat(47)}0de4c1aa`;
  const A3 = `77aa11bb22${'3'.repeat(47)}aa11bb22`;
  const saved = [{ id: '0'.repeat(16), name: 'Mom', address: A1 }];
  const r = D.planBook(
    [
      { name: 'Mom', address: A1 }, // already saved
      { name: 'Mum', address: LOOK }, // looks like Mom's
      { name: 'mom', address: A2 }, // Mom's name for another address
      { name: 'Dan', address: A3 },
      { name: 'Dan twice', address: A3 },
    ],
    saved,
  );
  assert.deepEqual(r.add, [{ name: 'Dan', address: A3 }]);
  assert.deepEqual(r.skipped, { already: 2, lookalike: 1, sameName: 1, full: 0, invalid: 0 });
  assert.match(D.bookSkippedText(r.skipped), /looks like one you saved.*name of a contact you saved/);
  assert.equal(D.bookSkippedText({ already: 3, lookalike: 0, sameName: 0, full: 0, invalid: 0 }), null, 'already saved is not a problem');
  const full = Array.from({ length: CONTACTS_MAX }, (_, i) => ({ id: String(i).padStart(16, '0'), name: `P${i}`, address: `${String(i).padStart(10, '0')}${'5'.repeat(47)}${String(i).padStart(8, '0')}` }));
  assert.equal(D.planBook([{ name: 'New', address: A3 }], full).skipped.full, 1);
});

test('the engine gets pieces it can hold: own addresses first, a payment never split, every piece BEAM JSON', () => {
  const own = Array.from({ length: 30 }, (_, i) => addr(String.fromCharCode(97 + (i % 6)), { index: 1000 + i, label: `L${i}` }));
  const txs = Array.from({ length: 40 }, (_, i) => tx(i, `note ${i}`));
  const data = D.parseWalletData(file({ own, contacts: [addr('e', { index: 0 })], txs })).data;
  const plan = D.planImport(data, D.localIndex({}));
  const chunks = D.importChunks(plan, 2000);
  assert.deepEqual([...new Set(chunks.map((c) => c.kind))], ['own', 'contacts', 'txs'], 'own addresses first: BEAM checks the seed there');
  assert.ok(chunks.length > 5);
  let own2 = 0;
  const seenTx = new Set();
  for (const c of chunks) {
    const o = JSON.parse(c.json);
    const key = { own: 'OwnAddresses', contacts: 'Contacts', txs: 'TransactionParameters' }[c.kind];
    assert.deepEqual(Object.keys(o), [key]);
    if (c.kind === 'own') own2 += o.OwnAddresses.length;
    if (c.kind === 'txs') {
      const ids = new Set(o.TransactionParameters.map((p) => D.txIdHex(p.TransactionId)));
      for (const id of ids) {
        assert.ok(!seenTx.has(id), 'a payment is in one piece only');
        seenTx.add(id);
        assert.ok(o.TransactionParameters.some((p) => D.txIdHex(p.TransactionId) === id && p.ParameterId === 0 && p.SubTransactionId === 1), 'its type travels with it');
      }
      assert.ok(c.json.length <= 2000 || ids.size === 1, 'at most the limit, unless one payment is bigger');
    }
  }
  assert.equal(own2, 30);
  assert.equal(seenTx.size, 40);
  assert.equal(D.importChunks(plan).length, 3, 'the default piece holds this whole small file per kind');
  assert.deepEqual(JSON.parse(D.txJson(plan.txs[0])).TransactionParameters, plan.txs[0].params);
  assert.ok(D.CHUNK_MAX_BYTES < 11e6, 'measured: 11 MB fits the engine, 14.7 MB stops it');
});

test('Beam PWA’s part is added without touching BEAM’s bytes, and reads back', () => {
  const beam = file({ own: [addr('a', { label: 'Rent' })], txs: [tx(1)] });
  // Written even when empty: it marks the address book as Beam PWA's, not BEAM's list of payees.
  assert.equal(D.withExtras(beam, {}), `${beam.slice(0, -1)},"${D.EXTRAS_KEY}":{"v":1}}`);
  assert.equal(D.withExtras(beam, { contacts: [], hiddenTokens: [] }), D.withExtras(beam, {}));
  const out = D.withExtras(beam, { contacts: [{ name: 'Bob', address: TOKEN('9'), id: 'secret-ish', createdAt: 1 }], hiddenTokens: [190, 47] });
  assert.ok(out.startsWith(beam.slice(0, -1)), 'BEAM’s JSON is kept byte for byte');
  const back = JSON.parse(out);
  assert.deepEqual(back[D.EXTRAS_KEY], { v: 1, contacts: [{ name: 'Bob', address: TOKEN('9') }], hiddenTokens: [47, 190] }, 'only name and address leave the address book');
  const r = D.parseWalletData(out);
  assert.equal(r.ok, true);
  assert.equal(r.summary.book, 1);
  assert.equal(D.withExtras('{}', { hiddenTokens: [3] }), `{"${D.EXTRAS_KEY}":{"v":1,"hiddenTokens":[3]}}`);
  assert.throws(() => D.withExtras('not json', { hiddenTokens: [3] }), (e) => e.code === 'export');
});

test('an export the engine cannot hold is refused before it is tried; pages join into one file', () => {
  assert.equal(D.exportFits({ txCount: 10, addressCount: 50 }).ok, true);
  const big = D.exportFits({ txCount: 920, addressCount: 1400 }); // a real test wallet: 17 MB of wallet data
  assert.equal(big.ok, false);
  assert.ok(big.maxTxs >= 100 && big.maxTxs <= 300);
  assert.ok(D.EXPORT_SAFE_BYTES < 7.5e6, 'measured: 7.5 MB exported, 10 MB stopped the engine');
  const p0 = JSON.stringify({ Contacts: [addr('e', { index: 0 })], OwnAddresses: [addr('a')], TransactionParameters: tx(1) });
  const p1 = JSON.stringify({ TransactionParameters: [...tx(2), ...tx(3)] });
  const joined = JSON.parse(D.joinPages([p0, p1]));
  assert.deepEqual(Object.keys(joined), ['Contacts', 'OwnAddresses', 'TransactionParameters'], 'BEAM’s key order');
  assert.equal(new Set(joined.TransactionParameters.map((p) => p.TransactionId[0])).size, 3);
  assert.throws(() => D.joinPages([]), (e) => e.code === 'export');
});

test('the words: what the words do not bring back, who can read the file, and that it cannot spend', () => {
  const T = D.DATA_TEXT;
  assert.match(T.lead, /12 words bring back your coins, not/);
  assert.doesNotMatch(T.leadImported, /12 words/, 'a wallet imported from its wallet.db has no words here');
  assert.match(T.reveals, /anyone who gets it/);
  assert.match(T.reveals, /no keys: nobody can spend your coins/);
  assert.equal(T.saveCta, 'Save wallet data');
  assert.equal(T.importCta, 'Bring in wallet data');
  assert.match(T.otherWallet, /Nothing was added.*different 12 words/);
  // The desktop wallet's own names for its menu item and its file are quoted as they are.
  const all = `${Object.values(T).join(' ')} ${Object.values(D.DATA_PROBLEM).join(' ')}`.replaceAll('Import wallet data', '').replaceAll('export….dat', '');
  for (const jargon of [/JSON/, /UTXO/i, /SBBS/i, /parameter/i, /seed/i, /wasm/i, /engine/i, /\bimport/i, /\bexport/i]) assert.doesNotMatch(all, jargon, String(jargon));
});

// ---------------------------------------------------------------- the engine wrapper (wasm patch 0110)

function fakeClient(over = {}) {
  return { subscribe: () => 1, unsubscribe: () => {}, setSyncHandler: () => {}, sendRequest: () => {}, isRunning: () => true, stopWallet: (cb) => cb(), delete: () => {}, ...over };
}

test('engine wrapper: export and import answer through BEAM’s callback; refused while not running or on an old engine; a silent engine times out', async () => {
  const seen = [];
  const s = new WalletSession({ FS: {} }, fakeClient({ exportData: (cb) => setTimeout(() => cb('{"OwnAddresses":[]}'), 5), importData: (json, cb) => { seen.push(json); setTimeout(() => cb(json.includes('ok')), 5); } }));
  assert.equal(await s.exportData(), '{"OwnAddresses":[]}');
  assert.equal(await s.importData('{"ok":1}'), true);
  assert.equal(await s.importData('{"no":1}'), false);
  assert.deepEqual(seen, ['{"ok":1}', '{"no":1}']);
  assert.equal(s.dataCalls, 0);
  await assert.rejects(s.importData(''), (e) => e.code === 'import_data', 'nothing empty reaches the engine');

  const nul = new WalletSession({ FS: {} }, fakeClient({ exportData: (cb) => cb(null) }));
  await assert.rejects(nul.exportData(), (e) => e.code === 'export');
  const old = new WalletSession({ FS: {} }, fakeClient());
  await assert.rejects(old.exportData(), (e) => e.code === 'engine' && /0110/.test(e.message));
  const idle = new WalletSession({ FS: {} }, fakeClient({ isRunning: () => false, exportData: (cb) => cb('{}') }));
  await assert.rejects(idle.exportData(), (e) => e.code === 'stopped');
  const silent = new WalletSession({ FS: {} }, fakeClient({ importData: () => {} }));
  await assert.rejects(silent.importData('{}', { timeoutMs: 30 }), (e) => e.code === 'timeout');
  assert.equal(silent.dataCalls, 1, 'still counted: the engine may answer later, and stop() waits for it');
  const throws = new WalletSession({ FS: {} }, fakeClient({ exportData: () => { throw new Error('embind'); } }));
  await assert.rejects(throws.exportData(), (e) => e.code === 'engine');
  assert.equal(throws.dataCalls, 0);
  s.stopped = true;
  await assert.rejects(s.exportData(), (e) => e.code === 'stopped');
});

test('engine wrapper: stop() waits for an export or import the engine is still doing (BEAM asserts nothing is queued when it stops)', async () => {
  let answer = null;
  let stoppedAt = null;
  const s = new WalletSession({ FS: { syncfs: (_, cb) => cb() } }, fakeClient({ importData: (json, cb) => (answer = cb), stopWallet: (cb) => { stoppedAt = Date.now(); cb(); } }));
  const p = s.importData('{}');
  const t0 = Date.now();
  setTimeout(() => answer(true), 120);
  await s.stop();
  assert.equal(await p.catch((e) => e.code), true);
  assert.ok(stoppedAt - t0 >= 100, 'the engine stopped only after it answered');
});

test('engine wrapper: pages (wasm patch 0111) are read until the engine says there are no more', async () => {
  const calls = [];
  const s = new WalletSession({ FS: {} }, fakeClient({ exportDataPage: (from, max, cb) => { calls.push([from, max]); setTimeout(() => (from === 0 ? cb('{"OwnAddresses":[],"Contacts":[],"TransactionParameters":[]}', 7) : cb('{"TransactionParameters":[]}', -1)), 2); } }));
  assert.equal(s.pagedExport, true);
  assert.equal((await s.exportDataPages({ maxBytes: 500 })).length, 2);
  assert.deepEqual(calls, [[0, 500], [7, 500]]);
  const stuck = new WalletSession({ FS: {} }, fakeClient({ exportDataPage: (from, max, cb) => cb('{}', 0) }));
  await assert.rejects(stuck.exportDataPages(), (e) => e.code === 'export', 'a page that does not move on is not read forever');
  assert.equal(new WalletSession({ FS: {} }, fakeClient()).pagedExport, false);
});

test('security: only transactions that are over come in; one still under way would be signed at the next start, unasked', () => {
  // [type, amount, time] without a status, then with each status as BEAM writes it (0x80 + TxStatus).
  const base = (n) => [param(n, 0, [1, 12]), param(n, 2, [4, 0, 225, 245, 5]), param(n, 10, [4, 143, 70, 203, 106])];
  const withStatus = (n, v, sub = 1) => [...base(n), param(n, 151, v, sub)];
  const txs = [
    withStatus(1, [130]), // cancelled
    withStatus(2, [131]), // completed
    withStatus(3, [132]), // failed
    withStatus(4, [128]), // pending
    withStatus(5, [129]), // in progress: a contract call BEAM would build and sign
    withStatus(6, [133]), // registering
    withStatus(7, [134]), // confirming
    base(8), // no status: BEAM takes it as pending
    withStatus(9, [3]), // not how BEAM writes it
    withStatus(10, [1, 3]),
    [...withStatus(11, [131]), param(11, 151, [129], 2)], // completed on sub 1, in progress on another
    [...withStatus(12, [131]), param(12, 151, [129])], // two status rows, one under way
  ];
  const parsed = D.parseWalletData(file({ txs }));
  assert.equal(parsed.ok, true);
  const plan = D.planImport(parsed.data, { ids: new Set(), tokens: new Set(), txIds: new Set() });
  assert.deepEqual(plan.txs.map((t) => Number.parseInt(t.id.slice(0, 2), 16)).sort((a, b) => a - b), [1, 2, 3], 'cancelled, completed, failed');
  assert.equal(plan.unfinished, 9);
  assert.equal(plan.counts.txs, 3);
  assert.match(D.unfinishedText(9), /^Left out: 9 payments still under way in that file\. Only the wallet that started a payment can finish it/);
  assert.equal(D.unfinishedText(0), null);
  assert.equal(D.statusValue([131]), 3);
  assert.equal(D.statusValue([3]), null);
  assert.equal(D.statusValue([0x87]), null);
  // What reaches the engine is built from the plan only.
  const sent = D.importChunks(plan).filter((c) => c.kind === 'txs').map((c) => JSON.parse(c.json).TransactionParameters).flat();
  assert.ok(sent.length > 0 && sent.every((p) => [1, 2, 3].includes(p.TransactionId[0])), 'nothing unfinished in what the engine receives');
});

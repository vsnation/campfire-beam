// BEAM names beyond register / renew / pay: transfer, sell, stop selling, buy,
// the inbox of what waits for this wallet's names, and claims. Recorded mainnet
// answers where a wallet could make them (test/beam/contracts/bans/fixtures,
// create_tx:false, nothing sent), hand-built kernels where only an owner could
// (as the desktop's bans_service_test.dart builds them).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { BANS_CID, args, ZERO_KEY, parseUserView, parseViewDomain, createBans, refusal, mapError, STATUS, HOLD_BLOCKS, CLAIMS_PER_TRANSACTION, checkCode } from '../../src/lib/bans.js';
import { parseShaderJson, bindSession, unbindSession, privilegedApp, nativeApp, setConsentPresenter, PRIVILEGED_SHADERS, contractsState } from '../../src/lib/contracts.js';
import { PRIVILEGED_SHADER_SHA256 } from '../../src/lib/dapps/sanitizer.js';
import { readContractTx, le, concat, fromHex } from '../../src/lib/contract_tx.js';
import { decodeInvokeData, InvokeDataError } from '../../src/lib/dapps/invoke_data.js';
import { summarize, advise, namePaymentsText, claimText, balanceChange, NameInbox, homeShouldRead, VISIBILITY, CLAIM_FEE, RECHECK_UNOWNED_MS } from '../../src/lib/bans_inbox.js';
import { intentExtras, approveLabel } from '../../src/screens/consent.js';
import { statusWords, pendingDone, needsRenewal, daysBetween, inDays } from '../../src/screens/name_parts.js';
import { invokeEntry, invokeData, FLAG_ADVANCED, FLAG_HAS_COMMITMENT, FLAG_SAVE_APP_INVOKE, FLAG_DEPENDENT } from './helpers/invoke_builder.mjs';
import { fakeEngine } from './helpers/fake_engine.mjs';
import { formatAmount } from '../../src/lib/amount.js';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const envelope = (name) => JSON.parse(readFileSync(join(REPO, 'test', 'beam', 'contracts', 'bans', 'fixtures', `${name}.json`), 'utf8'));
const out = (name) => parseShaderJson(envelope(name).result.output);
const BANS_SHADER = new Uint8Array(readFileSync(join(REPO, 'assets', 'beam', 'shaders', 'bans_app.wasm')));
const FAKE_KEY = '5a'.repeat(32) + '00';
const OTHER_KEY = '72e368c016bec94e0aa0274aae5b6e9ef4bbb64d0ce1436acb134488570d51ef01';
const ONE_TIME = '3c'.repeat(32) + '01';
const VAULT = 'a3385e50cf33afc9f769ee1d82d56b73046d680d343977f36d9a303d7bcdc4da';
const TIP = 4068103;
const TXID = 'ee'.repeat(16);
const fmt = (g) => formatAmount(g);
const unit = (id) => (id === 0 ? 'BEAM' : id === 174 ? 'FOMO' : `#${id}`);

// ---------------------------------------------------------------- hand-built kernels

const nameBytes = (n) => [n.length, ...new TextEncoder().encode(n)];
const sig = ['ab'.repeat(32)];
const setOwnerKernel = (name, key, spend = {}) => invokeData([invokeEntry({ contractId: BANS_CID, method: 3, args: [...fromHex(key), ...nameBytes(name)], sigs: sig, charge: 50000, comment: 'BANS: setting the domain owner', spend })]);
const setPriceKernel = (name, aid, amount) => invokeData([invokeEntry({ contractId: BANS_CID, method: 5, args: [...le(aid, 4), ...le(amount, 8), ...nameBytes(name)], sigs: sig, charge: 50000, comment: 'BANS: setting the domain price' })]);
/** A vault withdrawal as vault_anon/app_impl.h builds one: BaseTx (amount, custom size, owner key, aid) + custom. */
const withdrawArgs = (amount, owner, aid, custom = []) => [...concat(le(amount, 8), le(custom.length, 4), fromHex(owner), le(aid, 4)), ...custom];
const anonReceive = (amount, aid = 0, fee = 1100000) =>
  invokeEntry({ contractId: VAULT, method: 3, flags: FLAG_ADVANCED | FLAG_HAS_COMMITMENT, args: withdrawArgs(amount, ONE_TIME, aid, new Array(97).fill(7)), comment: 'vault_anon receive', spend: { [aid]: -amount }, adv: { minHeight: TIP, dh: 15, fee } });
const rawReceive = (amount, aid = 0, owner = FAKE_KEY) => invokeEntry({ contractId: VAULT, method: 3, args: withdrawArgs(amount, owner, aid), sigs: sig, comment: 'vault_anon receive raw', spend: { [aid]: -amount } });

const mine = (extra = '') => ({ output: `{"res": {"key": "${FAKE_KEY}","hExpire": ${TIP + 100000}${extra}}}` });

/** As in bans.test.mjs: App.view / App.transact stand-ins answering by action; privileged ones too. */
function fakeDeps(answers, { privileged = true, status = { current_height: TIP, current_state_timestamp: 1791276300, is_in_sync: true } } = {}) {
  const calls = [];
  const intents = [];
  const pick = (a) => {
    const action = /action=([a-z_]+)/.exec(a)[1];
    const name = /name=([^,]*)/.exec(a)?.[1];
    calls.push(action);
    const reply = answers[`${action}:${name}`] ?? answers[action];
    if (reply == null) throw new Error(`no answer for ${a}`);
    if (reply instanceof Error) throw reply;
    return typeof reply === 'string' ? envelope(reply).result : reply;
  };
  const shaderErr = (o) => {
    if (o && typeof o === 'object' && 'error' in o) throw Object.assign(new Error(String(o.error)), { code: 'shader' });
    return o;
  };
  const transact = (label) => async (a, { inspect, expect, intent }) => {
    const r = pick(a);
    const output = shaderErr(parseShaderJson(r.output || '{}'));
    try {
      const problem = await inspect(Uint8Array.from(r.raw_data), output);
      if (problem) throw new Error(problem.message || String(problem));
    } catch (e) {
      throw Object.assign(new Error(e.message), { code: 'unexpected' });
    }
    const d = readContractTx(r.raw_data, { allowAdvanced: true });
    const req = { kind: 'contract', spends: [...d.pays].map(([assetId, amount]) => ({ assetId, amount })), receives: [...d.receives].map(([assetId, amount]) => ({ assetId, amount })), fee: d.fee };
    intents.push({ ...intent });
    const no = expect(req);
    if (no) throw Object.assign(new Error(no.message), { code: no.code });
    calls.push(`signed:${label}`);
    return TXID;
  };
  return {
    calls,
    intents,
    view: async (a) => shaderErr(parseShaderJson(pick(a).output || '{}')),
    transact: transact('native'),
    viewPrivileged: privileged ? async (a) => shaderErr(parseShaderJson(pick(a).output || '{}')) : undefined,
    transactPrivileged: privileged ? transact('privileged') : undefined,
    status: async () => status,
  };
}

// ---------------------------------------------------------------- arguments and answers

test('arguments: transfer, sell, buy and claims carry every argument the shader reads', () => {
  const c = BANS_CID;
  assert.equal(args.setOwner('alice', OTHER_KEY), `role=user,action=domain_set_owner,cid=${c},name=alice,pkOwner=${OTHER_KEY}`);
  assert.equal(args.setPrice('alice', 0, 50000000000n), `role=user,action=domain_set_price,cid=${c},name=alice,aid=0,amount=50000000000`);
  assert.equal(args.setPrice('alice', 174, 0n), `role=user,action=domain_set_price,cid=${c},name=alice,aid=174,amount=0`, 'zero takes it off sale');
  assert.equal(args.buy('nephrite'), `role=user,action=domain_buy,cid=${c},name=nephrite`);
  assert.equal(args.receive({ assetId: 0 }), `role=user,action=receive,cid=${c},pkOwner=${ZERO_KEY},aid=0,amount=0`, 'sale proceeds: the zero key, all of it');
  assert.equal(args.receive({ assetId: 7, oneTimeKey: ONE_TIME, amount: 5n }), `role=user,action=receive,cid=${c},pkOwner=${ONE_TIME},aid=7,amount=5`);
  assert.equal(args.receiveAll(), `role=user,action=receive_all,cid=${c}`);
  assert.equal(args.userView(), `role=user,action=view,cid=${c}`);
  assert.throws(() => args.setOwner('alice', ZERO_KEY), (e) => e.code === 'invalidKey');
  assert.throws(() => args.setOwner('alice', `${OTHER_KEY},amount=1`), (e) => e.code === 'invalidKey');
  assert.throws(() => args.setPrice('a,b', 0, 1n), (e) => e.code === 'invalidName');
  assert.throws(() => args.setPrice('alice', 0, -1n), RangeError);
  assert.throws(() => args.setPrice('alice', 0, 1n << 64n), RangeError);
  assert.equal(CLAIMS_PER_TRANSACTION, 30);
});

test('the inbox (role=user view): my names, sale proceeds, payments with the name paid', () => {
  // What the engine answered at privilege 1 for a fresh mainnet wallet (2026-10-11).
  assert.deepEqual(parseUserView(parseShaderJson('{"res": {"domains": [],"raw": [],"anon": []}}')), { domains: [], saleProceeds: [], payments: [] });
  const v = parseUserView({
    res: {
      domains: [{ name: 'alice', key: FAKE_KEY, hExpire: TIP + 5, price: { aid: 0, amount: '50000000000' } }],
      raw: [{ aid: 0, amount: '50000000000' }],
      anon: [{ pk: ONE_TIME, aid: 0, amount: 250000000, domain: 'alice' }, { pk: ONE_TIME, aid: 174, amount: '100000000000', domain: '' }],
    },
  });
  assert.equal(v.domains[0].salePrice.amount, 50000000000n);
  assert.deepEqual(v.saleProceeds, [{ assetId: 0, amount: 50000000000n }]);
  assert.deepEqual(v.payments, [
    { oneTimeKey: ONE_TIME, assetId: 0, amount: 250000000n, name: 'alice' },
    { oneTimeKey: ONE_TIME, assetId: 174, amount: 100000000000n, name: null },
  ]);
  assert.throws(() => parseUserView({ res: { anon: [{ pk: 'x', aid: 0, amount: 1 }] } }), (e) => e.code === 'unexpected');
  assert.throws(() => parseUserView({ res: { raw: [{ aid: -1, amount: 1 }] } }), (e) => e.code === 'unexpected');
  assert.throws(() => parseUserView({ res: 'x' }), (e) => e.code === 'unexpected');
});

test('a name the contract could never have stored is refused; a payment note that is not a name is dropped (audit D-10)', () => {
  // The contract stores only canonical names (bans/contract.cpp: IsValidChar, 3..64), so anything
  // else in a list of names came from a node that made it up.
  const bad = ['Alice', 'al ice', 'a,b=c', 'ab', 'a'.repeat(65), 'alice.beam', 'аlice', ''];
  for (const name of bad) {
    const entry = { name, key: FAKE_KEY, hExpire: TIP + 5 };
    assert.throws(() => parseViewDomain({ domains: [entry] }), (e) => e.code === 'unexpected', `view_domain ${JSON.stringify(name)}`);
    assert.throws(() => parseUserView({ res: { domains: [entry] } }), (e) => e.code === 'unexpected', `user view ${JSON.stringify(name)}`);
  }
  assert.deepEqual(parseViewDomain({ domains: [{ name: 'a-b_c~1', key: FAKE_KEY, hExpire: 1 }] }).map((d) => d.name), ['a-b_c~1']);
  // The name a payment names is whatever its sender encrypted: a bad one never fails the inbox, it is just not a name.
  const v = parseUserView({ res: { anon: [{ pk: ONE_TIME, aid: 0, amount: 1, domain: 'Send 5 BEAM to x' }, { pk: ONE_TIME, aid: 0, amount: 2, domain: 'alice' }] } });
  assert.deepEqual(v.payments.map((p) => p.name), [null, 'alice']);
});

test('advanced entries (vault claims) are read only when asked for, with their own fee and window', () => {
  const raw = invokeData([anonReceive(480000000000)]);
  assert.throws(() => decodeInvokeData(raw), (e) => e instanceof InvokeDataError && /advanced/.test(e.message), 'a dApp never gets one through');
  const d = readContractTx(raw, { allowAdvanced: true });
  const e = d.entries[0];
  assert.equal(e.isAdvanced, true);
  assert.equal(e.advancedFee, 1100000n);
  assert.equal(e.minHeight, BigInt(TIP));
  assert.equal(e.maxHeight, BigInt(TIP + 15));
  assert.equal(d.fee, 1100000n, 'the fee fixed in the kernel, not the formula');
  assert.deepEqual([...d.receives], [[0, 480000000000n]]);
  assert.equal(d.pays.size, 0);
  // A fee the kernel fixed differently is what the core pays.
  assert.equal(readContractTx(invokeData([anonReceive(5n, 0, 2200000)]), { allowAdvanced: true }).fee, 2200000n);
  // A commitment on a plain entry, or a multisigned one, is never read.
  assert.throws(() => decodeInvokeData(invokeData([invokeEntry({ contractId: VAULT, method: 3, flags: FLAG_HAS_COMMITMENT })]), { allowAdvanced: true }), InvokeDataError);
  assert.throws(() => decodeInvokeData(invokeData([invokeEntry({ contractId: VAULT, method: 3, flags: FLAG_ADVANCED | 0x08 })]), { allowAdvanced: true }), InvokeDataError);
  // Trailing bytes are still refused.
  assert.throws(() => decodeInvokeData([...raw, 0], { allowAdvanced: true }), InvokeDataError);
});

// ---------------------------------------------------------------- transfer

test('transfer: only my name, never to my own key, the kernel names this key and this name and moves nothing', async () => {
  let deps = fakeDeps({ my_key: 'my_key', view_name: mine(), domain_set_owner: { output: '{}', raw_data: setOwnerKernel('alice', OTHER_KEY) } });
  const r = await createBans(deps).setOwner('alice', OTHER_KEY, { words: { rows: [['Name', 'alice.beam']], ack: 'I checked' } });
  assert.equal(r.txId, TXID);
  assert.equal(r.fee, 1100000n);
  assert.equal(deps.intents[0].action, 'nameTransfer');
  assert.equal(deps.intents[0].checkCode, checkCode(OTHER_KEY));
  assert.equal(deps.intents[0].ack, 'I checked', 'the screen words ride along');
  assert.ok(deps.calls.includes('signed:native'));

  // The kernel gives it to another key.
  deps = fakeDeps({ my_key: 'my_key', view_name: mine(), domain_set_owner: { output: '{}', raw_data: setOwnerKernel('alice', '11'.repeat(32) + '00') } });
  await assert.rejects(createBans(deps).setOwner('alice', OTHER_KEY), (e) => e.code === 'unexpected');
  assert.ok(!deps.calls.some((c) => c.startsWith('signed')));
  // Another name, or funds moving.
  deps = fakeDeps({ my_key: 'my_key', view_name: mine(), domain_set_owner: { output: '{}', raw_data: setOwnerKernel('alicf', OTHER_KEY) } });
  await assert.rejects(createBans(deps).setOwner('alice', OTHER_KEY), (e) => e.code === 'unexpected');
  deps = fakeDeps({ my_key: 'my_key', view_name: mine(), domain_set_owner: { output: '{}', raw_data: setOwnerKernel('alice', OTHER_KEY, { 0: 5 }) } });
  await assert.rejects(createBans(deps).setOwner('alice', OTHER_KEY), (e) => e.code === 'unexpected');
  // To this wallet's own key, someone else's name, a name nobody holds, one long expired.
  await assert.rejects(createBans(fakeDeps({ my_key: 'my_key', view_name: mine() })).setOwner('alice', FAKE_KEY), (e) => e.refusal === 'ownKey');
  await assert.rejects(createBans(fakeDeps({ my_key: 'my_key', view_name: 'view_name_beam' })).setOwner('beam', OTHER_KEY), (e) => e.refusal === 'ownedByOther');
  await assert.rejects(createBans(fakeDeps({ my_key: 'my_key', view_name: 'view_name_free' })).setOwner('zzzzz', OTHER_KEY), (e) => e.refusal === 'notRegistered');
  const old = { output: `{"res": {"key": "${FAKE_KEY}","hExpire": ${TIP - HOLD_BLOCKS}}}` };
  await assert.rejects(createBans(fakeDeps({ my_key: 'my_key', view_name: old })).setOwner('old', OTHER_KEY), (e) => e.refusal === 'pastHold');
  await assert.rejects(createBans(fakeDeps({})).setOwner('alice', 'nope'), (e) => e.code === 'invalidKey');
});

// ---------------------------------------------------------------- sell and stop selling

test('sell: a price in any asset, zero takes it off sale; the kernel carries exactly that and moves nothing', async () => {
  let deps = fakeDeps({ my_key: 'my_key', view_name: mine(), domain_set_price: { output: '{}', raw_data: setPriceKernel('alice', 0, 50000000000n) } });
  await createBans(deps).setPrice('alice', 0, 50000000000n);
  assert.deepEqual({ action: deps.intents[0].action, amount: deps.intents[0].amount, assetId: deps.intents[0].assetId }, { action: 'nameSell', amount: 50000000000n, assetId: 0 });
  // Another price or asset in the kernel.
  deps = fakeDeps({ my_key: 'my_key', view_name: mine(), domain_set_price: { output: '{}', raw_data: setPriceKernel('alice', 0, 50000000001n) } });
  await assert.rejects(createBans(deps).setPrice('alice', 0, 50000000000n), (e) => e.code === 'unexpected');
  deps = fakeDeps({ my_key: 'my_key', view_name: mine(), domain_set_price: { output: '{}', raw_data: setPriceKernel('alice', 174, 50000000000n) } });
  await assert.rejects(createBans(deps).setPrice('alice', 0, 50000000000n), (e) => e.code === 'unexpected');
  // Stop selling a listed name.
  const listed = mine(',"price": {"aid": 0,"amount": 50000000000}');
  deps = fakeDeps({ my_key: 'my_key', view_name: listed, domain_set_price: { output: '{}', raw_data: setPriceKernel('alice', 0, 0n) } });
  await createBans(deps).setPrice('alice', 0, 0n);
  assert.equal(deps.intents[0].action, 'nameUnlist');
  // Nothing to change: the same price, or off sale already.
  await assert.rejects(createBans(fakeDeps({ my_key: 'my_key', view_name: listed })).setPrice('alice', 0, 50000000000n), (e) => e.refusal === 'noChange');
  await assert.rejects(createBans(fakeDeps({ my_key: 'my_key', view_name: mine() })).setPrice('alice', 0, 0n), (e) => e.refusal === 'noChange');
  await assert.rejects(createBans(fakeDeps({ my_key: 'my_key', view_name: 'view_name_beam' })).setPrice('beam', 0, 1n), (e) => e.refusal === 'ownedByOther');
});

// ---------------------------------------------------------------- buy

test('buy (recorded on mainnet: nephrite, listed at 100,000 BEAM): the kernel pays exactly the listed price, the name comes to this key', async () => {
  const answers = { my_key: 'my_key', view_name: 'view_name_listed', domain_buy: 'buy_listed' };
  let deps = fakeDeps(answers);
  const r = await createBans(deps).buy('nephrite', { expectedPrice: { assetId: 0, amount: 10000000000000n }, words: { rows: [['Yours until', 'about 9 Jul 2027']] } });
  assert.equal(r.fee, 1100000n);
  assert.deepEqual(r.price, { assetId: 0, amount: 10000000000000n });
  assert.deepEqual([...r.pays], [[0, 10000000000000n]]);
  assert.equal(deps.intents[0].action, 'nameBuy');
  assert.deepEqual(deps.intents[0].rows, [['Yours until', 'about 9 Jul 2027']]);
  // The seller changed the price after it was shown: nothing is built.
  deps = fakeDeps(answers);
  await assert.rejects(createBans(deps).buy('nephrite', { expectedPrice: { assetId: 0, amount: 1n } }), (e) => e.code === 'priceMoved');
  assert.ok(!deps.calls.includes('domain_buy'));
  // A kernel paying something else, or for someone else.
  const raw = envelope('buy_listed').result.raw_data;
  const d = readContractTx(raw);
  assert.equal(d.entries[0].method, 6);
  deps = fakeDeps({ ...answers, domain_buy: { output: '{}', raw_data: invokeData([invokeEntry({ contractId: BANS_CID, method: 6, args: [...fromHex(FAKE_KEY), ...nameBytes('nephrite')], spend: { 0: 10000000000001 } })]) } });
  await assert.rejects(createBans(deps).buy('nephrite'), (e) => e.code === 'unexpected');
  deps = fakeDeps({ ...answers, domain_buy: { output: '{}', raw_data: invokeData([invokeEntry({ contractId: BANS_CID, method: 6, args: [...fromHex(OTHER_KEY), ...nameBytes('nephrite')], spend: { 0: 10000000000000 } })]) } });
  await assert.rejects(createBans(deps).buy('nephrite'), (e) => e.code === 'unexpected');
  // Not listed (recorded), already mine.
  await assert.rejects(createBans(fakeDeps({ my_key: 'my_key', view_name: 'view_name_beam' })).buy('beam'), (e) => e.refusal === 'notForSale');
  await assert.rejects(createBans(fakeDeps({ my_key: 'my_key', view_name: mine(',"price": {"aid": 0,"amount": 5}') })).buy('alice'), (e) => e.refusal === 'alreadyMine');
  assert.equal(mapError(Object.assign(new Error(out('buy_not_for_sale').error), { code: 'shader' })).refusal, 'notForSale');
});

// ---------------------------------------------------------------- inbox and claims

test('inbox: at privilege 1; an engine that cannot run it says so as claimUnsupported', async () => {
  const deps = fakeDeps({ view: { output: '{"res": {"domains": [],"raw": [{"aid": 0,"amount": 500}],"anon": []}}' } });
  assert.deepEqual((await createBans(deps).inbox()).saleProceeds, [{ assetId: 0, amount: 500n }]);
  await assert.rejects(createBans(fakeDeps({}, { privileged: false })).inbox(), (e) => e.code === 'claimUnsupported');
  // The recorded get_PkEx failure (privilege 0), and an app the engine would not open.
  const pk0 = fakeDeps({ view: Object.assign(new Error('Contract call failed'), { code: 'rpc', rpc: envelope('user_view').error }) });
  await assert.rejects(createBans(pk0).inbox(), (e) => e.code === 'claimUnsupported');
  const closed = fakeDeps({ view: Object.assign(new Error('no api'), { code: 'open', privileged: true }) });
  await assert.rejects(createBans(closed).inbox(), (e) => e.code === 'claimUnsupported');
});

test('claim all: vault withdrawals to this wallet only; the fee fixed in the kernel; the words come from what was built', async () => {
  const raw = invokeData([rawReceive(50000000000n), anonReceive(250000000n), anonReceive(100000000000n, 174)]);
  let deps = fakeDeps({ view_params: 'view_params', my_key: 'my_key', receive_all: { output: '{}', raw_data: raw } });
  const r = await createBans(deps).claimAll({ words: (b) => ({ rows: [['Your balance changes by', balanceChange(b.receives, b.fee, fmt, unit)]] }) });
  assert.equal(r.count, 3);
  assert.deepEqual([...r.receives].sort(), [[0, 50250000000n], [174, 100000000000n]]);
  assert.equal(r.fee, readContractTx(raw, { allowAdvanced: true }).fee);
  assert.ok(deps.calls.includes('signed:privileged'), 'built and sent through the privileged app');
  assert.equal(deps.intents[0].action, 'nameClaim');
  assert.deepEqual(deps.intents[0].rows, [['Your balance changes by', `+${fmt(50250000000n - r.fee)} BEAM, +1,000 FOMO`]]);

  const refused = async (rawData, what) => {
    deps = fakeDeps({ view_params: 'view_params', my_key: 'my_key', receive_all: { output: '{}', raw_data: rawData } });
    await assert.rejects(createBans(deps).claimAll(), (e) => e.code === 'unexpected', what);
    assert.ok(!deps.calls.some((c) => c.startsWith('signed')), what);
  };
  await refused(invokeData([invokeEntry({ contractId: BANS_CID, method: 3, args: withdrawArgs(5n, FAKE_KEY, 0), spend: { 0: -5 } })]), 'another contract');
  await refused(invokeData([invokeEntry({ contractId: VAULT, method: 2, args: withdrawArgs(5n, FAKE_KEY, 0), spend: { 0: 5 } })]), 'a deposit');
  await refused(invokeData([rawReceive(5n, 0, OTHER_KEY)]), "someone else's sale proceeds");
  await refused(invokeData([invokeEntry({ contractId: VAULT, method: 3, args: withdrawArgs(5n, FAKE_KEY, 0), sigs: sig, spend: { 0: -6 } })]), 'more than its own amount');
  await refused(invokeData([anonReceive(5n), invokeEntry({ contractId: VAULT, method: 3, args: withdrawArgs(5n, FAKE_KEY, 0), sigs: sig, spend: { 0: 7 } })]), 'something paid');
  // Nothing waiting: the shader's own words.
  deps = fakeDeps({ view_params: 'view_params', my_key: 'my_key', receive_all: { output: '{"error": "nothing to withdraw"}', raw_data: [] } });
  await assert.rejects(createBans(deps).claimAll(), (e) => e.refusal === 'nothingToClaim' && e.message === 'There is nothing waiting to be claimed.');
  // No privileged app: said, not tried.
  await assert.rejects(createBans(fakeDeps({}, { privileged: false })).claimAll(), (e) => e.code === 'claimUnsupported');
});

test('claim sale proceeds: privilege 0, the zero key; "no funds" (recorded) means nothing waits', async () => {
  let deps = fakeDeps({ view_params: 'view_params', my_key: 'my_key', receive: { output: '{}', raw_data: invokeData([rawReceive(50000000000n)]) } }, { privileged: false });
  const r = await createBans(deps).claimSaleProceeds(0);
  assert.deepEqual([...r.receives], [[0, 50000000000n]]);
  assert.ok(deps.calls.includes('signed:native'));
  deps = fakeDeps({ view_params: 'view_params', my_key: 'my_key', receive: 'receive_raw' });
  await assert.rejects(createBans(deps).claimSaleProceeds(0), (e) => e.refusal === 'noFunds');
});

// ---------------------------------------------------------------- the inbox in words

const inbox = (payments = [], raw = [], domains = []) => ({ domains, saleProceeds: raw, payments });
const pay = (amount, assetId = 0, name = 'alice') => ({ oneTimeKey: ONE_TIME, assetId, amount, name });

test('summary and advice: totals per asset, only real names, the fee per 30 claims, who pays it', () => {
  const s = summarize(inbox([pay(250000000n), pay(100n, 0, 'bob'), pay(5n, 0, 'Not A Name'), pay(100000000000n, 174)], [{ assetId: 0, amount: 7n }]));
  assert.deepEqual([...s.totals], [[0, 250000112n], [174, 100000000000n]]);
  assert.equal(s.entryCount, 5);
  assert.deepEqual(s.names, ['alice', 'bob'], 'a decrypted name that is not a name is left out');
  assert.equal(advise(s, 0n).canClaim, true, 'the BEAM waiting pays the fee');
  assert.equal(advise(s, 0n).fee, CLAIM_FEE);
  const tokens = summarize(inbox([pay(5n, 174)]));
  assert.deepEqual(advise(tokens, 0n), { canClaim: false, transactions: 1, fee: CLAIM_FEE, reason: 'needsBeam', costsMoreThanItReturns: false });
  assert.equal(advise(tokens, CLAIM_FEE).canClaim, true);
  const dust = summarize(inbox([pay(1000n)]));
  assert.equal(advise(dust, 10n ** 9n).costsMoreThanItReturns, true);
  const many = summarize(inbox(Array.from({ length: 31 }, () => pay(10n ** 8n))));
  assert.equal(advise(many, 0n).transactions, 2);
  assert.equal(advise(summarize(inbox()), 0n).reason, 'nothing');
  assert.equal(advise({ visibility: VISIBILITY.unsupported }, 0n).reason, 'unsupported');
});

test('words: the Home line, the claim sheet, the balance change after the fee', () => {
  assert.deepEqual(namePaymentsText(summarize(inbox([pay(250000000n)])), fmt, unit), { lead: 'Sent to your name alice.beam', amounts: '2.5 BEAM' });
  assert.equal(namePaymentsText(summarize(inbox([pay(1n), pay(1n, 0, 'bob')])), fmt, unit).lead, 'Sent to your names');
  assert.equal(namePaymentsText(summarize(inbox([], [{ assetId: 0, amount: 1n }])), fmt, unit).lead, 'From names you sold');
  assert.equal(namePaymentsText(summarize(inbox()), fmt, unit), null);
  const s = summarize(inbox([pay(250000000n), pay(100000000000n, 174)]));
  const t = claimText({ summary: s, advice: advise(s, 0n), canSpend: true, fmt, unit });
  assert.equal(t.headline, 'Claim what was sent to alice.beam');
  assert.equal(t.cta, 'Claim all');
  assert.equal(t.balanceChange, '+2.489 BEAM, +1,000 FOMO');
  assert.match(t.feeNote, /^Pays its own fee/);
  assert.match(t.privacyNote, /can be linked on the blockchain/);
  assert.equal(t.blocker, null);
  assert.match(claimText({ summary: s, advice: advise(s, 0n), canSpend: false, fmt, unit }).blocker, /paused until the wallet is up to date/);
  const one = summarize(inbox([pay(250000000n)]));
  assert.equal(claimText({ summary: one, advice: advise(one, 0n), canSpend: true, fmt, unit }).cta, 'Claim 2.5 BEAM');
  const built = { receives: new Map([[0, 300000000n]]), fee: 1100000n };
  assert.equal(claimText({ summary: one, advice: advise(one, 0n), canSpend: true, built, fmt, unit }).cta, 'Claim 3 BEAM', 'once built, the engine’s figures');
  assert.equal(balanceChange(new Map([[174, 5n]]), 1100000n, fmt, unit), '+0.00000005 FOMO, −0.011 BEAM');
  const sold = summarize(inbox([], [{ assetId: 0, amount: 50000000000n }]));
  assert.equal(claimText({ summary: sold, advice: advise(sold, 0n), canSpend: true, fmt, unit }).headline, 'Claim what your sold names earned');
});

test('the inbox monitor: one read at a time, not too often, keeps the last good answer', async () => {
  let n = 0;
  let now = 0;
  let next = () => inbox([pay(5n)]);
  const m = new NameInbox(async () => {
    n++;
    return next();
  }, { minIntervalMs: 20000, now: () => now });
  const seen = [];
  m.onChange((s) => seen.push(s));
  await Promise.all([m.refresh(), m.refresh()]);
  assert.equal(n, 1, 'concurrent refreshes share one read');
  await m.refresh();
  assert.equal(n, 1, 'within the interval: skipped');
  await m.refresh({ force: true });
  assert.equal(n, 2);
  next = () => {
    throw new Error('node went away');
  };
  now += 30000;
  await m.refresh();
  assert.equal(m.latest.entryCount, 1, 'a failed read keeps the last good summary');
  assert.equal(m.lastError.message, 'node went away');
  next = () => {
    throw Object.assign(new Error('x'), { code: 'claimUnsupported' });
  };
  now += 30000;
  await m.refresh();
  assert.equal(m.latest.visibility, VISIBILITY.unsupported);
  m.markClaiming(new Map([[0, 5n]]));
  next = () => inbox([pay(5n)]);
  now += 30000;
  await m.refresh();
  assert.ok(m.claiming, 'still waiting in the vault: still on its way');
  next = () => inbox();
  now += 30000;
  await m.refresh();
  assert.equal(m.claiming, null, 'gone from the vault: claimed');
  assert.ok(seen.length >= 5);
});

test('Home reads the inbox only for a wallet that may hold names', () => {
  const now = 10 ** 12;
  assert.equal(homeShouldRead({ hint: null, record: { restored: false }, now }), false, 'made here from new words: owns none');
  assert.equal(homeShouldRead({ hint: null, record: { restored: true }, now }), true);
  assert.equal(homeShouldRead({ hint: null, record: { imported: true }, now }), true);
  assert.equal(homeShouldRead({ hint: { owns: true, at: now }, record: {}, now }), true);
  assert.equal(homeShouldRead({ hint: { owns: false, at: now - 1000 }, record: { imported: true }, now }), false);
  assert.equal(homeShouldRead({ hint: { owns: false, at: now - RECHECK_UNOWNED_MS - 1 }, record: {}, now }), true, 'once a day: a name can be given to it');
});

test('a name in words: until, soon, expired, gone; what is on its way', () => {
  const clock = { tipHeight: TIP, tipTime: 1791276300 };
  assert.match(statusWords({ status: STATUS.active, expireHeight: TIP + 1440 * 400 }, clock).text, /^Until \d{1,2} \w{3} \d{4}$/);
  assert.equal(statusWords({ status: STATUS.active, expireHeight: TIP + 1440 * 12 }, clock).text, 'Expires in 12 days');
  assert.equal(statusWords({ status: STATUS.active, expireHeight: TIP + 1440 * 12 }, clock).tone, 'soon');
  assert.match(statusWords({ status: STATUS.onHold, expireHeight: TIP - 10 }, clock).text, /^Expired · renew by /);
  assert.equal(statusWords({ status: STATUS.forSale, expireHeight: TIP + 1440 * 400, salePrice: { assetId: 0, amount: 5n * 10n ** 10n } }, clock).sale, 'For sale at 500 BEAM');
  assert.equal(needsRenewal({ status: STATUS.onHold, expireHeight: TIP }, TIP), true);
  assert.equal(needsRenewal({ status: STATUS.active, expireHeight: TIP + 1440 * 31 }, TIP), false);
  assert.equal(needsRenewal({ status: STATUS.availableAgain, expireHeight: 0 }, TIP), false);
  assert.equal(daysBetween(TIP, TIP + 1440), 1);
  assert.deepEqual([0, 1, 5].map(inDays), ['today', 'tomorrow', 'in 5 days']);
  const list = [{ name: 'alice', expireHeight: 9, salePrice: { assetId: 0, amount: 5n } }];
  assert.equal(pendingDone({ kind: 'register' }, 'alice', list), true);
  assert.equal(pendingDone({ kind: 'transfer' }, 'alice', list), false, 'still here: not gone yet');
  assert.equal(pendingDone({ kind: 'transfer' }, 'alice', []), true);
  assert.equal(pendingDone({ kind: 'sell', assetId: 0, amount: 5n }, 'alice', list), true);
  assert.equal(pendingDone({ kind: 'unlist' }, 'alice', list), false);
  assert.equal(pendingDone({ kind: 'renew', expireBefore: 9 }, 'alice', list), false);
});

test('the approve sheet: the outcome on the button, the screen’s rows, notes and tick', () => {
  const req = (intent, spends = [], receives = []) => ({ kind: 'contract', native: true, intent, spends, receives, fee: 1100000n });
  const u = (id) => (id === 0 ? 'BEAM' : 'FOMO');
  assert.equal(approveLabel(req({ action: 'nameTransfer', name: 'alice' }), u), 'Transfer alice');
  assert.equal(approveLabel(req({ action: 'nameSell', name: 'alice' }), u), 'List alice for sale');
  assert.equal(approveLabel(req({ action: 'nameUnlist', name: 'alice' }), u), 'Stop selling alice');
  assert.equal(approveLabel(req({ action: 'nameBuy', name: 'nephrite' }, [{ assetId: 0, amount: 10000000000000n }]), u), 'Pay 100,000 BEAM and buy nephrite');
  assert.equal(approveLabel(req({ action: 'nameClaim' }, [], [{ assetId: 0, amount: 250000000n }]), u), 'Claim 2.5 BEAM');
  assert.equal(approveLabel(req({ action: 'nameClaim' }, [], [{ assetId: 0, amount: 1n }, { assetId: 174, amount: 1n }]), u), 'Claim all');
  // A transfer that moves money, or a "claim" that pays, gets no friendly words.
  assert.equal(approveLabel(req({ action: 'nameTransfer', name: 'alice' }, [{ assetId: 0, amount: 5n }]), u), 'Pay 0.00000005 BEAM');
  assert.equal(approveLabel(req({ action: 'nameClaim' }, [{ assetId: 0, amount: 5n }], [{ assetId: 0, amount: 6n }]), u), 'Pay 0.00000005 BEAM, get 0.00000006 BEAM');
  const x = intentExtras(req({ action: 'nameTransfer', name: 'alice', rows: [['New owner', '72e3 68c0 … 570d 51ef']], warn: "This can't be undone.", ack: 'I checked all 16 characters with the new owner', notes: ['a', '', 7, 'b'] }));
  assert.deepEqual(x, { rows: [['New owner', '72e3 68c0 … 570d 51ef']], warn: "This can't be undone.", ack: 'I checked all 16 characters with the new owner', notes: ['a', 'b'] });
  assert.deepEqual(intentExtras({ ...req({ action: 'nameSell', notes: ['x'] }), native: false }), { rows: [], warn: null, ack: null }, "a dApp's intent is never shown");
});

// ---------------------------------------------------------------- the privileged app

test('the privileged app: opened at privilege 1, runs only the pinned names shader, never anything re-runnable', async () => {
  assert.deepEqual([...PRIVILEGED_SHADERS], [...PRIVILEGED_SHADER_SHA256], 'the same list dApps are refused');
  const sent = [];
  const engine = fakeEngine({
    respond: (r, api) => {
      sent.push({ method: r.method, privilege: api.privilege, args: r.params && r.params.args });
      if (r.method === 'invoke_contract' && /receive_all/.test(r.params.args)) return api.reply(r.id, { output: '{}', raw_data: invokeData([anonReceive(250000000n)]) });
      if (r.method === 'invoke_contract' && /rebuild/.test(r.params.args)) return api.reply(r.id, { output: '{}', raw_data: invokeData([invokeEntry({ contractId: VAULT, method: 3, flags: FLAG_SAVE_APP_INVOKE, args: withdrawArgs(5n, FAKE_KEY, 0), sigs: sig, spend: { 0: -5 } })], { firstFlags: FLAG_SAVE_APP_INVOKE, privilege: 1 }) });
      if (r.method === 'invoke_contract' && /dependent/.test(r.params.args)) return api.reply(r.id, { output: '{}', raw_data: invokeData([invokeEntry({ contractId: VAULT, method: 3, flags: FLAG_DEPENDENT })]) });
      if (r.method === 'invoke_contract') return api.reply(r.id, { output: '{"res": {"domains": [],"raw": [],"anon": []}}' });
      if (r.method === 'process_invoke_data') return engine.askContract(api, r, { comment: 'vault_anon receive', fee: '0.011', isEnough: true, isSpend: false }, [{ amount: '2.5', assetID: 0, spend: false }]);
      return api.reply(r.id, {});
    },
  });
  bindSession(engine.session);
  const shown = [];
  const unset = setConsentPresenter(async (q) => {
    shown.push(q);
    return false;
  });
  try {
    const app = await privilegedApp();
    assert.equal(app, await privilegedApp(), 'one per session');
    const api = engine.apis.at(-1);
    assert.equal(api.privilege, 1);
    assert.deepEqual(api.apiVersions, ['current', 'current']);
    assert.notEqual(api.appId, (await nativeApp()).appId, 'not the same app as the wallet’s own (privilege 0)');
    assert.equal(engine.apis.at(-1).privilege, 0);

    // Any other shader is refused before the engine sees it; so is a direct call.
    await assert.rejects(app.view('role=user,action=view', [0, 97, 115, 109]), (e) => e.code === 'unexpected');
    await assert.rejects(app.call('tx_send', { value: 1 }), (e) => e.code === 'unexpected');
    await assert.rejects(app.call('invoke_contract', { args: 'x', contract: Array.from(BANS_SHADER) }), (e) => e.code === 'unexpected', 'only through view/transact');
    assert.equal(sent.length, 0);

    assert.deepEqual(await app.view(args.userView(), BANS_SHADER), { res: { domains: [], raw: [], anon: [] } });
    // Invoke data the engine could re-run later at a stored privilege, or a dependent call: never sent.
    await assert.rejects(app.transact('action=rebuild', BANS_SHADER), (e) => e.code === 'unexpected' && /change after approval/.test(e.message));
    await assert.rejects(app.transact('action=dependent', BANS_SHADER), (e) => e.code === 'unexpected');
    assert.ok(!sent.some((s) => s.method === 'process_invoke_data'));
    // A claim reaches the approve sheet as the wallet itself, with its words.
    await assert.rejects(app.transact(args.receiveAll(), BANS_SHADER, { intent: { action: 'nameClaim', rows: [['Sent to', 'alice.beam']] } }), (e) => e.code === 'rejected');
    assert.equal(shown.length, 1);
    assert.equal(shown[0].native, true);
    assert.equal(shown[0].appName, 'BEAM Campfire'); // the engine's name for the wallet (NATIVE_APP_NAME)
    assert.equal(shown[0].intent.action, 'nameClaim');
    assert.deepEqual(shown[0].receives.map((a) => a.amount), [250000000n]);
    assert.ok(sent.every((s) => s.privilege === 1));
  } finally {
    unset();
    unbindSession();
  }
  assert.equal(contractsState().apps, 0, 'closed with the session');
});

test('refusal words for the new shader answers', () => {
  assert.equal(refusal('invalid account key').refusal, 'invalidAccountKey');
  assert.equal(refusal('not for sale').message, 'This name is not listed for sale.');
  assert.equal(refusal('no funds').message, 'There is nothing waiting to be claimed.');
});

test('apps are opened one at a time (two createAppAPI calls in flight stop the engine’s page)', async () => {
  const engine = fakeEngine();
  const real = engine.client.createAppAPI.bind(engine.client);
  let inFlight = 0;
  let most = 0;
  engine.client.createAppAPI = (...a) => {
    inFlight++;
    most = Math.max(most, inFlight);
    const cb = a.length === 6 ? a[4] : a[2];
    const wrapped = (err, api) => setTimeout(() => {
      inFlight--;
      cb(err, api);
    }, 5);
    if (a.length === 6) a[4] = wrapped;
    else a[2] = wrapped;
    real(...a);
  };
  bindSession(engine.session);
  try {
    const { openApp } = await import('../../src/lib/contracts.js');
    const apps = await Promise.all([nativeApp(), privilegedApp(), openApp({ appName: 'Probe A', appUrl: 'https://a.example' }), openApp({ appName: 'Probe B', appUrl: 'https://b.example' })]);
    assert.equal(apps.length, 4);
    assert.equal(most, 1);
  } finally {
    unbindSession();
  }
});

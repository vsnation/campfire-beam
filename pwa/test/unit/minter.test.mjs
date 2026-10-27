// Your own token: the metadata exactly as the desktop app (and the BEAM wallet core) builds and
// refuses it, the costs, the Minter's arguments and answers, the checks on every built create and
// mint, one transaction at a time; burns through the BlackHole; the approve sheet's words for
// both. Vectors and recordings from the desktop's tests (test/beam/contracts/minter, burn).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  MINTER_CID, METHOD, CREATE_CHARGE, KERNEL, ASSET_DEPOSIT, CREATE_FEE, MINT_FEE, NTH_RATIO, MAX_LIMIT, MAX_PER_TX, LIMITS,
  encodeMetadata, fieldProblem, normaliseFields, metadataFields, MetadataError, parseSupply, parseUnits, unlimited, args, parseParams, parseToken, parseOwned,
  codeFor, mapError, minterProblem, createMinter,
} from '../../src/lib/minter.js';
import { BLACKHOLE_CID, DEPOSIT_METHOD, KERNEL as BURN_KERNEL, BURN_FEE, args as burnArgs, confirmWord, confirms, createBurn } from '../../src/lib/burn.js';
import { parseShaderJson, bindSession, unbindSession, nativeApp, setConsentPresenter } from '../../src/lib/contracts.js';
import { readContractTx, le, concat, toHex } from '../../src/lib/contract_tx.js';
import { InvokeDataError } from '../../src/lib/dapps/invoke_data.js';
import { approveLabel } from '../../src/screens/consent.js';
import { invokeEntry, invokeData, hexBytes } from './helpers/invoke_builder.mjs';
import { fakeEngine, TXID } from './helpers/fake_engine.mjs';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const recorded = (dir, name) => JSON.parse(readFileSync(join(REPO, 'test', 'beam', 'contracts', dir, 'fixtures', `${name}.json`), 'utf8')).result;
const FAKE_KEY = '5a'.repeat(32) + '00';
const g = BigInt;
const enc = (s) => [...new TextEncoder().encode(s)];
const err = (code) => (e) => e.code === code;

// ---------------------------------------------------------------- constants

test('the live Minter, the fixed deposit, and the fees from the declared charges', () => {
  assert.equal(MINTER_CID, '295fe749dc12c55213d1bd16ced174dc8780c020f59cb17749e900bb0c15d868');
  assert.equal(METHOD.createToken, 3);
  assert.equal(METHOD.withdraw, 4);
  assert.equal(CREATE_CHARGE, 157000);
  assert.equal(ASSET_DEPOSIT, 1000000000n, '10 BEAM');
  assert.equal(CREATE_FEE, 1670000n, '0.0167 BEAM');
  assert.equal(MINT_FEE, 1100000n, '0.011 BEAM');
  assert.equal(NTH_RATIO, 100000000n);
  assert.equal(MAX_LIMIT, (1n << 128n) - 1n);
  assert.equal(MAX_PER_TX, (1n << 63n) - 1n);
  assert.deepEqual(KERNEL, { createToken: 'Creating asset', mint: 'Minting asset' });
  assert.equal(BLACKHOLE_CID, '5ab408982b148210e88f180114f10222a2235eafeede0a3a224fda0e523e17b7');
  assert.equal(DEPOSIT_METHOD, 2);
  assert.equal(BURN_KERNEL, 'Send to Black hole contract');
  assert.equal(BURN_FEE, 1100000n);
});

test('the same contract ids as the desktop app', () => {
  const dart = (p) => readFileSync(join(REPO, p), 'utf8');
  assert.ok(dart('lib/wallets/beam/contracts/minter/minter_constants.dart').includes(`'${MINTER_CID}'`));
  assert.ok(dart('lib/wallets/beam/contracts/burn/blackhole_constants.dart').includes(`'${BLACKHOLE_CID}'`));
  assert.ok(dart('lib/wallets/beam/contracts/minter/minter_constants.dart').includes("'Creating asset'"));
  assert.ok(dart('lib/wallets/beam/contracts/burn/blackhole_constants.dart').includes(`'${BURN_KERNEL}'`));
});

// ---------------------------------------------------------------- metadata

test('metadata: the standard schema in a fixed order (desktop vector)', () => {
  const m = encodeMetadata({ name: 'Campfire Coin', shortName: 'CFC', shortDescription: 'A test token = fun, maybe.', color: '#25C2A0', siteUrl: 'https://example.org/cfc?x=1' });
  assert.equal(m, 'STD:SCH_VER=1;N=Campfire Coin;SN=CFC;UN=CFC;NTHUN=groth;NTH_RATIO=100000000;OPT_SHORT_DESC=A test token = fun, maybe.;OPT_COLOR=#25C2A0;OPT_SITE_URL=https://example.org/cfc?x=1');
  assert.equal(
    encodeMetadata({ name: 'Campfire build check', shortName: 'CFBC', unitName: 'CFBC', shortDescription: 'Built and decoded by a test, never sent.' }),
    'STD:SCH_VER=1;N=Campfire build check;SN=CFBC;UN=CFBC;NTHUN=groth;NTH_RATIO=100000000;OPT_SHORT_DESC=Built and decoded by a test, never sent.',
    'the text of the recorded mainnet build',
  );
  // The unit name is the ticker unless given; empty optional fields are left out; NTH_RATIO is always 10^8.
  assert.equal(encodeMetadata({ name: 'A', shortName: 'B', shortDescription: '   ', color: '' }), 'STD:SCH_VER=1;N=A;SN=B;UN=B;NTHUN=groth;NTH_RATIO=100000000');
  assert.equal(encodeMetadata({ name: 'A', shortName: 'B', unitName: 'UNIT', nthUnitName: 'bit', longDescription: 'Long.' }), 'STD:SCH_VER=1;N=A;SN=B;UN=UNIT;NTHUN=bit;NTH_RATIO=100000000;OPT_LONG_DESC=Long.');
  assert.deepEqual(normaliseFields({ name: 'A', shortName: 'B' }), { name: 'A', shortName: 'B', unitName: 'B', nthUnitName: 'groth', shortDescription: null, longDescription: null, color: null, siteUrl: null, pdfUrl: null, logoUrl: null });
});

const bad = (fields, field) => assert.throws(() => encodeMetadata(fields), (e) => e instanceof MetadataError && e.field === field, `${JSON.stringify(fields)} -> ${field}`);

test('metadata: refuses what the core would not read as standard (desktop cases)', () => {
  bad({ name: 'A', shortName: 'SEVENCH', unitName: 'A' }, 'shortName');
  encodeMetadata({ name: 'A', shortName: 'SIXCHR', unitName: 'A' });
  for (const b of ['Bad;Name', 'Bad=Name', 'Bad"Name', 'Ünïcode', 'a/b', 'tab\there', 'emoji 🔥']) bad({ name: b, shortName: 'B', unitName: 'B' }, 'name');
  encodeMetadata({ name: 'Ok name, v1.0 - _', shortName: 'B', unitName: 'B' });
  bad({ name: '', shortName: 'B', unitName: 'B' }, 'name');
  bad({ name: 'A', shortName: ' B', unitName: 'B' }, 'shortName');
  bad({ name: 'A ', shortName: 'B', unitName: 'B' }, 'name');
  bad({ name: 'A', shortName: 'B', unitName: 'B', nthUnitName: '' }, 'nthUnitName');
  bad({ name: 'A'.repeat(65), shortName: 'B', unitName: 'B' }, 'name');
  encodeMetadata({ name: 'A'.repeat(64), shortName: 'B', unitName: 'B' });
  bad({ name: 'A', shortName: 'B', unitName: 'NINECHARS' }, 'unitName');
  bad({ name: 'A', shortName: 'B', unitName: 'B', nthUnitName: 'x'.repeat(17) }, 'nthUnitName');
  for (const b of ['a;b', 'say "hi"', 'back\\slash', 'two\nlines', 'cr\rhere', 'del\u007f']) bad({ name: 'A', shortName: 'B', unitName: 'B', shortDescription: b }, 'shortDescription');
  encodeMetadata({ name: 'A', shortName: 'B', unitName: 'B', shortDescription: 'x'.repeat(128), longDescription: 'y'.repeat(1024) });
  bad({ name: 'A', shortName: 'B', unitName: 'B', shortDescription: 'x'.repeat(129) }, 'shortDescription');
  // Bytes, not characters: 'é' is two UTF-8 bytes.
  bad({ name: 'A', shortName: 'B', unitName: 'B', longDescription: 'é'.repeat(513) }, 'longDescription');
  encodeMetadata({ name: 'A', shortName: 'B', unitName: 'B', longDescription: 'é'.repeat(512) });
  for (const c of ['#25c2a0', '#ABC']) encodeMetadata({ name: 'A', shortName: 'B', unitName: 'B', color: c });
  for (const c of ['25c2a0', '#25c2a', '#ggg', 'red', '#25c2a0;']) bad({ name: 'A', shortName: 'B', unitName: 'B', color: c }, 'color');
  for (const u of ['ftp://x', 'https://a b', 'https://a;b', 'javascript:alert(1)', 'https://a"b', `https://${'a'.repeat(510)}`]) bad({ name: 'A', shortName: 'B', unitName: 'B', logoUrl: u }, 'logoUrl');
  for (const u of ['http://x', 'https://example.org/p?q=1']) encodeMetadata({ name: 'A', shortName: 'B', unitName: 'B', siteUrl: u });
  bad({ name: 'A', shortName: 'B', siteUrl: 'example.org' }, 'siteUrl');
  // The first wrong field in the schema's order is the one named.
  bad({ name: '', shortName: 'TOOLONGX' }, 'name');
});

test('metadata: per-field problems in the words the form shows ("Ticker", not "Short name")', () => {
  const f = { name: 'Bad;Name', shortName: 'TOOLONGXY', nthUnitName: 'groth', color: 'red', siteUrl: 'www.x' };
  assert.equal(fieldProblem('name', f), 'Name can use English letters, digits, spaces and . , - _ only.');
  assert.equal(fieldProblem('shortName', f), 'Ticker can be at most 6 characters.');
  assert.equal(fieldProblem('shortName', { shortName: '' }), 'Ticker cannot be empty or start or end with a space.');
  assert.equal(fieldProblem('unitName', f), 'Unit name can be at most 8 characters.', 'the unit name defaults to the ticker');
  assert.equal(fieldProblem('unitName', { shortName: 'TOOLONGX', unitName: 'OK' }), null);
  assert.equal(fieldProblem('nthUnitName', f), null);
  assert.equal(fieldProblem('color', f), 'Use a colour like #25C2A0.');
  assert.match(fieldProblem('siteUrl', f), /^Use a full web address that starts with https/);
  assert.equal(fieldProblem('shortDescription', f), null, 'optional and empty');
  assert.equal(fieldProblem('shortDescription', { shortDescription: 'a;b' }), 'The description cannot be empty or contain ; " \\ or line breaks.');
  assert.equal(fieldProblem('longDescription', { longDescription: 'x'.repeat(1025) }), 'The description can be at most 1024 bytes.');
});

test('metadata: 16 KiB in total at most; chain metadata split as the core splits it', () => {
  assert.equal(LIMITS.encoded, 16384);
  const long = 'y'.repeat(1024);
  // Every field at its longest is still far below the limit: the total check is a backstop.
  assert.ok(encodeMetadata({ name: 'A'.repeat(64), shortName: 'B', longDescription: long, shortDescription: 'x'.repeat(128), siteUrl: `https://${'a'.repeat(500)}`, pdfUrl: `https://${'b'.repeat(500)}`, logoUrl: `https://${'c'.repeat(500)}` }).length < 16384);
  const cto = 'STD:SCH_VER=1;N=CTO;UN=CTO;SN=CTO;NTHUN=groth;NTH_RATIO=100000000;OPT_SHORT_DESC=CTO';
  assert.equal(metadataFields(cto).N, 'CTO');
  assert.equal(metadataFields(cto).NTH_RATIO, '100000000');
  assert.deepEqual(metadataFields('STD:A=b=c;;novalue'), { A: 'b=c' });
  assert.equal(metadataFields('not standard'), null);
});

// ---------------------------------------------------------------- numbers

test('maximum supply: whole tokens, empty for no maximum, 128 bits at most', () => {
  assert.deepEqual(parseSupply(''), { empty: true, whole: null, limit: MAX_LIMIT, error: null });
  assert.deepEqual(parseSupply('  '), { empty: true, whole: null, limit: MAX_LIMIT, error: null });
  assert.deepEqual(parseSupply('1000'), { empty: false, whole: 1000n, limit: 100000000000n, error: null });
  assert.equal(parseSupply('1,000,000').limit, 100000000000000n);
  assert.equal(parseSupply('21 000 000').whole, 21000000n);
  assert.equal(parseSupply('1_000').whole, 1000n);
  for (const b of ['0', '-5', '1.5', 'abc', '1e9', '0x10', '+5']) assert.equal(parseSupply(b).error, 'Enter a whole number above zero, like 1000000', b);
  const most = MAX_LIMIT / NTH_RATIO;
  assert.equal(parseSupply(String(most)).limit, most * NTH_RATIO);
  assert.match(parseSupply(String(most + 1n)).error, /more than a token can ever have/);
  assert.equal(unlimited(MAX_LIMIT), true);
  assert.equal(unlimited(100n), false);
});

test('amounts to mint or burn: 8 decimals, above 2^53, refused past the ceiling', () => {
  assert.deepEqual(parseUnits(''), { value: null, error: null });
  assert.deepEqual(parseUnits('1'), { value: 100000000n, error: null });
  assert.deepEqual(parseUnits('1,5'), { value: 150000000n, error: null });
  assert.equal(parseUnits('1,000').value, null, '"1,000" is asked, never read as 1');
  assert.match(parseUnits('1,000').error, /1000 or 1\.000/);
  assert.deepEqual(parseUnits('.00000001'), { value: 1n, error: null });
  assert.deepEqual(parseUnits('1 000 000 000'), { value: 100000000000000000n, error: null }, 'past 2^53 groth, unlike tx_send');
  assert.equal(parseUnits('0').error, 'The amount must be more than zero.');
  assert.equal(parseUnits('-1').error, 'The amount must be more than zero.');
  assert.equal(parseUnits('1.123456789').error, 'Tokens have 8 decimal places at most.');
  assert.equal(parseUnits('1.2.3').error, 'Use one decimal mark, like 1.25');
  assert.equal(parseUnits('1e5').error, 'Only digits and one decimal mark, like 1.25');
  assert.deepEqual(parseUnits('92233720368.54775807'), { value: MAX_PER_TX, error: null });
  assert.deepEqual(parseUnits('92233720368.54775808'), { value: MAX_PER_TX + 1n, error: 'over' });
  assert.deepEqual(parseUnits('5', 400000000n), { value: 500000000n, error: 'over' });
});

// ---------------------------------------------------------------- args and answers

test('args: no roles, plain decimals, the metadata quoted and last, limits split in lo and hi', () => {
  const cid = MINTER_CID;
  assert.equal(args.viewParams(), `action=view_params,cid=${cid}`);
  assert.equal(args.viewOwned(), `action=view_owned,cid=${cid}`);
  assert.equal(args.viewToken({ assetId: 44 }), `action=view_token,cid=${cid},aid=44`);
  const meta = encodeMetadata({ name: 'Campfire Coin', shortName: 'CFC', shortDescription: 'A, b = c' });
  assert.equal(args.createToken({ metadata: meta, limit: 100000000000n }), `action=create_token,cid=${cid},limit=100000000000,limitHi=0,metadata="${meta}"`);
  assert.equal(args.createToken({ metadata: meta, limit: MAX_LIMIT }), `action=create_token,cid=${cid},limit=18446744073709551615,limitHi=18446744073709551615,metadata="${meta}"`);
  assert.equal(args.createToken({ metadata: meta, limit: (1n << 64n) + 5n }), `action=create_token,cid=${cid},limit=5,limitHi=1,metadata="${meta}"`);
  assert.equal(args.mint({ assetId: 4242, value: 90n }), `action=withdraw,cid=${cid},aid=4242,value=90`);
  assert.throws(() => args.viewToken({ assetId: 0 }), RangeError, 'aid=0 would list every token');
  assert.throws(() => args.viewToken({ assetId: 2 ** 32 }), RangeError);
  assert.throws(() => args.createToken({ metadata: meta, limit: 0n }), RangeError);
  assert.throws(() => args.createToken({ metadata: meta, limit: MAX_LIMIT + 1n }), RangeError);
  assert.throws(() => args.createToken({ metadata: 'STD:N="x"', limit: 1n }), RangeError);
  assert.throws(() => args.createToken({ metadata: 'STD:N=a\\', limit: 1n }), RangeError);
  assert.throws(() => args.createToken({ metadata: 'N=x', limit: 1n }), RangeError);
  assert.throws(() => args.mint({ assetId: 1, value: 0n }), RangeError);
  assert.throws(() => args.mint({ assetId: 1, value: 1n << 64n }), RangeError);
  assert.throws(() => args.viewParams({ cid: 'AB'.repeat(32) }), RangeError);
});

test('answers: the recorded view_params, view_token and a missing token; view_owned', () => {
  const p = parseParams(parseShaderJson(recorded('minter', 'view_params').output));
  assert.equal(p.issueFee, 5000000000n, '50 BEAM, read from the contract');
  assert.ok(p.daoVaultCid.startsWith('0066b120'));
  const cto = parseToken(parseShaderJson(recorded('minter', 'view_token_44').output).res, { assetId: 44 });
  assert.equal(cto.isOwner, false);
  assert.equal(cto.limit, 100000000000000n);
  assert.equal(cto.minted, 0n);
  assert.equal(cto.mintable, 100000000000000n);
  assert.ok(cto.metadata.startsWith('STD:SCH_VER=1;N=CTO;'));
  assert.equal(parseShaderJson(recorded('minter', 'view_token_missing').output).error, 'no such token');
  const owned = parseOwned({ res: [{ aid: 4242, mintedLo: 10, mintedHi: 0, limitLo: 100, limitHi: 0, owner_pk: FAKE_KEY, metadata: 'STD:N=X' }, { aid: 7, mintedLo: 0, mintedHi: 1, limitLo: '18446744073709551615', limitHi: '18446744073709551615', owner_pk: FAKE_KEY }] });
  assert.deepEqual(owned.map((t) => t.assetId), [7, 4242], 'sorted by id');
  assert.equal(owned[1].isOwner, true);
  assert.equal(owned[1].mintable, 90n);
  assert.equal(owned[0].minted, 1n << 64n, '128-bit minted');
  assert.equal(owned[0].limit, MAX_LIMIT);
  assert.equal(parseToken({ mintedLo: 0, mintedHi: 0, limitLo: 1, limitHi: 0, is_owner: 1 }, { assetId: 5 }).isOwner, true);
  assert.throws(() => parseParams({ res: { tokenIssueFee: 1, cidDaoVault: 'zz' } }), err('unexpected'));
  assert.throws(() => parseOwned({ res: {} }), err('unexpected'));
  assert.throws(() => parseToken({ mintedLo: -1, mintedHi: 0, limitLo: 0, limitHi: 0 }, { assetId: 1 }), err('unexpected'));
  assert.equal(codeFor('no such token'), 'noSuchToken');
  assert.equal(codeFor('not owner'), 'notOwner');
  assert.equal(codeFor('no such contract'), 'noSuchContract');
  assert.equal(codeFor('aid and amount must be nnz'), 'shaderError');
  assert.equal(mapError(Object.assign(new Error('not owner'), { code: 'shader' })).code, 'notOwner');
  assert.equal(mapError(new InvokeDataError('x')).code, 'unexpected');
});

test('the recorded create_token (mainnet, never sent): 60 BEAM out, 0.0167 BEAM fee, the layout the checks read', () => {
  const raw = recorded('minter', 'create_token_cfbc').raw_data;
  const d = readContractTx(raw);
  const e = d.entries[0];
  assert.equal(d.entries.length, 1);
  assert.equal(e.contractId, MINTER_CID);
  assert.equal(e.method, METHOD.createToken);
  assert.equal(e.charge, CREATE_CHARGE);
  assert.equal(e.comment, KERNEL.createToken);
  assert.equal(e.signatureCount, 0);
  assert.deepEqual([...d.spend], [[0, 6000000000n]]);
  assert.equal(d.fee, CREATE_FEE);
  const text = enc(encodeMetadata({ name: 'Campfire build check', shortName: 'CFBC', unitName: 'CFBC', shortDescription: 'Built and decoded by a test, never sent.' }));
  const a = [...e.args];
  assert.deepEqual(a.slice(0, 4), [0, 0, 0, 0]);
  assert.deepEqual(a.slice(4, 12), [...le(100000000000n, 8)], '1,000 tokens');
  assert.deepEqual(a.slice(12, 20), Array(8).fill(0));
  assert.deepEqual(a.slice(20, 53), hexBytes(FAKE_KEY));
  assert.deepEqual(a.slice(53, 57), [...le(text.length, 4)]);
  assert.deepEqual(a.slice(57), text);
});

// ---------------------------------------------------------------- the service over a fake shader

/** Answers like the pinned Minter shader, from an in-memory contract (the desktop's _FakeMinter). */
function fakeMinter({ issueFee = 5000000000n } = {}) {
  const st = { owned: new Map([[4242, { minted: 10n, limit: 100n }]]), seen: [], tamper: null, issueFee, signed: 0 };
  const parse = (a) => {
    const out = {};
    let rest = a;
    while (rest) {
      const eq = rest.indexOf('=');
      const k = rest.slice(0, eq);
      rest = rest.slice(eq + 1);
      let v;
      if (rest.startsWith('"')) {
        const end = rest.indexOf('"', 1);
        v = rest.slice(1, end);
        rest = rest.slice(end + 2);
      } else {
        const c = rest.indexOf(',');
        v = c < 0 ? rest : rest.slice(0, c);
        rest = c < 0 ? '' : rest.slice(c + 1);
      }
      out[k] = v;
    }
    return out;
  };
  const built = (e) => ({ output: '{}', raw_data: invokeData([invokeEntry(st.tamper ? st.tamper(e) : e)]) });
  st.answer = async (a) => {
    st.seen.push(a);
    const p = parse(a);
    assert.ok(!('role' in p), 'the Minter shader has no roles');
    if (p.cid !== MINTER_CID) return { output: '{"error": "no such contract"}' };
    switch (p.action) {
      case 'view_params':
        return { output: `{"res": {"tokenIssueFee": ${st.issueFee},"cidDaoVault": "0066b12078623df132b691001b25d7eb94b207b42c018020c9e58152e21ecd25"}}` };
      case 'view_owned':
        return { output: JSON.stringify({ res: [...st.owned].map(([aid, o]) => ({ aid, mintedLo: Number(o.minted), mintedHi: 0, limitLo: Number(o.limit), limitHi: 0, owner_pk: FAKE_KEY, metadata: 'STD:SCH_VER=1;N=X;SN=X;UN=X;NTHUN=g;NTH_RATIO=1' })) }) };
      case 'view_token': {
        const aid = Number(p.aid);
        if (aid === 44) return recorded('minter', 'view_token_44');
        const o = st.owned.get(aid);
        if (!o) return recorded('minter', 'view_token_missing');
        return { output: JSON.stringify({ res: { mintedLo: Number(o.minted), mintedHi: 0, limitLo: Number(o.limit), limitHi: 0, owner_pk: FAKE_KEY, is_owner: 1 } }) };
      }
      case 'create_token': {
        const meta = enc(p.metadata);
        return built({ contractId: MINTER_CID, method: METHOD.createToken, args: [...le(0, 4), ...le(p.limit, 8), ...le(p.limitHi, 8), ...hexBytes(FAKE_KEY), ...le(meta.length, 4), ...meta], spend: { 0: 6000000000n }, comment: KERNEL.createToken, charge: CREATE_CHARGE });
      }
      case 'withdraw':
        return built({ contractId: MINTER_CID, method: METHOD.withdraw, args: [...le(p.aid, 4), ...le(p.value, 8)], spend: { [p.aid]: -BigInt(p.value) }, sigs: ['07'.repeat(32)], comment: KERNEL.mint, charge: 0 });
      default:
        return { output: '{"error": "unknown action"}' };
    }
  };
  return st;
}

/** createMinter over the fake, with lib/contracts.js's handling of inspect and expect. */
function service(st, { consent = null } = {}) {
  const shaderErr = (o) => {
    if (o && typeof o === 'object' && 'error' in o) throw Object.assign(new Error(String(o.error)), { code: 'shader' });
    return o;
  };
  const shown = [];
  const svc = createMinter({
    view: async (a) => shaderErr(parseShaderJson((await st.answer(a)).output)),
    transact: async (a, { inspect, expect, intent }) => {
      const r = await st.answer(a);
      const output = shaderErr(parseShaderJson(r.output));
      let refused = null;
      try {
        refused = await inspect(Uint8Array.from(r.raw_data), output);
      } catch (e) {
        throw Object.assign(new Error(e.message), { code: 'unexpected' });
      }
      if (refused) throw Object.assign(new Error(refused.message), { code: refused.code });
      const d = readContractTx(r.raw_data);
      const req = consent ? consent(d) : { kind: 'contract', spends: [...d.pays].map(([assetId, amount]) => ({ assetId, amount })), receives: [...d.receives].map(([assetId, amount]) => ({ assetId, amount })), fee: d.fee };
      const problem = expect(req);
      if (problem) throw Object.assign(new Error(problem.message), { code: problem.code });
      shown.push({ ...req, intent });
      st.signed++;
      return TXID;
    },
  });
  return { svc, shown };
}

const META = encodeMetadata({ name: 'Campfire build check', shortName: 'CFBC', unitName: 'CFBC', shortDescription: 'Built and decoded by a test, never sent.' });

test('create: the issuance fee comes from view_params; the sheet sees exactly what was built; one at a time', async () => {
  const st = fakeMinter();
  const { svc, shown } = service(st);
  const first = svc.createToken({ metadata: META, limit: 100000000000n, ticker: 'CFBC' });
  await assert.rejects(svc.createToken({ metadata: META, limit: 1n }), err('busy'), 'a double tap does not build a second 60 BEAM token');
  await assert.rejects(svc.mint({ assetId: 4242, value: 1n }), err('busy'));
  assert.equal(svc.busy, true);
  const r = await first;
  assert.equal(r.txId, TXID);
  assert.equal(r.issueFee, 5000000000n);
  assert.equal(r.deposit, 1000000000n);
  assert.equal(r.fee, 1670000n);
  assert.equal(r.built.pays.get(0), 6000000000n);
  assert.equal(svc.busy, false);
  assert.equal(st.signed, 1);
  assert.deepEqual(shown[0].intent, { action: 'tokenCreate', ticker: 'CFBC', issueFee: 5000000000n, deposit: 1000000000n });
  assert.deepEqual(st.seen.slice(0, 2), [`action=view_params,cid=${MINTER_CID}`, `action=create_token,cid=${MINTER_CID},limit=100000000000,limitHi=0,metadata="${META}"`]);
  // No maximum: the largest ceiling, split in lo and hi.
  await svc.createToken({ metadata: META, limit: MAX_LIMIT, ticker: 'CFBC' });
  assert.match(st.seen.at(-1), /,limit=18446744073709551615,limitHi=18446744073709551615,/);
});

test('create: a different issuance fee on chain than the shader locks is refused before signing', async () => {
  const st = fakeMinter({ issueFee: 7000000000n });
  const { svc } = service(st);
  await assert.rejects(svc.createToken({ metadata: META, limit: 1n }), (e) => e.code === 'unexpected' && /expected exactly/.test(e.detail));
  assert.equal(st.signed, 0);
  assert.equal(svc.busy, false);
});

test('create: every way a built transaction can differ from the request is refused, nothing signed', async () => {
  const cases = {
    'the metadata': (e) => ({ ...e, args: e.args.map((b, i) => (i === 60 ? b ^ 1 : b)) }),
    'the limit': (e) => ({ ...e, args: e.args.map((b, i) => (i === 4 ? b ^ 1 : b)) }),
    'the limit, high half': (e) => ({ ...e, args: e.args.map((b, i) => (i === 12 ? 1 : b)) }),
    'the owner key parity': (e) => ({ ...e, args: e.args.map((b, i) => (i === 52 ? 2 : b)) }),
    'a token id': (e) => ({ ...e, args: e.args.map((b, i) => (i === 0 ? 7 : b)) }),
    'a byte more': (e) => ({ ...e, args: [...e.args, 0] }),
    'more BEAM': (e) => ({ ...e, spend: { 0: 6000000001n } }),
    'another asset as well': (e) => ({ ...e, spend: { 0: 6000000000n, 174: 1n } }),
    'another charge': (e) => ({ ...e, charge: CREATE_CHARGE + 1 }),
    'another comment': (e) => ({ ...e, comment: 'Minting asset' }),
    'another method': (e) => ({ ...e, method: METHOD.withdraw }),
    'another contract': (e) => ({ ...e, contractId: 'ee'.repeat(32) }),
    'a signing key': (e) => ({ ...e, sigs: ['07'.repeat(32)] }),
  };
  for (const [what, tamper] of Object.entries(cases)) {
    const st = fakeMinter();
    st.tamper = tamper;
    const { svc } = service(st);
    await assert.rejects(svc.createToken({ metadata: META, limit: 100000000000n }), err('unexpected'), what);
    assert.equal(st.signed, 0, what);
    assert.equal(svc.busy, false, what);
  }
});

test('create: an approve sheet that would show other amounts or another fee is refused', async () => {
  for (const consent of [
    (d) => ({ kind: 'contract', spends: [{ assetId: 0, amount: 1n }], receives: [], fee: d.fee }),
    (d) => ({ kind: 'contract', spends: [...d.pays].map(([assetId, amount]) => ({ assetId, amount })), receives: [], fee: d.fee + 1n }),
    (d) => ({ kind: 'send', spends: [...d.pays].map(([assetId, amount]) => ({ assetId, amount })), receives: [], fee: d.fee }),
  ]) {
    const st = fakeMinter();
    const { svc } = service(st, { consent });
    await assert.rejects(svc.createToken({ metadata: META, limit: 100000000000n }), err('unexpected'));
    assert.equal(st.signed, 0);
  }
});

test('mint: within the limit, receives exactly the amount; above it, not mine, not a Minter token', async () => {
  const st = fakeMinter();
  const { svc, shown } = service(st);
  const r = await svc.mint({ assetId: 4242, value: 90n, ticker: 'X #4242' });
  assert.equal(r.fee, MINT_FEE);
  assert.deepEqual([...r.built.receives], [[4242, 90n]]);
  assert.equal(r.built.pays.size, 0);
  assert.deepEqual(shown[0].intent, { action: 'tokenMint', ticker: 'X #4242' });
  assert.ok(st.seen.includes(`action=withdraw,cid=${MINTER_CID},aid=4242,value=90`));
  await assert.rejects(svc.mint({ assetId: 4242, value: 91n }), (e) => e.code === 'aboveLimit' && e.mintable === 90n);
  await assert.rejects(svc.mint({ assetId: 44, value: 1n }), err('notOwner'));
  await assert.rejects(svc.mint({ assetId: 999, value: 1n }), err('noSuchToken'));
  await assert.rejects(svc.mint({ assetId: 4242, value: MAX_PER_TX + 1n }), err('aboveLimit'));
  assert.equal(await svc.token(999), null);
  assert.equal((await svc.token(44)).isOwner, false);
  assert.deepEqual((await svc.owned()).map((t) => [t.assetId, t.mintable]), [[4242, 90n]]);
  assert.equal(svc.busy, false);
});

test('mint: a mint that pays out more, or to another token, or asks this wallet to pay, is refused', async () => {
  for (const tamper of [
    (e) => ({ ...e, spend: { 4242: -91n } }),
    (e) => ({ ...e, spend: { 4243: -90n } }),
    (e) => ({ ...e, spend: { 4242: -90n, 0: 1n } }),
    (e) => ({ ...e, args: [...le(4243, 4), ...le(90, 8)] }),
    (e) => ({ ...e, sigs: [] }),
    (e) => ({ ...e, charge: 1 }),
  ]) {
    const st = fakeMinter();
    st.tamper = tamper;
    const { svc } = service(st);
    await assert.rejects(svc.mint({ assetId: 4242, value: 90n }), err('unexpected'));
    assert.equal(st.signed, 0);
  }
});

test('plain words for every way an action can stop: what happened, never the person, the next step', () => {
  const p = (e) => minterProblem(e);
  assert.deepEqual(p({ code: 'rejected' }), { title: 'Cancelled', message: 'Nothing was sent.' });
  assert.match(p({ code: 'busy' }).title, /Another token action is still open/);
  assert.match(p({ code: 'noSuchToken' }).message, /waiting for the network/);
  assert.match(p({ code: 'notOwner' }).message, /Open the wallet that created it/);
  assert.equal(p({ code: 'aboveLimit', message: 'At most 90 more can be minted.' }).message, 'At most 90 more can be minted. Lower the amount.');
  assert.match(p({ code: 'unexpected' }).message, /nothing was sent/);
  assert.match(p({ code: 'timeout' }).message, /Check Activity/);
  assert.match(p({ code: 'shaderError', message: 'aid and amount must be nnz' }).message, /It said: "aid and amount must be nnz"/);
  assert.match(p(new Error('boom')).message, /^Nothing was sent\./);
  for (const code of ['rejected', 'busy', 'noSuchToken', 'notOwner', 'unexpected', 'timeout', 'notAcknowledged', 'locked']) {
    const { title, message } = p({ code, message: 'x' });
    assert.ok(!/you (did|made|typed) (it )?wrong|your fault|invalid input/i.test(`${title} ${message}`), code);
  }
});

// ---------------------------------------------------------------- burn

test('burn: args under role=manager, BEAM refused; the confirm word', () => {
  assert.equal(burnArgs.deposit({ assetId: 174, amount: 250n }), `role=manager,action=deposit,cid=${BLACKHOLE_CID},aid=174,amount=250`);
  assert.equal(burnArgs.viewFunds(), `role=manager,action=view_funds,cid=${BLACKHOLE_CID}`);
  assert.throws(() => burnArgs.deposit({ assetId: 0, amount: 1n }), RangeError, 'BEAM itself is never burned');
  assert.throws(() => burnArgs.deposit({ assetId: 174, amount: 0n }), RangeError);
  assert.throws(() => burnArgs.deposit({ assetId: 174, amount: MAX_PER_TX + 1n }), RangeError);
  assert.equal(confirmWord('FOMO', 174), 'FOMO');
  assert.equal(confirmWord('cfbc', 4242), 'CFBC');
  assert.equal(confirmWord('BEAM/FOMO LP', 175), '175', 'a ticker hard to type: its number');
  assert.equal(confirmWord('PEPE#', 94), '94');
  assert.equal(confirmWord('TOOLONGXX', 9), '9');
  assert.equal(confirms(' fomo ', 'FOMO'), true);
  assert.equal(confirms('FOM', 'FOMO'), false);
  assert.equal(confirms('', '175'), false);
});

function fakeBlackHole() {
  const st = { seen: [], tamper: null, signed: 0 };
  st.answer = async (a) => {
    st.seen.push(a);
    const p = Object.fromEntries(a.split(',').map((kv) => kv.split('=')));
    if (p.action === 'view_funds') return recorded('burn', 'view_funds');
    const e = { contractId: BLACKHOLE_CID, method: DEPOSIT_METHOD, args: [...le(p.aid, 4), ...le(p.amount, 8)], spend: { [p.aid]: BigInt(p.amount) }, comment: BURN_KERNEL, charge: 0 };
    return { output: '{}', raw_data: invokeData([invokeEntry(st.tamper ? st.tamper(e) : e)]) };
  };
  return st;
}

function burnService(st) {
  const shown = [];
  const svc = createBurn({
    view: async (a) => parseShaderJson((await st.answer(a)).output),
    transact: async (a, { inspect, expect, intent }) => {
      const r = await st.answer(a);
      try {
        await inspect(Uint8Array.from(r.raw_data), {});
      } catch (e) {
        throw Object.assign(new Error(e.message), { code: 'unexpected' });
      }
      const d = readContractTx(r.raw_data);
      const req = { kind: 'contract', spends: [...d.pays].map(([assetId, amount]) => ({ assetId, amount })), receives: [], fee: d.fee };
      const problem = expect(req);
      if (problem) throw Object.assign(new Error(problem.message), { code: problem.code });
      shown.push({ ...req, intent });
      st.signed++;
      return TXID;
    },
  });
  return { svc, shown };
}

test('burn: nothing is built without the acknowledgement; exactly the amount, into the BlackHole; one at a time', async () => {
  const st = fakeBlackHole();
  const { svc, shown } = burnService(st);
  await assert.rejects(svc.burn({ assetId: 174, amount: 250n }), err('notAcknowledged'));
  await assert.rejects(svc.burn({ assetId: 174, amount: 250n, acknowledged: 'yes' }), err('notAcknowledged'), 'exactly true');
  assert.equal(st.seen.length, 0, 'nothing asked of the shader');
  const first = svc.burn({ assetId: 174, amount: 250n, ticker: 'FOMO', acknowledged: true });
  await assert.rejects(svc.burn({ assetId: 174, amount: 1n, acknowledged: true }), err('busy'));
  const r = await first;
  assert.equal(r.txId, TXID);
  assert.equal(r.fee, BURN_FEE);
  assert.deepEqual([...r.built.pays], [[174, 250n]]);
  assert.deepEqual(shown[0].intent, { action: 'burn', ticker: 'FOMO' });
  assert.deepEqual(shown[0].spends, [{ assetId: 174, amount: 250n }]);
  assert.equal(svc.busy, false);
  await assert.rejects(svc.burn({ assetId: 0, amount: 1n, acknowledged: true }), RangeError);
  assert.equal(svc.busy, false);
});

test('burn: a deposit that is not exactly the request is refused, nothing signed', async () => {
  for (const tamper of [
    (e) => ({ ...e, spend: { 174: 251n } }),
    (e) => ({ ...e, spend: { 175: 250n } }),
    (e) => ({ ...e, spend: { 174: 250n, 0: 1n } }),
    (e) => ({ ...e, args: [...le(174, 4), ...le(251, 8)] }),
    (e) => ({ ...e, contractId: MINTER_CID }),
    (e) => ({ ...e, method: 3 }),
    (e) => ({ ...e, charge: 1 }),
    (e) => ({ ...e, comment: 'x' }),
    (e) => ({ ...e, sigs: ['07'.repeat(32)] }),
  ]) {
    const st = fakeBlackHole();
    st.tamper = tamper;
    const { svc } = burnService(st);
    await assert.rejects(svc.burn({ assetId: 174, amount: 250n, acknowledged: true }), err('unexpected'));
    assert.equal(st.signed, 0);
    assert.equal(svc.busy, false);
  }
});

test('burn: everything ever burned (recorded view_funds)', async () => {
  const { svc } = burnService(fakeBlackHole());
  const t = await svc.burnedTotals();
  assert.equal(t.size, 16);
  assert.equal(t.get(0), 105120000n);
  assert.equal(t.get(174), 2431214n);
  assert.equal(t.get(161), 99495756307153710n, 'kept exact past 2^53');
});

// ---------------------------------------------------------------- through lib/contracts.js and the approve sheet

test('through the wallet: the approve sheet gets the native intent; Cancel sends nothing', async () => {
  const meta = META;
  const raw = invokeData([invokeEntry({ contractId: MINTER_CID, method: METHOD.createToken, args: [...le(0, 4), ...le(100000000000n, 8), ...le(0, 8), ...hexBytes(FAKE_KEY), ...le(enc(meta).length, 4), ...enc(meta)], spend: { 0: 6000000000n }, comment: KERNEL.createToken, charge: CREATE_CHARGE })]);
  const engine = fakeEngine({
    respond: (req, api) => {
      if (req.method === 'invoke_contract' && req.params.args.includes('view_params')) return api.reply(req.id, { output: recorded('minter', 'view_params').output });
      if (req.method === 'invoke_contract') return api.reply(req.id, { output: '{}', raw_data: raw });
      if (req.method === 'process_invoke_data') return engine.askContract(api, req, { comment: 'Creating asset', fee: '0.0167', isEnough: false, isSpend: true }, [{ amount: '60', assetID: 0, spend: true }]);
      return api.reply(req.id, {});
    },
  });
  bindSession(engine.session);
  const seen = [];
  const unset = setConsentPresenter(async (req) => {
    seen.push(req);
    return false;
  });
  try {
    const app = await nativeApp();
    const svc = createMinter({ view: (a) => app.view(a, [0]), transact: (a, o) => app.transact(a, [0], o) });
    await assert.rejects(svc.createToken({ metadata: meta, limit: 100000000000n, ticker: 'CFBC' }), err('rejected'));
    assert.equal(seen.length, 1);
    assert.deepEqual(seen[0].intent, { action: 'tokenCreate', ticker: 'CFBC', issueFee: 5000000000n, deposit: 1000000000n });
    assert.equal(seen[0].fee, 1670000n);
    assert.deepEqual(seen[0].spends.map((a) => [a.assetId, a.amount]), [[0, 6000000000n]]);
    assert.deepEqual(engine.answers, ['rejected']);
    assert.equal(svc.busy, false);
  } finally {
    unset();
    unbindSession();
  }
});

test('the approve sheet says what approving does: create, mint, burn', () => {
  const unit = (id) => ({ 0: 'BEAM', 174: 'FOMO', 4242: 'CFBC #4242' })[id] || `#${id}`;
  const req = (intent, spends, receives, fee) => ({ kind: 'contract', intent, fee, spends, receives });
  assert.equal(approveLabel(req({ action: 'tokenCreate', ticker: 'CFBC' }, [{ assetId: 0, amount: 6000000000n }], [], 1670000n), unit), 'Pay 60 BEAM and create CFBC');
  assert.equal(approveLabel(req({ action: 'tokenMint', ticker: 'CFBC #4242' }, [], [{ assetId: 4242, amount: 100000000000n }], 1100000n), unit), 'Mint 1,000 CFBC #4242');
  assert.equal(approveLabel(req({ action: 'burn', ticker: 'FOMO' }, [{ assetId: 174, amount: 500000000n }], [], 1100000n), unit), 'Burn 5 FOMO forever');
  // Any other shape falls back to the plain words.
  assert.equal(approveLabel(req({ action: 'burn' }, [], [{ assetId: 174, amount: 1n }], 1100000n), unit), 'Approve and get 0.00000001 FOMO');
  assert.equal(approveLabel(req({ action: 'tokenCreate', ticker: 'X' }, [{ assetId: 0, amount: 1n }], [{ assetId: 9, amount: 1n }], 1n), unit), 'Pay 0.00000001 BEAM, get 0.00000001 #9');
});

test('raw helpers agree with the core layout used above', () => {
  assert.equal(toHex(concat(le(1, 4), le(2n, 8))), '010000000200000000000000');
});

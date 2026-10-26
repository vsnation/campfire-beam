// Contract data the core can redo later with a dApp's own code: a dependent call that misses its
// block is rebuilt by re-running the stored app body (contract_transaction.cpp RebuildHft), and the
// variant it signs is never checked against what was approved, apart from the funds (1%). So a
// dApp may store only an app body Beam PWA knows: one from a package the catalogue pins, or
// the wallet's own pinned DEX shader, both as the core stores them (compiled).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { homedir, tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { decodeInvokeData, InvokeDataError, FLAG_DEPENDENT, FLAG_SAVE_APP_INVOKE } from '../../src/lib/dapps/invoke_data.js';
import { checkContractData, checkRebuild, storedArgsProblem, PolicyRefusal } from '../../src/lib/dapps/policy.js';
import { DappSession } from '../../src/lib/dapps/session.js';
import { CATALOGUE, REBUILD_BODIES } from '../../src/lib/dapps/catalogue.js';
import { SHADERS } from '../../src/lib/shaders.js';
import { readZip } from '../../src/lib/dapps/zip.js';
import { invokeData, invokeEntry, cid } from './helpers/invoke_builder.mjs';

const pwa = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const swapFixture = join(pwa, '..', 'test', 'beam', 'dapps', 'fixtures', 'dex_dapp_swap_raw_data.json');
const cacheDir = process.env.CAMPFIRE_DAPP_CACHE || join(homedir(), '.cache', 'campfire-beam', 'dapps');
const sha = (b) => createHash('sha256').update(b).digest('hex');
const refused = (e) => e instanceof PolicyRefusal && e.reason === 'rebuild';
const DEX = '729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae69b47bcfdeef9cbf';
const swapRaw = () => new Uint8Array(Buffer.from(JSON.parse(readFileSync(swapFixture, 'utf8')).result.raw_data_base64, 'base64'));
const rebuildable = (appShader, extra = {}) =>
  new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xee), flags: FLAG_DEPENDENT | FLAG_SAVE_APP_INVOKE, spend: { 0: 1 } })], { firstFlags: FLAG_SAVE_APP_INVOKE, appShader, ...extra }));

test("the recorded mainnet Beam DEX swap stores the compiled body the catalogue's Beam DEX pins", async (t) => {
  if (!existsSync(swapFixture)) return t.skip('desktop fixtures not next to the PWA');
  const d = checkContractData(swapRaw());
  assert.equal(d.appShader.length, 32903);
  assert.equal(d.contractShaderLength, 0);
  const pin = REBUILD_BODIES[sha(d.appShader)];
  assert.ok(pin, 'pinned');
  assert.equal(pin.package, 'dex-app.dapp');
  await checkRebuild(d, { unchecked: false });
});

test('a rebuildable call is refused unless its stored body is pinned, and always from a dApp installed from a file', async () => {
  const unknown = checkContractData(rebuildable([0, 0x61, 0x73, 0x6d]));
  await assert.rejects(checkRebuild(unknown, { unchecked: false }), refused);
  await assert.rejects(checkRebuild(unknown, { unchecked: true }), refused);
  // Dependent, but nothing stored: the core could not rebuild it, yet nothing here is known either.
  const bare = checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: cid(0xee), flags: FLAG_DEPENDENT })])));
  await assert.rejects(checkRebuild(bare, { unchecked: false }), refused);
  // A plain call is not rebuildable: nothing to check.
  await checkRebuild(checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: DEX, spend: { 0: 5 } })]))), { unchecked: true });
});

test('a pinned body passes from a checked dApp; not from a file, and not with a contract body stored next to it', async (t) => {
  if (!existsSync(swapFixture)) return t.skip('desktop fixtures not next to the PWA');
  const d = checkContractData(swapRaw());
  await assert.rejects(checkRebuild(d, { unchecked: true }), refused);
  const body = [...d.appShader];
  await checkRebuild(checkContractData(rebuildable(body, { appArgs: { action: 'pool_trade', cid: DEX } })), { unchecked: false });
  // invoke_builder stores an empty contract body; one with bytes deploys code on a rebuild.
  const withContract = Uint8Array.from([...rebuildable(body, { appArgs: { action: 'pool_trade', cid: DEX } })]);
  const decoded = checkContractData(withContract);
  await assert.rejects(checkRebuild({ ...decoded, contractShaderLength: 4 }, { unchecked: false }), refused);
});

test('session: the refusal reaches the dApp (-32020) and nothing reaches the wallet; a catalogue dApp swap goes through', async (t) => {
  if (!existsSync(swapFixture)) return t.skip('desktop fixtures not next to the PWA');
  const calls = [];
  const refusedWhy = [];
  const appFor = (unchecked) => ({ unchecked, async call(method, params) { calls.push(method); return { txid: '0'.repeat(32) }; } });
  const req = (id, data) => JSON.stringify({ jsonrpc: '2.0', id, method: 'process_invoke_data', params: { data: [...data] } });
  const file = new DappSession({ appName: 'From a file', app: appFor(true), confirmSign: async () => true, onRefused: (w) => refusedWhy.push(w) });
  const r1 = JSON.parse(await file.handle(req(1, swapRaw())));
  assert.equal(r1.error.code, -32020);
  assert.match(r1.error.data, /redo the call later/);
  assert.equal(calls.length, 0);
  assert.equal(refusedWhy.length, 1);
  const unknown = new DappSession({ appName: 'Store dApp', app: appFor(false), confirmSign: async () => true });
  assert.equal(JSON.parse(await unknown.handle(req(2, rebuildable([1, 2, 3])))).error.code, -32020);
  assert.equal(calls.length, 0);
  const dex = new DappSession({ appName: 'Beam DEX', app: appFor(false), confirmSign: async () => true });
  assert.equal(JSON.parse(await dex.handle(req(3, swapRaw()))).result.txid, '0'.repeat(32));
  assert.deepEqual(calls, ['process_invoke_data']);
});

// Recomputes the pins from the packages the catalogue pins (when they are on this machine): every
// app shader in them that can make a dependent call (imports SelectContext) is listed, with its
// file hash, and nothing else is. The compiled hash is bvm2::Processor::Compile(Kind::Manager) of
// that file (beam-7.5.14493); with CAMPFIRE_BVM_COMPILER set to a tool that writes <file>.body,
// it is recomputed too.
test('the pinned bodies are exactly the dependent-capable app shaders of the catalogue packages', async (t) => {
  const byPackage = new Map(Object.entries(REBUILD_BODIES).filter(([, v]) => v.package).map(([k, v]) => [`${v.package}:${v.file}`, { compiled: k, ...v }]));
  const seen = new Set();
  const compiler = process.env.CAMPFIRE_BVM_COMPILER;
  const tmp = compiler ? mkdtempSync(join(tmpdir(), 'bvm-')) : null;
  let checked = 0;
  try {
    for (const e of CATALOGUE) {
      const f = join(cacheDir, e.fileName);
      if (!existsSync(f)) continue;
      const bytes = readFileSync(f);
      assert.equal(sha(bytes), e.sha256, `${e.fileName}: the cached copy is the pinned package`);
      checked++;
      const files = await readZip(new Uint8Array(bytes), { maxPackageBytes: 64e6, maxTotalBytes: 256e6, maxEntries: 10000, maxEntryBytes: 64e6, maxRatio: 1000 });
      for (const [name, b] of files) {
        if (!name.endsWith('.wasm')) continue;
        let imports;
        try {
          imports = WebAssembly.Module.imports(await WebAssembly.compile(b)).map((i) => i.name);
        } catch {
          continue;
        }
        const key = `${e.fileName}:${name}`;
        if (!imports.includes('SelectContext')) {
          assert.ok(!byPackage.has(key), `${key} cannot make a dependent call and is not pinned`);
          continue;
        }
        const pin = byPackage.get(key);
        assert.ok(pin, `${key} can make a dependent call: pin its compiled body`);
        assert.equal(pin.wasmSha256, sha(b), key);
        seen.add(key);
        if (compiler) {
          const src = join(tmp, name.replace(/\//g, '_'));
          writeFileSync(src, b);
          execFileSync(compiler, [src]);
          assert.equal(sha(readFileSync(`${src}.body`)), pin.compiled, `${key}: compiled body`);
        }
      }
    }
  } finally {
    if (tmp) rmSync(tmp, { recursive: true, force: true });
  }
  if (!checked) return t.skip(`catalogue packages not cached in ${cacheDir}`);
  if (checked === CATALOGUE.length) assert.deepEqual([...seen].sort(), [...byPackage.keys()].sort(), 'every pinned package body was found');
});

test("the wallet's own DEX shader is pinned by its compiled body too", () => {
  const own = Object.entries(REBUILD_BODIES).filter(([, v]) => v.shader === SHADERS.amm.file);
  assert.equal(own.length, 1);
  assert.equal(own[0][1].wasmSha256, SHADERS.amm.sha256);
  assert.equal(own[0][0], 'bdff009943b48d32af3253b7e61facd09777c8064e83934b23caa0443533dc8b', "the desktop's pin (dapp_rebuild_terms.dart)");
});

// Audit BC-4: checkRebuild pinned the stored app body but not its stored arguments, and the core
// re-runs that body with those arguments. A store dApp could store BEAM's own DEX body with
// cid=<another contract> next to a 1-groth call to the real DEX; the rebuild would then run BEAM's
// AMM code against that contract (bounded by the core to the approved funds + 1%). Now the stored
// cid (and cidAmm, the only other contract argument a pinned body may be redone with) must be the
// contract that body is for.
const ACCUM = 'ec160307c43bc3fc0c3a52d3e3d3dfd8101593e8cec7a907fc42c9f103aabbae';

test("the audit's shape: BEAM's DEX body stored with another contract's id is refused; with the DEX's, it passes", async (t) => {
  if (!existsSync(swapFixture)) return t.skip('desktop fixtures not next to the PWA');
  const body = [...checkContractData(swapRaw()).appShader];
  const trade = { role: 'user', action: 'pool_trade', aid1: '0', aid2: '174', kind: '2', val1_buy: '0', val2_pay: '100000000', bPredictOnly: '0' };
  const shaped = (appArgs) => checkContractData(new Uint8Array(invokeData([invokeEntry({ contractId: DEX, method: 7, flags: FLAG_DEPENDENT | FLAG_SAVE_APP_INVOKE, spend: { 0: 1 }, comment: 'Amm trade' })], { firstFlags: FLAG_SAVE_APP_INVOKE, appShader: body, appArgs, privilege: 0 })));
  await assert.rejects(checkRebuild(shaped({ ...trade, cid: cid(0xa7) }), { unchecked: false }), refused, 'cid of another contract');
  await assert.rejects(checkRebuild(shaped(trade), { unchecked: false }), refused, 'no cid at all');
  await assert.rejects(checkRebuild(shaped({ ...trade, cid: DEX, cidAmm: cid(0xa7) }), { unchecked: false }), refused, 'a contract argument the DEX body is not redone with');
  // A spaced copy of the key is now refused while decoding, before the pin is looked at (RE2-1).
  assert.throws(() => shaped({ ...trade, cid: DEX, ' cid': cid(0xa7) }), PolicyRefusal, 'a spaced copy of the key');
  await checkRebuild(shaped({ ...trade, cid: DEX }), { unchecked: false });
  await checkRebuild(shaped({ ...trade, cid: DEX.toUpperCase() }), { unchecked: false });
});

test('every pinned body names the contract it is for; the stored contract arguments must be those', () => {
  for (const [hash, pin] of Object.entries(REBUILD_BODIES)) {
    assert.ok(pin.contracts && Array.isArray(pin.contracts.cid) && pin.contracts.cid.length > 0, `${hash}: names its contract`);
    for (const list of Object.values(pin.contracts)) for (const c of list) assert.match(c, /^[0-9a-f]{64}$/, hash);
    if (pin.package === 'dex-app.dapp' || pin.shader) assert.deepEqual(pin.contracts, { cid: [DEX] }, `${hash}: the Beam DEX`);
    if (pin.package === 'accum-dapp.dapp') assert.deepEqual(pin.contracts, { cid: [ACCUM], cidAmm: [DEX] }, `${hash}: the DAO accumulator (and the DEX it farms)`);
  }
  const accum = { cid: [ACCUM], cidAmm: [DEX] };
  assert.equal(storedArgsProblem({ action: 'user_lock', cid: ACCUM, amountLpToken: '5' }, accum), null);
  assert.equal(storedArgsProblem({ action: 'start_farming', cid: ACCUM, cidAmm: DEX }, accum), null);
  assert.ok(storedArgsProblem({ action: 'user_lock', cid: DEX }, accum));
  assert.ok(storedArgsProblem({ action: 'start_farming', cid: ACCUM, cidAmm: cid(0xa7) }, accum));
  assert.ok(storedArgsProblem({ action: 'start_farming', cid: ACCUM, cidDaoCore: cid(0xa7) }, accum), 'a contract argument not listed');
  assert.ok(storedArgsProblem({ action: 'user_lock', CID: ACCUM }, accum), 'keys are exact');
  assert.ok(storedArgsProblem(null, accum));
  assert.ok(storedArgsProblem({ cid: ACCUM }, null), 'a body that names no contract is never redone');
});

// Re-audit RE2-1: the core keeps the FIRST value of a repeated stored-args key (a std::map filled
// with insert, yas keyval.hpp), while the decoder here kept the LAST. [cid=<attacker>, cid=<DEX>]
// then passed the BC-4 pin while the rebuild ran BEAM's AMM body against the attacker's contract.
// A repeated key, or two keys that are the same once trimmed, is refused when decoding.
test('a stored-args key given twice (or twice once trimmed) is refused when decoding, whatever the order', async (t) => {
  const stored = (appArgs, appShader = [0, 0x61, 0x73, 0x6d]) =>
    new Uint8Array(invokeData([invokeEntry({ contractId: DEX, method: 7, flags: FLAG_DEPENDENT | FLAG_SAVE_APP_INVOKE, spend: { 0: 1 }, comment: 'Amm trade' })], { firstFlags: FLAG_SAVE_APP_INVOKE, appShader, appArgs, privilege: 0 }));
  const twice = /stored arguments name .* twice/;
  for (const pairs of [
    [['action', 'pool_trade'], ['cid', cid(0xa7)], ['cid', DEX]],
    [['action', 'pool_trade'], ['cid', DEX], ['cid', cid(0xa7)]],
    [['action', 'pool_trade'], ['cid', DEX], ['cid', DEX]],
    [['action', 'pool_trade'], [' cid', cid(0xa7)], ['cid', DEX]],
    [['action', 'pool_trade'], ['cid', DEX], ['cid ', cid(0xa7)]],
    [['action', 'pool_trade'], ['action', 'pool_trade'], ['cid', DEX]],
  ]) {
    assert.throws(() => decodeInvokeData(stored(pairs)), (e) => e instanceof InvokeDataError && twice.test(e.message), JSON.stringify(pairs.map(([k]) => k)));
    assert.throws(() => checkContractData(stored(pairs)), PolicyRefusal);
  }
  // One of each still decodes, as before.
  assert.deepEqual(decodeInvokeData(stored([['action', 'pool_trade'], ['cid', DEX]])).appArgs, { action: 'pool_trade', cid: DEX });
  // The audit's exact bytes, with BEAM's own pinned DEX body: refused before the pin is looked at.
  if (!existsSync(swapFixture)) return t.skip('desktop fixtures not next to the PWA');
  const body = [...checkContractData(swapRaw()).appShader];
  assert.throws(() => checkContractData(stored([['action', 'pool_trade'], ['cid', cid(0xa7)], ['cid', DEX]], body)), PolicyRefusal);
  await checkRebuild(checkContractData(stored([['action', 'pool_trade'], ['cid', DEX]], body)), { unchecked: false });
});

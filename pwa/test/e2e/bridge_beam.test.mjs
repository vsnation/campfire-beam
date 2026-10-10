// LIVE, READ-ONLY, NO FUNDS: the bridge's BEAM side on BEAM mainnet, through
// the real engine (installed Google Chrome, headless, the built dist/).
//
//   node tools/stage_engine.mjs && node tools/build.mjs && \
//     node --test --test-concurrency=1 test/e2e/bridge_beam.test.mjs
//
// A fresh throwaway wallet (never funded) is created and synced. Then:
// - every pipe answers get_pk, local_msg_count, view_incoming and local_msg
//   through lib/bridge/beam_pipe.js, and an asset-owner contract shows the trap
//   the registry exists to avoid;
// - a send on every route is built with create_tx:false (never submitted) and
//   its raw_data must pass the module's inspect and equal the desktop app's
//   mainnet recording (test/beam/bridge/fixtures/pipe_builds.json) byte for
//   byte; the recorded claims are built the same way when still unclaimed;
// - one full send goes up to the consent sheet, which must show what the
//   engine reported (and so passed expect): "not enough", no approve button.
//   Cancel; nothing is sent.
// Screenshots go to $CAMPFIRE_SHOTS (never committed).
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { startServer, launch, recordedPage, shot, foreignHosts, PWA, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';

const PORT = 8830;
const NODE = 'eu-nodes.mainnet.beam.mw:8200';
const PASSWORD = `bridge-${Math.random().toString(36).slice(2, 10)}`;
const RECEIVER = '5a'.repeat(20); // the recordings' receiver: nobody's address
const OWNER = 'acefc4bed717cf94de3868e9979f72184aee00627bd3ebe1b8c0f086ab968b9f'; // bETH's asset-owner contract
const RECEIVES = { usdt: [78, '91049000'], eth: [67, '500000'], beam: [226, '2000000'] };
const BUILDS = JSON.parse(readFileSync(join(PWA, '..', 'test', 'beam', 'bridge', 'fixtures', 'pipe_builds.json'), 'utf8')).builds;
const tid = (id) => `[data-testid="${id}"]`;

let srv, browser, ctx, page, rec;

before(async () => {
  srv = await startServer({ root: 'dist', port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  ({ page, rec } = await recordedPage(ctx, { label: 'bridge' }));
  console.log(`# screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
});

test('a new wallet, synced', { timeout: 15 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  console.log(`# synced: ${JSON.stringify(await waitSynced(page))}`);
  const shaderLoads = await page.evaluate(() => performance.getEntriesByType('resource').filter((e) => e.name.includes('/shaders/pipe')).length);
  assert.equal(shaderLoads, 0, 'no pipe shader is loaded before the bridge needs it');
});

test('every pipe answers: get_pk, local_msg_count, view_incoming, local_msg', { timeout: 10 * 60000 }, async () => {
  const out = await page.evaluate(async () => {
    const { BeamPipe } = await import('./lib/bridge/beam_pipe.js');
    const { ROUTES } = await import('./lib/bridge/routes.js');
    const svc = new BeamPipe();
    const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
    const res = {};
    for (const r of ROUTES) {
      const t0 = performance.now();
      const key = await svc.receiveKey(r);
      const count = await svc.localMessageCount(r);
      const incoming = await svc.incoming(r, { startFrom: 0 });
      const last = count > 0 ? await svc.localMessage(r, count) : null;
      const beyond = await svc.localMessage(r, count + 1);
      res[r.id] = {
        key: hex(key),
        count,
        incoming: incoming.length,
        last: last && { height: last.height, amount: String(last.amount), relayerFee: String(last.relayerFee), receiverOk: /^0x[0-9a-f]{40}$/.test(last.receiver) },
        beyond: beyond === null ? 'absent' : 'present',
        ms: Math.round(performance.now() - t0),
      };
    }
    return res;
  });
  const keys = new Set();
  for (const [id, r] of Object.entries(out)) {
    // The key is this throwaway wallet's: only its shape is printed.
    console.log(`# ${id}: key 33 bytes parity ${r.key.slice(64)}, local_msg_count ${r.count}, view_incoming ${r.incoming}, last ${JSON.stringify(r.last)}, next ${r.beyond}, ${r.ms} ms`);
    assert.match(r.key, /^[0-9a-f]{64}0[01]$/);
    keys.add(r.key);
    assert.ok(r.count > 0, `${id}: the pipe has recorded messages`);
    assert.equal(r.incoming, 0, 'a fresh wallet has nothing to claim');
    assert.ok(r.last && r.last.receiverOk && Number(r.last.height) > 0);
  }
  assert.equal(keys.size, 5, 'one receive key per pipe');
});

test('the asset-owner contract next to a pipe: a normal-looking key, and a view_incoming that is not JSON', { timeout: 5 * 60000 }, async () => {
  const out = await page.evaluate(async (owner) => {
    const { nativeApp } = await import('./lib/contracts.js');
    const { loadShader } = await import('./lib/shaders.js');
    const { BeamPipe } = await import('./lib/bridge/beam_pipe.js');
    const { routeById } = await import('./lib/bridge/routes.js');
    const app = await nativeApp();
    const shader = await loadShader('pipe');
    const pk = await app.view(`action=get_pk,cid=${owner}`, shader);
    const raw = await app.call('invoke_contract', { args: `action=view_incoming,cid=${owner}`, contract: Array.from(shader), create_tx: false });
    let refused = null;
    try {
      await app.view(`action=view_incoming,cid=${owner}`, shader);
    } catch (e) {
      refused = e.code;
    }
    // Both shaders give the same key for the same cid (the reverse pipe, asked with the forward shader).
    const beam = routeById('beam');
    const viaForward = await app.view(`action=get_pk,cid=${beam.beamPipeCid}`, shader);
    const viaReverse = await new BeamPipe().receiveKey(beam);
    const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
    return { pkShape: typeof pk.pk === 'string' && /^[0-9a-f]{66}$/.test(pk.pk), output: raw.output, refused, sameKey: viaForward.pk === hex(viaReverse) };
  }, OWNER);
  console.log(`# owner ${OWNER.slice(0, 8)}…: get_pk looks like a key: ${out.pkShape}; view_incoming printed ${JSON.stringify(out.output)}; view() -> ${out.refused}; same key from both shaders: ${out.sameKey}`);
  assert.equal(out.pkShape, true);
  assert.equal(out.output.trim(), '{"incoming": ["error": "no params"]}');
  assert.equal(out.refused, 'unexpected');
  assert.equal(out.sameKey, true);
});

test('a send built on mainnet passes inspect and equals the desktop recording, every route; nothing is submitted', { timeout: 10 * 60000 }, async () => {
  const out = await page.evaluate(
    async ({ receiver, receives }) => {
      const { nativeApp } = await import('./lib/contracts.js');
      const { loadShader } = await import('./lib/shaders.js');
      const pipe = await import('./lib/bridge/beam_pipe.js');
      const { ROUTES, routeById } = await import('./lib/bridge/routes.js');
      const { decodeInvokeData } = await import('./lib/dapps/invoke_data.js');
      const app = await nativeApp();
      const b64 = (a) => btoa(String.fromCharCode(...a));
      const summary = (raw) => {
        const d = decodeInvokeData(raw);
        const e = d.entries[0];
        return { entries: d.entries.length, flags: e.flags, method: e.method, args: e.args.length, sigs: e.signatureKeyHashes.length, charge: e.charge, comment: e.comment, spend: [...e.spend].map(([k, v]) => [k, String(v)]), appArgs: d.appArgs, privilege: d.appPrivilege };
      };
      const res = { sends: {}, claims: {} };
      for (const r of ROUTES) {
        const args = pipe.sendArgs({ cid: r.beamPipeCid, amount: 100000000n, receiver, relayerFee: 1000000n });
        const built = await app.call('invoke_contract', { args, contract: Array.from(await loadShader(r.shaderKey)), create_tx: false });
        const raw = Uint8Array.from(built.raw_data);
        const problem = pipe.sendInspector(r, { receiver, amount: 100000000n, fee: 1000000n })(raw);
        // A changed byte in the amount must be refused by the same check.
        const tampered = raw.slice();
        const hex = Array.from(raw, (x) => x.toString(16).padStart(2, '0')).join('');
        tampered[hex.indexOf(receiver) / 2 + 20] ^= 1;
        res.sends[r.id] = { args, rawB64: b64(raw), problem, tamperedRefused: Boolean(pipe.sendInspector(r, { receiver, amount: 100000000n, fee: 1000000n })(tampered)), summary: summary(raw) };
      }
      const svc = new pipe.BeamPipe();
      for (const [id, [msgId, amount]] of Object.entries(receives)) {
        const r = routeById(id);
        const msg = await svc.remoteMessage(r, msgId);
        if (!msg) {
          res.claims[id] = { msgId, state: 'claimed since the recording' };
          continue;
        }
        const args = pipe.receiveArgs({ cid: r.beamPipeCid, msgId });
        const built = await app.call('invoke_contract', { args, contract: Array.from(await loadShader(r.shaderKey)), create_tx: false });
        const raw = Uint8Array.from(built.raw_data);
        res.claims[id] = { msgId, args, state: 'unclaimed', amount: String(msg.amount), rawB64: b64(raw), problem: await pipe.claimInspector(r, { msgId, amount: BigInt(amount) })(raw), summary: summary(raw) };
      }
      return res;
    },
    { receiver: RECEIVER, receives: RECEIVES },
  );
  for (const [id, s] of Object.entries(out.sends)) {
    const same = BUILDS[s.args] && BUILDS[s.args].raw_data_base64 === s.rawB64;
    console.log(`# send ${id}: ${JSON.stringify(s.summary)}; inspect ${s.problem ? `REFUSED ${s.problem.why}` : 'passed'}; one flipped amount bit refused: ${s.tamperedRefused}; equals the desktop recording: ${same}`);
    assert.equal(s.problem, null);
    assert.equal(s.tamperedRefused, true);
    assert.equal(s.summary.args, 36);
    assert.equal(s.summary.sigs, 0);
    assert.ok(same, `${id}: the engine built the same bytes as the recording`);
  }
  for (const [id, c] of Object.entries(out.claims)) {
    if (c.state !== 'unclaimed') {
      console.log(`# claim ${id} msg ${c.msgId}: ${c.state}, not built`);
      continue;
    }
    const same = BUILDS[c.args] && BUILDS[c.args].raw_data_base64 === c.rawB64;
    console.log(`# claim ${id} msg ${c.msgId} (built, never submitted; this wallet could never sign it): ${JSON.stringify(c.summary)}; inspect ${c.problem ? `REFUSED ${c.problem.why}` : 'passed'}; equals the desktop recording: ${same}`);
    assert.equal(c.problem, null);
    assert.equal(c.summary.charge, 1200000);
    assert.ok(same);
  }
  const txs = await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    return (await wallet.session.call('tx_list', { count: 100, skip: 0 })).length;
  });
  assert.equal(txs, 0, 'building submits nothing');
});

test('one full send to Ethereum stops at the consent sheet: what the engine reported, not enough, Cancel sends nothing', { timeout: 10 * 60000 }, async () => {
  await page.evaluate(async (receiver) => {
    const { BeamPipe } = await import('./lib/bridge/beam_pipe.js');
    const { routeById } = await import('./lib/bridge/routes.js');
    window.__bridgeSend = new BeamPipe().send(routeById('beam'), { ethReceiver: `0x${receiver}`, amount: 100000000n, fee: 1000000n }).then(
      (txId) => ({ txId }),
      (e) => ({ code: e.code, rpc: e.rpc ? e.rpc.code : null, message: e.message }),
    );
  }, RECEIVER);
  await page.waitForSelector(tid('consent'), { timeout: 120000 });
  await shot(page, 'bridge-01-consent-not-enough');
  // The wallet's own move reads as one (screens/consent.js, bridge rows): shown only when the
  // engine's report equals the request, so these rows are what the engine reported.
  const move = await page.textContent(tid('consent-bridge-amount'));
  const bridgeFee = await page.textContent(tid('consent-bridge-fee'));
  const fee = await page.textContent(tid('consent-fee'));
  const total = await page.textContent(tid('consent-total'));
  console.log(`# consent: "${await page.textContent(`${tid('consent')} h2`)}", move "${move}", bridge fee "${bridgeFee}", fee "${fee}", total "${total}", "${(await page.textContent(tid('consent-not-enough'))).trim()}"`);
  assert.equal(await page.getAttribute(tid('consent'), 'data-bridge'), 'send');
  assert.equal(move, '1 BEAM');
  assert.equal(bridgeFee, '0.01 BEAM');
  assert.equal(fee, '0.011 BEAM');
  assert.equal(total, '1.021 BEAM');
  assert.equal(await page.textContent(tid('consent-bridge-receives')), '1 WBEAM');
  assert.equal(await page.getAttribute(tid('consent-bridge-to'), 'data-address'), `0x${RECEIVER}`);
  assert.match(await page.textContent(tid('consent-not-enough')), /^Not enough BEAM\./);
  assert.equal(await page.isVisible(tid('consent-approve')), false, 'no approve button: the engine says it is not enough');
  await page.click(tid('consent-cancel'));
  const result = await page.evaluate(() => window.__bridgeSend);
  console.log(`# after Cancel: ${JSON.stringify(result)}`);
  assert.equal(result.code, 'rejected');
  assert.equal(result.rpc, -32021, 'the engine answered "Call is rejected by user"');
  const last = (await page.evaluate(() => window.__campfire.consents())).at(-1);
  console.log(`# consent log: ${JSON.stringify(last)}`);
  // Shown, so expect() passed on what the engine reported: 1.01 BEAM out, 0.011 fee.
  assert.equal(last.decision, 'rejected');
  assert.equal(last.appName, 'BEAM Campfire');
  assert.equal(last.isEnough, false);
  assert.equal(last.fee, '0.011');
  assert.deepEqual(last.spends, [{ assetId: 0, amount: '1.01' }]);
  assert.deepEqual(last.receives, []);
  const truth = await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const txs = await wallet.session.call('tx_list', { count: 100, skip: 0 });
    const st = await wallet.session.call('wallet_status', { nz_totals: true });
    return { txs: txs.length, available: String(st.available), contracts: window.__campfire.contracts() };
  });
  console.log(`# engine after Cancel: ${JSON.stringify(truth)}`);
  assert.equal(truth.txs, 0);
  assert.equal(truth.available, '0');
  assert.equal(truth.contracts.consents, 0);
  assert.equal(truth.contracts.inflight, 0);
});

test('IP privacy: only this origin and the chosen node', async () => {
  assert.deepEqual(foreignHosts(rec, srv.url, [NODE]), []);
  assert.deepEqual(rec.csp, []);
  assert.deepEqual(rec.errors, []);
});

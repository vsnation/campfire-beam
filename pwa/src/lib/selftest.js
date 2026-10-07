// In-page self-test for devices the e2e harness cannot drive (iOS Safari in
// the Simulator). It only runs when the page is on localhost AND the dev
// server (tools/serve.mjs --selftest) answers /__dev/flags; production hosts
// answer 404 there, so this file is inert in a real deployment.
//
// It creates a THROWAWAY wallet (any existing wallet in this browser profile
// is deleted first - never point it at a profile with a real wallet), unlocks
// it with a password, starts it the way a new wallet starts (no snapshot, no
// block scan), waits for Synced, makes a receive address, checks which address
// types a scan-less wallet refuses, reloads, unlocks again, checks the address
// survived, then imports the recovery snapshot (the restore / "find coins"
// path) and waits for Synced again. The result is POSTed to /__dev/result,
// which the dev server prints; the throwaway wallet is deleted at the end.

import { h, put } from './dom.js';
import { generatePhrase, deleteWalletDb, engineLog, loadEngine, nodeGuard } from './engine.js';
import { createWallet, openWithPasswordFor, markSetupDone, setScan } from './session.js';
import { store, getPrefs, getWalletRecord } from './store.js';
import { downloadRecovery } from './recovery.js';
import { wallet } from './wallet.js';
import { toHex, randomBytes } from './envelope.js';
import { passkeyAvailable } from './passkey.js';

const KEY = 'campfire-selftest';

function save(st) {
  sessionStorage.setItem(KEY, JSON.stringify(st));
}
function load() {
  try {
    return JSON.parse(sessionStorage.getItem(KEY) || 'null');
  } catch {
    return null;
  }
}

function waitFor(pred, timeoutMs, label) {
  return new Promise((resolve, reject) => {
    const t0 = Date.now();
    const tick = () => {
      let v;
      try {
        v = pred();
      } catch (e) {
        return reject(e);
      }
      if (v) return resolve(v);
      if (Date.now() - t0 > timeoutMs) return reject(new Error(`timeout waiting for ${label}`));
      setTimeout(tick, 1000);
    };
    tick();
  });
}

export async function runSelfTest(app) {
  const root = document.getElementById('app');
  const lines = h('pre', { class: 'mono selftest-log', 'data-testid': 'selftest-log' });
  put(root, h('main', { class: 'screen' }, h('h1', { text: 'BEAM Campfire self-test' }), lines));
  const log = (m) => {
    lines.textContent += `${new Date().toISOString().slice(11, 19)} ${m}\n`;
    console.log('[selftest]', m);
  };
  let st = load();
  const result = st && st.result ? st.result : { ok: false, steps: {} };
  const finish = async (ok, error) => {
    result.ok = ok;
    if (error) result.error = String(error && error.message ? error.message : error);
    result.finishedAt = new Date().toISOString();
    log(ok ? 'PASS' : `FAIL: ${result.error}`);
    try {
      await fetch('__dev/result', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(result) });
    } catch (e) {
      log(`could not report: ${e.message}`);
    }
    sessionStorage.removeItem(KEY);
    await wallet.stop().catch(() => {});
    // The wallet was a throwaway: remove it so the next visit starts at Welcome.
    await deleteWalletDb().catch(() => {});
    await store.clear().catch(() => {});
    log('throwaway wallet removed');
  };

  try {
    if (!st) {
      result.env = {
        userAgent: navigator.userAgent,
        crossOriginIsolated: self.crossOriginIsolated,
        sharedArrayBuffer: typeof SharedArrayBuffer !== 'undefined',
        hardwareConcurrency: navigator.hardwareConcurrency,
        standalone: navigator.standalone === true || matchMedia('(display-mode: standalone)').matches,
        serviceWorkerControlled: Boolean(navigator.serviceWorker && navigator.serviceWorker.controller),
        webauthn: typeof PublicKeyCredential !== 'undefined',
      };
      try {
        result.env.platformAuthenticator = await passkeyAvailable();
        if (typeof PublicKeyCredential !== 'undefined' && PublicKeyCredential.getClientCapabilities) result.env.clientCapabilities = await PublicKeyCredential.getClientCapabilities();
      } catch (e) {
        result.env.passkeyProbeError = e.message;
      }
      log(`isolated=${result.env.crossOriginIsolated} SAB=${result.env.sharedArrayBuffer} cores=${result.env.hardwareConcurrency}`);

      const t0 = performance.now();
      await loadEngine();
      result.steps.engineLoadMs = Math.round(performance.now() - t0);
      log(`engine loaded in ${result.steps.engineLoadMs} ms`);

      // Throwaway wallet: wipe whatever this test profile had.
      await wallet.stop().catch(() => {});
      await deleteWalletDb();
      await store.clear();
      app.prefs = await getPrefs();
      app.record = null;
      const password = `selftest-${toHex(randomBytes(6))}`;
      app.setup = { mode: 'create', words: await generatePhrase() };
      await createWallet(app, password);
      await app.setPrefs({ ipAck: true });
      result.steps.created = true;
      log('throwaway wallet created');

      const ti = performance.now();
      await wallet.start({ dbPass: app.dbPass, node: app.prefs.node, bodyRequests: false });
      await markSetupDone(app);
      result.steps.rulesSignature = engineLog.rulesSignature();

      await waitFor(() => wallet.state.sync.state === 'synced', 5 * 60000, 'Synced');
      result.steps.newWalletStartToSyncedMs = Math.round(performance.now() - ti);
      result.steps.synced = { height: wallet.state.status.current_height, explorerHeight: wallet.state.explorer && wallet.state.explorer.height, verified: wallet.state.sync.verified };
      log(`new wallet synced at ${result.steps.synced.height} (explorer ${result.steps.synced.explorerHeight}) ${result.steps.newWalletStartToSyncedMs} ms after start, no download`);
      result.steps.guardRefusals = Object.values(nodeGuard.state.blocked).reduce((a, b) => a + b, 0);
      result.steps.connectionEvent = wallet.state.connEvent;

      const address = await wallet.receiveAddress();
      const v = await wallet.validateAddress(address);
      result.steps.address = { length: address.length, valid: v.is_valid, mine: v.is_mine, type: v.type };
      log(`receive address ok (${address.length} chars, valid=${v.is_valid})`);
      const refused = {};
      for (const type of ['max_privacy', 'offline']) {
        try {
          await wallet.session.call('create_address', { type });
          refused[type] = false;
        } catch (e) {
          refused[type] = (e.rpc && e.rpc.code) || e.message;
        }
      }
      result.steps.scanlessRefusesAddressTypes = refused;
      log(`scan-less wallet refuses: ${JSON.stringify(refused)}`);
      await wallet.persistNow();
      await wallet.stop();
      st = { phase: 'reload', password, address, result };
      save(st);
      log('reloading to check persistence…');
      setTimeout(() => location.reload(), 500);
      return;
    }

    // ---- after the reload
    log('after reload: unlocking with the password');
    app.prefs = await getPrefs();
    app.record = await getWalletRecord();
    if (!app.record) throw new Error('wallet record missing after reload');
    const dbPass = await openWithPasswordFor(app, st.password);
    try {
      await openWithPasswordFor(app, `${st.password}-wrong`);
      result.steps.wrongPasswordRefused = false;
    } catch (e) {
      result.steps.wrongPasswordRefused = e.code === 'wrong_secret';
    }
    app.dbPass = dbPass;
    const tr = performance.now();
    await wallet.start({ dbPass, node: app.prefs.node, bodyRequests: false });
    const list = await wallet.session.call('addr_list', { own: true });
    result.steps.addressPersisted = (list || []).some((a) => a.address === st.address);
    log(`address after reload: ${result.steps.addressPersisted}`);
    await waitFor(() => wallet.state.sync.state === 'synced', 5 * 60000, 'Synced after reload');
    result.steps.resyncAfterReloadMs = Math.round(performance.now() - tr);
    log(`synced again in ${result.steps.resyncAfterReloadMs} ms`);

    // The restore / "find coins" path: snapshot download + import, then scanning on.
    await wallet.stop();
    const td = performance.now();
    let buf = await downloadRecovery((d, t) => {
      if (d === t || d % 50e6 < 2e6) log(`download ${Math.round(d / 1e6)}/${Math.round(t / 1e6)} MB`);
    });
    result.steps.recoveryBytes = buf.length;
    result.steps.downloadMs = Math.round(performance.now() - td);
    const ti = performance.now();
    await wallet.start({ dbPass, node: app.prefs.node, recovery: buf, bodyRequests: true });
    buf = null;
    result.steps.importMs = Math.round(performance.now() - ti);
    await setScan(app, true);
    log(`snapshot: ${result.steps.downloadMs} ms download, ${result.steps.importMs} ms import`);
    const ts2 = performance.now();
    await waitFor(() => wallet.state.sync.state === 'synced', 10 * 60000, 'Synced after import');
    result.steps.syncAfterImportMs = Math.round(performance.now() - ts2);
    result.steps.scanningAfterImport = wallet.state.scanning;
    log(`synced after import in ${result.steps.syncAfterImportMs} ms`);
    await finish(Boolean(result.steps.addressPersisted && result.steps.wrongPasswordRefused && result.steps.synced && result.steps.importMs));
  } catch (e) {
    await finish(false, e);
  }
}

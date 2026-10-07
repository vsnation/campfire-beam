// The wallet.db import in Safari on the iOS Simulator (no file picker can be
// driven there, so the in-page self-test feeds the file in; see
// src/lib/selftest.js, ?selftest=import).
//
//   node test/e2e/ios_import.mjs        (SIM_UDID=<udid> to pick a device; default: a booted
//                                         iPhone, else the first available one)
//
// 1. Makes a THROWAWAY wallet.db with BEAM's native 7.5.14493 CLI (walletdb.mjs).
// 2. Builds a release into a temp dir and serves it on :8794 with --selftest --import-test.
// 3. Opens Welcome in Safari and screenshots it (the three choices, iPhone-sized).
// 4. Opens ?selftest=import and waits for SELFTEST_RESULT; screenshots the log.
// 5. Deletes the throwaway wallet (the self-test does, in the browser) and the temp files.
// Never run it against a Simulator whose Safari holds a real wallet for localhost:8794.
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync, readFileSync, existsSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PWA, startServer, sleep, SHOTS } from './harness.mjs';
import { makeWalletDb, cliVersion, WANT_CORE } from './walletdb.mjs';

const PORT = 8794;
const pkg = JSON.parse(readFileSync(join(PWA, 'package.json'), 'utf8'));
const simctl = (...a) => execFileSync('xcrun', ['simctl', ...a], { encoding: 'utf8' });

function pickDevice() {
  const all = JSON.parse(simctl('list', 'devices', 'available', '--json')).devices;
  const phones = Object.entries(all)
    .filter(([rt]) => /iOS/.test(rt))
    .flatMap(([rt, ds]) => ds.map((d) => ({ ...d, rt })))
    .filter((d) => /iPhone/.test(d.name));
  if (process.env.SIM_UDID) return phones.find((d) => d.udid === process.env.SIM_UDID);
  return phones.find((d) => d.state === 'Booted') || phones.find((d) => d.name === 'iPhone 17') || phones[0];
}

async function waitResult(file, timeoutMs) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    if (existsSync(file)) {
      const line = readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).pop();
      if (line) return JSON.parse(line);
    }
    await sleep(2000);
  }
  throw new Error('no SELFTEST_RESULT in time');
}

const tmp = mkdtempSync(join(tmpdir(), 'campfire-ios-import-'));
let srv = null;
let bootedHere = false;
let dev = null;
try {
  const v = cliVersion(join(tmp, 'cli'));
  if (v !== WANT_CORE) throw new Error(`BEAM CLI must be ${WANT_CORE} (got ${v})`);
  const dir = join(tmp, 'wallet');
  const w = makeWalletDb(dir);
  writeFileSync(join(dir, 'import.json'), JSON.stringify({ password: w.password, addresses: w.addresses }), { mode: 0o600 });
  console.log(`# throwaway wallet.db: ${w.size} bytes from beam-wallet ${v}`);
  const rel = join(tmp, 'rel');
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', rel, '--version', pkg.version, '--quiet'], { cwd: PWA });
  const resultFile = join(tmp, 'result.jsonl');
  srv = await startServer({ root: rel, port: PORT, selftest: true, extra: ['--import-test', dir, '--result-file', resultFile, '--verbose'] });

  dev = pickDevice();
  if (!dev) throw new Error('no iPhone simulator available');
  if (dev.state !== 'Booted') {
    simctl('boot', dev.udid);
    bootedHere = true;
  }
  spawnSync('xcrun', ['simctl', 'bootstatus', dev.udid, '-b'], { stdio: 'ignore' });
  spawnSync('open', ['-a', 'Simulator', '--args', '-CurrentDeviceUDID', dev.udid], { stdio: 'ignore' });
  console.log(`# simulator: ${dev.name} (${dev.rt.split('.').pop()}) ${dev.udid}`);
  mkdirSync(SHOTS, { recursive: true });

  // First visit: the signed copy is verified and installed, the page reloads, Welcome renders,
  // and ~4 s later the app looks for a signed update (GET /release.json): that request is the
  // sign that Welcome is on screen.
  const mark = srv.output.length;
  simctl('openurl', dev.udid, `http://localhost:${PORT}/`);
  const t0 = Date.now();
  while (!srv.output.slice(mark).join('').match(/GET \/release\.json 200/g)?.length || Date.now() - t0 < 5000) {
    if (Date.now() - t0 > 180000) throw new Error('Welcome did not load in Safari within 3 minutes');
    await sleep(1000);
  }
  // The install itself also fetches release.json: wait for the update check after the reload too.
  const installed = Date.now();
  while ((srv.output.slice(mark).join('').match(/GET \/release\.json 200/g) || []).length < 2 && Date.now() - installed < 20000) await sleep(1000);
  await sleep(2000);
  console.log(`# Welcome loaded in Safari after ${Math.round((Date.now() - t0) / 1000)} s`);
  const welcomeShot = join(SHOTS, 'ios-import-01-welcome-safari.png');
  simctl('io', dev.udid, 'screenshot', welcomeShot);
  console.log(`# screenshot ${welcomeShot}`);

  simctl('openurl', dev.udid, `http://localhost:${PORT}/?selftest=import`);
  const r = await waitResult(resultFile, 8 * 60000);
  const logShot = join(SHOTS, 'ios-import-02-selftest-result.png');
  await sleep(1500);
  simctl('io', dev.udid, 'screenshot', logShot);
  console.log(`# screenshot ${logShot}`);
  console.log(`SELFTEST_RESULT ${JSON.stringify(r)}`);
  if (!r.ok) process.exitCode = 1;
} catch (e) {
  console.error(`ios import self-test: ${e.message}`);
  process.exitCode = 1;
} finally {
  if (srv) srv.stop();
  rmSync(tmp, { recursive: true, force: true });
  if (bootedHere && process.env.SIM_KEEP !== '1' && dev) spawnSync('xcrun', ['simctl', 'shutdown', dev.udid], { stdio: 'ignore' });
}

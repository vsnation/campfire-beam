// The dApp frame on WebKit: Safari on the iOS Simulator (default) or Chrome (--chrome).
//
//   node test/e2e/ios_dapps.mjs [--chrome] [--file]   (SIM_UDID=<udid>; default: iPhone 17)
//
// Builds a release into a temporary directory and serves it with the dev
// server (--selftest). Opens it once so the service worker installs the
// verified copy, then opens __dev/dapp-probe.html (test/e2e/dapp_probe/),
// which runs the real DappRunner against a synthetic dApp that probes its
// own frame (origin, the wallet page's DOM and storage, requests to the
// wallet's origin and to an ungranted host, eval) and reports through the
// bridge. Prints DAPP_PROBE_RESULT and fails unless the frame is opaque and a
// message posted to the wallet window reached nothing. No wallet, no funds.
// --file: the same for a dApp installed from a .dapp file (the probe's
// ?file=1): read with the real rules, kept in IndexedDB, run under the file
// policy with its inline script, and its refused request heard as "blocked".
import { execFileSync, spawnSync, spawn } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PWA, sleep, SHOTS, launch } from './harness.mjs';

const PORT = Number(process.env.CAMPFIRE_IOS_DAPPS_PORT || 8799);
const chrome = process.argv.includes('--chrome');
const fileMode = process.argv.includes('--file');
const tmp = mkdtempSync(join(tmpdir(), 'campfire-dapp-probe-'));
const rel = join(tmp, 'rel');
const resultFile = join(tmp, 'result.jsonl');
let server = null;
let browser = null;
try {
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', rel, '--quiet'], { cwd: PWA });
  server = spawn(process.execPath, [join(PWA, 'tools', 'serve.mjs'), '--root', rel, '--port', String(PORT), '--selftest', '--result-file', resultFile], { stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise((resolve) => server.stdout.on('data', (d) => String(d).includes('dev server') && resolve()));
  const base = `http://localhost:${PORT}/`;
  const probe = `${base}__dev/dapp-probe.html${fileMode ? '?file=1' : ''}`;
  if (chrome) {
    browser = await launch();
    const page = await (await browser.newContext({ viewport: { width: 390, height: 844 } })).newPage();
    await page.goto(base);
    const t1 = Date.now();
    while (Date.now() - t1 < 120000) {
      const ok = await page.evaluate(() => Boolean(navigator.serviceWorker.controller) && document.getElementById('app').dataset.screen === 'welcome').catch(() => false);
      if (ok) break;
      await sleep(500);
    }
    await page.goto(probe);
  } else {
    const simctl = (...a) => execFileSync('xcrun', ['simctl', ...a], { encoding: 'utf8' });
    const devices = Object.values(JSON.parse(simctl('list', 'devices', 'available', '--json')).devices).flat();
    const udid = process.env.SIM_UDID || (devices.find((d) => d.name === 'iPhone 17') || devices.find((d) => /iPhone/.test(d.name))).udid;
    spawnSync('xcrun', ['simctl', 'boot', udid], { stdio: 'ignore' });
    spawnSync('xcrun', ['simctl', 'bootstatus', udid, '-b'], { stdio: 'ignore' });
    spawnSync('xcrun', ['simctl', 'terminate', udid, 'com.apple.mobilesafari'], { stdio: 'ignore' });
    const data = simctl('get_app_container', udid, 'com.apple.mobilesafari', 'data').trim();
    for (const d of ['Library/WebKit/com.apple.mobilesafari/WebsiteData', 'Library/Caches/com.apple.mobilesafari', 'Library/Caches/WebKit']) rmSync(join(data, d), { recursive: true, force: true });
    console.log(`# Safari on the iOS Simulator ${udid}: first open ${base}`);
    simctl('openurl', udid, base);
    await sleep(45000); // the first open downloads and verifies the release, then reloads into it
    simctl('openurl', udid, probe);
    const t0 = Date.now();
    while (!existsSync(resultFile) && Date.now() - t0 < 120000) await sleep(1000);
    await sleep(500);
    spawnSync('xcrun', ['simctl', 'io', udid, 'screenshot', join(SHOTS, fileMode ? 'ios-dapp-file-probe.png' : 'ios-dapp-probe.png')], { stdio: 'ignore' });
  }
  const t0 = Date.now();
  while (!existsSync(resultFile) && Date.now() - t0 < 120000) await sleep(1000);
  if (!existsSync(resultFile)) throw new Error('no probe result');
  const result = JSON.parse(readFileSync(resultFile, 'utf8').trim().split('\n').pop());
  console.log(`DAPP_PROBE_RESULT ${JSON.stringify(result)}`);
  if (!result.ok) process.exitCode = 1;
} catch (e) {
  console.error(`dapp probe: ${e.message}`);
  process.exitCode = 1;
} finally {
  if (browser) await browser.close();
  if (server) server.kill();
  rmSync(tmp, { recursive: true, force: true });
}

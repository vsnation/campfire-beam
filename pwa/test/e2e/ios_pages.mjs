// GitHub Pages, emulated, in Safari on the iOS Simulator: a static host under
// /beam-campfire-pwa/ with no security headers and no relays (static_host.mjs).
//
//   node test/e2e/ios_pages.mjs        (SIM_UDID=<udid>; default: iPhone 17)
//
// 1. Clears Safari's website data on the Simulator (a phone that never saw the app).
// 2. First open as a timeline (ios_firstrun.mjs --no-erase): setup screen -> Welcome.
// 3. On that installed copy, the in-page self-test (?selftest=1): checks the page is
//    cross-origin isolated, creates a throwaway wallet, Synced on mainnet, makes an
//    address, reloads, unlocks, Synced again; the snapshot step is skipped (no relay
//    on a static host). Prints SELFTEST_RESULT; the self-test deletes its wallet.
import { execFileSync, spawnSync, spawn } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PWA, sleep, SHOTS } from './harness.mjs';
import { startStaticHost } from './static_host.mjs';

const PORT = 8798;
const here = dirname(fileURLToPath(import.meta.url));
const pkg = JSON.parse(readFileSync(join(PWA, 'package.json'), 'utf8'));
const simctl = (...a) => execFileSync('xcrun', ['simctl', ...a], { encoding: 'utf8' });
const devices = Object.values(JSON.parse(simctl('list', 'devices', 'available', '--json')).devices).flat();
const udid = process.env.SIM_UDID || (devices.find((d) => d.name === 'iPhone 17') || devices.find((d) => /iPhone/.test(d.name))).udid;

function clearSafari() {
  spawnSync('xcrun', ['simctl', 'boot', udid], { stdio: 'ignore' });
  spawnSync('xcrun', ['simctl', 'bootstatus', udid, '-b'], { stdio: 'ignore' });
  spawnSync('xcrun', ['simctl', 'terminate', udid, 'com.apple.mobilesafari'], { stdio: 'ignore' });
  const data = simctl('get_app_container', udid, 'com.apple.mobilesafari', 'data').trim();
  for (const d of ['Library/WebKit/com.apple.mobilesafari/WebsiteData', 'Library/Caches/com.apple.mobilesafari', 'Library/Caches/WebKit']) rmSync(join(data, d), { recursive: true, force: true });
}

const tmp = mkdtempSync(join(tmpdir(), 'campfire-ios-pages-'));
let host = null;
try {
  const rel = join(tmp, 'rel');
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', rel, '--version', pkg.version, '--quiet'], { cwd: PWA });
  const resultFile = join(tmp, 'result.jsonl');
  host = await startStaticHost({ root: rel, port: PORT, devHooks: true, resultFile });
  console.log(`# Pages emulation ${host.url} (no security headers, no relays), release ${pkg.version}`);
  clearSafari();
  const out = join(SHOTS, 'ios-pages-firstrun');
  // Not spawnSync: the static host lives in this process and must keep answering meanwhile.
  const stdout = await new Promise((resolve, reject) => {
    const c = spawn(process.execPath, [join(here, 'ios_firstrun.mjs'), host.url, '--udid', udid, '--no-erase', '--out', out, '--times', '1,2,3,4,5,6,8,10,12,15,20,25,30'], { stdio: ['ignore', 'pipe', 'inherit'] });
    let buf = '';
    c.stdout.on('data', (d) => (buf += d));
    c.on('error', reject);
    c.on('exit', () => resolve(buf));
  });
  process.stdout.write(stdout.split('\n').filter((l) => l.startsWith('#')).join('\n') + '\n');
  const firstRun = host.requests.filter((q) => q.path.includes('/sw-')).length;
  console.log(`# first open: ${host.requests.length} requests to the static host (loader fetches ${firstRun})`);

  simctl('openurl', udid, `${host.url}?selftest=1`);
  const t0 = Date.now();
  let result = null;
  while (!result && Date.now() - t0 < 8 * 60000) {
    if (existsSync(resultFile)) {
      const line = readFileSync(resultFile, 'utf8').trim().split('\n').filter(Boolean).pop();
      if (line) result = JSON.parse(line);
    }
    if (!result) await sleep(2000);
  }
  if (!result) throw new Error('no self-test result in 8 minutes');
  await sleep(1500);
  spawnSync('xcrun', ['simctl', 'io', udid, 'screenshot', join(SHOTS, 'ios-pages-selftest.png')], { stdio: 'ignore' });
  const asked = host.requests.filter((q) => /\/(explorer|recovery)\//.test(q.path)).map((q) => `${q.method} ${q.path}`);
  console.log(`# requests to /explorer or /recovery: ${JSON.stringify(asked)} (the self-test's snapshot probe only)`);
  console.log(`SELFTEST_RESULT ${JSON.stringify(result)}`);
  if (!result.ok) process.exitCode = 1;
} catch (e) {
  console.error(`ios pages run: ${e.message}`);
  process.exitCode = 1;
} finally {
  if (host) await host.stop();
  rmSync(tmp, { recursive: true, force: true });
}

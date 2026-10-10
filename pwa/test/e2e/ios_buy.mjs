// Buy BEAM in Safari on the iOS Simulator, against the real buybeam.my.
//
//   node test/e2e/ios_buy.mjs        (SIM_UDID=<udid>; default: iPhone 17)
//
// Serves this tree's signed build like GitHub Pages, clears Safari's website
// data, opens the app once (it installs itself), then runs the in-page Buy
// self-test (?selftest=buy): the same requests the Buy screen makes, with the
// exact error and any CSP refusal if one fails. No wallet, no funds.
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PWA, sleep, SHOTS } from './harness.mjs';
import { startStaticHost } from './static_host.mjs';

const PORT = 8796;
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

const tmp = mkdtempSync(join(tmpdir(), 'campfire-ios-buy-'));
let host = null;
try {
  const rel = join(tmp, 'rel');
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', rel, '--version', pkg.version, '--quiet'], { cwd: PWA });
  const resultFile = join(tmp, 'result.jsonl');
  host = await startStaticHost({ root: rel, port: PORT, devHooks: true, resultFile });
  console.log(`# Pages emulation ${host.url}, release ${pkg.version}, Simulator ${udid}`);
  clearSafari();
  simctl('openurl', udid, host.url);
  await sleep(30000); // first open: the app sets itself up and reloads into its installed copy
  simctl('openurl', udid, `${host.url}?selftest=buy`);
  const t0 = Date.now();
  let result = null;
  while (!result && Date.now() - t0 < 3 * 60000) {
    if (existsSync(resultFile)) {
      const line = readFileSync(resultFile, 'utf8').trim().split('\n').filter(Boolean).pop();
      if (line) result = JSON.parse(line);
    }
    if (!result) await sleep(2000);
  }
  if (!result) throw new Error('no Buy self-test result in 3 minutes');
  spawnSync('xcrun', ['simctl', 'io', udid, 'screenshot', join(SHOTS, 'ios-buy-selftest.png')], { stdio: 'ignore' });
  console.log(`SELFTEST_RESULT ${JSON.stringify(result)}`);
  if (!result.ok) process.exitCode = 1;
} catch (e) {
  console.error(`ios buy run: ${e.message}`);
  process.exitCode = 1;
} finally {
  if (host) await host.stop();
  rmSync(tmp, { recursive: true, force: true });
}

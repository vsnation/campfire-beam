// An update in Safari on the iOS Simulator, the way a phone gets it: the
// previous public release installed, the host then serves this tree's build,
// Check for updates -> Update, then Buy BEAM against the real buybeam.my.
//
//   node test/e2e/ios_update.mjs <unpacked previous release>   (SIM_UDID=<udid>)
//
// The previous release comes from its GitHub release zip, unpacked. A small
// driver page under __dev/ (which every loader passes to the network) asks
// the installed loader to check and apply, exactly as Settings does, then
// opens the app. The Buy self-test (?selftest=buy) then reports which loader
// controls the page and whether buybeam.my is reachable, after the update and
// again after Safari is restarted.
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, existsSync, cpSync, mkdirSync, writeFileSync, symlinkSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { PWA, sleep, SHOTS } from './harness.mjs';
import { startStaticHost } from './static_host.mjs';

const PORT = 8795;
const prev = resolve(process.argv[2] || '');
if (!existsSync(join(prev, 'release.json'))) throw new Error('usage: ios_update.mjs <unpacked previous release>');
const pkg = JSON.parse(readFileSync(join(PWA, 'package.json'), 'utf8'));
const simctl = (...a) => execFileSync('xcrun', ['simctl', ...a], { encoding: 'utf8' });
const devices = Object.values(JSON.parse(simctl('list', 'devices', 'available', '--json')).devices).flat();
const udid = process.env.SIM_UDID || (devices.find((d) => d.name === 'iPhone 17') || devices.find((d) => /iPhone/.test(d.name))).udid;

const DRIVER = `<!doctype html><meta charset="utf-8"><title>update driver</title><pre id="o"></pre><script>
const o = document.getElementById('o');
const report = (x) => fetch('result', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(x) });
const ask = (msg) => new Promise((res) => {
  const sw = navigator.serviceWorker.controller;
  if (!sw) return res({ error: 'no controller' });
  const ch = new MessageChannel();
  const t = setTimeout(() => res({ error: 'timeout' }), 120000);
  ch.port1.onmessage = (e) => { clearTimeout(t); res(e.data); };
  sw.postMessage(msg, [ch.port2]);
});
(async () => {
  const ctl = navigator.serviceWorker.controller;
  const check = await ask({ type: 'check-update' });
  const apply = check && check.result === 'ready' ? await ask({ type: 'apply-update' }) : null;
  o.textContent = JSON.stringify({ check, apply });
  await report({ mode: 'drive', controller: ctl ? ctl.scriptURL.split('/').pop() : null, check, apply });
  location.href = '../';
})();
</script>`;

function clearSafari() {
  spawnSync('xcrun', ['simctl', 'boot', udid], { stdio: 'ignore' });
  spawnSync('xcrun', ['simctl', 'bootstatus', udid, '-b'], { stdio: 'ignore' });
  spawnSync('xcrun', ['simctl', 'terminate', udid, 'com.apple.mobilesafari'], { stdio: 'ignore' });
  const data = simctl('get_app_container', udid, 'com.apple.mobilesafari', 'data').trim();
  for (const d of ['Library/WebKit/com.apple.mobilesafari/WebsiteData', 'Library/Caches/com.apple.mobilesafari', 'Library/Caches/WebKit']) rmSync(join(data, d), { recursive: true, force: true });
}

const tmp = mkdtempSync(join(tmpdir(), 'campfire-ios-update-'));
let host = null;
const resultFile = join(tmp, 'result.jsonl');
const results = () => (existsSync(resultFile) ? readFileSync(resultFile, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
async function waitResult(mode, n, ms) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    const r = results().filter((x) => x.mode === mode);
    if (r.length >= n) return r[n - 1];
    await sleep(2000);
  }
  throw new Error(`no ${mode} result #${n}`);
}
try {
  const old = join(tmp, 'old');
  const next = join(tmp, 'new');
  cpSync(prev, old, { recursive: true });
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', next, '--version', pkg.version, '--quiet'], { cwd: PWA });
  for (const d of [old, next]) {
    mkdirSync(join(d, '__dev'), { recursive: true });
    writeFileSync(join(d, '__dev', 'drive.html'), DRIVER);
  }
  const live = join(tmp, 'live');
  const point = (dir) => {
    try {
      unlinkSync(live);
    } catch {
      /* first */
    }
    symlinkSync(dir, live);
  };
  point(old);
  host = await startStaticHost({ root: live, port: PORT, devHooks: true, resultFile });
  const prevVersion = JSON.parse(readFileSync(join(prev, 'release.json'), 'utf8')).version;
  console.log(`# ${host.url}: ${prevVersion} installed, then ${pkg.version}; Simulator ${udid}`);
  clearSafari();
  simctl('openurl', udid, host.url);
  await sleep(30000); // the previous release sets itself up
  point(next);
  simctl('openurl', udid, `${host.url}__dev/drive.html`);
  const drive = await waitResult('drive', 1, 4 * 60000);
  console.log(`# drive: controller ${drive.controller}, check ${JSON.stringify(drive.check)}, apply ${JSON.stringify(drive.apply)}`);
  await sleep(20000); // the updated app runs; its loader may move meanwhile
  simctl('openurl', udid, `${host.url}?selftest=buy`);
  const first = await waitResult('buy', 1, 3 * 60000);
  spawnSync('xcrun', ['simctl', 'io', udid, 'screenshot', join(SHOTS, 'ios-update-buy-1.png')], { stdio: 'ignore' });
  console.log(`BUY_AFTER_UPDATE ${JSON.stringify(first)}`);
  spawnSync('xcrun', ['simctl', 'terminate', udid, 'com.apple.mobilesafari'], { stdio: 'ignore' });
  await sleep(5000);
  simctl('openurl', udid, `${host.url}?selftest=buy`);
  const second = await waitResult('buy', 2, 3 * 60000);
  console.log(`BUY_AFTER_RESTART ${JSON.stringify(second)}`);
  const loaders = host.requests.filter((q) => /\/sw-[0-9a-f]+\.js$/.test(q.path)).map((q) => q.path.split('/').pop());
  console.log(`# loader fetches: ${JSON.stringify(loaders)}`);
  if (!first.ok || !second.ok) process.exitCode = 1;
} catch (e) {
  console.error(`ios update run: ${e.message}`);
  console.error(JSON.stringify(results()));
  process.exitCode = 1;
} finally {
  if (host) await host.stop();
  rmSync(tmp, { recursive: true, force: true });
}

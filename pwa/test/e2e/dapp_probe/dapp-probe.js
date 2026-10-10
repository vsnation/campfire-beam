// dApp frame probe, for browsers the e2e harness cannot drive (Safari on the
// iOS Simulator). Served only by the dev server with --selftest, at
// __dev/dapp-probe.html, on a page the installed service worker controls.
// It runs the real DappRunner (lib/dapps/runner.js from the verified copy)
// with a synthetic dApp that probes its own frame and reports through the
// bridge, and a stand-in app API that records what reaches it (no wallet).
// The result is POSTed to __dev/result.
//
// ?file=1: a dApp installed from a .dapp file instead. The probe zips a tiny
// package here, reads it with the real rules (lib/dapps/file_package.js),
// keeps it in this browser's IndexedDB (lib/dapps/installed.js), allows it
// one host, opens it again from storage and runs it under the file policy:
// its inline script and handler must run, its frame must be opaque, and a
// request to a host it was not allowed must reach the wallet as "blocked".
// It is removed at the end.
import { DappRunner, runnerStats } from '../lib/dapps/runner.js';

const status = document.getElementById('status');
const say = (s) => (status.textContent = `dApp frame probe: ${s}`);
const post = (o) => fetch('result', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(o) });
const enc = (s) => new TextEncoder().encode(s);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const out = { controlled: Boolean(navigator.serviceWorker && navigator.serviceWorker.controller), ua: navigator.userAgent };
  if (!out.controlled) return post({ ...out, ok: false, error: 'not controlled by the installed service worker' });
  const dappJs = await (await fetch('probe-dapp.js', { cache: 'no-store' })).text();
  const files = new Map([
    ['manifest.json', enc('{"name":"Probe","guid":"00000000000000000000000000000001","url":"localapp/app/index.html"}')],
    ['app/index.html', enc('<!doctype html><html><head><title>probe</title></head><body><p>probe dApp</p><script src="probe-dapp.js"></script></body></html>')],
    ['app/probe-dapp.js', enc(dappJs)],
    ['app/data.txt', enc('own file')],
  ]);
  const reached = [];
  let report = null;
  const appApi = {
    async call(method, params) {
      reached.push(method);
      if (method === 'invoke_contract' && typeof params.args === 'string' && params.args.startsWith('report=')) report = JSON.parse(params.args.slice(7));
      return { output: '{}' };
    },
    close() {},
  };
  const states = [];
  const runner = new DappRunner({
    entry: { guid: '00000000000000000000000000000001', needsEval: false, remoteOrigins: [] },
    manifest: { name: 'Probe', startPath: 'app/index.html', apiVersion: '7.0', minApiVersion: '7.0' },
    files,
    appApi,
    confirmSign: async () => false,
    onState: (s) => states.push(s.kind),
  });
  runner.mount(document.getElementById('stage'));
  say('running');
  for (let i = 0; i < 60 && !report; i++) await sleep(500);
  out.report = report;
  out.sandboxAttr = document.querySelector('iframe').getAttribute('sandbox');
  out.frameSrc = document.querySelector('iframe').getAttribute('src');
  // A message to this window, as another frame could post it: reaches no call.
  const before = reached.length;
  window.postMessage({ t: 'rpc', json: JSON.stringify({ jsonrpc: '2.0', id: 'forged', method: 'tx_send', params: { address: 'x', value: 1 } }) }, '*');
  await sleep(1500);
  out.forgedReached = reached.length - before;
  out.reached = reached;
  out.stats = runnerStats();
  out.states = states;
  out.ok = Boolean(report && report.origin === 'null' && out.forgedReached === 0);
  say(out.ok ? 'PASS' : 'FAIL');
  await post(out);
  runner.close();
}

// ------------------------------------------------------------ ?file=1
const FILE_GUID = 'f11ef11ef11ef11ef11ef11ef11ef11e';
const ALLOWED = 'https:' + '//probe-allowed.example.com';
const NOT_ALLOWED = 'https:' + '//probe-refused.example.com';
const FILE_DAPP = `<!doctype html><html><head><title>file probe</title></head><body><p>file probe</p>
<button id="b" onclick="window.__handler = true">b</button>
<script>
var r = { origin: self.origin, href: location.href, inline: true };
document.getElementById('b').click();
r.handler = window.__handler === true;
r.evalOk = (function () { try { return eval('1 + 1') === 2; } catch (e) { return false; } })();
fetch('${NOT_ALLOWED}/x').then(function (x) { r.notAllowed = 'status ' + x.status; }, function (e) { r.notAllowed = 'refused ' + e.name; }).then(function () {
  window.BEAM.callWalletApi(JSON.stringify({ jsonrpc: '2.0', id: 'report', method: 'invoke_contract', params: { contract: [0], args: 'report=' + JSON.stringify(r) } }));
});
</script></body></html>`;

/** A zip of stored entries, enough for the probe's package. */
async function storedZip(entries) {
  const { crc32 } = await import('../lib/dapps/zip.js');
  const u16 = (v) => [v & 255, (v >>> 8) & 255];
  const u32 = (v) => [v & 255, (v >>> 8) & 255, (v >>> 16) & 255, (v >>> 24) & 255];
  const local = [];
  const central = [];
  let off = 0;
  for (const [name, data] of entries) {
    const n = enc(name);
    const crc = crc32(data);
    const head = [...u32(0x04034b50), ...u16(20), ...u16(0x0800), ...u16(0), ...u16(0), ...u16(0), ...u32(crc), ...u32(data.length), ...u32(data.length), ...u16(n.length), ...u16(0), ...n];
    local.push(...head, ...data);
    central.push(...u32(0x02014b50), 20, 3, ...u16(20), ...u16(0x0800), ...u16(0), ...u16(0), ...u16(0), ...u32(crc), ...u32(data.length), ...u32(data.length), ...u16(n.length), ...u16(0), ...u16(0), ...u16(0), ...u16(0), ...u32((0o100644 << 16) >>> 0), ...u32(off), ...n);
    off += head.length + data.length;
  }
  const end = [...u32(0x06054b50), ...u16(0), ...u16(0), ...u16(entries.length), ...u16(entries.length), ...u32(central.length), ...u32(off), ...u16(0)];
  return new Uint8Array([...local, ...central, ...end]);
}

async function fileMain() {
  const out = { mode: 'file', controlled: Boolean(navigator.serviceWorker && navigator.serviceWorker.controller), ua: navigator.userAgent };
  if (!out.controlled) return post({ ...out, ok: false, error: 'not controlled by the installed service worker' });
  const { readFilePackage } = await import('../lib/dapps/file_package.js');
  const { installed } = await import('../lib/dapps/installed.js');
  const manifest = { name: 'File probe', description: 'A probe installed from a file', url: 'localapp/app/index.html', guid: FILE_GUID, version: '1.0.0', api_version: '7.3' };
  const bytes = await storedZip([
    ['manifest.json', enc(JSON.stringify(manifest))],
    ['app/index.html', enc(FILE_DAPP)],
  ]);
  const pkg = await readFilePackage(bytes);
  await installed.remove(FILE_GUID).catch(() => {});
  await installed.install(pkg, bytes);
  await installed.allow(FILE_GUID, ALLOWED);
  const { rec, pkg: kept } = await installed.open(FILE_GUID);
  out.kept = { origins: rec.origins, sha256: rec.sha256 === pkg.sha256 };
  let report = null;
  const blocked = [];
  const appApi = {
    async call(method, params) {
      if (method === 'invoke_contract' && typeof params.args === 'string' && params.args.startsWith('report=')) report = JSON.parse(params.args.slice(7));
      return { output: '{}' };
    },
    close() {},
  };
  const runner = new DappRunner({
    entry: { file: true, guid: FILE_GUID, needsEval: true, remoteOrigins: rec.origins },
    manifest: { name: rec.name, startPath: kept.manifest.startPath, apiVersion: kept.manifest.apiVersion, minApiVersion: kept.manifest.minApiVersion },
    files: kept.files,
    appApi,
    remoteOrigins: rec.origins,
    confirmSign: async () => false,
    onBlocked: (b) => blocked.push(b),
  });
  runner.mount(document.getElementById('stage'));
  say('running a dApp installed from a file');
  for (let i = 0; i < 60 && !(report && blocked.length); i++) await sleep(500);
  out.report = report;
  out.blocked = blocked;
  out.frameSrc = document.querySelector('iframe').getAttribute('src');
  out.sandboxAttr = document.querySelector('iframe').getAttribute('sandbox');
  runner.close();
  await installed.remove(FILE_GUID);
  out.removed = (await installed.list()).every((r) => r.guid !== FILE_GUID);
  out.ok = Boolean(
    report && report.origin === 'null' && report.inline && report.handler && report.evalOk && /^refused/.test(report.notAllowed) &&
      blocked.some((b) => b.origin === NOT_ALLOWED && b.directive === 'connect-src') &&
      out.frameSrc.includes('/dapp-run/f,probe-allowed.example.com/') && out.kept.sha256 && out.removed,
  );
  say(out.ok ? 'PASS' : 'FAIL');
  await post(out);
}

(new URLSearchParams(location.search).get('file') === '1' ? fileMain() : main()).catch((e) => post({ ok: false, error: String(e && e.stack ? e.stack : e) }));

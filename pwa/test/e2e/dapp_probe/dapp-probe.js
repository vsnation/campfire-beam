// dApp frame probe, for browsers the e2e harness cannot drive (Safari on the
// iOS Simulator). Served only by the dev server with --selftest, at
// __dev/dapp-probe.html, on a page the installed service worker controls.
// It runs the real DappRunner (lib/dapps/runner.js from the verified copy)
// with a synthetic dApp that probes its own frame and reports through the
// bridge, and a stand-in app API that records what reaches it (no wallet).
// The result is POSTed to __dev/result.
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

main().catch((e) => post({ ok: false, error: String(e && e.stack ? e.stack : e) }));

// The privacy-relevant configuration agrees everywhere it is written down.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { NODES as HEADER_NODES, CSP, SECURITY_HEADERS, DAPP_PACKAGE_SOURCE, LOADER_CSP, headersFor, nginxHeaderLines, PROXY_PATHS, securityHeaders } from '../../tools/headers.mjs';
import { BUILTIN_SOURCES } from '../../src/lib/update_sources.js';
import { CATALOGUE, sourceUrl, REMOTE_ORIGINS } from '../../src/lib/dapps/catalogue.js';
import { frameCsp } from '../../src/lib/dapps/frame_policy.js';
import { NODES, POOL, RANDOM_NODE } from '../../src/lib/nodes.js';
import { DEFAULT_PREFS } from '../../src/lib/store.js';
import { connectSources, ETH_RPC_HOSTS, DEFAULT_ETH_RPC, PRICE_HOST, TX_EXPLORER, originOf, txExplorerUrl } from '../../src/lib/eth/hosts.js';
import { buyConnectSources } from '../../src/lib/buy/hosts.js';

const pwa = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

test('the app offers exactly the nodes the CSP allows: the five-node pool, random by default', () => {
  assert.deepEqual(NODES, HEADER_NODES);
  assert.deepEqual(POOL.map((n) => n.address), [
    'eu-node02.mainnet.beam.mw:8200',
    'eu-node03.mainnet.beam.mw:8200',
    'eu-node04.mainnet.beam.mw:8200',
    'eu-nodes.mainnet.beam.mw:8200',
    'eu-node01.mainnet.beam.mw:8200',
  ]);
  assert.equal(DEFAULT_PREFS.node, RANDOM_NODE);
});

const connectSrc = (csp) => csp.split('; ').find((d) => d.startsWith('connect-src ')).split(' ').slice(1);

test('CSP without an own node: the static headers, unchanged', () => {
  assert.equal(securityHeaders(), SECURITY_HEADERS);
  assert.equal(securityHeaders(null), SECURITY_HEADERS);
  assert.ok(!connectSrc(CSP).some((s) => s.startsWith('wss://') && !HEADER_NODES.includes(s.slice(6))), 'only pool nodes are wss sources');
  assert.ok(!connectSrc(CSP).includes('wss:') && !connectSrc(CSP).includes('*'), 'no wildcard');
});

test('CSP with an own node: exactly one extra wss origin in connect-src, every other header and directive as before', () => {
  for (const [given, origin] of [
    ['127.0.0.1:9443', 'wss://127.0.0.1:9443'],
    ['wss://Node.Example.com:8200/', 'wss://node.example.com:8200'],
  ]) {
    const h = securityHeaders(given);
    for (const k of Object.keys(SECURITY_HEADERS)) if (k !== 'Content-Security-Policy') assert.equal(h[k], SECURITY_HEADERS[k], k);
    const before = CSP.split('; ');
    const after = h['Content-Security-Policy'].split('; ');
    assert.equal(after.length, before.length);
    for (let i = 0; i < before.length; i++) if (!before[i].startsWith('connect-src ')) assert.equal(after[i], before[i]);
    const extra = connectSrc(h['Content-Security-Policy']).filter((s) => !connectSrc(CSP).includes(s));
    assert.deepEqual(extra, [origin]);
    assert.deepEqual(connectSrc(h['Content-Security-Policy']).slice(0, -1), connectSrc(CSP), 'appended, nothing else moved');
  }
  // A pool node given as an own node adds nothing (it is already allowed).
  assert.equal(securityHeaders('eu-node03.mainnet.beam.mw:8200')['Content-Security-Policy'], CSP);
  // Anything that is not host:port never reaches the header.
  for (const bad of ["evil.com:443; script-src *", 'a.com:443 wss:', '*:443', 'wss://*.com:1', '[::1]:8200', 'h:1/x']) assert.throws(() => securityHeaders(bad), bad);
});

test('the own node is a page policy only: the loader keeps its own, the dApp frame policy is untouched', () => {
  assert.equal(headersFor('sw-0123456789abcdef.js')['Content-Security-Policy'], LOADER_CSP);
  assert.ok(!LOADER_CSP.includes('wss:'), 'the loader reaches no node');
  assert.equal(headersFor('index.html')['Content-Security-Policy'], CSP, 'deployments serve the static page policy');
  const withNode = securityHeaders('127.0.0.1:9443')['Content-Security-Policy'];
  assert.notEqual(withNode, LOADER_CSP);
  assert.ok(!frameCsp({ evalAllowed: true, remoteOrigins: REMOTE_ORIGINS, nonce: 'abcdefghijklmnop' }).includes('wss:'), 'dApp frames reach no node');
});

test('connect-src: this origin, the wss nodes, the pinned dApp package directory, the Ethereum servers of lib/eth/hosts.js and buybeam.my\'s buy API only (no explorer, no other host)', () => {
  const connect = CSP.split(';').map((d) => d.trim()).find((d) => d.startsWith('connect-src'));
  const sources = connect.split(/\s+/).slice(1);
  assert.deepEqual(sources, ["'self'", ...HEADER_NODES.map((n) => `wss://${n}`), DAPP_PACKAGE_SOURCE, ...connectSources(), ...buyConnectSources()]);
  // Buy BEAM: buybeam.my's buy API path only, never the whole host.
  assert.deepEqual(buyConnectSources(), ['https://buybeam.my/api/v1/buy/']);
  assert.ok(!sources.includes('https://buybeam.my'));
  assert.deepEqual(connectSources(), [
    'https://eth2.stackwallet.com',
    'https://ethereum-rpc.publicnode.com',
    'https://eth.drpc.org',
    'https://rpc.mevblocker.io',
    'https://eth-mainnet.public.blastapi.io',
    'https://api.coingecko.com/api/v3/simple/price',
  ]);
  assert.ok(ETH_RPC_HOSTS.some((h) => h.id === DEFAULT_ETH_RPC));
  assert.equal(originOf(ETH_RPC_HOSTS.find((h) => h.id === DEFAULT_ETH_RPC)), 'https://eth2.stackwallet.com', 'the desktop default');
  assert.ok(!sources.some((s) => s.includes(TX_EXPLORER.host)), 'the block explorer is a link the person taps, never contacted by the app');
  assert.match(DAPP_PACKAGE_SOURCE, /^https:\/\/raw\.githubusercontent\.com\/BeamMW\/beam-ui\/[0-9a-f]{40}\/ui\/apps\/mainnet\/$/);
  for (const e of CATALOGUE) assert.ok(sourceUrl(e).startsWith(DAPP_PACKAGE_SOURCE), e.fileName);
  assert.ok(!CSP.includes('explorer'), 'the explorer is reached through this origin');
  assert.ok(!CSP.includes("'unsafe-eval'") && !CSP.includes("'unsafe-inline'"));
});

test('the block explorer link is built only for a transaction hash', () => {
  const hash = `0x${'ab'.repeat(32)}`;
  assert.equal(txExplorerUrl(hash), `https://etherscan.io/tx/${hash}`);
  assert.equal(txExplorerUrl(hash.toUpperCase().replace('0X', '0x')), `https://etherscan.io/tx/${hash}`);
  for (const bad of ['', '0x12', `${hash}/../x`, `javascript:${hash}`, null]) assert.throws(() => txExplorerUrl(bad));
  assert.equal(PRICE_HOST.path, '/api/v3/simple/price');
});

test('cross-origin isolation headers are present', () => {
  assert.equal(SECURITY_HEADERS['Cross-Origin-Opener-Policy'], 'same-origin');
  assert.equal(SECURITY_HEADERS['Cross-Origin-Embedder-Policy'], 'require-corp');
});

test('deploy configs carry the same headers', () => {
  const nginx = readFileSync(join(pwa, 'deploy', 'nginx.conf'), 'utf8');
  const headers = readFileSync(join(pwa, 'deploy', '_headers'), 'utf8');
  for (const line of nginxHeaderLines()) assert.ok(nginx.includes(line), `nginx: ${line.slice(0, 60)}`);
  // nginx drops server-level add_header in any location that has its own: none may.
  const server = nginx.slice(nginx.indexOf('server {'));
  assert.ok(!/location[^{]*\{[^}]*add_header/.test(server), 'no add_header inside a location block');
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) assert.ok(headers.includes(`${k}: ${v}`), `_headers: ${k}`);
  assert.ok(nginx.includes('location = /explorer/status') && nginx.includes('location = /recovery/mainnet_recovery.bin'));
});

test('the loader gets its own policy (it may fetch signed updates from any https copy); pages keep theirs; release files are readable by any copy, the proxies are not', () => {
  assert.equal(LOADER_CSP, "default-src 'none'; connect-src 'self' https:");
  for (const p of ['sw-0123456789abcdef.js', '/sw-0123456789abcdef.js', 'sw.js']) assert.equal(headersFor(p)['Content-Security-Policy'], LOADER_CSP, p);
  for (const p of ['index.html', 'app.js', 'lib/sw-0123456789abcdef.js', 'vendor/engine/wasm-client.worker.js', 'release.json']) assert.equal(headersFor(p)['Content-Security-Policy'], CSP, p);
  assert.ok(!CSP.includes('https:;') && !/connect-src[^;]* https:( |;|$)/.test(CSP), 'the page policy names its hosts, never all of https');
  for (const p of ['index.html', 'release.json', 'release.sig', 'manifest.json', 'vendor/engine/wasm-client.wasm', 'sw-0123456789abcdef.js']) assert.equal(headersFor(p)['Access-Control-Allow-Origin'], '*', p);
  for (const p of PROXY_PATHS) assert.equal(headersFor(p)['Access-Control-Allow-Origin'], undefined, p);
  // Everything else is the same set on every path.
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) if (k !== 'Content-Security-Policy') assert.equal(headersFor('sw-0123456789abcdef.js')[k], v, k);
  const headers = readFileSync(join(pwa, 'deploy', '_headers'), 'utf8');
  assert.match(headers, /\n\/\*\n(?:  [^\n]+\n)*  Access-Control-Allow-Origin: \*\n/);
  assert.ok(headers.includes(`/sw-*.js\n  ! Content-Security-Policy\n  Content-Security-Policy: ${LOADER_CSP}\n`));
});

test('no source file reaches out to another origin', () => {
  const { readdirSync, statSync } = require_fs();
  const walk = (d) => readdirSync(d).flatMap((n) => (statSync(join(d, n)).isDirectory() ? walk(join(d, n)) : [join(d, n)]));
  const offenders = [];
  for (const f of walk(join(pwa, 'src'))) {
    if (!/\.(js|html|css|webmanifest)$/.test(f)) continue;
    const s = readFileSync(f, 'utf8');
    // Third-party code that runs only inside a sandboxed dApp frame (src/vendor/): its URLs are
    // references in comments. It must not make requests of its own.
    if (f.startsWith(join(pwa, 'src', 'vendor') + '/')) {
      assert.ok(!/\b(fetch\(|XMLHttpRequest|WebSocket|importScripts|sendBeacon|EventSource)/.test(s), `${f} makes requests`);
      continue;
    }
    for (const m of s.matchAll(/https?:\/\/[^\s'"`)<]+/g)) {
      const u = m[0];
      if (/^http:\/\/www\.w3\.org\/2000\/svg/.test(u)) continue; // SVG namespace, not a request
      // A link the person taps to download BEAM's own recovery file in the browser: a navigation
      // they choose, never a request by the app. Only this one, only on that screen.
      if (u === 'https://${RECOVERY_OFFICIAL}' && f.endsWith(join('screens', 'fast_start.js'))) continue;
      // Where BEAM publishes the dApp packages (fetched only when a dApp is first opened, and
      // checked against its pin), and the hosts a dApp may be granted, which its own sandboxed
      // frame contacts only when the person allows it. Only in these two files.
      if (u === 'https://raw.githubusercontent.com' && f.endsWith(join('lib', 'dapps', 'catalogue.js'))) continue;
      if (REMOTE_ORIGINS.includes(u) && (f.endsWith(join('lib', 'dapps', 'catalogue.js')) || f.endsWith(join('lib', 'dapps', 'frame_policy.js')))) continue;
      // The Ethereum servers (exactly what connect-src lists) and the block explorer's
      // address, whose transaction pages the person may open with a tap: only in this file.
      if (f.endsWith(join('lib', 'eth', 'hosts.js')) && (connectSources().includes(u) || u === originOf(TX_EXPLORER))) continue;
      // The public copies of the release, asked only by a tapped Check for updates (from the
      // loader, after this app's own address): exactly the list, only in this file.
      // Besides those, only the scheme it puts in front of a typed address, and its wording.
      if (f.endsWith(join('lib', 'update_sources.js')) && (BUILTIN_SOURCES.includes(u) || u === 'https://${s}' || u === 'https://.')) continue;
      offenders.push(`${f.slice(pwa.length)}: ${u}`);
    }
  }
  assert.deepEqual(offenders, []);
});

function require_fs() {
  return { readdirSync: (d) => readdirSyncImpl(d), statSync: (p) => statSyncImpl(p) };
}
import { readdirSync as readdirSyncImpl, statSync as statSyncImpl } from 'node:fs';

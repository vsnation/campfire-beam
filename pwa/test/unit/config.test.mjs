// The privacy-relevant configuration agrees everywhere it is written down.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { NODES as HEADER_NODES, CSP, SECURITY_HEADERS, DAPP_PACKAGE_SOURCE } from '../../tools/headers.mjs';
import { CATALOGUE, sourceUrl, REMOTE_ORIGINS } from '../../src/lib/dapps/catalogue.js';
import { NODES } from '../../src/lib/nodes.js';
import { DEFAULT_PREFS } from '../../src/lib/store.js';
import { connectSources, ETH_RPC_HOSTS, DEFAULT_ETH_RPC, PRICE_HOST, TX_EXPLORER, originOf, txExplorerUrl } from '../../src/lib/eth/hosts.js';

const pwa = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

test('the app offers exactly the nodes the CSP allows', () => {
  assert.deepEqual(NODES.map((n) => n.address), HEADER_NODES);
  assert.ok(HEADER_NODES.includes(DEFAULT_PREFS.node));
});

test('connect-src: this origin, the wss nodes, the pinned dApp package directory and the Ethereum servers of lib/eth/hosts.js only (no explorer, no other host)', () => {
  const connect = CSP.split(';').map((d) => d.trim()).find((d) => d.startsWith('connect-src'));
  const sources = connect.split(/\s+/).slice(1);
  assert.deepEqual(sources, ["'self'", ...HEADER_NODES.map((n) => `wss://${n}`), DAPP_PACKAGE_SOURCE, ...connectSources()]);
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
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) {
    assert.ok(nginx.includes(`add_header ${k} "${v}" always;`), `nginx: ${k}`);
    assert.ok(headers.includes(`${k}: ${v}`), `_headers: ${k}`);
  }
  assert.ok(nginx.includes('location = /explorer/status') && nginx.includes('location = /recovery/mainnet_recovery.bin'));
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
      offenders.push(`${f.slice(pwa.length)}: ${u}`);
    }
  }
  assert.deepEqual(offenders, []);
});

function require_fs() {
  return { readdirSync: (d) => readdirSyncImpl(d), statSync: (p) => statSyncImpl(p) };
}
import { readdirSync as readdirSyncImpl, statSync as statSyncImpl } from 'node:fs';

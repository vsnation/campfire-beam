// The privacy-relevant configuration agrees everywhere it is written down.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { NODES as HEADER_NODES, CSP, SECURITY_HEADERS } from '../../tools/headers.mjs';
import { NODES } from '../../src/lib/nodes.js';
import { DEFAULT_PREFS } from '../../src/lib/store.js';

const pwa = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

test('the app offers exactly the nodes the CSP allows', () => {
  assert.deepEqual(NODES.map((n) => n.address), HEADER_NODES);
  assert.ok(HEADER_NODES.includes(DEFAULT_PREFS.node));
});

test('connect-src: this origin and the wss nodes only (no explorer, no other host)', () => {
  const connect = CSP.split(';').map((d) => d.trim()).find((d) => d.startsWith('connect-src'));
  const sources = connect.split(/\s+/).slice(1);
  assert.deepEqual(sources, ["'self'", ...HEADER_NODES.map((n) => `wss://${n}`)]);
  assert.ok(!CSP.includes('explorer'), 'the explorer is reached through this origin');
  assert.ok(!CSP.includes("'unsafe-eval'") && !CSP.includes("'unsafe-inline'"));
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
    for (const m of s.matchAll(/https?:\/\/[^\s'"`)<]+/g)) {
      const u = m[0];
      if (/^http:\/\/www\.w3\.org\/2000\/svg/.test(u)) continue; // SVG namespace, not a request
      // A link the person taps to download BEAM's own recovery file in the browser: a navigation
      // they choose, never a request by the app. Only this one, only on that screen.
      if (u === 'https://${RECOVERY_OFFICIAL}' && f.endsWith(join('screens', 'fast_start.js'))) continue;
      offenders.push(`${f.slice(pwa.length)}: ${u}`);
    }
  }
  assert.deepEqual(offenders, []);
});

function require_fs() {
  return { readdirSync: (d) => readdirSyncImpl(d), statSync: (p) => statSyncImpl(p) };
}
import { readdirSync as readdirSyncImpl, statSync as statSyncImpl } from 'node:fs';

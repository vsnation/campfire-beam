// The security headers BEAM Campfire must be served with. One list, used by
// the dev server (tools/serve.mjs), the build (which writes deploy/_headers
// and checks deploy/nginx.conf against it) and the service worker (which
// re-applies them to every response it serves from its cache).
//
// Why each one:
// - COOP + COEP make the page cross-origin isolated. Without that there is no
//   SharedArrayBuffer, and BEAM's wasm engine (pthreads) cannot start.
// - CORP same-origin: no other site can embed our files.
// - CSP: scripts only from this origin; 'wasm-unsafe-eval' is what
//   WebAssembly.instantiate needs (no 'unsafe-eval': the engine is built with
//   DYNAMIC_EXECUTION=0). connect-src names the BEAM nodes, one dApp host and
//   the Ethereum servers:
//   the explorer check goes through this origin (/explorer/status), so the
//   wallet talks to this origin and the chosen node, plus BEAM's GitHub
//   (raw.githubusercontent.com, one directory at a pinned commit) only when
//   the person opens a dApp for the first time: that is where BEAM publishes
//   the dApp packages, and the app refuses any package whose SHA-256 differs
//   from its pin. dApps themselves run in sandboxed frames with their own,
//   stricter policy (src/lib/dapps/frame_policy.js); frames come from this
//   origin only (default-src 'self').
//   The Ethereum servers come from one list, src/lib/eth/hosts.js
//   (connectSources()): the five RPC servers the person can pick from (the
//   app talks to the one picked, never a fallback, and only once there is an
//   Ethereum wallet) and CoinGecko's price path for the bridge (only after
//   the person allows it). All six are in one release, because this policy is
//   inlined into the loader and changing it renames the loader.
//   Buy BEAM asks buybeam.my's buy API (src/lib/buy/hosts.js,
//   buyConnectSources()): that one path, not the whole host, and only once the
//   person opens Buy BEAM.

import { SOURCE_HOST, SOURCE_COMMIT } from '../src/lib/dapps/catalogue.js';
import { connectSources as ethConnectSources } from '../src/lib/eth/hosts.js';
import { buyConnectSources } from '../src/lib/buy/hosts.js';

export const NODES = [
  'eu-nodes.mainnet.beam.mw:8200',
  'eu-node01.mainnet.beam.mw:8200',
  'eu-node02.mainnet.beam.mw:8200',
];

/** The one directory BEAM's dApp packages are fetched from: beam-ui at the pinned commit (src/lib/dapps/catalogue.js). */
export const DAPP_PACKAGE_SOURCE = `${SOURCE_HOST}/BeamMW/beam-ui/${SOURCE_COMMIT}/ui/apps/mainnet/`;

export const CSP = [
  "default-src 'self'",
  "script-src 'self' 'wasm-unsafe-eval'",
  "worker-src 'self'",
  `connect-src 'self' ${NODES.map((n) => `wss://${n}`).join(' ')} ${DAPP_PACKAGE_SOURCE} ${ethConnectSources().join(' ')} ${buyConnectSources().join(' ')}`,
  "img-src 'self' data: blob:",
  "style-src 'self'",
  "font-src 'self'",
  "manifest-src 'self'",
  "frame-ancestors 'none'",
  "base-uri 'none'",
  "form-action 'none'",
  "object-src 'none'",
].join('; ');

export const SECURITY_HEADERS = {
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Embedder-Policy': 'require-corp',
  'Cross-Origin-Resource-Policy': 'same-origin',
  'Content-Security-Policy': CSP,
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=(), usb=(), bluetooth=()',
};

export const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  '.webmanifest': 'application/manifest+json',
  '.wasm': 'application/wasm',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ttf': 'font/ttf',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
  '.sig': 'text/plain; charset=utf-8',
  '.jwk': 'application/json',
};

export function mimeFor(path) {
  const i = path.lastIndexOf('.');
  return (i >= 0 && MIME[path.slice(i).toLowerCase()]) || 'application/octet-stream';
}

// Upstreams the deployment proxies under this origin.
export const RECOVERY_UPSTREAM = 'https://mobile-restore.beam.mw/mainnet/mainnet_recovery.bin';
export const EXPLORER_UPSTREAMS = [
  'https://explorer.0xmx.net/api/status',
  'https://beamsmart.net:8000/status',
];

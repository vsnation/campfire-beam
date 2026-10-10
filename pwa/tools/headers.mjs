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
//   DYNAMIC_EXECUTION=0). connect-src names the BEAM node pool
//   (src/lib/nodes.js), one dApp host and the Ethereum servers. The person's
//   own BEAM node, when they add one, is added by the service worker to the
//   pages and workers it serves (securityHeaders(node) below, the same function
//   inlined into sw.js): exactly that wss origin, never a wildcard. A static
//   host's headers never name it; they only cover the first load, before the
//   service worker takes over.
//   The explorer check goes through this origin (/explorer/status), so the
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
//   BEAM's recovery snapshot, on a copy hosted without a relay, comes from
//   BEAM Campfire's own server (src/lib/recovery.js,
//   recoveryConnectSources()): that one path.

import { SOURCE_HOST, SOURCE_COMMIT } from '../src/lib/dapps/catalogue.js';
import { connectSources as ethConnectSources } from '../src/lib/eth/hosts.js';
import { buyConnectSources } from '../src/lib/buy/hosts.js';
import { recoveryConnectSources } from '../src/lib/recovery.js';
import { NODES as POOL_NODES } from '../src/lib/nodes.js';
import { cspWithNode } from '../src/lib/node_address.js';

export const NODES = [...POOL_NODES];

/** The one directory BEAM's dApp packages are fetched from: beam-ui at the pinned commit (src/lib/dapps/catalogue.js). */
export const DAPP_PACKAGE_SOURCE = `${SOURCE_HOST}/BeamMW/beam-ui/${SOURCE_COMMIT}/ui/apps/mainnet/`;

export const CSP = [
  "default-src 'self'",
  "script-src 'self' 'wasm-unsafe-eval'",
  "worker-src 'self'",
  `connect-src 'self' ${NODES.map((n) => `wss://${n}`).join(' ')} ${DAPP_PACKAGE_SOURCE} ${ethConnectSources().join(' ')} ${buyConnectSources().join(' ')} ${recoveryConnectSources().join(' ')}`,
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

// The loader (sw-<hash>.js) is a worker, not a page: the policy on ITS response
// decides what it may fetch, and the browser applies it every time the worker
// starts. It fetches releases: from this origin, or, when that does not answer
// a tapped "Check for updates", from the copies in src/lib/update_sources.js or
// an address the person added - any https address, since a downloaded file is
// kept only after the release signature and its SHA-256 checked out. It runs no
// other script and loads nothing else. Pages keep CSP above (the loader puts
// SECURITY_HEADERS on every page it serves): pages never fetch updates.
export const LOADER_CSP = ["default-src 'none'", "connect-src 'self' https:"].join('; ');
export const LOADER_FILE = /^sw(-[0-9a-f]+)?\.js$/;

// Every file of a release may be read by any origin, so any copy of the app can
// serve updates to installs whose own address is gone (GitHub Pages already
// sends this). Not on the two same-origin proxies below: they are no relay for
// other sites.
export const RELEASE_CORS = { 'Access-Control-Allow-Origin': '*' };
export const PROXY_PATHS = ['/recovery/mainnet_recovery.bin', '/explorer/status'];

/** The headers a deployment sends for a path under the app's folder (rel: path relative to it, no leading slash). */
export function headersFor(rel) {
  const clean = String(rel).replace(/^\/+/, '');
  const h = { ...SECURITY_HEADERS };
  if (LOADER_FILE.test(clean)) h['Content-Security-Policy'] = LOADER_CSP;
  if (!PROXY_PATHS.includes(`/${clean}`)) Object.assign(h, RELEASE_CORS);
  return h;
}

/**
 * What deploy/nginx.conf must contain (tools/build.mjs and the unit tests check
 * it): every header, the page policy and the loader's from one map on $uri,
 * and CORS from another (empty on the proxies, which nginx then leaves out).
 */
export function nginxHeaderLines() {
  const lines = [];
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) if (k !== 'Content-Security-Policy') lines.push(`add_header ${k} "${v}" always;`);
  lines.push('add_header Content-Security-Policy $campfire_csp always;');
  lines.push('add_header Access-Control-Allow-Origin $campfire_acao always;');
  lines.push(`default "${CSP}";`);
  lines.push(`"~/sw(-[0-9a-f]+)?\\.js$" "${LOADER_CSP}";`);
  for (const p of PROXY_PATHS) lines.push(`${p} "";`);
  return lines;
}

/**
 * A page's (or a page worker's) headers with the person's own node ("host:port")
 * in connect-src; null: SECURITY_HEADERS unchanged. The loader serves pages with
 * this; its own response keeps LOADER_CSP above.
 */
export function securityHeaders(ownNode = null) {
  return ownNode == null ? SECURITY_HEADERS : { ...SECURITY_HEADERS, 'Content-Security-Policy': cspWithNode(CSP, ownNode) };
}

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

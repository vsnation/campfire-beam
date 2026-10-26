// The security headers Beam PWA must be served with. One list, used by
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
//   "Pay with BTC, ZEC or LTC" asks NEAR Intents' 1Click API
//   (src/lib/intents/hosts.js, intentsConnectSources()): that one path, not
//   the whole host, and only once the person opens that screen.
//   BEAM's recovery snapshot, on a copy hosted without a relay, comes from
//   Beam PWA's own server (src/lib/recovery.js,
//   recoveryConnectSources()): that one path.

import { SOURCE_HOST, SOURCE_COMMIT } from '../src/lib/dapps/catalogue.js';
import { connectSources as ethConnectSources } from '../src/lib/eth/hosts.js';
import { buyConnectSources } from '../src/lib/buy/hosts.js';
import { intentsConnectSources } from '../src/lib/intents/hosts.js';
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
  `connect-src 'self' ${NODES.map((n) => `wss://${n}`).join(' ')} ${DAPP_PACKAGE_SOURCE} ${ethConnectSources().join(' ')} ${buyConnectSources().join(' ')} ${intentsConnectSources().join(' ')} ${recoveryConnectSources().join(' ')}`,
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
  // camera=(self): Send's Scan reads an address QR code with the camera (lib/qr_scan.js), in
  // this page only; dApp frames keep camera=() (lib/dapps/frame_policy.js) and are sandboxed
  // into an opaque origin, which 'self' never matches.
  'Permissions-Policy': 'camera=(self), microphone=(), geolocation=(), payment=(), usb=(), bluetooth=()',
  // HSTS: after one visit the browser goes straight to https for a year, so a first http:// link
  // or typed address on a hostile network cannot be answered with an imitation that asks for the
  // recovery words. This host only: includeSubDomains or preload would bind every site under the
  // parent domain (the owner's decision, not this file's). A response the loader builds from its
  // cache carries it too; browsers take it from network responses only, so there it changes nothing.
  'Strict-Transport-Security': 'max-age=31536000',
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
// sends this).
export const RELEASE_CORS = { 'Access-Control-Allow-Origin': '*' };

// The two proxies a deployment serves on this origin (deploy/nginx.conf, deploy/Caddyfile).
export const RECOVERY_RELAY = '/recovery/mainnet_recovery.bin';
export const EXPLORER_PROXY = '/explorer/status';
export const PROXY_PATHS = [RECOVERY_RELAY, EXPLORER_PROXY];

// BEAM's recovery snapshot, relayed here: every copy of the app without a relay
// of its own (GitHub Pages, jsDelivr, static mirrors) restores through this one
// (lib/recovery.js RECOVERY_FALLBACK), so any origin may read it, read-only.
// Resuming sends Range and If-Range (If-Range is not a simple header: the browser
// asks first with OPTIONS) and reads ETag and Content-Range. The engine checks the
// file against the chain's proof of work, whoever serves it. The explorer proxy
// stays this origin's own: no CORS there.
export const RECOVERY_CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, HEAD',
  'Access-Control-Allow-Headers': 'Range, If-Range',
  'Access-Control-Expose-Headers': 'Content-Length, Content-Range, ETag, Last-Modified',
  'Access-Control-Max-Age': '86400',
  'Cross-Origin-Resource-Policy': 'cross-origin',
};

// App files are revalidated on every load (a CDN must not mix two releases). The
// relay keeps BEAM's own caching headers, so a CDN in front can hold the 330 MB
// file instead of fetching it again for every restore.
export const CACHE_CONTROL = 'no-cache';

/** The headers a deployment sends for a path under the app's folder (rel: path relative to it, no leading slash). */
export function headersFor(rel) {
  const clean = String(rel).replace(/^\/+/, '');
  const h = { ...SECURITY_HEADERS };
  if (LOADER_FILE.test(clean)) h['Content-Security-Policy'] = LOADER_CSP;
  if (`/${clean}` === RECOVERY_RELAY) Object.assign(h, RECOVERY_CORS);
  else if (`/${clean}` !== EXPLORER_PROXY) Object.assign(h, RELEASE_CORS);
  return h;
}

/** Cache-Control a deployment sends for a path (null: the upstream's own, on the relay). */
export function cacheControlFor(rel) {
  return `/${String(rel).replace(/^\/+/, '')}` === RECOVERY_RELAY ? null : CACHE_CONTROL;
}

// Headers that differ by path, as nginx variables: [header, variable, default, {path or "~regex": value}].
// An empty value means nginx leaves the header out. headersFor() above says the same, path by path.
function nginxPathRules() {
  const R = RECOVERY_RELAY;
  return [
    ['Content-Security-Policy', '$campfire_csp', CSP, { '~^/sw(-[0-9a-f]+)?\\.js$': LOADER_CSP }],
    ['Cross-Origin-Resource-Policy', '$campfire_corp', SECURITY_HEADERS['Cross-Origin-Resource-Policy'], { [R]: RECOVERY_CORS['Cross-Origin-Resource-Policy'] }],
    ['Access-Control-Allow-Origin', '$campfire_acao', RELEASE_CORS['Access-Control-Allow-Origin'], { [EXPLORER_PROXY]: '' }],
    ['Access-Control-Allow-Methods', '$campfire_acam', '', { [R]: RECOVERY_CORS['Access-Control-Allow-Methods'] }],
    ['Access-Control-Allow-Headers', '$campfire_acah', '', { [R]: RECOVERY_CORS['Access-Control-Allow-Headers'] }],
    ['Access-Control-Expose-Headers', '$campfire_aceh', '', { [R]: RECOVERY_CORS['Access-Control-Expose-Headers'] }],
    ['Access-Control-Max-Age', '$campfire_acma', '', { [R]: RECOVERY_CORS['Access-Control-Max-Age'] }],
    ['Cache-Control', '$campfire_cache', CACHE_CONTROL, { [R]: '' }],
  ];
}

/**
 * What deploy/nginx.conf must contain (tools/build.mjs and the unit tests check
 * it): an add_header for every header at server level (nginx drops them in any
 * location with an add_header of its own, so none may have one), and a map on
 * $uri for each header that differs by path. The maps belong to the http context.
 */
export function nginxHeaderLines() {
  const lines = [];
  const rules = nginxPathRules();
  const byPath = new Set(rules.map((r) => r[0]));
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) if (!byPath.has(k)) lines.push(`add_header ${k} "${v}" always;`);
  for (const [k, variable] of rules) lines.push(`add_header ${k} ${variable} always;`);
  for (const [, variable, def, paths] of rules) {
    const entries = Object.entries(paths).map(([p, v]) => `    ${p.startsWith('~') ? `"${p}"` : p} "${v}";`);
    lines.push([`map $uri ${variable} {`, `    default "${def}";`, ...entries, '}'].join('\n'));
  }
  return lines;
}

/**
 * What deploy/Caddyfile must contain (tools/build.mjs and the unit tests check
 * it). Caddy runs every matching header directive, so a field set in the block
 * for every response and again for one path ends up with whichever ran last:
 * a header that differs by path is therefore set by matchers that never both
 * match (@loader/@page for the policy, @relay/@files for the relay's CORS and
 * caching, @cors for everything but the explorer proxy), and the block for
 * every response carries the rest. The loader's name is sw-<hash>.js (LOADER_FILE).
 */
export function caddyHeaderLines() {
  const lines = [];
  const byPath = new Set(['Content-Security-Policy', 'Cross-Origin-Resource-Policy']);
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) if (!byPath.has(k)) lines.push(`\t\t${k} "${v}"`);
  lines.push('\t@loader path /sw-*.js /sw.js');
  lines.push('\t@page not path /sw-*.js /sw.js');
  lines.push(`\theader @page Content-Security-Policy "${CSP}"`);
  lines.push(`\theader @loader Content-Security-Policy "${LOADER_CSP}"`);
  lines.push(`\t@relay path ${RECOVERY_RELAY}`);
  lines.push(`\t@files not path ${RECOVERY_RELAY}`);
  lines.push(`\theader @files {\n\t\tCross-Origin-Resource-Policy "${SECURITY_HEADERS['Cross-Origin-Resource-Policy']}"\n\t\tCache-Control "${CACHE_CONTROL}"\n\t}`);
  lines.push(['\theader @relay {', ...Object.entries(RECOVERY_CORS).map(([k, v]) => `\t\t${k} "${v}"`), '\t}'].join('\n'));
  lines.push(`\t@cors not path ${EXPLORER_PROXY}`);
  lines.push(`\theader @cors Access-Control-Allow-Origin "${RELEASE_CORS['Access-Control-Allow-Origin']}"`);
  lines.push(...caddyMimeLines());
  return lines;
}

/**
 * Content-Type exactly as the loader serves it (MIME below): Caddy would take it from the
 * system's mime.types or sniff it. One matcher per type; anything else is plain bytes, as with
 * nginx's default_type (the folder itself and the two proxies keep theirs).
 */
function caddyMimeLines() {
  const byType = new Map();
  for (const [ext, type] of Object.entries(MIME)) byType.set(type, [...(byType.get(type) || []), `*${ext}`]);
  const lines = [];
  for (const [type, globs] of byType) {
    const name = `mime_${type.split(';')[0].replace(/[^a-z0-9]+/g, '_')}`;
    lines.push(`\t@${name} path ${globs.join(' ')}`);
    lines.push(`\theader @${name} Content-Type "${type}"`);
  }
  const all = Object.keys(MIME).map((e) => `*${e}`).join(' ');
  lines.push(`\t@mime_other {\n\t\tnot path ${all}\n\t\tnot path / ${RECOVERY_RELAY} ${EXPLORER_PROXY}\n\t}`);
  lines.push('\theader @mime_other Content-Type "application/octet-stream"');
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

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
//   DYNAMIC_EXECUTION=0). connect-src names the BEAM nodes and nothing else:
//   the explorer check goes through this origin (/explorer/status), so the
//   browser talks to exactly two parties, this origin and the chosen node.

export const NODES = [
  'eu-nodes.mainnet.beam.mw:8200',
  'eu-node01.mainnet.beam.mw:8200',
  'eu-node02.mainnet.beam.mw:8200',
];

export const CSP = [
  "default-src 'self'",
  "script-src 'self' 'wasm-unsafe-eval'",
  "worker-src 'self'",
  `connect-src 'self' ${NODES.map((n) => `wss://${n}`).join(' ')}`,
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

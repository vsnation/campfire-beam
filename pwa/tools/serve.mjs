// BEAM Campfire dev server. Node only, no dependencies.
//
//   node tools/serve.mjs [--port 8780] [--root dist|src|<dir>] [--selftest]
//                        [--result-file <path>] [--quiet]
//
// - Serves --root (default dist/) with the production headers (tools/headers.mjs
//   headersFor(): the page policy, the loader's own, CORS on the app's files).
//   The root may be a symlink; it is resolved on every request, so tests can
//   switch releases by re-pointing it.
// - Proxies /recovery/mainnet_recovery.bin (BEAM's recovery file, which has no
//   CORS headers) by streaming it: nothing is written to disk.
// - Proxies /explorer/status (independent chain height), so the page itself
//   only ever talks to this origin and the BEAM node.
// - Listens on loopback only and refuses Host headers that are not loopback
//   (DNS rebinding).
// - --selftest enables /__dev/flags and POST /__dev/result, which the in-page
//   self-test (?selftest=1 on localhost) uses to report back. Without the flag
//   both answer 404, which is what any production host does.
// - With --selftest also /__dev/dapp-probe.html (test/e2e/dapp_probe/): the dApp frame probe.
// - --import-test <dir> (with --selftest): serves <dir>/wallet.db at /__dev/import.db and
//   <dir>/import.json ({password, addresses}) at /__dev/import.json for the wallet.db import
//   self-test (?selftest=import). Throwaway test wallets only; 404 otherwise.
import http from 'node:http';
import https from 'node:https';
import { createReadStream } from 'node:fs';
import { stat, realpath, writeFile, readFile } from 'node:fs/promises';
import { join, normalize, sep, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SECURITY_HEADERS, headersFor, mimeFor, RECOVERY_UPSTREAM, EXPLORER_UPSTREAMS } from './headers.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const pwaRoot = join(here, '..');

function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  if (i < 0) return def;
  const v = process.argv[i + 1];
  return v === undefined || v.startsWith('--') ? true : v;
}

const port = Number(arg('port', process.env.PORT || 8780));
const rootArg = arg('root', 'dist');
const rootDir = rootArg === 'dist' || rootArg === 'src' ? join(pwaRoot, rootArg) : resolve(String(rootArg));
const selftest = Boolean(arg('selftest', false));
const resultFile = arg('result-file', null);
const importTestDir = arg('import-test', null);
const quiet = Boolean(arg('quiet', false));
const verbose = Boolean(arg('verbose', false));
// Dev only: serve a local copy of the recovery file instead of proxying BEAM's (saves a 330 MB download per test run).
const recoveryFile = arg('recovery-file', process.env.BEAM_RECOVERY_FILE || null);

const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);

function log(...a) {
  if (!quiet) console.log(new Date().toISOString().slice(11, 19), ...a);
}

function baseHeaders(extra = {}) {
  return { ...SECURITY_HEADERS, 'Cache-Control': 'no-cache', ...extra };
}

function send(res, code, body, type = 'text/plain; charset=utf-8', extra = {}) {
  const buf = Buffer.from(body);
  res.writeHead(code, baseHeaders({ 'Content-Type': type, 'Content-Length': buf.length, ...extra }));
  res.end(buf);
}

function upstreamGet(url, method, timeoutMs) {
  return new Promise((ok, fail) => {
    const req = https.request(url, { method, timeout: timeoutMs, headers: { 'User-Agent': 'beam-campfire-dev' } }, ok);
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', fail);
    req.end();
  });
}

async function proxyRecovery(req, res) {
  if (recoveryFile) {
    const st = await stat(String(recoveryFile));
    res.writeHead(200, baseHeaders({ 'Content-Type': 'application/octet-stream', 'Content-Length': st.size }));
    if (req.method === 'HEAD') return res.end();
    log('recovery from local file', st.size);
    return createReadStream(String(recoveryFile)).pipe(res);
  }
  let up;
  try {
    up = await upstreamGet(RECOVERY_UPSTREAM, req.method, 30000);
  } catch (e) {
    return send(res, 502, `recovery upstream: ${e.message}`);
  }
  const h = baseHeaders({ 'Content-Type': 'application/octet-stream' });
  if (up.headers['content-length']) h['Content-Length'] = up.headers['content-length'];
  if (up.headers['last-modified']) h['Last-Modified'] = up.headers['last-modified'];
  res.writeHead(up.statusCode === 200 ? 200 : 502, h);
  if (req.method === 'HEAD') {
    up.resume();
    return res.end();
  }
  up.pipe(res);
  req.on('close', () => up.destroy());
  log('recovery proxy', up.statusCode, up.headers['content-length']);
}

async function proxyExplorer(req, res) {
  for (const url of EXPLORER_UPSTREAMS) {
    try {
      const up = await upstreamGet(url, 'GET', 4000);
      const chunks = [];
      for await (const c of up) chunks.push(c);
      if (up.statusCode !== 200) continue;
      const j = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (typeof j.height !== 'number') continue;
      // Only what the app uses: height and block time.
      return send(res, 200, JSON.stringify({ height: j.height, timestamp: Math.floor(Number(j.timestamp) || 0) }), 'application/json');
    } catch {
      // next
    }
  }
  return send(res, 503, JSON.stringify({ error: 'no explorer answered' }), 'application/json');
}

async function serveFile(req, res, pathname) {
  let root;
  try {
    root = await realpath(rootDir);
  } catch {
    return send(res, 500, `root ${rootArg} does not exist (run npm run build)`);
  }
  let rel = decodeURIComponent(pathname);
  if (rel.endsWith('/')) rel += 'index.html';
  const full = normalize(join(root, rel));
  if (!full.startsWith(root + sep)) return send(res, 403, 'forbidden');
  let st;
  try {
    st = await stat(full);
  } catch {
    return send(res, 404, 'not found');
  }
  if (!st.isFile()) return send(res, 404, 'not found');
  res.writeHead(200, { ...headersFor(pathname), 'Cache-Control': 'no-cache', 'Content-Type': mimeFor(full), 'Content-Length': st.size });
  if (req.method === 'HEAD') return res.end();
  createReadStream(full).pipe(res);
}

async function readBody(req, limit = 256 * 1024) {
  const chunks = [];
  let n = 0;
  for await (const c of req) {
    n += c.length;
    if (n > limit) throw new Error('body too large');
    chunks.push(c);
  }
  return Buffer.concat(chunks).toString('utf8');
}

const server = (host) =>
  http.createServer(async (req, res) => {
    try {
      const hostHeader = String(req.headers.host || '').replace(/:\d+$/, '');
      if (!LOOPBACK_HOSTS.has(hostHeader)) return send(res, 421, 'loopback only');
      const url = new URL(req.url, `http://localhost:${port}`);
      const p = url.pathname;
      if (verbose) res.on('finish', () => log(req.method, p, res.statusCode, String(req.headers['user-agent'] || '').slice(0, 40)));
      if (p === '/__dev/flags') {
        if (!selftest || req.method !== 'GET') return send(res, 404, 'not found');
        return send(res, 200, JSON.stringify({ selftest: true, importTest: Boolean(importTestDir) }), 'application/json');
      }
      if (p === '/__dev/import.db' || p === '/__dev/import.json') {
        if (!selftest || !importTestDir || req.method !== 'GET') return send(res, 404, 'not found');
        const name = p === '/__dev/import.db' ? 'wallet.db' : 'import.json';
        const body = await readFile(join(String(importTestDir), name));
        return send(res, 200, body, name === 'wallet.db' ? 'application/octet-stream' : 'application/json', { 'Cache-Control': 'no-store' });
      }
      if (p === '/__dev/dapp-probe.html' || p === '/__dev/dapp-probe.js' || p === '/__dev/probe-dapp.js') {
        // The dApp frame probe (test/e2e/dapp_probe/), for Safari on the iOS Simulator.
        if (!selftest || req.method !== 'GET') return send(res, 404, 'not found');
        const name = p.slice('/__dev/'.length);
        const body = await readFile(join(pwaRoot, 'test', 'e2e', 'dapp_probe', name));
        return send(res, 200, body, mimeFor(name), { 'Cache-Control': 'no-store' });
      }
      if (p === '/__dev/result') {
        if (!selftest || req.method !== 'POST') return send(res, 404, 'not found');
        const body = await readBody(req);
        let parsed;
        try {
          parsed = JSON.parse(body);
        } catch {
          return send(res, 400, 'bad json');
        }
        const line = JSON.stringify(parsed);
        console.log(`SELFTEST_RESULT ${line}`);
        if (resultFile) await writeFile(String(resultFile), line + '\n', { flag: 'a' });
        return send(res, 200, '{"ok":true}', 'application/json');
      }
      if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'method not allowed');
      if (p === '/recovery/mainnet_recovery.bin') return proxyRecovery(req, res);
      if (p === '/explorer/status') return proxyExplorer(req, res);
      return serveFile(req, res, p);
    } catch (e) {
      log('error', e.message);
      if (!res.headersSent) send(res, 500, 'server error');
      else res.destroy();
    }
  }).listen(port, host, () => log(`BEAM Campfire dev server: http://localhost:${port}/ (root ${rootDir}, ${host}${selftest ? ', selftest on' : ''})`));

server('127.0.0.1');
server('::1').on('error', () => {}); // no IPv6 loopback: fine

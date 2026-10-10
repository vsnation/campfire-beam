// Test-only BEAM node relays: a TLS WebSocket endpoint on 127.0.0.1 with a
// self-signed certificate (the browser under test runs with
// --ignore-certificate-errors) that relays the raw WebSocket byte stream to a
// real BEAM mainnet node over its own, verified TLS connection. It counts every
// connection, by the name the browser asked for (TLS SNI; none for an IP).
//
// Per-name behaviour, changeable while it runs:
//   forward - relay both ways (the node answers);
//   refuse  - close the connection as soon as TLS is up (a node that refuses);
//   silent  - relay the upgrade so the WebSocket opens, then drop everything the
//             node sends (a node that accepts and never answers).
import tls from 'node:tls';
import net from 'node:net';
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

/** A throwaway self-signed certificate for 127.0.0.1, localhost and the pool names. */
export function selfSignedCert(dir) {
  mkdirSync(dir, { recursive: true });
  const key = join(dir, 'relay-key.pem');
  const cert = join(dir, 'relay-cert.pem');
  execFileSync('openssl', [
    'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes',
    '-keyout', key, '-out', cert, '-days', '2', '-subj', '/CN=campfire-test-relay',
    '-addext', 'subjectAltName=IP:127.0.0.1,DNS:localhost,DNS:*.mainnet.beam.mw',
  ], { stdio: 'ignore' });
  return { key: readFileSync(key), cert: readFileSync(cert) };
}

function derToPem(der) {
  const b64 = Buffer.from(der).toString('base64').replace(/(.{64})/g, '$1\n');
  return `-----BEGIN CERTIFICATE-----\n${b64.trim()}\n-----END CERTIFICATE-----\n`;
}

/**
 * Roots for the relay's own upstream TLS: Node's store plus the issuers named in
 * eu-node01's certificate (Authority Information Access: Let's Encrypt YE1 and
 * Root YE, cross-signed by ISRG Root X2). eu-node01 sends only its own
 * certificate; browsers fetch the rest themselves, Node does not.
 */
export async function upstreamCa() {
  const extra = [];
  for (const u of ['http://ye1.i.lencr.org/', 'http://ye.i.lencr.org/']) {
    try {
      const r = await fetch(u, { signal: AbortSignal.timeout(8000) });
      if (r.ok) extra.push(derToPem(new Uint8Array(await r.arrayBuffer())));
    } catch {
      /* the full-chain nodes verify without it */
    }
  }
  return [...tls.rootCertificates, ...extra];
}

/**
 * @param {object} o
 * @param {number} o.port
 * @param {{key, cert}} o.tlsCert
 * @param {string[]} o.ca               roots for the upstream connections
 * @param {(name: string) => string} o.behaviour  'forward' | 'refuse' | 'silent'
 * @param {(name: string) => {host: string, port: number}} o.upstream
 */
export function startRelay({ port, tlsCert, ca, behaviour = () => 'forward', upstream }) {
  const counts = new Map();
  const log = [];
  const live = new Set();
  let total = 0;
  const server = tls.createServer({ key: tlsCert.key, cert: tlsCert.cert }, (client) => {
    const name = client.servername || 'ip';
    const how = behaviour(name);
    total++;
    counts.set(name, (counts.get(name) || 0) + 1);
    log.push({ name, how, at: Date.now() });
    live.add(client);
    client.on('close', () => live.delete(client));
    client.on('error', () => {});
    if (how === 'refuse') return client.destroy();
    const up = upstream(name);
    const u = tls.connect({ host: up.host, port: up.port, servername: up.host, ca, rejectUnauthorized: true });
    live.add(u);
    u.on('close', () => {
      live.delete(u);
      client.destroy();
    });
    u.on('error', () => client.destroy());
    client.on('close', () => u.destroy());
    client.on('data', (d) => u.write(d));
    let headersDone = false;
    let head = Buffer.alloc(0);
    u.on('data', (d) => {
      if (how !== 'silent') return client.write(d);
      if (headersDone) return; // the node answers; nothing reaches the wallet
      head = Buffer.concat([head, d]);
      const end = head.indexOf('\r\n\r\n');
      if (end >= 0) {
        headersDone = true;
        client.write(head.subarray(0, end + 4));
      }
    });
  });
  server.on('tlsClientError', () => {});
  return new Promise((resolve) => {
    server.listen(port, '127.0.0.1', () =>
      resolve({
        port,
        counts,
        log,
        get total() {
          return total;
        },
        stop: () =>
          new Promise((r) => {
            for (const s of live) s.destroy();
            server.close(() => r());
          }),
      }),
    );
  });
}

/** A TLS listener that only counts connections: something must never reach it. */
export function startCanary(port, tlsCert) {
  let total = 0;
  const server = tls.createServer({ key: tlsCert.key, cert: tlsCert.cert }, (s) => {
    total++;
    s.destroy();
  });
  const raw = { n: 0 };
  server.on('connection', () => raw.n++);
  server.on('tlsClientError', () => {});
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve({ get total() { return total; }, get tcp() { return raw.n; }, stop: () => new Promise((r) => server.close(() => r())) })));
}

/** Accepts TCP and never answers: a node address that hangs. */
export function startBlackhole(port) {
  const socks = new Set();
  const server = net.createServer((s) => {
    socks.add(s);
    s.on('error', () => {});
    s.on('close', () => socks.delete(s));
  });
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve({ stop: () => new Promise((r) => { for (const s of socks) s.destroy(); server.close(() => r()); }) })));
}

/** A port on 127.0.0.1 nothing listens on. */
export async function deadPort() {
  const s = net.createServer();
  await new Promise((r) => s.listen(0, '127.0.0.1', r));
  const { port } = s.address();
  await new Promise((r) => s.close(r));
  return port;
}

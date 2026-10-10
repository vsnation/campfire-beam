// The own-node address: what is accepted, how it is written, and what can reach a CSP.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { normalizeNodeAddress, nodeOrigin, cspWithNode, probeCsp, PROBE_ID } from '../../src/lib/node_address.js';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src');
const ok = (input, address) => {
  const r = normalizeNodeAddress(input);
  assert.equal(r.ok, true, `${JSON.stringify(input)}: ${r.error}`);
  assert.equal(r.address, address, JSON.stringify(input));
};
const bad = (input, code) => {
  const r = normalizeNodeAddress(input);
  assert.equal(r.ok, false, `${JSON.stringify(input)} was accepted as ${r.address}`);
  assert.equal(r.code, code, `${JSON.stringify(input)}: ${r.error}`);
  assert.ok(r.error.length > 10 && !/invalid|error/i.test(r.error), `a plain sentence: ${r.error}`);
};

test('accepted: host names and IPv4 with a port, written in one canonical form', () => {
  ok('node.example.com:8200', 'node.example.com:8200');
  ok('  Node.Example.COM:8200  ', 'node.example.com:8200');
  ok('127.0.0.1:9443', '127.0.0.1:9443');
  ok('localhost:8200', 'localhost:8200');
  ok('my-node.duckdns.org:443', 'my-node.duckdns.org:443');
  ok('node.example.com.:8200', 'node.example.com:8200');
  ok('a.b:1', 'a.b:1');
  ok('a.b:65535', 'a.b:65535');
  ok('bücher.de:8200', 'xn--bcher-kva.de:8200');
});

test('a pasted wss:// address is accepted and the scheme and a trailing slash are stripped', () => {
  ok('wss://node.example.com:8200', 'node.example.com:8200');
  ok('WSS://node.example.com:8200/', 'node.example.com:8200');
  ok('wss://127.0.0.1:9443/', '127.0.0.1:9443');
});

test('refused with a plain reason: other schemes, credentials, paths, IPv6, ports, hosts', () => {
  bad('', 'empty');
  bad('   ', 'empty');
  bad(null, 'empty');
  bad('ws://node.example.com:8200', 'insecure');
  bad('https://node.example.com:8200', 'scheme');
  bad('http://node.example.com:8200', 'scheme');
  bad('user:pass@node.example.com:8200', 'credentials');
  bad('wss://user@node.example.com:8200', 'credentials');
  bad('node.example.com:8200/ws', 'path');
  bad('node.example.com:8200?x=1', 'path');
  bad('node.example.com:8200#x', 'path');
  bad('wss://node.example.com:8200//', 'path');
  bad('[::1]:8200', 'ipv6');
  bad('2001:db8::1', 'ipv6');
  bad('node.example.com', 'port');
  bad('node.example.com:', 'port');
  bad('node.example.com:0', 'port');
  bad('node.example.com:65536', 'port');
  bad('node.example.com:-1', 'port');
  bad('node.example.com:80a', 'port');
  bad('node.example.com:123456', 'port');
  bad('node example.com:8200', 'host');
  bad('-node.example.com:8200', 'host');
  bad('node-.example.com:8200', 'host');
  bad('node..example.com:8200', 'host');
  bad('node_1.example.com:8200', 'host');
  bad('*.example.com:8200', 'host');
  bad(':8200', 'host');
  bad('256.1.1.1:8200', 'host');
  bad('1.2.3:8200', 'host');
  bad('010.0.0.1:8200', 'host');
  bad('1.2.3.4.5:8200', 'host');
  bad(`${'a'.repeat(64)}.com:8200`, 'host');
  bad("evil.com:443;script-src", 'port');
});

test('nothing but [a-z0-9.-], one colon and digits survives', () => {
  const inputs = ['a.b:1', 'wss://X.Y:2/', '127.0.0.1:9443', 'bücher.de:8200', 'evil.com:443; script-src *', "a'b:1", 'a"b:1', 'a,b:1', 'a b:1', 'a\nb:1'];
  for (const i of inputs) {
    const r = normalizeNodeAddress(i);
    if (r.ok) assert.match(r.address, /^[a-z0-9.-]+:[0-9]{1,5}$/, i);
  }
});

test('nodeOrigin and the CSP helpers', () => {
  assert.equal(nodeOrigin('wss://A.b:9/'), 'wss://a.b:9');
  assert.throws(() => nodeOrigin('a.b'));
  const csp = "default-src 'self'; connect-src 'self' wss://x.y:1; frame-ancestors 'none'";
  assert.equal(cspWithNode(csp, null), csp);
  assert.equal(cspWithNode(csp, '127.0.0.1:9443'), "default-src 'self'; connect-src 'self' wss://x.y:1 wss://127.0.0.1:9443; frame-ancestors 'none'");
  assert.equal(cspWithNode(csp, 'x.y:1'), csp, 'already allowed: unchanged');
  assert.throws(() => cspWithNode(csp, 'x.y'));
  assert.equal(probeCsp('wss://N.example:8200'), "default-src 'none'; script-src 'self'; connect-src wss://n.example:8200; frame-ancestors 'self'; base-uri 'none'; form-action 'none'; object-src 'none'");
  assert.throws(() => probeCsp('n.example'));
  assert.ok(PROBE_ID.test('abcdefgh12') && !PROBE_ID.test('ABC') && !PROBE_ID.test('a/b'));
});

test('the loader inlines the address check and uses it for every header it builds', () => {
  const sw = readFileSync(join(src, 'sw.js'), 'utf8');
  assert.match(sw, /\/\*__INLINE_NODE_ADDRESS_JS__\*\//);
  assert.match(sw, /pageHeaders\(await readOwnNode\(\)\)/, 'pages and workers get the own node');
  assert.match(sw, /request\.destination !== 'iframe'/, 'the node check is served only as a frame');
  assert.match(sw, /probeCsp\(n\.address\)/);
  assert.ok(!/^import /m.test(readFileSync(join(src, 'lib', 'node_address.js'), 'utf8')), 'node_address.js imports nothing (it is inlined)');
  const probe = readFileSync(join(src, 'node_probe.js'), 'utf8');
  assert.match(probe, /window\.parent !== window/, 'the check runs only inside the app');
  assert.match(probe, /postMessage\([^)]*location\.origin\)/, 'it answers this origin only');
});

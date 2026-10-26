// The loader's sentences (sw.js and what is inlined into it: lib/release.js, lib/update_sources.js,
// lib/node_address.js) stay English in those files (changing their bytes renames the loader or
// changes its loader_compat); the screens show them through lib/loader_words.js loaderText(). This
// lists every word-like literal of those files: each has its templates there, or the reason it is
// never shown. A new sentence in those files fails here until it is listed and has a template.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { scanSource } from '../../tools/i18n_scan.mjs';
import { LOADER_WORDS, loaderTemplate, loaderText } from '../../src/lib/loader_words.js';
import { activateLanguage, t } from '../../src/lib/i18n.js';
import { normalizeNodeAddress, NODE_EXAMPLE } from '../../src/lib/node_address.js';
import { verifyManifest, verifyFile, ReleaseError } from '../../src/lib/release.js';
import { normalizeSource } from '../../src/lib/update_sources.js';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src');
const FILES = ['lib/release.js', 'lib/update_sources.js', 'lib/node_address.js', 'sw.js'];

// Source text (as the scanner gives it: {…} where a value goes) -> its templates in LOADER_WORDS, or a
// string: why it is never shown to a person.
const MAP = {
  'Release key must be a public P-256 JWK.': ['Release key must be a public P-256 JWK.'],
  'The release signature is not readable.': ['The release signature is not readable.'],
  'This update is not signed with the BEAM Campfire release key.': ['This update is not signed with the BEAM Campfire release key.'],
  'release.json is not JSON.': ['release.json is not JSON.'],
  'release.json is missing fields.': ['release.json is missing fields.'],
  "This update's file list is not the one that was signed.": ["This update's file list is not the one that was signed."],
  'manifest.json does not belong to this release.': ['manifest.json does not belong to this release.'],
  'File count differs from the signed release.': ['File count differs from the signed release.'],
  'Bad file path in manifest: {…}': ['Bad file path in manifest: {path}'],
  'Duplicate path {…}': ['Duplicate path {path}'],
  'Bad entry for {…}': ['Bad entry for {path}'],
  'A file in this update ({…}) is not the one that was signed.': ['A file in this update ({path}) is not the one that was signed.'],
  'No BEAM Campfire release is published at this address.': ['No BEAM Campfire release is published at this address.'],
  'unknown error': ['unknown error'],
  'A different release claims version {…}.': ['A different release claims version {version}.'],
  'Paste the address of a copy of BEAM Campfire.': ['Paste the address of a copy of BEAM Campfire.'],
  'That address is too long.': ['That address is too long.'],
  "That isn't a web address.": ["That isn't a web address."],
  'Use an address that starts with https://.': ['Use an address that starts with https://.'],
  'Leave out the user name and password: the address must work without them.': ['Leave out the user name and password: the address must work without them.'],
  "Type your node's address, for example {…}.": ["Type your node's address, for example {example}."],
  'The app connects to nodes over a secure connection (wss) only. Type the address without ws://, like {…}.': ['The app connects to nodes over a secure connection (wss) only. Type the address without ws://, like {example}.'],
  'Leave out {…} and type only the host and port, like {…}.': ['Leave out {scheme} and type only the host and port, like {example}.'],
  'Leave out the user name and password: type only the host and port, like {…}.': ['Leave out the user name and password: type only the host and port, like {example}.'],
  'Leave out everything after the port: type only the host and port, like {…}.': ['Leave out everything after the port: type only the host and port, like {example}.'],
  'An address has no spaces. It looks like {…}.': ['An address has no spaces. It looks like {example}.'],
  "IPv6 addresses can't be used here. Use the node's host name or its IPv4 address.": ["IPv6 addresses can't be used here. Use the node's host name or its IPv4 address."],
  'Add the port your node accepts wallets on (its websocket_port), like {…}.': ['Add the port your node accepts wallets on (its websocket_port), like {example}.'],
  'The port must be a number from 1 to 65535.': ['The port must be a number from 1 to 65535.'],
  'That is not a host name or an IPv4 address. It looks like {…}.': ['That is not a host name or an IPv4 address. It looks like {example}.'],
  'not a node address': 'nodeOrigin() is only called with an address already checked: an internal error',
  "default-src 'none'": 'CSP text', "script-src 'self'": 'CSP text', 'connect-src {…}': 'CSP text', "frame-ancestors 'self'": 'CSP text',
  "base-uri 'none'": 'CSP text', "form-action 'none'": 'CSP text', "object-src 'none'": 'CSP text', "default-src 'none'; sandbox": 'CSP text', 'use strict': 'a directive',
  // sw.js: ` from ${host}` is put after the file's path; each sentence is written both ways.
  ' from {…}': 'a part of the sentences below (where = own ? "" : " from host"): their templates cover both forms',
  'Could not download {…}{…}.': ['Could not download {path}.', 'Could not download {path} from {host}.'],
  '{…}{…}: HTTP {…}': ['{path}: HTTP {status}', '{path} from {host}: HTTP {status}'],
  '{…}{…} is far larger than a BEAM Campfire release file.': ['{path} is far larger than a BEAM Campfire release file.', '{path} from {host} is far larger than a BEAM Campfire release file.'],
  'The download of {…}{…} was interrupted.': ['The download of {path} was interrupted.', 'The download of {path} from {host} was interrupted.'],
};
// Sentences the loader writes that the scanner does not see as words (a property named reason).
const EXTRA = ['unknown request'];

test("every sentence of the loader's code is listed: templates for the shown ones, a reason for the rest", () => {
  const found = new Set();
  for (const f of FILES) {
    for (const it of scanSource(readFileSync(join(src, f), 'utf8'), f).items) if (it.kind === 'text') found.add(it.value);
  }
  assert.deepEqual([...found].filter((x) => !(x in MAP)), [], 'new sentences: list them here and give them templates in lib/loader_words.js');
  assert.deepEqual(Object.keys(MAP).filter((x) => !found.has(x)), [], 'listed here but gone from the files');
  const templates = new Set(Object.values(MAP).filter(Array.isArray).flat().concat(EXTRA));
  assert.deepEqual([...templates].filter((x) => !LOADER_WORDS.includes(x)), [], 'missing from LOADER_WORDS');
  assert.deepEqual(LOADER_WORDS.filter((x) => !templates.has(x)), [], 'in LOADER_WORDS but written by nothing');
  assert.ok(readFileSync(join(src, 'sw.js'), 'utf8').includes("reason: 'unknown request'"));
});

test('a sentence is matched back to its own template with its values, the longest template first', () => {
  const fill = (tpl) => tpl.replace(/\{(\w+)\}/g, (m, k) => ({ path: 'lib/app.js', host: 'mirror.test:8812', status: '503', example: NODE_EXAMPLE, scheme: 'https://', version: '0.2.15' })[k]);
  for (const tpl of LOADER_WORDS) {
    const s = fill(tpl);
    const r = loaderTemplate(s);
    assert.ok(r, s);
    assert.equal(r.template, tpl, s);
    // English: the same sentence, but with the app's present name (the loader still writes BEAM Campfire).
    assert.equal(loaderText(s), s.replaceAll('BEAM Campfire', 'Beam PWA'), 'English: the same sentence');
  }
  assert.deepEqual(loaderTemplate('Could not download app.js from mirror.test:8812.'), { template: 'Could not download {path} from {host}.', params: { path: 'app.js', host: 'mirror.test:8812' } });
  assert.equal(loaderTemplate('Something the engine said.'), null);
  assert.equal(loaderText('Something the engine said.'), 'Something the engine said.');
  assert.equal(loaderText(undefined), undefined);
});

test('what the inlined code really writes has a template: node addresses, manifests, files', async () => {
  for (const bad of ['', 'ws://n.example:8200', 'https://n.example:8200', 'u:p@n.example:8200', 'n.example:8200/x', 'n example:8200', '[::1]:8200', 'n.example', 'n.example:99999', 'bad_host!:8200']) {
    const r = normalizeNodeAddress(bad);
    assert.equal(r.ok, false, bad);
    assert.ok(loaderTemplate(r.error), `${bad}: ${r.error}`);
  }
  for (const bad of ['', 'x'.repeat(5000), 'http://copy.example/', 'https://u:p@copy.example/', 'https://']) {
    const r = normalizeSource(bad);
    assert.equal(r.ok, false, bad);
    assert.ok(loaderTemplate(r.reason), `${bad.slice(0, 20)}: ${r.reason}`);
  }
  const release = { app: 'beam-campfire-pwa', version: '1.0.0', manifest_sha256: '0'.repeat(64) };
  await assert.rejects(verifyManifest(release, new TextEncoder().encode('{}')), (e) => e instanceof ReleaseError && Boolean(loaderTemplate(e.message)));
  await assert.rejects(verifyFile({ path: 'app.js', size: 3, sha256: '0'.repeat(64) }, new Uint8Array(2)), (e) => Boolean(loaderTemplate(e.message)));
});

test('in another language the template is translated and the values put back as text', async () => {
  const catalog = {
    'Could not download {path} from {host}.': 'Не удалось скачать {path} с {host}.',
    'An address has no spaces. It looks like {example}.': 'В адресе нет пробелов. Он выглядит так: {example}.',
  };
  const fetchImpl = async () => ({ ok: true, json: async () => catalog });
  const storage = { getItem: () => null, setItem() {}, removeItem() {} };
  const doc = { documentElement: { setAttribute() {} } };
  try {
    await activateLanguage('ru', { storage, doc, fetchImpl, notify: false });
    assert.equal(loaderText('Could not download app.js from <b>x</b>.'), 'Не удалось скачать app.js с <b>x</b>.');
    assert.equal(loaderText(normalizeNodeAddress('n example:8200').error), `В адресе нет пробелов. Он выглядит так: ${NODE_EXAMPLE}.`);
    assert.equal(loaderText('Could not download app.js.'), 'Could not download app.js.', 'not translated yet: English');
    assert.equal(t('Reload'), 'Reload');
  } finally {
    await activateLanguage('en', { storage, doc, notify: false });
  }
});

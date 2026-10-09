// The .dapp zip reader: what it reads, and what it refuses.
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { readZip, ZipError, pathSegments, crc32 } from '../../src/lib/dapps/zip.js';
import { makeZip } from './helpers/zipwriter.mjs';

const text = (b) => new TextDecoder().decode(b);
const refuses = async (bytes, code, re) => {
  await assert.rejects(readZip(bytes), (e) => e instanceof ZipError && e.code === code && (!re || re.test(e.message)));
};

test('reads a deflated and a stored entry, in archive order', async () => {
  const big = 'console.log("hello");\n'.repeat(500);
  const z = makeZip([
    { name: 'manifest.json', data: '{"name":"x"}', method: 0 },
    { name: 'app/', data: '' , method: 0 },
    { name: 'app/index.js', data: big, method: 8 },
  ]);
  const files = await readZip(z);
  assert.deepEqual([...files.keys()], ['manifest.json', 'app/index.js']);
  assert.equal(text(files.get('manifest.json')), '{"name":"x"}');
  assert.equal(text(files.get('app/index.js')), big);
});

test('CRC-32 matches the zip polynomial', () => {
  assert.equal(crc32(new TextEncoder().encode('123456789')), 0xcbf43926);
  assert.equal(crc32(new Uint8Array(0)), 0);
});

test('a damaged entry is refused (CRC), stored or deflated', async () => {
  await refuses(makeZip([{ name: 'a.txt', data: 'abc', method: 0, crc: 1 }]), 'corrupt', /CRC/);
  await refuses(makeZip([{ name: 'a.txt', data: 'abc'.repeat(100), method: 8, crc: 1 }]), 'corrupt', /CRC/);
});

test('a deflate stream that inflates past its declared size is cut off', async () => {
  await refuses(makeZip([{ name: 'bomb.bin', data: new Uint8Array(100000), method: 8, size: 1000 }]), 'too_large');
});

test('names that climb out, are absolute, odd or collide are refused', async () => {
  for (const name of ['../evil.js', 'app/../../evil.js', '/etc/passwd', 'app//x.js', 'app/./x.js', 'a\\b.js', 'con.txt', 'x.js.', 'app/x?.js']) {
    await refuses(makeZip([{ name, data: 'x', method: 0 }]), 'unsafe_path', undefined);
  }
  await refuses(makeZip([{ name: 'App.js', data: 'x', method: 0 }, { name: 'app.js', data: 'y', method: 0 }]), 'unsafe_path', /case/);
  await refuses(makeZip([{ name: 'a', data: 'x', method: 0 }, { name: 'a/b.js', data: 'y', method: 0 }]), 'unsafe_path');
  assert.deepEqual(pathSegments('app/assets/beam asset minter.png'), ['app', 'assets', 'beam asset minter.png']);
});

test('symlinks, encryption, zip64 and other methods are refused', async () => {
  await refuses(makeZip([{ name: 'link', data: '/etc/passwd', method: 0, externalAttr: 0o120777 << 16 }]), 'unsafe_path', /symlink/);
  await refuses(makeZip([{ name: 'a.txt', data: 'x', method: 0, flags: 0x0001 }]), 'unsupported', /encrypted/);
  await refuses(makeZip([{ name: 'a.txt', data: 'x', method: 0 }], { zip64Locator: true }), 'unsupported', /zip64/);
  const z = makeZip([{ name: 'a.txt', data: 'x', method: 0 }]);
  // method 12 (bzip2), in the local header (offset 8) and the central one (offset 10)
  const bad = z.slice();
  bad[8] = 12;
  for (let i = 0; i < bad.length - 4; i++) if (bad[i] === 0x50 && bad[i + 1] === 0x4b && bad[i + 2] === 1 && bad[i + 3] === 2) bad[i + 10] = 12;
  await refuses(bad, 'unsupported', /method 12/);
});

test("local and central names must agree; entry count must match", async () => {
  await refuses(makeZip([{ name: 'a.txt', localName: 'b.txt', data: 'x', method: 0 }]), 'format', /names differ/);
  await refuses(makeZip([{ name: 'a.txt', data: 'x', method: 0 }], { countOverride: 2 }), 'format');
  await refuses(new Uint8Array(100), 'format');
});

test('macOS metadata is checked, then dropped', async () => {
  const files = await readZip(makeZip([{ name: '__MACOSX/app/._index.js', data: 'x', method: 0 }, { name: 'app/.DS_Store', data: 'y', method: 0 }, { name: 'app/index.js', data: 'z', method: 0 }]));
  assert.deepEqual([...files.keys()], ['app/index.js']);
});

test('the 9 real packages unpack (when the local cache has them)', async (t) => {
  const dir = process.env.CFB_DAPP_PACKAGES || join(homedir(), '.cache', 'campfire-beam', 'dapps');
  if (!existsSync(join(dir, 'dex-app.dapp'))) return t.skip('no cached packages');
  const { CATALOGUE } = await import('../../src/lib/dapps/catalogue.js');
  for (const e of CATALOGUE) {
    const files = await readZip(readFileSync(join(dir, e.fileName)));
    assert.ok(files.has('manifest.json'), e.fileName);
    assert.ok(files.has('app/index.html'), e.fileName);
  }
});

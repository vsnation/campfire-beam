import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { SHADERS, verifyShader, loadShader } from '../../src/lib/shaders.js';
import { checkShaders, REPO_ROOT } from '../../tools/shader_check.mjs';

test('the shaders in the repository match their pins and the desktop app pins the same bytes', async () => {
  const list = await checkShaders();
  assert.deepEqual(list.map((s) => s.key).sort(), ['airdrop', 'amm', 'bans', 'minter', 'pipe', 'pipeReverse']);
});

/** A copy of the parts of the repository checkShaders reads. */
function repoCopy() {
  const dir = mkdtempSync(join(tmpdir(), 'campfire-shaders-'));
  for (const pin of Object.values(SHADERS)) {
    for (const rel of [join('assets', 'beam', 'shaders', pin.file), pin.dart]) {
      mkdirSync(dirname(join(dir, rel)), { recursive: true });
      copyFileSync(join(REPO_ROOT, rel), join(dir, rel));
    }
  }
  return dir;
}

test('the build refuses a shader whose bytes changed', async () => {
  const dir = repoCopy();
  try {
    const f = join(dir, 'assets', 'beam', 'shaders', SHADERS.amm.file);
    const b = readFileSync(f);
    b[100] ^= 1;
    writeFileSync(f, b);
    await assert.rejects(checkShaders(dir), /amm_app\.wasm: sha256 .* does not match the pin/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the build refuses when the desktop pins a different shader', async () => {
  const dir = repoCopy();
  try {
    const f = join(dir, SHADERS.bans.dart);
    writeFileSync(f, readFileSync(f, 'utf8').replace(SHADERS.bans.sha256, '0'.repeat(64)));
    await assert.rejects(checkShaders(dir), /bans_constants\.dart does not pin/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the two bridge shaders share one Dart file, and each pin is checked against it', async () => {
  assert.equal(SHADERS.pipe.dart, SHADERS.pipeReverse.dart);
  for (const [key, edit] of [
    ['pipeReverse', (t) => t.replace(SHADERS.pipeReverse.sha256, '0'.repeat(64))],
    ['pipe', (t) => t.replace(`= ${SHADERS.pipe.size};`, `= ${SHADERS.pipe.size + 1};`)],
  ]) {
    const dir = repoCopy();
    try {
      const f = join(dir, SHADERS[key].dart);
      writeFileSync(f, edit(readFileSync(f, 'utf8')));
      await assert.rejects(checkShaders(dir), new RegExp(`${SHADERS[key].file.replace('.', '\\.')}: .*pipe_constants\\.dart does not pin`));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

test('the page checks a shader again before using it, and does not cache a failure', async () => {
  const good = new Uint8Array(readFileSync(join(REPO_ROOT, 'assets', 'beam', 'shaders', SHADERS.minter.file)));
  const bad = good.slice();
  bad[10] ^= 0xff;
  await verifyShader('minter', good);
  await assert.rejects(verifyShader('minter', bad), (e) => e.code === 'mismatch');
  await assert.rejects(verifyShader('minter', good.slice(1)), (e) => e.code === 'mismatch');
  const asked = [];
  const fetchWith = (bytes) => async (url) => {
    asked.push(url);
    return { ok: true, arrayBuffer: async () => bytes.buffer.slice(0) };
  };
  await assert.rejects(loadShader('minter', { fetchImpl: fetchWith(bad) }), (e) => e.code === 'mismatch');
  const ok = await loadShader('minter', { fetchImpl: fetchWith(good) });
  assert.equal(ok.length, SHADERS.minter.size);
  assert.deepEqual(asked, ['shaders/minter_app.wasm', 'shaders/minter_app.wasm']);
  await assert.rejects(loadShader('nope'), (e) => e.code === 'unknown');
});

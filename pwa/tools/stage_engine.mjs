// Copies the pinned BEAM wasm engine into vendor/engine/ (git-ignored).
// Source: $BEAM_WASM_OUT, default ~/Desktop/Beam/beam-core-build/wasm/out.
// Refuses, and copies nothing, unless every file matches engine.lock.json.
import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdir, rename } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const lock = JSON.parse(await readFile(join(root, 'engine.lock.json'), 'utf8'));
const src = process.env.BEAM_WASM_OUT || join(homedir(), 'Desktop', 'Beam', 'beam-core-build', 'wasm', 'out');
const dst = join(root, 'vendor', 'engine');

const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');

const loaded = {};
let bad = 0;
for (const [name, want] of Object.entries(lock.files)) {
  let buf;
  try {
    buf = await readFile(join(src, name));
  } catch (e) {
    console.error(`stage_engine: missing ${name} in the engine directory (set BEAM_WASM_OUT): ${e.code}`);
    bad++;
    continue;
  }
  const got = sha256(buf);
  if (got !== want) {
    console.error(`stage_engine: REFUSED ${name}: sha256 ${got} != pinned ${want}`);
    bad++;
    continue;
  }
  loaded[name] = buf;
}
if (bad) {
  console.error(`stage_engine: ${bad} problem(s); vendor/engine was not changed.`);
  process.exit(1);
}
await mkdir(dst, { recursive: true });
for (const [name, buf] of Object.entries(loaded)) {
  const tmp = join(dst, `.${name}.tmp`);
  await writeFile(tmp, buf);
  await rename(tmp, join(dst, name));
  console.log(`stage_engine: ${name} ${lock.files[name].slice(0, 12)}… ${buf.length} bytes`);
}

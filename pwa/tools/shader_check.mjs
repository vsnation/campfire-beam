// Checks the app shaders the PWA ships against their pins (src/lib/shaders.js)
// and against the desktop app's Dart constants, so the two apps cannot drift
// apart: one pin, two apps. Used by tools/build.mjs and the unit tests.
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SHADERS } from '../src/lib/shaders.js';

const here = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = join(here, '..', '..');
const sha256 = (b) => createHash('sha256').update(b).digest('hex');

/**
 * Every pinned shader, read from <repo>/assets/beam/shaders/. Throws when a
 * file's size or SHA-256 differs from its pin, or when the desktop's Dart file
 * does not pin the same hash and size.
 * @returns {Promise<Array<{key: string, file: string, bytes: Buffer}>>}
 */
export async function checkShaders(repoRoot = REPO_ROOT, pins = SHADERS) {
  const out = [];
  for (const [key, pin] of Object.entries(pins)) {
    let bytes;
    try {
      bytes = await readFile(join(repoRoot, 'assets', 'beam', 'shaders', pin.file));
    } catch {
      throw new Error(`shader ${pin.file} (${key}) is missing from assets/beam/shaders`);
    }
    if (bytes.length !== pin.size) throw new Error(`shader ${pin.file}: ${bytes.length} bytes, pinned ${pin.size}`);
    const got = sha256(bytes);
    if (got !== pin.sha256) throw new Error(`shader ${pin.file}: sha256 ${got} does not match the pin ${pin.sha256}`);
    const dart = await readFile(join(repoRoot, pin.dart), 'utf8').catch(() => '');
    if (!dart.includes(`'${pin.sha256}'`)) throw new Error(`shader ${pin.file}: ${pin.dart} does not pin ${pin.sha256}`);
    if (!new RegExp(`=\\s*${pin.size}\\s*;`).test(dart)) throw new Error(`shader ${pin.file}: ${pin.dart} does not pin the size ${pin.size}`);
    out.push({ key, file: pin.file, bytes });
  }
  return out;
}

// A real, throwaway BEAM wallet.db for the import e2e, made by BEAM's own
// 7.5.14493 core: the native beam-wallet CLI that scripts/beam/core builds
// (~/Desktop/Beam/beam-core-build/out/macos-arm64/beam-wallet, or
// $BEAM_WALLET_CLI). A random password, a temporary directory, nothing
// printed: the CLI's output holds the new seed phrase, so it is read for
// "wallet successfully created" and the addresses only, then dropped. The
// password reaches the CLI in a 0600 config file that is deleted right after
// (never on argv).
import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync, existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomBytes, createHash } from 'node:crypto';

export const BEAM_CLI = process.env.BEAM_WALLET_CLI || join(homedir(), 'Desktop', 'Beam', 'beam-core-build', 'out', 'macos-arm64', 'beam-wallet');
export const WANT_CORE = '7.5.14493';

export function cliVersion(scratch) {
  if (!existsSync(BEAM_CLI)) return null;
  mkdirSync(scratch, { recursive: true });
  const r = spawnSync(BEAM_CLI, ['--version'], { cwd: scratch, encoding: 'utf8', timeout: 30000 });
  const m = String(r.stdout || '').match(/\b\d+\.\d+\.\d+\b/);
  return m ? m[0] : null;
}

function runCli(dir, command, password) {
  const cfg = join(dir, `.${randomBytes(6).toString('hex')}.cfg`);
  writeFileSync(cfg, `pass=${password}\n`, { mode: 0o600 });
  try {
    return spawnSync(BEAM_CLI, [command, `--wallet_path=${join(dir, 'wallet.db')}`, `--config_file=${cfg}`, '--log_level=info', '--file_log_level=error'], { cwd: dir, encoding: 'utf8', timeout: 120000 });
  } finally {
    rmSync(cfg, { force: true });
  }
}

/**
 * @returns {{path:string, password:string, addresses:string[], sha256:string, size:number}}
 */
export function makeWalletDb(dir) {
  mkdirSync(dir, { recursive: true });
  const password = `imp-${randomBytes(9).toString('base64url')}`;
  const init = runCli(dir, 'init', password);
  const created = init.status === 0 && /wallet successfully created/i.test(`${init.stdout}${init.stderr}`);
  if (!created) throw new Error(`beam-wallet init failed (exit ${init.status}); output withheld: it can contain a seed phrase`);
  const list = runCli(dir, 'address_list', password);
  const addresses = [...new Set([...String(list.stdout).matchAll(/^Address:\s+([0-9a-f]{40,})\s*$/gm)].map((m) => m[1]))];
  rmSync(join(dir, 'logs'), { recursive: true, force: true });
  const path = join(dir, 'wallet.db');
  const bytes = readFileSync(path);
  return { path, password, addresses, sha256: createHash('sha256').update(bytes).digest('hex'), size: bytes.length };
}

export function sha256File(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

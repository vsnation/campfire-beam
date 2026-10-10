// A real, throwaway BEAM wallet.db for the import e2e, made by BEAM's own
// 7.5.14493 core: the native beam-wallet CLI that scripts/beam/core builds
// (~/Desktop/Beam/beam-core-build/out/macos-arm64/beam-wallet, or
// $BEAM_WALLET_CLI). A random password, a temporary directory, nothing
// printed: the CLI's output holds the new seed phrase, so it is read for
// "wallet successfully created" and the addresses only, then dropped. The
// password reaches the CLI in a 0600 config file that is deleted right after
// (never on argv).
import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync, existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
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

/**
 * Opens a wallet.db with BEAM's native 7.5.14493 CLI - the same core the
 * desktop app's "Import wallet.db" uses (WalletDB::open) - in a scratch copy, so
 * the file under test is not changed. Returns whether it opened, and its addresses.
 * The CLI output is read for those two things only and never printed.
 */
export function openWithCli(file, password, scratch) {
  mkdirSync(scratch, { recursive: true });
  const dir = join(scratch, `cli-${randomBytes(4).toString('hex')}`);
  mkdirSync(dir);
  writeFileSync(join(dir, 'wallet.db'), readFileSync(file));
  try {
    const info = runCli(dir, 'info', password);
    const infoOut = `${info.stdout}${info.stderr}`;
    const opened = info.status === 0 && /wallet successfully opened/i.test(infoOut) && !/invalid password|file is not a database/i.test(infoOut);
    const list = opened ? runCli(dir, 'address_list', password) : { stdout: '' };
    const addresses = [...new Set([...String(list.stdout).matchAll(/^Address:\s+([0-9a-f]{40,})\s*$/gm)].map((m) => m[1]))];
    return { opened, addresses };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/**
 * `beam-wallet export_owner_key` on a scratch copy of `file`: the owner key as
 * BEAM's own CLI exports it, encrypted with `password`; null when the
 * password does not open the file. The key is returned, never printed.
 */
export function cliOwnerKey(file, password, scratch) {
  mkdirSync(scratch, { recursive: true });
  const dir = join(scratch, `okey-${randomBytes(4).toString('hex')}`);
  mkdirSync(dir);
  writeFileSync(join(dir, 'wallet.db'), readFileSync(file));
  try {
    const r = runCli(dir, 'export_owner_key', password);
    const m = String(r.stdout).match(/^Owner Viewer key:\s*(\S+)\s*$/m);
    return r.status === 0 && m ? m[1] : null;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

export const BEAM_NODE = process.env.BEAM_NODE_CLI || join(dirname(BEAM_CLI), 'beam-node');

/**
 * Starts BEAM's native beam-node on a throwaway storage with
 * --owner_key=<key> --pass=<password> (both in a 0600 config file, deleted
 * once the node has read it, never on argv), and no peer it can reach, so it
 * syncs nothing. Waits until the node lists its owned accounts, says
 * "key import failed", or exits; then stops it. The output is parsed, never
 * printed: the owned-accounts line names an endpoint derived from the key.
 * @returns {Promise<{accepted:boolean, rejected:boolean, accounts:number, version:string|null}>}
 */
export async function nodeReadsOwnerKey(key, password, scratch, { timeoutMs = 30000 } = {}) {
  mkdirSync(scratch, { recursive: true });
  const dir = join(scratch, `node-${randomBytes(4).toString('hex')}`);
  mkdirSync(dir);
  const cfg = join(dir, `.${randomBytes(6).toString('hex')}.cfg`);
  writeFileSync(cfg, `owner_key=${key}\npass=${password}\n`, { mode: 0o600 });
  const port = 20000 + (randomBytes(2).readUInt16BE(0) % 20000);
  const args = [`--port=${port}`, `--storage=${join(dir, 'node.db')}`, `--config_file=${cfg}`, '--peer=127.0.0.1:1', '--stratum_port=0', '--websocket_port=0', '--log_level=info', '--file_log_level=error'];
  const proc = spawn(BEAM_NODE, args, { cwd: dir, stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  const result = await new Promise((resolve) => {
    const done = () => {
      clearTimeout(timer);
      const owned = out.match(/Owned accounts :\r?\n((?:\t\S+\r?\n?)*)/);
      const accounts = owned ? owned[1].split(/\r?\n/).filter((l) => /^\t\S+/.test(l)).length : 0;
      const version = (out.match(/Beam Node (\d+\.\d+\.\d+)/) || [])[1] || null;
      resolve({ accepted: accounts > 0 && !/key import failed/.test(out), rejected: /key import failed/.test(out), accounts, version });
    };
    const onData = (d) => {
      out += String(d);
      if (out.includes('Reading config from') && existsSync(cfg)) rmSync(cfg, { force: true });
      if (/Owned accounts :\r?\n\t\S+/.test(out) || /key import failed/.test(out)) setTimeout(done, 300);
    };
    proc.stdout.on('data', onData);
    proc.stderr.on('data', onData);
    proc.on('exit', () => setTimeout(done, 50));
    const timer = setTimeout(done, timeoutMs);
  });
  proc.kill('SIGTERM');
  await new Promise((r) => (proc.exitCode !== null || proc.signalCode !== null ? r() : proc.once('exit', r)));
  rmSync(dir, { recursive: true, force: true });
  return result;
}

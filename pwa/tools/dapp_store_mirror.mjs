#!/usr/bin/env node
// Brings Beam PWA's copy of BEAM's DApp Store up to date (lib/dapps/store_install.js reads it).
//
//   node tools/dapp_store_mirror.mjs <hosting dir> [--dry-run]
//
// 1. Reads the store from the chain exactly as the app does: this build, in headless Chrome, with a
//    throwaway wallet that holds nothing (two free view calls; nothing is signed or sent).
// 2. For every listed IPFS hash with no `<hosting dir>/dapp-store/<hash>.dapp` yet, downloads the
//    package from BEAM's own IPFS nodes (http://eu-node0N.mainnet.beam.mw:6200/ipfs/<hash>, plain
//    http: fine here, because nothing is kept unless it re-hashes to exactly that IPFS hash, with the
//    same code the app uses, lib/dapps/ipfs_hash.js).
// 3. Writes it there. Packages no longer listed are kept (someone may still have that version).
// The hosting dir is then committed and published like a release (scratchpad deploy script).
import { mkdirSync, writeFileSync, existsSync, readdirSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { matchesCid, CIDV0 } from '../src/lib/dapps/ipfs_hash.js';
import { startServer, launch, PWA } from '../test/e2e/harness.mjs';
import { createWallet, waitHome, waitSynced } from '../test/e2e/flows.mjs';

const NODES = ['eu-node01', 'eu-node02', 'eu-node03', 'eu-node04'].map((n) => `http://${n}.mainnet.beam.mw:6200`);
const MAX = 32 * 1024 * 1024;
const TIMEOUT_MS = 60000;

const [, , hostDir, flag] = process.argv;
if (!hostDir) {
  console.error('usage: node tools/dapp_store_mirror.mjs <hosting dir> [--dry-run]');
  process.exit(2);
}
const dir = join(hostDir, 'dapp-store');
const dry = flag === '--dry-run';

async function readListedCids() {
  const tmp = mkdtempSync(join(tmpdir(), 'campfire-mirror-'));
  const dist = join(tmp, 'dist');
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', dist, '--quiet'], { cwd: PWA });
  const srv = await startServer({ root: dist, port: 8839 });
  const browser = await launch();
  try {
    const page = await (await browser.newContext()).newPage();
    await page.goto(srv.url);
    await createWallet(page, { password: `mirror-${Math.random().toString(36).slice(2, 10)}` });
    await waitHome(page);
    await waitSynced(page);
    return await page.evaluate(async () => {
      const { storeData } = await import('./screens/dapp_store.js');
      const s = await storeData();
      return s.dapps.map((d) => ({ cid: d.cid, name: d.name, publisher: (s.publishers.get(d.publisher) || {}).name || '' }));
    });
  } finally {
    await browser.close();
    srv.stop();
    rmSync(tmp, { recursive: true, force: true });
  }
}

async function download(cid) {
  for (const base of NODES) {
    try {
      const r = await fetch(`${base}/ipfs/${cid}`, { signal: AbortSignal.timeout(TIMEOUT_MS) });
      if (!r.ok) continue;
      const bytes = new Uint8Array(await r.arrayBuffer());
      if (bytes.length > MAX) continue;
      if (await matchesCid(bytes, cid)) return { bytes, from: base };
      console.log(`  ${base}: not the file (hash differs), next`);
    } catch (e) {
      console.log(`  ${base}: ${e.name === 'TimeoutError' ? 'timed out' : e.message}`);
    }
  }
  return null;
}

const listed = await readListedCids();
const have = new Set(existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith('.dapp')).map((f) => f.slice(0, -5)) : []);
const missing = listed.filter((d) => CIDV0.test(d.cid) && !have.has(d.cid));
console.log(`store lists ${listed.length} dApps; the copy has ${have.size} packages; ${missing.length} to fetch`);
if (!dry) mkdirSync(dir, { recursive: true });
let got = 0;
for (const d of missing) {
  console.log(`- ${d.name} by ${d.publisher} (${d.cid})`);
  if (dry) continue;
  const r = await download(d.cid);
  if (!r) {
    console.log('  not fetched: no node had it');
    continue;
  }
  writeFileSync(join(dir, `${d.cid}.dapp`), r.bytes);
  got++;
  console.log(`  ${r.bytes.length} bytes from ${r.from}, hash checked`);
}
console.log(dry ? 'dry run: nothing written' : `added ${got}; the copy has ${have.size + got} packages`);

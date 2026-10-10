// The Ethereum core against a local anvil mainnet fork: sign a 0-value
// self-transfer with anvil's key 0 and send it to the fork, never anywhere
// else. Skips when nothing that calls itself anvil answers chain id 1 on
// 127.0.0.1:8545 (start one with `anvil --fork-url <rpc> --chain-id 1`).
//
//   node --test --test-concurrency=1 test/fork/*.test.mjs
//
// The fork is shared with the desktop app's fork tests, so this takes the same
// lock they take ($TMPDIR/campfire-eth-fork.lock, an fcntl lock, held here by
// a small python3 child) and puts the fork back with evm_snapshot/evm_revert.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { EthRpc, walletFees, gasWithHeadroom } from '../../src/lib/eth/rpc.js';
import { ethKeyFromMnemonic, wipe } from '../../src/lib/eth/crypto.js';
import { signTransaction, parseSignedTransaction } from '../../src/lib/eth/tx.js';

const ANVIL = 'http://127.0.0.1:8545';
const JUNK = 'test test test test test test test test test test test junk';

async function raw(method, params = []) {
  const r = await fetch(ANVIL, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }), signal: AbortSignal.timeout(3000) });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return j.result;
}

async function anvilProblem() {
  try {
    if ((await raw('eth_chainId')) !== '0x1') return 'the node on 8545 is not chain 1';
    if (!/anvil/i.test(await raw('web3_clientVersion'))) return 'the node on 8545 is not anvil';
    return null;
  } catch {
    return 'no anvil on 127.0.0.1:8545';
  }
}

function takeLock() {
  const file = join(tmpdir(), 'campfire-eth-fork.lock');
  const py = 'import fcntl,sys\nf=open(sys.argv[1],"a+")\nfcntl.lockf(f,fcntl.LOCK_EX)\nprint("locked",flush=True)\nsys.stdin.read()\n';
  const child = spawn('python3', ['-I', '-c', py, file], { stdio: ['pipe', 'pipe', 'inherit'] });
  return new Promise((resolve, reject) => {
    child.stdout.once('data', () => resolve(() => child.stdin.end()));
    child.once('exit', (code) => reject(new Error(`lock helper exited ${code}`)));
  });
}

const skip = await anvilProblem();

test('anvil fork: a signed 0-value self-transfer is mined with status 1', { skip: skip || false, timeout: 60000 }, async () => {
  const release = await takeLock();
  const snapshot = await raw('evm_snapshot');
  try {
    // Every request this client makes goes to the local fork, whatever host it names.
    const rpc = new EthRpc('stackwallet', { fetch: (url, init) => fetch(ANVIL, init) });
    await rpc.assertMainnet();
    const { sk, address } = await ethKeyFromMnemonic(JUNK);
    const nonce = await rpc.getTransactionCount(address, 'pending');
    const fees = await walletFees(rpc);
    const gas = gasWithHeadroom(await rpc.estimateGas({ from: address, to: address, value: 0n }));
    const tx = { nonce, to: address, value: 0n, gasLimit: gas, maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas };
    const signed = signTransaction(tx, sk);
    wipe(sk);
    assert.equal(parseSignedTransaction(signed.raw).from, address);
    assert.equal(await rpc.sendRawTransaction(signed.raw), signed.hash);
    let receipt = null;
    for (let i = 0; i < 60 && !receipt; i++) {
      receipt = await rpc.getTransactionReceipt(signed.hash);
      if (!receipt) await new Promise((r) => setTimeout(r, 500));
    }
    assert.ok(receipt, 'mined');
    assert.equal(receipt.status, 1);
    assert.equal(receipt.from, address.toLowerCase());
    assert.equal(receipt.to, address.toLowerCase());
    assert.ok(receipt.gasUsed >= 21000n && receipt.gasUsed <= gas);
    assert.equal(await rpc.getTransactionCount(address, 'latest'), nonce + 1n);
    // The identical bytes again: already known or already mined, never a second spend.
    await rpc.sendRawTransaction(signed.raw).then(
      (h) => assert.equal(h, signed.hash),
      (e) => assert.match(e.message, /nonce|known/i),
    );
  } finally {
    await raw('evm_revert', [snapshot]).catch(() => {});
    release();
  }
});

// Test stub of the parts of web3 1.x that utils/eth_gas.js uses.
class BN {
  constructor(v) { this.v = BigInt(v); }
  cmp(o) { return this.v < o.v ? -1 : this.v > o.v ? 1 : 0; }
  lt(o) { return this.v < o.v; }
  gt(o) { return this.v > o.v; }
  muln(n) { if (!Number.isInteger(n)) throw new Error('muln int only'); return new BN(this.v * BigInt(n)); }
  divn(n) { if (!Number.isInteger(n)) throw new Error('divn int only'); return new BN(this.v / BigInt(n)); }
  add(o) { return new BN(this.v + o.v); }
}
const toBN = (x) => x instanceof BN ? x : new BN(typeof x === 'string' && x.startsWith('0x') ? x : x);
const units = { gwei: 9n, ether: 18n, wei: 0n };
const toWei = (s, unit) => {
  const dec = units[unit]; const [w, f = ''] = String(s).split('.');
  return (BigInt(w || '0') * 10n ** dec + BigInt((f + '0'.repeat(Number(dec))).slice(0, Number(dec)) || '0')).toString();
};
const fromWei = (x, unit) => {
  const v = BigInt(x); const dec = units[unit]; const base = 10n ** dec;
  const whole = (v / base).toString();
  let frac = (v % base).toString().padStart(Number(dec), '0').replace(/0+$/, '');
  return frac ? `${whole}.${frac}` : whole;
};
const toHex = (b) => '0x' + toBN(b).v.toString(16);
export default class Web3 {
  constructor() {
    this.utils = { toBN, toWei, fromWei, toHex };
    this.eth = { getFeeHistory: async () => globalThis.__feeHistory };
  }
}
Web3.providers = { HttpProvider: class { constructor(u) { this.u = u; } } };

// Runs BeamMW's own relayer fee code (utils/eth_gas.js + utils/eth_fee.js,
// mainnet = forward relayers, reverse_mainnet = WBEAM relayer, unmodified)
// on fixed inputs and prints what it computes, as test vectors.
import http from 'http';
let prices = {};
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x'); const id = u.searchParams.get('ids');
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ [id]: { usd: prices[id] } }));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
process.env.COINGECKO_CURRENCY_RATE_API_URL = `http://127.0.0.1:${server.address().port}/price`;
process.env.ETH_HTTP_PROVIDER = 'http://unused';
const fwd = await import('./fwd/eth_fee.js');
const rev = await import('./rev/eth_fee.js');
const { estimateFeeParams } = await import('./fwd/eth_gas.js');

const routes = [
  { id: 'beam', dec: 8, rate: 'beam', fee: rev },
  { id: 'eth', dec: 18, rate: 'ethereum', fee: fwd },
  { id: 'wbtc', dec: 8, rate: 'wrapped-bitcoin', fee: fwd },
  { id: 'usdt', dec: 6, rate: 'tether', fee: fwd },
  { id: 'dai', dec: 18, rate: 'dai', fee: fwd },
];
// beam2eth_relay.js getCurrentMinRelayerFee, verbatim but for the env var.
const minFee = (dec, est) => Math.trunc(Math.pow(10, dec) * est);

let seed = 20261009;
const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const hex = (n) => '0x' + BigInt(Math.floor(n)).toString(16);
const vectors = [];
const cases = [];
// The live snapshot read 2026-10-09 (worker report) first.
cases.push({ history: { baseFeePerGas: Array(11).fill(hex(437410677)), reward: Array(10).fill([hex(168460833)]) },
  prices: { ethereum: 2485.63, beam: 0.00795925, 'wrapped-bitcoin': 82513.0, tether: 0.999197, dai: 0.999891 } });
for (let i = 0; i < 400; i++) {
  const gwei = Math.pow(10, -1.5 + rnd() * 3.5); // 0.03 .. 100 gwei
  const base = [];
  for (let b = 0; b < 11; b++) base.push(hex(gwei * 1e9 * (0.8 + rnd() * 0.4)));
  const n = i % 7 === 0 ? 0 : (i % 5 === 0 ? 9 : 10);
  const reward = [];
  for (let b = 0; b < n; b++) reward.push(rnd() < 0.1 ? [] : [hex(Math.pow(10, 5 + rnd() * 5.2))]);
  cases.push({ history: { baseFeePerGas: base, reward },
    prices: { ethereum: 800 + rnd() * 6000, beam: 0.001 + rnd() * 0.08, 'wrapped-bitcoin': 20000 + rnd() * 180000,
      tether: 0.95 + rnd() * 0.1, dai: 0.95 + rnd() * 0.1 } });
}
for (const c of cases) {
  globalThis.__feeHistory = c.history; prices = c.prices;
  const params = await estimateFeeParams();
  const row = { history: c.history, prices: c.prices, maxFeePerGas: BigInt(params.maxFeePerGas).toString(),
    maxPriorityFeePerGas: BigInt(params.maxPriorityFeePerGas).toString(), minimum: {} };
  for (const r of routes) {
    const est = await r.fee.calcCurrentRelayerFee(r.rate, false);
    // The relayer compares BigInt(expectedMinimumFee): the double's exact
    // value, not its shortest decimal (they differ above 2^53, e.g. DAI).
    row.minimum[r.id] = BigInt(minFee(r.dec, est)).toString();
  }
  vectors.push(row);
}
server.close();
console.log(JSON.stringify({
  source: 'BeamMW/beam-bridge-ethrelay utils/eth_gas.js + utils/eth_fee.js, unmodified: mainnet d626ceb89dcc5360af9905f8b3eca99096278bf7, reverse_mainnet 19b0daa64bdfab168a075374fc2ce36c6dc9ec15',
  vectors,
}));

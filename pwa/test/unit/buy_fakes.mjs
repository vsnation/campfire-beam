// A buybeam.my stand-in for the Buy BEAM unit tests: a fetch that answers the
// buy API's five calls the way buybeam.my does (shapes from its real answers,
// as the desktop app's test/beam/buy/buybeam_fakes.dart has them), records
// every request, and can fail in each of the ways the real one can; and a
// clock whose timers run when told. Every address here is made up.

export const BEAM_ADDRESS = `${'1'.repeat(64)}aa`;
export const BEAM_ADDRESS_2 = `${'2'.repeat(64)}bb`;
export const BTC_REFUND = 'bc1qfake0refund0address0for0tests0only00000';
export const ETH_REFUND = '0x1111111111111111111111111111111111111111';
export const DEPOSIT = 'bc1qfake0deposit0address0000000000000000000';
export const BTC = 'coin:btc';
export const ETH = 'coin:eth';
export const USDT_TRON = 'coin:tron-usdt';

export function assetJson(id, symbol, chain, decimals, { contract = null, price = null } = {}) {
  return { asset_id: id, symbol, blockchain: chain, decimals, contract_address: contract, price_usd: price, price_updated_at: null, coingecko_id: null };
}

/** A few of buybeam.my's coins, deliberately out of order. */
export const ASSETS = [
  assetJson('coin:eth-aave', 'AAVE', 'eth', 18, { contract: '0x7fc6', price: 140 }),
  assetJson('coin:ltc', 'LTC', 'ltc', 8, { price: 63.31 }),
  assetJson(ETH, 'ETH', 'eth', 18, { price: 2476.84 }),
  assetJson(USDT_TRON, 'USDT', 'tron', 6, { contract: 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t', price: 0.9992 }),
  assetJson('coin:kaia', 'KAIA', 'kaia', 18, { price: 0.12 }),
  assetJson(BTC, 'BTC', 'btc', 8, { price: 82306 }),
  assetJson('coin:zec', 'ZEC', 'zec', 8, { price: 1201.81 }),
];

export function envelope(body) {
  return { ok: true, error: null, api_version: '1.0.0', server_time: 1791576000, ...body };
}

export function errorJson(code, { minimumUsd, orderValueUsd, retryAfter } = {}) {
  const error = { code, message: 'words that change' };
  if (minimumUsd !== undefined) error.minimum_usd = minimumUsd;
  if (orderValueUsd !== undefined) error.order_value_usd = orderValueUsd;
  if (retryAfter !== undefined) error.retry_after = retryAfter;
  return { ok: false, api_version: '1.0.0', server_time: 1791576000, error };
}

export function statusJson(state, { deposit = DEPOSIT, terminal, pollAfter = 15, txId = null } = {}) {
  return envelope({
    order_id: deposit,
    deposit_address: deposit,
    state,
    state_description: 'words that change',
    terminal: terminal ?? ['delivered', 'refunded', 'expired', 'failed'].includes(state),
    poll_after_seconds: pollAfter,
    beam_txid: txId,
    beam_estimate: 192460.19775695,
    deadline: null,
    raw: { payin_status: 'anything' },
  });
}

/** {status, body, headers} or a JSON object (200) or an Error to throw. */
export function answer(status, body, headers = {}) {
  return { __answer: true, status, body: typeof body === 'string' ? body : JSON.stringify(body), headers: { 'content-type': 'application/json', ...headers } };
}

export class FakeBuyBeam {
  constructor() {
    this.requests = [];
    this.queued = new Map();
    this.offline = false;
    this.depositAddress = DEPOSIT;
    this.state = 'awaiting_deposit';
    this.txId = null;
    this.holdQuotes = null; // a promise the next /quote waits for
    this.fetch = (url, init = {}) => this._handle(url, init);
  }

  queue(path, a) {
    if (!this.queued.has(path)) this.queued.set(path, []);
    this.queued.get(path).push(a);
  }

  count(path) {
    return this.requests.filter((r) => r.path === path || (path.endsWith('/') && r.path.startsWith(path))).length;
  }

  async _handle(url, init) {
    const u = new URL(url);
    const path = decodeURIComponent(u.pathname.replace('/api/v1/buy', ''));
    const req = { url: u, path, method: init.method || 'GET', headers: init.headers || {}, body: init.body ? JSON.parse(init.body) : null, init };
    this.requests.push(req);
    if (this.offline) throw new TypeError('Failed to fetch');
    const q = this.queued.get(path);
    let a;
    if (q && q.length) a = q.shift();
    else {
      if (path === '/quote' && this.holdQuotes) await this.holdQuotes;
      a = this._default(req);
    }
    if (a instanceof Error) throw a;
    if (a && a.__never) return new Promise(() => {});
    const r = a && a.__answer ? a : answer(200, a);
    return new Response(r.body, { status: r.status, headers: r.headers });
  }

  _default(req) {
    const { path, url } = req;
    if (path === '/assets') return envelope({ count: ASSETS.length, blockchains: ['btc', 'eth', 'ltc', 'tron', 'zec', 'kaia'], cache_age_s: 0, assets: ASSETS });
    if (path === '/limits') return envelope({ our_minimum_usd: 5.0, maximum_usd: null, upstream_observed_minimum_usd: 1000.0, upstream_observed_at: 1791576000 });
    if (path === '/quote') {
      const id = url.searchParams.get('asset_id');
      const amount = Number(url.searchParams.get('amount'));
      const asset = ASSETS.find((x) => x.asset_id === id);
      const usd = amount * (asset.price_usd ?? 1);
      if (usd < 1000) return answer(400, errorJson('amount_below_upstream_minimum', { minimumUsd: 1000 }));
      const raw = BigInt(Math.round(amount * Number(`1e${asset.decimals}`)));
      return envelope({
        asset_id: id,
        symbol: asset.symbol,
        blockchain: asset.blockchain,
        decimals: asset.decimals,
        send_amount: amount,
        send_amount_raw: raw.toString(),
        order_value_usd: usd,
        beam_estimate: usd * 110,
        beam_estimate_raw: BigInt(Math.round(usd * 110 * 1e8)).toString(),
        eta_seconds: 810,
        deadline: null,
      });
    }
    if (path === '/order') {
      const b = req.body;
      const asset = ASSETS.find((x) => x.asset_id === b.asset_id);
      return envelope({
        order_id: this.depositAddress,
        deposit_address: this.depositAddress,
        asset_id: b.asset_id,
        symbol: asset.symbol,
        blockchain: asset.blockchain,
        send_amount: b.amount,
        send_amount_raw: BigInt(Math.round(b.amount * Number(`1e${asset.decimals}`))).toString(),
        beam_wallet: b.beam_wallet,
        beam_estimate: 192460.19775695,
        order_value_usd: 1012.36,
        deadline: 1791579600,
        eta_seconds: 810,
        payable: true,
        created: true,
      });
    }
    if (path.startsWith('/order/')) return statusJson(this.state, { deposit: this.depositAddress, txId: this.txId });
    return answer(404, errorJson('not_found'));
  }
}

/** A clock that stands still until advance()d; timers fire in order. */
export class FakeClock {
  constructor(start = Date.UTC(2026, 9, 9, 12)) {
    this.t = start;
    this.timers = [];
  }

  now() {
    return this.t;
  }

  schedule(ms, fn) {
    const timer = { at: this.t + Math.max(0, ms), fn };
    this.timers.push(timer);
    return () => {
      this.timers = this.timers.filter((x) => x !== timer);
    };
  }

  get pending() {
    return this.timers.length;
  }

  async advance(ms) {
    const end = this.t + ms;
    for (;;) {
      await drain();
      const due = this.timers.filter((x) => x.at <= end).sort((a, b) => a.at - b.at);
      if (!due.length) break;
      const x = due[0];
      this.timers = this.timers.filter((y) => y !== x);
      if (x.at > this.t) this.t = x.at;
      x.fn();
    }
    this.t = end;
    await drain();
  }
}

export async function drain() {
  for (let i = 0; i < 30; i++) await new Promise((r) => setImmediate(r));
}

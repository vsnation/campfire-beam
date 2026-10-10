// The buybeam.my client over a fake fetch (a port of the desktop app's
// test/beam/buy/buybeam_client_test.dart): every error code it documents, a
// proxy's HTML page and a dead connection (never "the order failed"), sandbox
// as a query parameter only, no cookies and no referrer, an order answer
// refused for every way it can differ from the question, and amounts typed as
// decimals carried exactly for 6, 8 and 18 decimals.
import test from 'node:test';
import assert from 'node:assert/strict';
import { BuyBeamClient, BuyBeamAmount, BuyBeamError, ERROR_CODES, sortAssets, assetFromJson, limitsFromJson, isDefaultCoin, parseState, chainName } from '../../src/lib/buy/buybeam.js';
import { buyApiBase, buyConnectSources, buySiteUrl } from '../../src/lib/buy/hosts.js';
import { FakeBuyBeam, answer, envelope, errorJson, statusJson, BTC, USDT_TRON, BEAM_ADDRESS, BTC_REFUND, DEPOSIT } from './buy_fakes.mjs';

const amount = (text, decimals) => BuyBeamAmount.parse(text, decimals).amount;
const client = (s, opts = {}) => new BuyBeamClient({ fetch: s.fetch, ...opts });

async function error(p) {
  try {
    await p;
  } catch (e) {
    assert.ok(e instanceof BuyBeamError, `a BuyBeamError, not ${e}`);
    return e;
  }
  assert.fail('expected a BuyBeamError');
}

const order = (c, { text = '0.0123', beam = BEAM_ADDRESS } = {}) => c.order({ assetId: BTC, amount: amount(text, 8), beamAddress: beam, refundAddress: BTC_REFUND });

test('the API lives under one path of buybeam.my', () => {
  assert.equal(buyApiBase(), 'https://buybeam.my/api/v1/buy');
  assert.deepEqual(buyConnectSources(), ['https://buybeam.my/api/v1/buy/']);
  assert.equal(buySiteUrl(), 'https://buybeam.my');
});

test('every documented error code is its own typed error', async () => {
  for (const code of ERROR_CODES) {
    const s = new FakeBuyBeam();
    s.queue('/quote', answer(400, errorJson(code)));
    const e = await error(client(s).quote({ assetId: BTC, amount: amount('0.0123', 8), refundAddress: BTC_REFUND }));
    assert.equal(e.code, code);
    assert.equal(e.rawCode, code);
    assert.equal(e.httpStatus, 400);
  }
  assert.equal(new Set(ERROR_CODES).size, ERROR_CODES.length);
});

test('an unknown code is "unknown" and keeps the code it had', async () => {
  const s = new FakeBuyBeam();
  s.queue('/limits', answer(400, errorJson('new_in_v1_9')));
  const e = await error(client(s).limits());
  assert.equal(e.code, 'unknown');
  assert.equal(e.rawCode, 'new_in_v1_9');
});

test('the smallest buy comes from the error, not the app', async () => {
  const s = new FakeBuyBeam();
  s.queue('/quote', answer(400, errorJson('amount_below_upstream_minimum', { minimumUsd: 1234.5, orderValueUsd: 99 })));
  const e = await error(client(s).quote({ assetId: BTC, amount: amount('0.001', 8), refundAddress: BTC_REFUND }));
  assert.equal(e.code, 'amount_below_upstream_minimum');
  assert.equal(e.belowMinimum, true);
  assert.equal(e.minimumUsd, 1234.5);
  assert.equal(e.orderValueUsd, 99);
});

test('retry_after: from the error, else the envelope', async () => {
  const s = new FakeBuyBeam();
  s.queue('/limits', answer(503, errorJson('upstream_unavailable', { retryAfter: 30 })));
  assert.equal((await error(client(s).limits())).retryAfterMs, 30000);
  s.queue('/limits', answer(503, { ...errorJson('upstream_unavailable'), retry_after: 12 }));
  assert.equal((await error(client(s).limits())).retryAfterMs, 12000);
  s.queue('/limits', answer(503, errorJson('upstream_unavailable'), { 'retry-after': '7' }));
  assert.equal((await error(client(s).limits())).retryAfterMs, 7000);
});

test("a proxy's HTML 403 or plain-text 502 is 'blocked', not an order failure", async () => {
  const s = new FakeBuyBeam();
  s.queue('/order', answer(403, '<!DOCTYPE html><html><body>Blocked</body></html>', { 'content-type': 'text/html' }));
  let e = await error(order(client(s)));
  assert.equal(e.code, 'blocked');
  assert.equal(e.unreachable, true);
  assert.equal(e.httpStatus, 403);
  s.queue('/limits', answer(502, 'Bad gateway', { 'content-type': 'text/plain' }));
  e = await error(client(s).limits());
  assert.equal(e.code, 'blocked');
  assert.equal(e.httpStatus, 502);
});

test('no connection, or an answer that never comes, is "network"', async () => {
  const s = new FakeBuyBeam();
  s.offline = true;
  const e = await error(client(s).assets());
  assert.equal(e.code, 'network');
  assert.equal(e.unreachable, true);
  const never = new FakeBuyBeam();
  never.queue('/limits', { __never: true });
  assert.equal((await error(client(never, { timeoutMs: 50 }).limits())).code, 'network');
});

test('JSON without "ok" is an unexpected answer', async () => {
  const s = new FakeBuyBeam();
  s.queue('/limits', { hello: 1 });
  assert.equal((await error(client(s).limits())).code, 'unexpected_answer');
});

test('sandbox: a query parameter on every call, never in the body', async () => {
  const s = new FakeBuyBeam();
  s.depositAddress = 'sbx_1_fake';
  const c = client(s, { sandbox: true });
  await c.assets();
  await c.limits();
  await c.quote({ assetId: BTC, amount: amount('0.0123', 8), refundAddress: BTC_REFUND });
  await order(c);
  await c.status('sbx_1_fake');
  assert.equal(s.requests.length, 5);
  for (const r of s.requests) assert.equal(r.url.searchParams.get('sandbox'), 'true', String(r.url));
  const post = s.requests.find((r) => r.method === 'POST');
  assert.deepEqual(Object.keys(post.body).sort(), ['amount', 'asset_id', 'beam_wallet', 'refund_address']);
});

test('without sandbox no call carries it', async () => {
  const s = new FakeBuyBeam();
  await client(s).assets();
  await order(client(s));
  for (const r of s.requests) assert.equal(r.url.searchParams.has('sandbox'), false);
});

test('no cookies, no referrer, JSON asked for, the BEAM address only in the body', async () => {
  const s = new FakeBuyBeam();
  await order(client(s));
  const r = s.requests[0];
  assert.equal(r.init.credentials, 'omit');
  assert.equal(r.init.referrerPolicy, 'no-referrer');
  assert.equal(r.init.redirect, 'error');
  assert.equal(r.headers.accept, 'application/json');
  assert.equal(r.headers['content-type'], 'application/json');
  assert.equal(r.url.href.includes(BEAM_ADDRESS), false);
  assert.equal(r.url.pathname, '/api/v1/buy/order');
  assert.equal(r.url.origin, 'https://buybeam.my');
  // A GET carries nothing that makes the browser ask first (no custom header).
  const get = new FakeBuyBeam();
  await client(get).limits();
  assert.deepEqual(Object.keys(get.requests[0].headers), ['accept']);
});

test('the coins are read, unreadable entries skipped', async () => {
  const s = new FakeBuyBeam();
  s.queue('/assets', envelope({ assets: [{ asset_id: 'x' }, { asset_id: 'coin:eth-aave', symbol: 'AAVE', blockchain: 'eth', decimals: 18, contract_address: '0x7fc6' }, { asset_id: '', symbol: 'Z', blockchain: 'z', decimals: 1 }, { asset_id: 'w', symbol: 'W', blockchain: 'w', decimals: 99 }, null] }));
  const list = await client(s).assets();
  assert.equal(list.length, 1);
  assert.equal(list[0].symbol, 'AAVE');
  assert.equal(list[0].isNative, false);
  assert.equal(list[0].isEvm, true);
  assert.equal(list[0].chainName, 'Ethereum');
});

test('BTC, ETH and USDT on Tron come first in the picker', async () => {
  const list = sortAssets(await client(new FakeBuyBeam()).assets());
  assert.deepEqual(
    list.map((a) => `${a.symbol}/${a.blockchain}`),
    ['BTC/btc', 'ETH/eth', 'USDT/tron', 'LTC/ltc', 'ZEC/zec', 'KAIA/kaia', 'AAVE/eth'],
  );
  assert.equal(list[0].chainName, 'Bitcoin');
  assert.equal(list[5].chainName, 'KAIA');
  assert.equal(isDefaultCoin(list[0]), true);
  assert.equal(isDefaultCoin(list[1]), false);
  assert.equal(chainName('tron'), 'Tron');
  assert.equal(chainName('constructor'), 'CONSTRUCTOR', 'no prototype names');
});

test('the smallest-buy hint prefers the observed figure', async () => {
  assert.equal((await client(new FakeBuyBeam()).limits()).hintUsd, 1000);
  assert.equal(limitsFromJson({ our_minimum_usd: 5 }).hintUsd, 5);
});

test("buybeam.my's estimate is taken as it is; the question is checked against the answer", async () => {
  const s = new FakeBuyBeam();
  s.queue('/quote', envelope({ asset_id: BTC, send_amount_raw: '1230000', beam_estimate: 192460.19775695, beam_estimate_raw: '19246019775695', eta_seconds: 810, order_value_usd: 1012.36 }));
  const q = await client(s).quote({ assetId: BTC, amount: amount('0.0123', 8), refundAddress: BTC_REFUND });
  assert.equal(q.beamEstimate, 192460.19775695);
  assert.equal(q.beamGroth, 19246019775695n);
  assert.equal(q.etaSeconds, 810);
  const query = s.requests[0].url.searchParams;
  assert.equal(query.get('amount'), '0.0123');
  assert.equal(query.get('refund_address'), BTC_REFUND);
  assert.equal(query.get('asset_id'), BTC);
  // Another amount or another coin in the answer: refused.
  for (const body of [{ asset_id: BTC, send_amount_raw: '1230001', beam_estimate: 1 }, { asset_id: 'coin:ltc', beam_estimate: 1 }, { asset_id: BTC }, { asset_id: BTC, beam_estimate: -1 }]) {
    s.queue('/quote', envelope(body));
    assert.equal((await error(client(s).quote({ assetId: BTC, amount: amount('0.0123', 8), refundAddress: BTC_REFUND }))).code, 'unexpected_answer');
  }
});

test('the order asked for is accepted, as is the same one again', async () => {
  const s = new FakeBuyBeam();
  const a = await order(client(s));
  assert.equal(a.depositAddress, DEPOSIT);
  assert.equal(a.created, true);
  assert.equal(a.payable, true);
  assert.equal(a.deadline, 1791579600000);
  s.queue('/order', envelope({ deposit_address: DEPOSIT, asset_id: BTC, send_amount_raw: '1230000', beam_wallet: BEAM_ADDRESS, payable: true, created: false }));
  const again = await order(client(s));
  assert.equal(again.created, false);
  assert.equal(again.depositAddress, a.depositAddress);
});

test('an order answer that differs from the question is refused', async () => {
  const good = { deposit_address: DEPOSIT, asset_id: BTC, send_amount_raw: '1230000', beam_wallet: BEAM_ADDRESS, payable: true };
  const cases = {
    'no deposit address': { ...good, deposit_address: '' },
    'another coin': { ...good, asset_id: 'coin:ltc' },
    'another BEAM address': { ...good, beam_wallet: 'someone else' },
    'another amount': { ...good, send_amount_raw: '1230001' },
    'no amount': { ...good, send_amount_raw: undefined },
    'not payable': { ...good, payable: false },
  };
  for (const [what, body] of Object.entries(cases)) {
    const s = new FakeBuyBeam();
    s.queue('/order', envelope(body));
    assert.equal((await error(order(client(s)))).code, 'unexpected_answer', what);
  }
});

test('sandbox: not payable, no raw figure, the same number', async () => {
  const s = new FakeBuyBeam();
  const c = client(s, { sandbox: true });
  s.queue('/order', envelope({ deposit_address: 'sbx_1_x', asset_id: BTC, send_amount: 0.0123, beam_wallet: BEAM_ADDRESS, payable: false }));
  assert.equal((await order(c)).depositAddress, 'sbx_1_x');
  s.queue('/order', envelope({ deposit_address: 'sbx_1_x', asset_id: BTC, send_amount: 0.0124, beam_wallet: BEAM_ADDRESS, payable: false }));
  assert.equal((await error(order(c))).code, 'unexpected_answer');
});

test('every state; an unknown one is "in progress"; a new state marked terminal is still followed', async () => {
  const s = new FakeBuyBeam();
  for (const [wire, terminal] of [['awaiting_deposit', false], ['deposit_detected', false], ['swapping', false], ['buying', false], ['processing', false], ['sending', false], ['delivered', true], ['refunded', true], ['expired', true], ['failed', true], ['attention', false]]) {
    s.state = wire;
    const st = await client(s).status(DEPOSIT);
    assert.equal(st.state, wire);
    assert.equal(st.rawState, wire);
    assert.equal(st.terminal, terminal, wire);
  }
  s.queue(`/order/${DEPOSIT}`, statusJson('teleporting', { terminal: true }));
  const st = await client(s).status(DEPOSIT);
  assert.equal(st.state, 'in_progress');
  assert.equal(st.rawState, 'teleporting');
  assert.equal(st.terminal, false);
  assert.equal(parseState('toString'), 'in_progress');
});

test('poll_after, the delivery transaction, the echo; a forced sandbox state', async () => {
  const s = new FakeBuyBeam();
  s.state = 'delivered';
  s.txId = 'sbx_delivery_txid';
  const st = await client(s).status(DEPOSIT);
  assert.equal(st.pollAfterMs, 15000);
  assert.equal(st.beamTxId, 'sbx_delivery_txid');
  s.queue('/order/other', statusJson('delivered', { deposit: 'someone_else' }));
  assert.equal((await error(client(s).status('other'))).code, 'unexpected_answer');

  const sb = new FakeBuyBeam();
  sb.depositAddress = 'sbx_1_y';
  await client(sb, { sandbox: true }).status('sbx_1_y', { forceState: 'expired' }).catch(() => {});
  assert.equal(sb.requests[0].url.pathname, '/api/v1/buy/order/sbx_1_y%3Aexpired');
  await client(sb).status('sbx_1_y', { forceState: 'expired' });
  assert.equal(sb.requests[1].url.pathname, '/api/v1/buy/order/sbx_1_y');
});

test('amounts: 8 decimals (BTC), text to the smallest unit, exactly', () => {
  const a = amount('0.0123', 8);
  assert.equal(a.raw, 1230000n);
  assert.equal(a.value, 0.0123);
  assert.equal(a.exact, true);
  assert.equal(amount('.5', 8).text, '0.5');
  assert.equal(amount('007.10', 8).text, '7.1');
  assert.equal(amount('7.', 8).raw, 700000000n);
});

test('amounts: 6 decimals (USDT), 1024.07 is carried exactly', async () => {
  const a = amount('1024.07', 6);
  assert.equal(a.raw, 1024070000n);
  // round(), not trunc(): 1024.07 * 1e6 is 1024069999.9999999.
  assert.equal(BuyBeamAmount.serverRaw(a.value, 6), a.raw);
  assert.equal(a.exact, true);
  const s = new FakeBuyBeam();
  await client(s).order({ assetId: USDT_TRON, amount: a, beamAddress: BEAM_ADDRESS, refundAddress: 'TFakeTronRefundAddress000000000000' });
  assert.equal(s.requests[0].body.amount, 1024.07, 'the JSON number is the decimal typed');
});

test('amounts: 18 decimals (ETH), most are exact, some are not', () => {
  const a = amount('0.51234567', 18);
  assert.equal(a.raw, 512345670000000000n);
  assert.equal(a.exact, true);
  // buybeam.my reads 0.51587833 ETH as 64 wei more: refused up front, with an amount it reads exactly.
  const b = amount('0.51587833', 18);
  assert.equal(BuyBeamAmount.serverRaw(b.value, 18) - b.raw, 64n);
  assert.equal(b.exact, false);
  const c = amount('9.51234567', 18);
  assert.equal(c.exact, false);
  assert.equal(c.nearestExact(), '9.5123457');
  assert.equal(amount('9.5123457', 18).exact, true);
});

test('amounts: 24 decimals, none is exact; at most min(decimals, 8) digits; words for every mistake', () => {
  assert.equal(amount('250', 24).exact, false);
  assert.equal(amount('250.12345678', 24).nearestExact(), null);
  assert.equal(BuyBeamAmount.parse('0.123456789', 18).error, 'Use at most 8 digits after the point');
  assert.equal(BuyBeamAmount.parse('1.1234567', 6).error, 'Use at most 6 digits after the point');
  assert.match(BuyBeamAmount.parse('1,5', 8).error, /dot/);
  assert.ok(BuyBeamAmount.parse('abc', 8).error);
  assert.ok(BuyBeamAmount.parse('1e5', 8).error);
  assert.deepEqual(BuyBeamAmount.parse('', 8), { amount: null, error: null });
  assert.equal(BuyBeamAmount.parse('1234567890123456', 8).error, 'That amount is too large');
});

test('assetFromJson: a price that is not a number is no price', () => {
  assert.equal(assetFromJson({ asset_id: 'a', symbol: 'A', blockchain: 'btc', decimals: 8, price_usd: 'abc' }).priceUsd, null);
  assert.equal(assetFromJson({ asset_id: 'a', symbol: 'A', blockchain: 'btc', decimals: 8, price_usd: '2.5' }).priceUsd, 2.5);
});

// The bridge's price feed (lib/bridge/prices.js), offline: CoinGecko's
// simple/price through a fake fetch. One request for every bridged asset, kept
// two minutes; never a guess; nothing asked while the person has not allowed
// it. The cases are the desktop's eth_pipe_service_test.dart "prices" group.
import test from 'node:test';
import assert from 'node:assert/strict';
import { PriceFeed, BRIDGE_PRICE_IDS, PRICE_MAX_AGE_MS } from '../../src/lib/bridge/prices.js';
import { BridgeError } from '../../src/lib/bridge/beam_pipe.js';

const ANSWER = {
  ethereum: { usd: 2487.25 },
  beam: { usd: 0.00783632 },
  'wrapped-bitcoin': { usd: 82567 },
  tether: { usd: 0.999262 },
  dai: { usd: 0.999917 },
};

function feed({ answer = ANSWER, status = 200, allowed = () => true, now = { t: 1000 } } = {}) {
  const asked = [];
  const state = { answer, status };
  const f = new PriceFeed({
    allowed,
    clock: () => now.t,
    fetch: async (url, init) => {
      asked.push({ url: new URL(url), init });
      return new Response(JSON.stringify(state.answer), { status: state.status });
    },
  });
  return { f, asked, state, now };
}

const noPrice = (e) => e instanceof BridgeError && e.code === 'noPrice';

test('one request for every bridged asset, kept two minutes, without cookies or a referrer', async () => {
  const { f, asked, now } = feed();
  const p = await f.usd(['ethereum', 'beam']);
  assert.equal(p.usd.beam, 0.00783632);
  assert.equal(p.usd['wrapped-bitcoin'], 82567);
  assert.equal(p.at, 1000);
  assert.equal(asked.length, 1);
  const { url, init } = asked[0];
  assert.equal(url.origin, 'https://api.coingecko.com');
  assert.equal(url.pathname, '/api/v3/simple/price');
  assert.equal(url.searchParams.get('ids'), 'beam,dai,ethereum,tether,wrapped-bitcoin');
  assert.equal(url.searchParams.get('vs_currencies'), 'usd');
  assert.equal(init.credentials, 'omit');
  assert.equal(init.referrerPolicy, 'no-referrer');
  assert.equal(init.cache, 'no-store');
  assert.equal(init.redirect, 'error');
  assert.deepEqual(BRIDGE_PRICE_IDS, ['beam', 'dai', 'ethereum', 'tether', 'wrapped-bitcoin']);
  now.t += PRICE_MAX_AGE_MS - 1000;
  await f.usd(['ethereum', 'tether']);
  assert.equal(asked.length, 1);
  now.t += 1000;
  await f.usd(['ethereum']);
  assert.equal(asked.length, 2);
});

test('a missing or zero price is no price (never a guess); the others still answer', async () => {
  const answer = { ...ANSWER, dai: { usd: 0 } };
  delete answer.tether;
  const { f } = feed({ answer });
  await assert.rejects(f.usd(['ethereum', 'tether']), noPrice);
  await assert.rejects(f.usd(['dai']), noPrice);
  assert.equal((await f.usd(['beam'])).usd.beam, 0.00783632);
});

test('busy, broken, or not allowed: no price; not allowed asks nothing at all', async () => {
  await assert.rejects(feed({ status: 429 }).f.usd(['beam']), (e) => noPrice(e) && /busy/.test(e.message));
  await assert.rejects(feed({ status: 500 }).f.usd(['beam']), noPrice);
  await assert.rejects(feed({ answer: { status: 'not json prices' } }).f.usd(['beam']), noPrice);
  await assert.rejects(feed({ answer: [1, 2] }).f.usd(['beam']), noPrice);
  for (const allowed of [() => false, () => undefined, () => 'yes']) {
    const { f, asked } = feed({ allowed });
    await assert.rejects(f.usd(['beam']), (e) => noPrice(e) && /off in Settings/.test(e.message));
    assert.equal(asked.length, 0);
  }
  await assert.rejects(feed().f.usd(['beam&x=1']), TypeError);
  assert.throws(() => new PriceFeed({}), TypeError, 'the caller must say whether lookups are allowed');
  const down = new PriceFeed({ allowed: () => true, fetch: async () => { throw new TypeError('offline'); } });
  await assert.rejects(down.usd(['beam']), noPrice);
});

test('two screens asking at once share one request', async () => {
  const { f, asked } = feed();
  const [a, b] = await Promise.all([f.usd(['beam']), f.usd(['ethereum'])]);
  assert.equal(asked.length, 1);
  assert.equal(a.at, b.at);
});

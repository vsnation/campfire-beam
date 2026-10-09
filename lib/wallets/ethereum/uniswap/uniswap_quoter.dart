/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Prices a swap on every route Uniswap offers and shares it between the
// routes that, together, give the most.
//
// Routes tried: every pool between the two tokens (v2, v3, v4, any fee or
// hook), and every two-pool route through ETH, USDC, USDT, DAI, WBTC or
// WBEAM. Each pool is priced by Uniswap's own quoter contracts (v3
// QuoterV2, v4 V4Quoter) or, for v2, from the pair's reserves with v2's
// own formula, all through Multicall3.
//
// One pool is rarely the best place for a whole swap: the more of it goes
// through one pool, the further that pool's price moves, and a swap that
// moves one pool a lot is what front-runners wait for. So the amount is
// cut into twentieths and every route is priced at each number of
// twentieths; `uniswap_split.dart` then picks the sharing that gives the
// most after gas (each extra route costs its own swaps' gas, which only
// matters on small swaps). The search goes in four steps, each one request
// per 25 prices: every first pool at a twentieth and at the whole amount;
// the second pool of each two-pool route the same; then, for the routes
// that could take part, every other twentieth.

import 'dart:math' as math;
import 'dart:typed_data';

import 'abi.dart';
import 'eth_rpc.dart';
import 'uniswap_constants.dart';
import 'uniswap_discovery.dart';
import 'uniswap_models.dart';
import 'uniswap_split.dart';

/// Tokens a two-pool route may go through.
const List<String> kUniRouteBases = [
  UniswapAddresses.nativeEth,
  UniswapAddresses.weth,
  '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48', // USDC
  '0xdac17f958d2ee523a2206206994597c13d831ec7', // USDT
  '0x6b175474e89094c44da98b954eedeac495271d0f', // DAI
  '0x2260fac5e5542a773aa44fbcfedf7c193bc2c599', // WBTC
  '0xe5acbb03d73267c03349c76ead672ee4d941f499', // WBEAM
];

/// Gas a v2 step costs (v3 and v4 steps use the quoters' own estimates).
final BigInt kV2HopGas = BigInt.from(90000);

/// The router's own work around the swaps (commands, transfers, checks).
final BigInt kRouterOverheadGas = BigInt.from(80000);

/// Checks that the real swap for a quote works (an eth_call of the router
/// transaction from the user's address): true / false, or null when it
/// cannot tell (not enough ETH to simulate it, or the node did not answer).
typedef UniRouteCheck = Future<bool?> Function(UniQuote quote);

/// How much better than the best route without hooks a route through a
/// hooked pool may claim to be, unverified, before it is not believed.
const int kHookedEdgeBips = 100;

class UniswapNoRoute implements Exception {
  const UniswapNoRoute(this.reason);

  /// noPool: no Uniswap pool links the two tokens (directly or through
  /// one of the base tokens); tooSmall: every pool gives nothing back.
  final String reason;

  @override
  String toString() => 'UniswapNoRoute($reason)';
}

class _Leg {
  _Leg(this.hop, this.amountIn, this.amountOut, this.gas);

  final UniHop hop;
  final BigInt amountIn;
  final BigInt amountOut;
  final BigInt gas;
}

class UniswapQuoter {
  UniswapQuoter({
    required this.rpc,
    required this.discovery,
    this.maxDirectPools = 16,
    this.maxPoolsPerPair = 4,
    this.splitSteps = 20,
    this.maxParts = 6,
    this.maxSplitRoutes = 10,
  });

  final EthRpc rpc;
  final UniswapDiscovery discovery;

  /// How many of the deepest pools between the two tokens are priced.
  final int maxDirectPools;

  /// How many of the deepest pools of each pair on a two-pool route.
  final int maxPoolsPerPair;

  /// The amount is shared between routes in this many equal steps.
  final int splitSteps;

  /// At most this many routes in one swap.
  final int maxParts;

  /// How many routes are priced at every step (the others only at one
  /// step and at the whole amount).
  final int maxSplitRoutes;

  /// Per pair, its deepest live pools and when they were ranked.
  final Map<(String, String), (DateTime, List<UniPool>)> _ranked = {};

  /// How long a pair's ranking is reused before every pool is read again.
  static const rankingLife = Duration(minutes: 5);

  /// The deepest live pools of [pair]: a pair like ETH/USDC has hundreds of
  /// v4 pools, most of them empty or tiny, so every pool is read once and
  /// only the deepest are priced (and re-read) for the next few minutes.
  /// Depth is the pool's liquidity (v3/v4) or √(reserve0·reserve1) (v2),
  /// which measure the same thing for one pair.
  Future<List<UniPool>> _deepest(
    (String, String) pair, {
    required bool direct,
    required Future<int> head,
  }) async {
    final cached = _ranked[pair];
    if (cached != null && DateTime.now().difference(cached.$1) < rankingLife) {
      return cached.$2;
    }
    final pools = await discovery.poolsBetween(
      pair.$1,
      pair.$2,
      head: await head,
    );
    if (pools.isEmpty) {
      _ranked[pair] = (DateTime.now(), const []);
      return const [];
    }
    final states = await discovery.liveState(pools);
    final ranked = [
      for (final p in pools)
        if (states[p.id]?.isLive ?? false) p,
    ]..sort((a, b) => depth(states[b.id]!).compareTo(depth(states[a.id]!)));
    final top = ranked.take(direct ? maxDirectPools : maxPoolsPerPair).toList();
    _ranked[pair] = (DateTime.now(), top);
    return top;
  }

  /// A pool's depth, comparable between pools of one pair.
  static BigInt depth(UniPoolState s) {
    if (s.reserve0 != null && s.reserve1 != null) {
      return _sqrt(s.reserve0! * s.reserve1!);
    }
    return s.liquidity ?? BigInt.zero;
  }

  static BigInt _sqrt(BigInt n) {
    if (n <= BigInt.one) return n;
    var x = BigInt.one << ((n.bitLength + 1) >> 1);
    while (true) {
      final y = (x + n ~/ x) >> 1;
      if (y >= x) return x;
      x = y;
    }
  }

  /// The best way to swap [amountIn] of [tokenIn] into [tokenOut], shared
  /// between routes when that gives more. [gasPriceWei], when known, lets
  /// fewer routes win over more that give slightly more but burn more gas
  /// (unknown, [assumedGasPrice] is used).
  Future<UniQuote> bestQuote({
    required UniToken tokenIn,
    required UniToken tokenOut,
    required BigInt amountIn,
    BigInt? gasPriceWei,
    Future<BigInt?>? gasPrice,
    UniRouteCheck? simulate,
  }) async {
    if (tokenIn.sameAsset(tokenOut)) {
      throw const UniswapNoRoute('sameAsset');
    }
    // Read while the pools are priced; only needed at the end.
    final head = rpc.blockNumber();
    head.ignore();
    gasPrice?.ignore();
    final ins = tokenIn.poolCurrencies;
    final outs = tokenOut.poolCurrencies;
    final mids = [
      for (final m in kUniRouteBases)
        if (!ins.contains(m) && !outs.contains(m)) m,
    ];

    // Every pool the search could use, found together.
    final pairs = <(String, String)>{
      for (final a in ins)
        for (final b in outs) (a, b),
      for (final a in ins)
        for (final m in mids) (a, m),
      for (final m in mids)
        for (final b in outs) (m, b),
    };
    final found = <(String, String), List<UniPool>>{};
    await Future.wait([
      for (final p in pairs)
        _deepest(
          p,
          direct: ins.contains(p.$1) && outs.contains(p.$2),
          head: head,
        ).then((pools) => found[p] = pools),
    ]);
    final all = {for (final l in found.values) ...l}.toList();
    if (all.isEmpty) throw const UniswapNoRoute('noPool');
    final states = await discovery.liveState(all);
    bool live(UniPool p) =>
        !distrusted.contains(p.id) && (states[p.id]?.isLive ?? false);

    final n = splitSteps;
    BigInt at(int k) => amountIn * BigInt.from(k) ~/ BigInt.from(n);
    final pricer = _Pricer(this, states);

    // Step 1: the direct pools and the first pool of each two-pool route,
    // with a twentieth of the amount and with all of it.
    final direct = <UniHop>[
      for (final a in ins)
        for (final b in outs)
          for (final p in found[(a, b)] ?? const <UniPool>[])
            if (live(p)) UniHop(p, a, b),
    ];
    final firstToMid = <UniHop>[
      for (final a in ins)
        for (final m in mids)
          for (final p in found[(a, m)] ?? const <UniPool>[])
            if (live(p)) UniHop(p, a, m),
    ];
    if (direct.isEmpty && firstToMid.isEmpty) {
      throw const UniswapNoRoute('noPool');
    }
    // Also at nineteen twentieths: the best route's last step says whether
    // any other route could add to it (step 3).
    final probe = {1, n - 1, n}.where((k) => k >= 1).toList();
    await pricer.price([
      for (final h in [...direct, ...firstToMid])
        for (final k in probe) (h, at(k)),
    ]);

    // Step 2: from the two best first pools into each middle token (ETH
    // and WETH count as one), every pool on to the token wanted.
    final byAsset = <String, List<UniHop>>{};
    for (final h in firstToMid) {
      if (pricer.leg(h, at(n)) == null && pricer.leg(h, at(1)) == null) {
        continue;
      }
      byAsset.putIfAbsent(_assetKey(h.currencyOut), () => []).add(h);
    }
    final candidates = <List<UniHop>>[
      for (final h in direct) [h],
    ];
    for (final entry in byAsset.entries) {
      final firsts = entry.value
        ..sort(
          (x, y) => (pricer.leg(y, at(n))?.amountOut ?? BigInt.zero).compareTo(
            pricer.leg(x, at(n))?.amountOut ?? BigInt.zero,
          ),
        );
      for (final first in firsts.take(2)) {
        for (final m in mids.where((m) => _assetKey(m) == entry.key)) {
          for (final b in outs) {
            for (final p in found[(m, b)] ?? const <UniPool>[]) {
              if (!live(p) || p.id == first.pool.id) continue;
              candidates.add([first, UniHop(p, m, b)]);
            }
          }
        }
      }
    }
    await pricer.priceRoutes(candidates, [for (final k in probe) at(k)]);

    BigInt? outAt(List<UniHop> c, int k) =>
        pricer.route(c, at(k))?.last.amountOut;
    bool hooked(List<UniHop> c) =>
        c.any((h) => h.pool is UniV4Pool && (h.pool as UniV4Pool).hasHooks);

    // A v4 hook is code the pool's creator wrote, and it can tell a quoter
    // one price and give a swap another (seen on mainnet: a USDC/WETH pool
    // quoting 20% above the market, whose real swap reverts). Unless the
    // real swap can be simulated, a hooked route takes part only when it is
    // not suspiciously better than the best route without hooks.
    bool suspicious(List<UniHop> c) {
      if (!hooked(c)) return false;
      for (final k in {1, n}) {
        final mine = outAt(c, k);
        if (mine == null) continue;
        BigInt? plain;
        for (final o in candidates) {
          if (hooked(o)) continue;
          final v = outAt(o, k);
          if (v != null && (plain == null || v > plain)) plain = v;
        }
        if (plain == null ||
            mine * BigInt.from(10000) >
                plain * BigInt.from(10000 + kHookedEdgeBips)) {
          return true;
        }
      }
      return false;
    }

    candidates.removeWhere(
      (c) =>
          (outAt(c, 1) ?? BigInt.zero) <= BigInt.zero &&
          (outAt(c, n) ?? BigInt.zero) <= BigInt.zero,
    );
    if (candidates.isEmpty) throw const UniswapNoRoute('tooSmall');

    // What a route's gas costs, in the token received.
    final bestOut = candidates
        .map((c) => outAt(c, n) ?? BigInt.zero)
        .reduce((x, y) => x > y ? x : y);
    final costPerGas = _costPerGas(
      tokenIn: tokenIn,
      tokenOut: tokenOut,
      amountIn: amountIn,
      bestOut: bestOut,
      gasPriceWei:
          gasPriceWei ??
          await (gasPrice ?? Future.value(null)).catchError((_) => null) ??
          assumedGasPrice,
      found: found,
      states: states,
    );
    BigInt costOf(List<UniHop> c) => costPerGas(
      (pricer.route(c, at(n)) ?? pricer.route(c, at(1)) ?? const [])
          .fold(BigInt.zero, (s, l) => s + l.gas),
    );

    UniQuote? quoteOf(List<List<UniHop>> routes, UniSplit split) {
      final shares = <(List<UniHop>, int)>[
        for (var i = 0; i < routes.length; i++)
          if (split.steps[i] > 0) (routes[i], split.steps[i]),
      ]..sort((x, y) => y.$2.compareTo(x.$2));
      final parts = <UniPart>[];
      final legsOf = <List<_Leg>>[];
      var given = BigInt.zero;
      for (final (route, k) in shares) {
        final legs = pricer.route(route, at(k));
        if (legs == null) return null;
        given += at(k);
        legsOf.add(legs);
      }
      for (var i = 0; i < shares.length; i++) {
        final legs = legsOf[i];
        // Whole steps leave a few raw units over; the largest share takes
        // them (its price is for slightly less, so it is not overstated).
        final extra = i == 0 ? amountIn - given : BigInt.zero;
        parts.add(
          UniPart(
            route: UniRoute([for (final l in legs) l.hop]),
            amountIn: legs.first.amountIn + extra,
            amountOut: legs.last.amountOut,
            hopOutputs: [for (final l in legs) l.amountOut],
            gas: legs.fold(BigInt.zero, (s, l) => s + l.gas),
          ),
        );
      }
      return UniQuote(
        tokenIn: tokenIn,
        tokenOut: tokenOut,
        amountIn: amountIn,
        parts: parts,
        gasEstimate: parts.fold(kRouterOverheadGas, (s, p) => s + p.gas),
        priceImpact: _impact(legsOf, states),
        block: 0,
      );
    }

    final dropped = <List<UniHop>>{};
    for (var attempt = 0; attempt < 4; attempt++) {
      final usable = [
        for (final c in candidates)
          if (!dropped.contains(c) &&
              !c.any((h) => distrusted.contains(h.pool.id)) &&
              !(simulate == null && suspicious(c)))
            c,
      ];
      if (usable.isEmpty) break;

      // Step 3: the best single route, and the routes that could add to
      // it. A route can only take part if its first twentieth, less its
      // gas spread over the swap, beats the best route's last twentieth
      // (prices fall the more goes through a pool, so nothing it could
      // take from the best route is worth more than that). Usually none
      // can, and the search ends here.
      BigInt net(List<UniHop> c) => (outAt(c, n) ?? BigInt.zero) - costOf(c);
      final best = usable.reduce((x, y) => net(y) > net(x) ? y : x);
      final full = outAt(best, n);
      final before = n > 1 ? outAt(best, n - 1) : BigInt.zero;
      final last = full == null || before == null ? null : full - before;
      bool couldAdd(List<UniHop> c) {
        if (identical(c, best)) return false;
        final first = outAt(c, 1);
        if (first == null || first <= BigInt.zero) return false;
        if (last == null) return true;
        return (first - last) * BigInt.from(n) > costOf(c);
      }

      final ranked = usable.where(couldAdd).toList()
        ..sort(
          (x, y) => (outAt(y, 1) ?? BigInt.zero).compareTo(
            outAt(x, 1) ?? BigInt.zero,
          ),
        );
      final kept = [best, ...ranked.take(maxSplitRoutes - 1)];
      if (kept.length > 1) {
        await pricer.priceRoutes(kept, [
          for (var k = 2; k < n - 1; k++) at(k),
        ]);
      }

      // Step 4: the best sharing of the amount between them.
      final curves = [
        for (final c in kept)
          UniSplitCurve(
            pools: {for (final h in c) h.pool.id},
            outs: [
              BigInt.zero,
              for (var k = 1; k <= n; k++)
                at(k) > BigInt.zero ? outAt(c, k) : null,
            ],
            cost: costOf(c),
          ),
      ];
      final split = bestSplit(curves, steps: n, maxParts: maxParts);
      final q = split == null ? null : quoteOf(kept, split);
      if (q == null) {
        dropped.add(best);
        continue;
      }
      final quote = UniQuote(
        tokenIn: q.tokenIn,
        tokenOut: q.tokenOut,
        amountIn: q.amountIn,
        parts: q.parts,
        gasEstimate: q.gasEstimate,
        priceImpact: q.priceImpact,
        block: await head,
      );

      // A v4 hook is code the pool's creator wrote (see [suspicious]):
      // with the real swap simulated, a hooked pool that would not trade
      // is left out and the search runs again without it.
      final hookedIds = {
        for (final p in quote.pools)
          if (p is UniV4Pool && p.hasHooks) p.id,
      };
      if (hookedIds.isEmpty) return quote;
      final ok = simulate == null ? null : await simulate(quote);
      if (ok == true) return quote;
      if (ok == false) {
        distrusted.addAll(hookedIds);
        continue;
      }
      final doubtful = [
        for (final c in kept)
          if (suspicious(c)) c,
      ];
      if (doubtful.isEmpty) return quote;
      dropped.addAll(doubtful);
    }
    throw const UniswapNoRoute('noPool');
  }

  /// The gas price assumed when the node does not say (it only decides how
  /// many routes are worth their gas).
  static final BigInt assumedGasPrice = BigInt.from(1000000000);

  /// Pools whose swap failed where its quote said it would work: left out
  /// for the rest of the session.
  final Set<String> distrusted = {};

  /// Prices [q]'s routes again, each with its share of [amountIn] (the
  /// review screen's fresh check).
  Future<UniQuote> requote(UniQuote q, {BigInt? amountIn}) async {
    final amount = amountIn ?? q.amountIn;
    final head = await rpc.blockNumber();
    final states = await discovery.liveState(q.pools.toSet().toList());
    final pricer = _Pricer(this, states);
    final amounts = [
      for (final p in q.parts)
        q.amountIn == BigInt.zero
            ? BigInt.zero
            : p.amountIn * amount ~/ q.amountIn,
    ];
    amounts[0] += amount - amounts.fold(BigInt.zero, (s, a) => s + a);
    final routes = [for (final p in q.parts) p.route.hops];
    await pricer.priceRoutes(routes, null, amounts: amounts);
    final legsOf = <List<_Leg>>[];
    for (var i = 0; i < routes.length; i++) {
      final legs = pricer.route(routes[i], amounts[i]);
      if (legs == null) throw const UniswapNoRoute('tooSmall');
      legsOf.add(legs);
    }
    final parts = [
      for (final legs in legsOf)
        UniPart(
          route: UniRoute([for (final l in legs) l.hop]),
          amountIn: legs.first.amountIn,
          amountOut: legs.last.amountOut,
          hopOutputs: [for (final l in legs) l.amountOut],
          gas: legs.fold(BigInt.zero, (s, l) => s + l.gas),
        ),
    ];
    return UniQuote(
      tokenIn: q.tokenIn,
      tokenOut: q.tokenOut,
      amountIn: amount,
      parts: parts,
      gasEstimate: parts.fold(kRouterOverheadGas, (s, p) => s + p.gas),
      priceImpact: _impact(legsOf, states),
      block: head,
    );
  }

  /// Turns gas into the token received: directly when that is ETH; at the
  /// swap's own rate when ETH is paid; else at the price of the deepest
  /// pool between ETH and the token received (zero if there is none).
  BigInt Function(BigInt gas) _costPerGas({
    required UniToken tokenIn,
    required UniToken tokenOut,
    required BigInt amountIn,
    required BigInt? bestOut,
    required BigInt gasPriceWei,
    required Map<(String, String), List<UniPool>> found,
    required Map<String, UniPoolState> states,
  }) {
    if (tokenOut.isEthLike) return (gas) => gas * gasPriceWei;
    if (tokenIn.isEthLike) {
      if (bestOut == null || amountIn <= BigInt.zero) {
        return (_) => BigInt.zero;
      }
      return (gas) => gas * gasPriceWei * bestOut ~/ amountIn;
    }
    // Raw units of the token received per wei.
    double? rate;
    BigInt deepest = BigInt.zero;
    for (final eth in const [
      UniswapAddresses.nativeEth,
      UniswapAddresses.weth,
    ]) {
      for (final out in tokenOut.poolCurrencies) {
        for (final p in [
          ...?found[(eth, out)],
          ...?found[(out, eth)],
        ]) {
          final s = states[p.id];
          final price = s?.price0to1;
          if (s == null || price == null || price <= 0) continue;
          final d = depth(s);
          if (d <= deepest) continue;
          deepest = d;
          rate = p.currency0 == eth ? price : 1 / price;
        }
      }
    }
    if (rate == null || !rate.isFinite) return (_) => BigInt.zero;
    final r = rate;
    return (gas) {
      final v = (gas * gasPriceWei).toDouble() * r;
      return v.isFinite ? BigInt.from(v) : BigInt.zero;
    };
  }

  // ------------------------------------------------------------- pricing

  /// One price per (hop, amount); null where the pool would not quote.
  Future<List<_Leg?>> _quoteEach(
    List<(UniHop, BigInt)> asks,
    Map<String, UniPoolState> states,
  ) async {
    final out = List<_Leg?>.filled(asks.length, null);
    final calls = <EthCall>[];
    final callFor = <int>[];
    for (var i = 0; i < asks.length; i++) {
      final (hop, amount) = asks[i];
      if (amount <= BigInt.zero) continue;
      switch (hop.pool) {
        case UniV2Pool():
          final s = states[hop.pool.id];
          if (s?.reserve0 == null) continue;
          final (rIn, rOut) = hop.zeroForOne
              ? (s!.reserve0!, s.reserve1!)
              : (s!.reserve1!, s.reserve0!);
          final amountOut = v2AmountOut(amount, rIn, rOut);
          if (amountOut > BigInt.zero) {
            out[i] = _Leg(hop, amount, amountOut, kV2HopGas);
          }
        case final UniV3Pool p:
          calls.add(
            EthCall(
              UniswapAddresses.v3QuoterV2,
              encodeCall(
                'quoteExactInputSingle((address,address,uint256,uint24,uint160))',
                [
                  [hop.currencyIn, hop.currencyOut, amount, p.fee, BigInt.zero],
                ],
              ),
            ),
          );
          callFor.add(i);
        case final UniV4Pool p:
          if (amount >= BigInt.one << 127) continue;
          calls.add(
            EthCall(
              UniswapAddresses.v4Quoter,
              encodeCall(
                'quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))',
                [
                  [p.key, hop.zeroForOne, amount, Uint8List(0)],
                ],
              ),
            ),
          );
          callFor.add(i);
      }
    }
    if (calls.isNotEmpty) {
      final results = await rpc.multicall(calls, chunk: 25);
      for (var k = 0; k < results.length; k++) {
        final r = results[k];
        if (!r.success || r.data.length < 64) continue;
        final i = callFor[k];
        final (hop, amount) = asks[i];
        final BigInt amountOut;
        final BigInt gas;
        if (hop.pool is UniV3Pool) {
          final d = abiDecode('uint256,uint160,uint32,uint256', r.data);
          amountOut = d[0] as BigInt;
          gas = d[3] as BigInt;
        } else {
          final d = abiDecode('uint256,uint256', r.data);
          amountOut = d[0] as BigInt;
          gas = d[1] as BigInt;
        }
        if (amountOut > BigInt.zero) out[i] = _Leg(hop, amount, amountOut, gas);
      }
    }
    return out;
  }

  /// How much less the swap gives than its pools' current prices (less
  /// their fees) promise, as a fraction; null if a price is unknown.
  double? _impact(List<List<_Leg>> parts, Map<String, UniPoolState> states) {
    var ideal = 0.0;
    var actual = 0.0;
    for (final legs in parts) {
      var v = legs.first.amountIn.toDouble();
      for (final leg in legs) {
        final s = states[leg.hop.pool.id];
        final p = s?.price0to1;
        if (p == null || p <= 0) return null;
        final rate = leg.hop.zeroForOne ? p : 1 / p;
        final feePpm = (leg.hop.pool is UniV4Pool)
            ? (s!.lpFee ?? (leg.hop.pool.fee ?? 0))
            : (leg.hop.pool.fee ?? 0);
        v = v * rate * (1 - feePpm / 1e6);
      }
      ideal += v;
      actual += legs.last.amountOut.toDouble();
    }
    if (ideal <= 0) return null;
    return math.max(0, 1 - actual / ideal);
  }

  static String _assetKey(String currency) =>
      currency == UniswapAddresses.nativeEth ||
          currency == UniswapAddresses.weth
      ? 'eth'
      : currency;
}

/// Prices hops and routes at given amounts, each (hop, amount) once.
class _Pricer {
  _Pricer(this.quoter, this.states);

  final UniswapQuoter quoter;
  final Map<String, UniPoolState> states;
  final Map<String, _Leg?> _legs = {};

  static String _key(UniHop h, BigInt amount) =>
      '${h.pool.id}:${h.currencyIn}:$amount';

  _Leg? leg(UniHop h, BigInt amount) => _legs[_key(h, amount)];

  /// Prices every (hop, amount) not priced yet, in one batch.
  Future<void> price(Iterable<(UniHop, BigInt)> asks) async {
    final todo = <(UniHop, BigInt)>[];
    final seen = <String>{};
    for (final a in asks) {
      final k = _key(a.$1, a.$2);
      if (_legs.containsKey(k) || !seen.add(k)) continue;
      todo.add(a);
    }
    if (todo.isEmpty) return;
    final r = await quoter._quoteEach(todo, states);
    for (var i = 0; i < todo.length; i++) {
      _legs[_key(todo[i].$1, todo[i].$2)] = r[i];
    }
  }

  /// Prices each route at each of [levels] (or route i at [amounts][i]),
  /// pool by pool: one batch per pool position.
  Future<void> priceRoutes(
    List<List<UniHop>> routes,
    List<BigInt>? levels, {
    List<BigInt>? amounts,
  }) async {
    final starts = <(int, BigInt)>[
      for (var i = 0; i < routes.length; i++)
        if (amounts != null)
          (i, amounts[i])
        else
          for (final a in levels!) (i, a),
    ];
    final depth = routes.fold(0, (m, r) => math.max(m, r.length));
    // What enters each route's next pool, per (route, starting amount).
    final current = <(int, BigInt), BigInt?>{for (final s in starts) s: s.$2};
    for (var d = 0; d < depth; d++) {
      await price([
        for (final s in starts)
          if (d < routes[s.$1].length && current[s] != null)
            (routes[s.$1][d], current[s]!),
      ]);
      for (final s in starts) {
        if (d >= routes[s.$1].length || current[s] == null) continue;
        current[s] = leg(routes[s.$1][d], current[s]!)?.amountOut;
      }
    }
  }

  /// The legs of [route] starting with [amount], if every pool priced.
  List<_Leg>? route(List<UniHop> route, BigInt amount) {
    final legs = <_Leg>[];
    var a = amount;
    for (final h in route) {
      if (a <= BigInt.zero) return null;
      final l = leg(h, a);
      if (l == null) return null;
      legs.add(l);
      a = l.amountOut;
    }
    return legs;
  }
}

/// Uniswap v2's getAmountOut: 0.3% fee, constant product.
BigInt v2AmountOut(BigInt amountIn, BigInt reserveIn, BigInt reserveOut) {
  if (amountIn <= BigInt.zero ||
      reserveIn <= BigInt.zero ||
      reserveOut <= BigInt.zero) {
    return BigInt.zero;
  }
  final withFee = amountIn * BigInt.from(997);
  return withFee * reserveOut ~/ (reserveIn * BigInt.from(1000) + withFee);
}

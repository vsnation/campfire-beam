/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Prices a swap on every route Uniswap offers and picks the best.
//
// Routes tried: every pool between the two tokens (v2, v3, v4, any fee or
// hook), and every two-pool route through ETH, USDC, USDT, DAI, WBTC or
// WBEAM. Each pool is priced by Uniswap's own quoter contracts (v3
// QuoterV2, v4 V4Quoter) or, for v2, from the pair's reserves with v2's
// own formula, all through Multicall3: one request per step of the
// search, whatever the number of pools.
//
// The best route is the one that gives the most after its gas: a second
// pool costs about 100 000 gas more, which only matters on small swaps.

import 'dart:math' as math;
import 'dart:typed_data';

import 'abi.dart';
import 'eth_rpc.dart';
import 'uniswap_constants.dart';
import 'uniswap_discovery.dart';
import 'uniswap_models.dart';

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
  });

  final EthRpc rpc;
  final UniswapDiscovery discovery;

  /// How many of the deepest pools between the two tokens are priced.
  final int maxDirectPools;

  /// How many of the deepest pools of each pair on a two-pool route.
  final int maxPoolsPerPair;

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
    required int head,
  }) async {
    final cached = _ranked[pair];
    if (cached != null && DateTime.now().difference(cached.$1) < rankingLife) {
      return cached.$2;
    }
    final pools = await discovery.poolsBetween(pair.$1, pair.$2, head: head);
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

  /// The best way to swap [amountIn] of [tokenIn] into [tokenOut].
  /// [gasPriceWei], when known, lets a cheaper route win over one that
  /// gives slightly more but burns more gas.
  Future<UniQuote> bestQuote({
    required UniToken tokenIn,
    required UniToken tokenOut,
    required BigInt amountIn,
    BigInt? gasPriceWei,
    UniRouteCheck? simulate,
  }) async {
    if (tokenIn.sameAsset(tokenOut)) {
      throw const UniswapNoRoute('sameAsset');
    }
    final head = await rpc.blockNumber();
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

    // Step 1: the direct pools and the first pool of each two-pool route,
    // all with the full amount.
    final firstHops = <UniHop>[
      for (final a in ins)
        for (final b in outs)
          for (final p in found[(a, b)] ?? const <UniPool>[])
            if (live(p)) UniHop(p, a, b),
      for (final a in ins)
        for (final m in mids)
          for (final p in found[(a, m)] ?? const <UniPool>[])
            if (live(p)) UniHop(p, a, m),
    ];
    final firstLegs = await _quoteHops(firstHops, amountIn, states);

    final candidates = <List<_Leg>>[];
    for (final leg in firstLegs) {
      if (outs.contains(leg.hop.currencyOut)) candidates.add([leg]);
    }

    // Step 2: from the best first pool into each middle token (ETH and
    // WETH count as one), every pool on to the token wanted.
    final bestInto = <String, _Leg>{};
    for (final leg in firstLegs) {
      final m = leg.hop.currencyOut;
      if (outs.contains(m)) continue;
      final key = _assetKey(m);
      final current = bestInto[key];
      if (current == null || leg.amountOut > current.amountOut) {
        bestInto[key] = leg;
      }
    }
    final secondHops = <(UniHop, _Leg)>[];
    for (final first in bestInto.values) {
      final asset = _assetKey(first.hop.currencyOut);
      for (final m in mids.where((m) => _assetKey(m) == asset)) {
        for (final b in outs) {
          for (final p in found[(m, b)] ?? const <UniPool>[]) {
            if (!live(p) || first.hop.pool.id == p.id) continue;
            secondHops.add((UniHop(p, m, b), first));
          }
        }
      }
    }
    if (secondHops.isNotEmpty) {
      final quoted = await _quoteEach([
        for (final s in secondHops) (s.$1, s.$2.amountOut),
      ], states);
      for (var i = 0; i < secondHops.length; i++) {
        final leg = quoted[i];
        if (leg != null) candidates.add([secondHops[i].$2, leg]);
      }
    }

    candidates.removeWhere((c) => c.last.amountOut <= BigInt.zero);
    if (candidates.isEmpty) {
      throw UniswapNoRoute(firstHops.isEmpty ? 'noPool' : 'tooSmall');
    }

    BigInt gasOf(List<_Leg> c) =>
        c.fold(kRouterOverheadGas, (s, l) => s + l.gas);
    BigInt net(List<_Leg> c) {
      final out = c.last.amountOut;
      if (gasPriceWei == null) return out;
      final gasWei = gasOf(c) * gasPriceWei;
      if (tokenOut.isEthLike) return out - gasWei;
      if (tokenIn.isEthLike && amountIn > BigInt.zero) {
        return out - gasWei * out ~/ amountIn;
      }
      return out;
    }

    candidates.sort((a, b) => net(b).compareTo(net(a)));

    UniQuote quoteOf(List<_Leg> c) => UniQuote(
      tokenIn: tokenIn,
      tokenOut: tokenOut,
      amountIn: amountIn,
      amountOut: c.last.amountOut,
      route: UniRoute([for (final l in c) l.hop]),
      hopOutputs: [for (final l in c) l.amountOut],
      gasEstimate: gasOf(c),
      priceImpact: _impact(c, states),
      block: head,
    );

    // A v4 hook is code the pool's creator wrote, and it can tell a quoter
    // one price and give a swap another (seen on mainnet: a USDC/WETH pool
    // quoting 20% above the market, whose real swap reverts). So a route
    // through a hooked pool wins only when the real swap was simulated and
    // works, or, when it cannot be simulated (the user has not approved the
    // token yet), when it is not suspiciously better than the best route
    // without hooks.
    bool hooked(List<_Leg> c) => c.any(
      (l) => l.hop.pool is UniV4Pool && (l.hop.pool as UniV4Pool).hasHooks,
    );
    final plain = candidates.where((c) => !hooked(c)).firstOrNull;
    for (final c in candidates) {
      if (!hooked(c)) return quoteOf(c);
      final q = quoteOf(c);
      final ok = simulate == null ? null : await simulate(q);
      if (ok == true) return q;
      if (ok == false) {
        distrusted.addAll(
          c.where((l) => l.hop.pool is UniV4Pool).map((l) => l.hop.pool.id),
        );
        continue;
      }
      if (plain == null ||
          c.last.amountOut * BigInt.from(10000) <=
              plain.last.amountOut * BigInt.from(10000 + kHookedEdgeBips)) {
        return q;
      }
    }
    throw const UniswapNoRoute('noPool');
  }

  /// Pools whose swap failed where its quote said it would work: left out
  /// for the rest of the session.
  final Set<String> distrusted = {};

  /// Prices [route] again for [amountIn] (the review screen's fresh check).
  Future<UniQuote> requote(UniQuote q, {BigInt? amountIn}) async {
    final amount = amountIn ?? q.amountIn;
    final head = await rpc.blockNumber();
    final states = await discovery.liveState(q.route.pools.toList());
    var a = amount;
    final legs = <_Leg>[];
    for (final hop in q.route.hops) {
      final leg = (await _quoteEach([(hop, a)], states)).first;
      if (leg == null) throw const UniswapNoRoute('tooSmall');
      legs.add(leg);
      a = leg.amountOut;
    }
    return UniQuote(
      tokenIn: q.tokenIn,
      tokenOut: q.tokenOut,
      amountIn: amount,
      amountOut: a,
      route: q.route,
      hopOutputs: [for (final l in legs) l.amountOut],
      gasEstimate: legs.fold(kRouterOverheadGas, (s, l) => s + l.gas),
      priceImpact: _impact(legs, states),
      block: head,
    );
  }

  // ------------------------------------------------------------- pricing

  Future<List<_Leg>> _quoteHops(
    List<UniHop> hops,
    BigInt amountIn,
    Map<String, UniPoolState> states,
  ) async {
    final r = await _quoteEach([for (final h in hops) (h, amountIn)], states);
    return r.whereType<_Leg>().toList();
  }

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

  /// How much less the route gives than its pools' current prices (less
  /// their fees) promise, as a fraction; null if a price is unknown.
  double? _impact(List<_Leg> legs, Map<String, UniPoolState> states) {
    var ideal = legs.first.amountIn.toDouble();
    for (final leg in legs) {
      final s = states[leg.hop.pool.id];
      final p = s?.price0to1;
      if (p == null || p <= 0) return null;
      final rate = leg.hop.zeroForOne ? p : 1 / p;
      final feePpm = (leg.hop.pool is UniV4Pool)
          ? (s!.lpFee ?? (leg.hop.pool.fee ?? 0))
          : (leg.hop.pool.fee ?? 0);
      ideal = ideal * rate * (1 - feePpm / 1e6);
    }
    if (ideal <= 0) return null;
    final actual = legs.last.amountOut.toDouble();
    return math.max(0, 1 - actual / ideal);
  }

  static String _assetKey(String currency) =>
      currency == UniswapAddresses.nativeEth ||
          currency == UniswapAddresses.weth
      ? 'eth'
      : currency;
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

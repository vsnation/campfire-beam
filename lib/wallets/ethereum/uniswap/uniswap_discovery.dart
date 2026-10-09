/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Finds Uniswap pools: every v2 pair, every v3 pool (any fee tier) and
// every v4 pool (any fee, tick spacing or hook) between two currencies, or
// every pool that holds one token.
//
// Where pools come from, in order:
// 1. The list shipped with the app (`uniswap_known_pools.dart`): the pools
//    between the main tokens and every WBEAM pool up to a recent block.
// 2. Uniswap's own events after that block (v2 PairCreated, v3
//    PoolCreated, v4 Initialize), searched through the wallet's RPC. What
//    was searched is remembered ([UniPoolStore]) so the next search starts
//    where this one stopped.
// 3. When the RPC will not search events at all, direct lookups: the v2
//    pair, the v3 pool of each fee tier, the common v4 pools without hooks.
//
// Then [UniswapDiscovery.liveState] reads each pool's price and liquidity
// in one Multicall3 request, so empty pools are dropped before quoting.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'abi.dart';
import 'eth_rpc.dart';
import 'uniswap_constants.dart';
import 'uniswap_known_pools.dart';
import 'uniswap_models.dart';

/// What was found for one search, and up to which block.
class UniPoolScan {
  const UniPoolScan(this.pools, this.scannedTo);

  final List<UniPool> pools;
  final int scannedTo;

  Map<String, Object?> toJson() => {
    'to': scannedTo,
    'pools': [for (final p in pools) p.toJson()],
  };

  static UniPoolScan fromJson(Map<String, Object?> j) => UniPoolScan([
    for (final p in (j['pools']! as List).cast<Map<String, Object?>>())
      UniPool.fromJson(p),
  ], j['to']! as int);
}

/// Remembers searches between runs (pool lists are public chain data).
abstract class UniPoolStore {
  Future<UniPoolScan?> read(String key);
  Future<void> write(String key, UniPoolScan scan);
}

class MemoryUniPoolStore implements UniPoolStore {
  final Map<String, UniPoolScan> _m = {};

  @override
  Future<UniPoolScan?> read(String key) async => _m[key];

  @override
  Future<void> write(String key, UniPoolScan scan) async => _m[key] = scan;
}

/// A pool's price and liquidity right now.
class UniPoolState {
  const UniPoolState({
    this.reserve0,
    this.reserve1,
    this.sqrtPriceX96,
    this.liquidity,
    this.lpFee,
  });

  /// v2 reserves.
  final BigInt? reserve0;
  final BigInt? reserve1;

  /// v3 / v4 price and in-range liquidity.
  final BigInt? sqrtPriceX96;
  final BigInt? liquidity;

  /// v4: the fee the pool charges now (dynamic-fee pools included).
  final int? lpFee;

  /// The pool can trade: v2 with both reserves, v3/v4 initialised with
  /// liquidity in range.
  bool get isLive {
    if (reserve0 != null) {
      return reserve0! > BigInt.zero && reserve1! > BigInt.zero;
    }
    return (sqrtPriceX96 ?? BigInt.zero) > BigInt.zero &&
        (liquidity ?? BigInt.zero) > BigInt.zero;
  }

  /// Raw units of currency1 per raw unit of currency0, before fees.
  double? get price0to1 {
    if (reserve0 != null && reserve1 != null && reserve0! > BigInt.zero) {
      return reserve1!.toDouble() / reserve0!.toDouble();
    }
    final s = sqrtPriceX96;
    if (s == null || s == BigInt.zero) return null;
    // 2^96 as a double: as an int it overflows 64 bits.
    final r = s.toDouble() / math.pow(2.0, 96);
    return r * r;
  }
}

/// How discovery reached its answer, for the "where do prices come from"
/// line and for tests.
enum UniDiscoverySource { events, lookups }

class UniswapDiscovery {
  UniswapDiscovery({
    required this.rpc,
    UniPoolStore? store,
    this.maxLogRequests = 40,
    this.interactiveLogRequests = 3,
    this.freshBlocks = 300,
  }) : store = store ?? MemoryUniPoolStore();

  final EthRpc rpc;
  final UniPoolStore store;

  /// Event-search requests one background search may make.
  final int maxLogRequests;

  /// Event-search requests a quote waits for.
  final int interactiveLogRequests;

  /// A search younger than this many blocks (about an hour) is not
  /// repeated: new pools show up at most an hour late, and a quote does
  /// not cost dozens of event searches.
  final int freshBlocks;

  /// The tokens the shipped list covers pair by pair, and the token it
  /// covers completely (every pool holding it).
  static const _knownBases = {
    UniswapAddresses.nativeEth,
    UniswapAddresses.weth,
    '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
    '0xdac17f958d2ee523a2206206994597c13d831ec7',
    '0x6b175474e89094c44da98b954eedeac495271d0f',
    '0x2260fac5e5542a773aa44fbcfedf7c193bc2c599',
    _wbeam,
  };
  static const _wbeam = '0xe5acbb03d73267c03349c76ead672ee4d941f499';

  static bool _knownCoversPair(String c0, String c1) =>
      c0 == _wbeam ||
      c1 == _wbeam ||
      _knownBases.contains(c0) && _knownBases.contains(c1);

  /// The widest event search the RPC took (learnt from its refusals).
  int? _logRange;

  /// False once the RPC refused event searches outright: lookups only.
  bool _logsWork = true;

  UniDiscoverySource get source =>
      _logsWork ? UniDiscoverySource.events : UniDiscoverySource.lookups;

  static final List<UniPool> _known = [
    for (final j in kUniKnownPools) UniPool.fromJson(j),
  ];

  /// Every pool between [a] and [b] (raw pool currencies: native ETH is
  /// the zero address; v2 and v3 have no native pools).
  Future<List<UniPool>> poolsBetween(String a, String b, {int? head}) async {
    final (c0, c1) = sortCurrencies(a, b);
    if (c0 == c1) return const [];
    final tip = head ?? await rpc.blockNumber();
    final native = c0 == UniswapAddresses.nativeEth;
    final results = await Future.wait([
      if (!native) _v2Pair(c0, c1),
      if (!native)
        _scan(
          key: 'v3:$c0:$c1',
          address: UniswapAddresses.v3Factory,
          topics: [
            UniswapTopics.v3PoolCreated,
            topicOfAddress(c0),
            topicOfAddress(c1),
          ],
          deployBlock: UniswapDeployBlocks.v3Factory,
          head: tip,
          seed: () => _knownBetween(UniVersion.v3, c0, c1),
          seeded: _knownCoversPair(c0, c1),
          parse: _parseV3,
          fallback: () => _probeV3(c0, c1),
        ),
      _scan(
        key: 'v4:$c0:$c1',
        address: UniswapAddresses.v4PoolManager,
        topics: [
          UniswapTopics.v4Initialize,
          null,
          topicOfAddress(c0),
          topicOfAddress(c1),
        ],
        deployBlock: UniswapDeployBlocks.v4PoolManager,
        head: tip,
        seed: () => _knownBetween(UniVersion.v4, c0, c1),
        seeded: _knownCoversPair(c0, c1),
        parse: _parseV4,
        fallback: () => _probeV4(c0, c1),
      ),
    ]);
    return {for (final list in results) ...list}.toList();
  }

  /// Every pool holding [token] (all versions), for "what trades with
  /// WBEAM". Only sensible for tokens with a modest number of pools: not
  /// for ETH or the big stablecoins.
  Future<List<UniPool>> poolsOf(String token, {int? head}) async {
    final t = normAddress(token);
    final tip = head ?? await rpc.blockNumber();
    final topic = topicOfAddress(t);
    final native = t == UniswapAddresses.nativeEth;
    final searches = <Future<List<UniPool>>>[
      if (!native)
        for (final side in [0, 1])
          _scan(
            key: 'v2of$side:$t',
            address: UniswapAddresses.v2Factory,
            topics: [
              UniswapTopics.v2PairCreated,
              if (side == 0) topic else null,
              if (side == 1) topic,
            ],
            deployBlock: UniswapDeployBlocks.v2Factory,
            head: tip,
            seed: () => _knownOf(UniVersion.v2, t, side),
            seeded: t == _wbeam,
            parse: _parseV2,
            fallback: () async => const [],
          ),
      if (!native)
        for (final side in [0, 1])
          _scan(
            key: 'v3of$side:$t',
            address: UniswapAddresses.v3Factory,
            topics: [
              UniswapTopics.v3PoolCreated,
              if (side == 0) topic else null,
              if (side == 1) topic,
            ],
            deployBlock: UniswapDeployBlocks.v3Factory,
            head: tip,
            seed: () => _knownOf(UniVersion.v3, t, side),
            seeded: t == _wbeam,
            parse: _parseV3,
            fallback: () async => const [],
          ),
      for (final side in [0, 1])
        _scan(
          key: 'v4of$side:$t',
          address: UniswapAddresses.v4PoolManager,
          topics: [
            UniswapTopics.v4Initialize,
            null,
            if (side == 0) topic else null,
            if (side == 1) topic,
          ],
          deployBlock: UniswapDeployBlocks.v4PoolManager,
          head: tip,
          seed: () => _knownOf(UniVersion.v4, t, side),
          seeded: t == _wbeam,
          parse: _parseV4,
          fallback: () async => const [],
        ),
    ];
    final results = await Future.wait(searches);
    return {for (final list in results) ...list}.toList();
  }

  /// Price and liquidity of [pools], in one round trip (Multicall3).
  Future<Map<String, UniPoolState>> liveState(List<UniPool> pools) async {
    final calls = <EthCall>[];
    final owners = <(UniPool, int)>[];
    for (final p in pools) {
      switch (p) {
        case UniV2Pool():
          calls.add(EthCall(p.pair, selector('getReserves()')));
          owners.add((p, 0));
        case UniV3Pool():
          calls.add(EthCall(p.pool, selector('slot0()')));
          owners.add((p, 1));
          calls.add(EthCall(p.pool, selector('liquidity()')));
          owners.add((p, 2));
        case UniV4Pool():
          final id = hexToBytes(p.id);
          calls.add(
            EthCall(
              UniswapAddresses.v4StateView,
              encodeCall('getSlot0(bytes32)', [id]),
            ),
          );
          owners.add((p, 3));
          calls.add(
            EthCall(
              UniswapAddresses.v4StateView,
              encodeCall('getLiquidity(bytes32)', [id]),
            ),
          );
          owners.add((p, 4));
      }
    }
    final results = await rpc.multicall(calls, chunk: 120);
    final partial = <String, Map<String, Object>>{};
    for (var i = 0; i < results.length; i++) {
      final (pool, kind) = owners[i];
      final r = results[i];
      if (!r.success || r.data.isEmpty) continue;
      final m = partial.putIfAbsent(pool.id, () => {});
      try {
        switch (kind) {
          case 0:
            final d = abiDecode('uint112,uint112,uint32', r.data);
            m['r0'] = d[0];
            m['r1'] = d[1];
          case 1:
            m['sqrt'] = abiDecode('uint160', r.data.sublist(0, 32))[0];
          case 2:
          case 4:
            m['liq'] = abiDecode('uint128', r.data)[0];
          case 3:
            final d = abiDecode('uint160,int24,uint24,uint24', r.data);
            m['sqrt'] = d[0];
            m['lpFee'] = (d[3] as BigInt).toInt();
        }
      } on FormatException {
        // A pool whose answer does not decode is treated as unknown.
      }
    }
    return {
      for (final e in partial.entries)
        e.key: UniPoolState(
          reserve0: e.value['r0'] as BigInt?,
          reserve1: e.value['r1'] as BigInt?,
          sqrtPriceX96: e.value['sqrt'] as BigInt?,
          liquidity: e.value['liq'] as BigInt?,
          lpFee: e.value['lpFee'] as int?,
        ),
    };
  }

  // ------------------------------------------------------------- searches

  Future<List<UniPool>> _scan({
    required String key,
    required String address,
    required List<String?> topics,
    required int deployBlock,
    required int head,
    required List<UniPool> Function() seed,
    required bool seeded,
    required UniPool? Function(EthLog) parse,
    required Future<List<UniPool>> Function() fallback,
  }) async {
    final cached = await store.read(key);
    final start =
        cached ??
        (seeded
            ? UniPoolScan(
                seed(),
                math.max(kUniKnownPoolsBlock, deployBlock - 1),
              )
            : UniPoolScan(const [], deployBlock - 1));
    if (head - start.scannedTo < freshBlocks || !_logsWork) {
      if (!_logsWork) {
        return {...start.pools, ...await fallback()}.toList();
      }
      return start.pools;
    }
    try {
      // A quote waits for a few requests at most; a longer search goes on
      // in the background and the next quote sees what it found.
      final r = await rpc.getLogsAdaptive(
        address: address,
        topics: topics,
        fromBlock: start.scannedTo + 1,
        toBlock: head,
        maxRequests: interactiveLogRequests,
        knownRange: _logRange,
      );
      final next = _merge(start, r.logs, r.scannedTo, parse);
      await store.write(key, next);
      if (!r.complete) {
        _continueInBackground(
          key: key,
          address: address,
          topics: topics,
          head: head,
          parse: parse,
        );
        // Meanwhile the direct lookups, so nothing obvious is missing.
        return {...next.pools, ...await fallback()}.toList();
      }
      return next.pools;
    } on EthRpcError catch (e) {
      if (e.isRangeTooLong || e.code == -32601) {
        // The RPC does not search events (or not over ranges worth
        // searching): lookups for the rest of this session.
        final r = e.suggestedRange;
        if (r != null && r >= 1000) _logRange = r;
        if (r == null || r < 1000) _logsWork = false;
      }
      // Busy or refused this once: lookups this time, events next time.
      return {...start.pools, ...await fallback()}.toList();
    }
  }

  /// Searches still running in the background, by store key.
  final Set<String> _background = {};

  void _continueInBackground({
    required String key,
    required String address,
    required List<String?> topics,
    required int head,
    required UniPool? Function(EthLog) parse,
  }) {
    if (!_background.add(key)) return;
    unawaited(() async {
      try {
        final start = await store.read(key);
        if (start == null) return;
        final r = await rpc.getLogsAdaptive(
          address: address,
          topics: topics,
          fromBlock: start.scannedTo + 1,
          toBlock: head,
          maxRequests: maxLogRequests,
          knownRange: _logRange,
        );
        await store.write(key, _merge(start, r.logs, r.scannedTo, parse));
      } catch (_) {
        // Tried again with the next quote.
      } finally {
        _background.remove(key);
      }
    }());
  }

  static UniPoolScan _merge(
    UniPoolScan start,
    List<EthLog> logs,
    int scannedTo,
    UniPool? Function(EthLog) parse,
  ) {
    final pools = {...start.pools};
    for (final l in logs) {
      if (parse(l) case final p?) pools.add(p);
    }
    return UniPoolScan(pools.toList(), scannedTo);
  }

  List<UniPool> _knownBetween(UniVersion v, String c0, String c1) => [
    for (final p in _known)
      if (p.version == v && p.currency0 == c0 && p.currency1 == c1) p,
  ];

  List<UniPool> _knownOf(UniVersion v, String t, int side) => [
    for (final p in _known)
      if (p.version == v && (side == 0 ? p.currency0 : p.currency1) == t) p,
  ];

  Future<List<UniPool>> _v2Pair(String c0, String c1) async {
    final key = 'v2:$c0:$c1';
    final cached = await store.read(key);
    if (cached != null) return cached.pools;
    final r = await rpc.ethCall(
      UniswapAddresses.v2Factory,
      encodeCall('getPair(address,address)', [c0, c1]),
    );
    final pair = abiDecode('address', r)[0] as String;
    final pools = pair == UniswapAddresses.nativeEth
        ? <UniPool>[]
        : [UniV2Pool(pair: pair, currency0: c0, currency1: c1)];
    // A pair, once created, never goes away; "none" is checked again in a
    // later session (scannedTo 0 is never "up to date").
    if (pools.isNotEmpty) await store.write(key, UniPoolScan(pools, 1 << 62));
    return pools;
  }

  Future<List<UniPool>> _probeV3(String c0, String c1) async {
    final fees = kV3FeeTickSpacing.entries.toList();
    final results = await rpc.multicall([
      for (final f in fees)
        EthCall(
          UniswapAddresses.v3Factory,
          encodeCall('getPool(address,address,uint24)', [c0, c1, f.key]),
        ),
    ]);
    return [
      for (var i = 0; i < fees.length; i++)
        if (results[i].success)
          if (abiDecode('address', results[i].data)[0] case final String pool
              when pool != UniswapAddresses.nativeEth)
            UniV3Pool(
              pool: pool,
              currency0: c0,
              currency1: c1,
              fee: fees[i].key,
              tickSpacing: fees[i].value,
            ),
    ];
  }

  Future<List<UniPool>> _probeV4(String c0, String c1) async {
    final candidates = [
      for (final k in kV4ProbeKeys)
        UniV4Pool.key(
          currency0: c0,
          currency1: c1,
          fee: k.fee,
          tickSpacing: k.tickSpacing,
          hooks: UniswapAddresses.nativeEth,
        ),
    ];
    final results = await rpc.multicall([
      for (final p in candidates)
        EthCall(
          UniswapAddresses.v4StateView,
          encodeCall('getSlot0(bytes32)', [hexToBytes(p.id)]),
        ),
    ]);
    return [
      for (var i = 0; i < candidates.length; i++)
        if (results[i].success &&
            results[i].data.length >= 32 &&
            bytesToBigInt(results[i].data.sublist(0, 32)) > BigInt.zero)
          candidates[i],
    ];
  }

  // -------------------------------------------------------------- parsing

  static UniPool? _parseV2(EthLog l) {
    if (l.topics.length < 3 || l.data.length < 32) return null;
    return UniV2Pool(
      pair: abiDecode('address', l.data.sublist(0, 32))[0] as String,
      currency0: addressOfTopic(l.topics[1]),
      currency1: addressOfTopic(l.topics[2]),
    );
  }

  static UniPool? _parseV3(EthLog l) {
    if (l.topics.length < 4 || l.data.length < 64) return null;
    final d = abiDecode('int24,address', l.data);
    return UniV3Pool(
      pool: d[1] as String,
      currency0: addressOfTopic(l.topics[1]),
      currency1: addressOfTopic(l.topics[2]),
      fee: BigInt.parse(l.topics[3].substring(2), radix: 16).toInt(),
      tickSpacing: (d[0] as BigInt).toInt(),
    );
  }

  static UniPool? _parseV4(EthLog l) {
    if (l.topics.length < 4 || l.data.length < 96) return null;
    final d = abiDecode('uint24,int24,address', l.data.sublist(0, 96));
    return UniV4Pool.key(
      currency0: addressOfTopic(l.topics[2]),
      currency1: addressOfTopic(l.topics[3]),
      fee: (d[0] as BigInt).toInt(),
      tickSpacing: (d[1] as BigInt).toInt(),
      hooks: d[2] as String,
    );
  }
}

/// Bytes helper for tests.
Uint8List hex(String h) => hexToBytes(h);

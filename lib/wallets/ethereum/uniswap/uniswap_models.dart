/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Tokens, pools, routes and quotes for the Uniswap swap.
//
// ETH and WETH are one asset to a person and two to Uniswap: v2 and v3
// pools hold WETH, v4 pools hold either. A [UniToken] is what the user
// holds; a pool side is a raw currency address. [UniToken.poolCurrencies]
// says which pool sides a token can trade through, and the router converts
// ETH ⇄ WETH on the way (`uniswap_planner.dart`).

import 'dart:typed_data';

import 'abi.dart';
import 'uniswap_constants.dart';

/// What a person swaps: ETH or an ERC-20 token.
class UniToken {
  const UniToken({
    required this.address,
    required this.symbol,
    required this.decimals,
    this.name,
  });

  static const eth = UniToken(
    address: UniswapAddresses.nativeEth,
    symbol: 'ETH',
    decimals: 18,
    name: 'Ether',
  );

  /// 0x-prefixed lowercase; the zero address for ETH.
  final String address;
  final String symbol;
  final int decimals;
  final String? name;

  bool get isEth => address == UniswapAddresses.nativeEth;
  bool get isWeth => address == UniswapAddresses.weth;

  /// ETH and WETH: the same asset, two forms.
  bool get isEthLike => isEth || isWeth;

  /// The pool sides this token trades through: for ETH and WETH both
  /// native ETH (v4) and WETH (all versions).
  List<String> get poolCurrencies => isEthLike
      ? const [UniswapAddresses.nativeEth, UniswapAddresses.weth]
      : [address];

  bool sameAsset(UniToken other) =>
      address == other.address || (isEthLike && other.isEthLike);

  @override
  bool operator ==(Object other) =>
      other is UniToken && other.address == address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() => symbol;
}

enum UniVersion {
  v2('v2'),
  v3('v3'),
  v4('v4');

  const UniVersion(this.label);
  final String label;
}

/// One Uniswap pool. [currency0] < [currency1] as Uniswap sorts them.
sealed class UniPool {
  const UniPool({required this.currency0, required this.currency1});

  final String currency0;
  final String currency1;

  UniVersion get version;

  /// Fee in hundredths of a bip (3000 = 0.3%); null for a v4 pool whose
  /// hook sets the fee per swap.
  int? get fee;

  /// A stable id: the pair address (v2, v3) or the v4 pool id.
  String get id;

  bool has(String currency) => currency0 == currency || currency1 == currency;

  String other(String currency) =>
      currency == currency0 ? currency1 : currency0;

  @override
  bool operator ==(Object other) => other is UniPool && other.id == id;

  @override
  int get hashCode => id.hashCode;

  Map<String, Object?> toJson();

  static UniPool fromJson(Map<String, Object?> j) => switch (j['v']) {
    'v2' => UniV2Pool(
      pair: j['pair']! as String,
      currency0: j['c0']! as String,
      currency1: j['c1']! as String,
    ),
    'v3' => UniV3Pool(
      pool: j['pool']! as String,
      currency0: j['c0']! as String,
      currency1: j['c1']! as String,
      fee: j['fee']! as int,
      tickSpacing: j['ts']! as int,
    ),
    'v4' => UniV4Pool.key(
      currency0: j['c0']! as String,
      currency1: j['c1']! as String,
      fee: j['fee']! as int,
      tickSpacing: j['ts']! as int,
      hooks: j['hooks']! as String,
    ),
    _ => throw FormatException('unknown pool ${j['v']}'),
  };
}

class UniV2Pool extends UniPool {
  const UniV2Pool({
    required this.pair,
    required super.currency0,
    required super.currency1,
  });

  final String pair;

  @override
  UniVersion get version => UniVersion.v2;

  @override
  int get fee => 3000;

  @override
  String get id => pair;

  @override
  Map<String, Object?> toJson() => {
    'v': 'v2',
    'pair': pair,
    'c0': currency0,
    'c1': currency1,
  };
}

class UniV3Pool extends UniPool {
  const UniV3Pool({
    required this.pool,
    required super.currency0,
    required super.currency1,
    required this.fee,
    required this.tickSpacing,
  });

  final String pool;
  @override
  final int fee;
  final int tickSpacing;

  @override
  UniVersion get version => UniVersion.v3;

  @override
  String get id => pool;

  @override
  Map<String, Object?> toJson() => {
    'v': 'v3',
    'pool': pool,
    'c0': currency0,
    'c1': currency1,
    'fee': fee,
    'ts': tickSpacing,
  };
}

class UniV4Pool extends UniPool {
  const UniV4Pool({
    required super.currency0,
    required super.currency1,
    required this.feeField,
    required this.tickSpacing,
    required this.hooks,
  });

  /// [fee] as stored in the pool key (may carry [kV4DynamicFeeFlag]).
  final int feeField;
  final int tickSpacing;
  final String hooks;

  factory UniV4Pool.key({
    required String currency0,
    required String currency1,
    required int fee,
    required int tickSpacing,
    required String hooks,
  }) => UniV4Pool(
    currency0: currency0,
    currency1: currency1,
    feeField: fee,
    tickSpacing: tickSpacing,
    hooks: hooks,
  );

  @override
  UniVersion get version => UniVersion.v4;

  bool get isDynamicFee => feeField & kV4DynamicFeeFlag != 0;

  @override
  int? get fee => isDynamicFee ? null : feeField;

  bool get hasHooks => hooks != UniswapAddresses.nativeEth;

  /// The PoolKey tuple: (currency0, currency1, fee, tickSpacing, hooks).
  List<Object> get key => [currency0, currency1, feeField, tickSpacing, hooks];

  /// keccak256(abi.encode(PoolKey)) — the pool's id.
  @override
  String get id => bytesToHex(
    keccak(abiEncode('address,address,uint24,int24,address', key)),
  );

  @override
  Map<String, Object?> toJson() => {
    'v': 'v4',
    'c0': currency0,
    'c1': currency1,
    'fee': feeField,
    'ts': tickSpacing,
    'hooks': hooks,
  };
}

/// One step of a route: [pool] from [currencyIn] to [currencyOut] (raw
/// pool sides; ETH-like steps may use native ETH or WETH).
class UniHop {
  const UniHop(this.pool, this.currencyIn, this.currencyOut);

  final UniPool pool;
  final String currencyIn;
  final String currencyOut;

  bool get zeroForOne => currencyIn == pool.currency0;
}

/// The pools a swap goes through, in order.
class UniRoute {
  const UniRoute(this.hops);

  final List<UniHop> hops;

  bool get isDirect => hops.length == 1;

  Iterable<UniPool> get pools => hops.map((h) => h.pool);

  String get id => hops.map((h) => h.pool.id).join('>');
}

/// A price for swapping [amountIn] of [tokenIn] into [tokenOut].
class UniQuote {
  const UniQuote({
    required this.tokenIn,
    required this.tokenOut,
    required this.amountIn,
    required this.amountOut,
    required this.route,
    required this.hopOutputs,
    required this.gasEstimate,
    this.priceImpact,
    required this.block,
  });

  final UniToken tokenIn;
  final UniToken tokenOut;
  final BigInt amountIn;
  final BigInt amountOut;
  final UniRoute route;

  /// What each hop gives, in order (the last is [amountOut]).
  final List<BigInt> hopOutputs;

  /// The quoters' gas estimate for the swaps alone (the router and the
  /// permit add a little; the real limit comes from eth_estimateGas).
  final BigInt gasEstimate;

  /// How much worse this is than the route's current price, as a fraction
  /// (0.031 = 3.1%); null when it could not be measured.
  final double? priceImpact;

  /// The block the quote was read at (for "price moved" checks).
  final int block;

  /// The least the user accepts: [amountOut] less [slippageBips] / 10 000.
  BigInt minimumOut(int slippageBips) =>
      amountOut * BigInt.from(10000 - slippageBips) ~/ BigInt.from(10000);
}

/// A pool's address as an `address` word, for event topics.
String topicOfAddress(String address) =>
    '0x${normAddress(address).substring(2).padLeft(64, '0')}';

String addressOfTopic(String topic) =>
    '0x${topic.substring(topic.length - 40)}'.toLowerCase();

/// The two currencies in Uniswap's order (lower address first).
(String, String) sortCurrencies(String a, String b) {
  final x = normAddress(a);
  final y = normAddress(b);
  return x.compareTo(y) < 0 ? (x, y) : (y, x);
}

/// Bytes of a v3 path: token, fee (3 bytes), token, …
Uint8List v3Path(List<String> tokens, List<int> fees) {
  final b = BytesBuilder();
  for (var i = 0; i < tokens.length; i++) {
    b.add(hexToBytes(tokens[i]));
    if (i < fees.length) {
      b.add([(fees[i] >> 16) & 0xff, (fees[i] >> 8) & 0xff, fees[i] & 0xff]);
    }
  }
  return b.toBytes();
}

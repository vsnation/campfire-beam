/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What a crossing pays the bridge's relayer, computed the way the relayer
// computes its own minimum (BeamMW beam-bridge-ethrelay, utils/eth_gas.js
// and utils/eth_fee.js, 2026-10-09).
//
// Going to Ethereum the relayer pays Ethereum gas, so the fee follows gas:
//
//   maxFeePerGas = 2 × next base fee + median tip (10 blocks, 50th
//                  percentile), the tip clamped to 0.01–3 gwei
//   fee          = relayGas × maxFeePerGas × ETH/USD / asset/USD
//
// The relayer refuses a message whose fee is below that (it re-checks it
// about every 30 minutes and relays it once gas has come down), and keeps
// whatever is above it. The wallet sets the fee, so it is not a guess but
// a price: [kBridgeFeeMargin] buys room for gas to rise between the quote
// and the relayer's check, nothing more.
//
// Going to BEAM the relayer settles on BEAM and does not check the fee;
// the official apps pay 0.02 BEAM worth, and so does Campfire.

import 'dart:math' as math;

import 'bridge_routes.dart';

/// Room for Ethereum gas to rise before the relayer checks a b2e fee. An
/// underpaid crossing is not lost, only later (see above).
const double kBridgeFeeMargin = 1.3;

/// Above this share of the amount, the fee is pointed out before the user
/// confirms.
const double kBridgeFeeWarnShare = 0.10;

/// What an e2b crossing pays the relayer: 0.02 BEAM worth.
const double kBridgeE2bFeeBeam = 0.02;

/// The relayer's tip clamp, in wei.
final BigInt kBridgeMinTip = BigInt.from(10000000); // 0.01 gwei
final BigInt kBridgeMaxTip = BigInt.from(3000000000); // 3 gwei

/// The gas price the relayer prices a b2e payout at.
class BridgeRelayerGas {
  const BridgeRelayerGas({
    required this.baseFee,
    required this.tip,
    required this.at,
  });

  /// Parses `eth_feeHistory(0xa, "latest", [50])`'s result.
  factory BridgeRelayerGas.fromFeeHistory(
    Map<String, dynamic> result, {
    DateTime? at,
  }) {
    BigInt hex(Object? v) {
      final s = v! as String;
      return s == '0x' ? BigInt.zero : BigInt.parse(s.substring(2), radix: 16);
    }

    final bases = (result['baseFeePerGas'] as List).map(hex).toList();
    if (bases.isEmpty) throw const FormatException('no baseFeePerGas');
    final tips = <BigInt>[
      for (final row in (result['reward'] as List?) ?? const [])
        if ((row as List).isNotEmpty) hex(row.first),
    ]..sort();
    var tip = tips.isEmpty ? kBridgeMinTip : _median(tips);
    if (tip < kBridgeMinTip) tip = kBridgeMinTip;
    if (tip > kBridgeMaxTip) tip = kBridgeMaxTip;
    return BridgeRelayerGas(
      baseFee: bases.last,
      tip: tip,
      at: at ?? DateTime.now(),
    );
  }

  /// The next block's base fee, in wei.
  final BigInt baseFee;

  /// The clamped median tip, in wei.
  final BigInt tip;

  final DateTime at;

  BigInt get maxFeePerGas => baseFee * BigInt.two + tip;

  /// The relayer's median: the upper of the two middle values when there
  /// are an even number (`sorted[Math.floor(n / 2)]`, eth_gas.js), never
  /// their average, which would quote below the relayer's minimum.
  static BigInt _median(List<BigInt> sorted) => sorted[sorted.length ~/ 2];
}

/// USD prices by CoinGecko id, and when they were read.
class BridgePrices {
  const BridgePrices(this.usd, this.at);

  final Map<String, double> usd;
  final DateTime at;

  /// The price of [id], or null when unknown or not a positive number.
  double? of(String id) {
    final v = usd[id];
    return v != null && v.isFinite && v > 0 ? v : null;
  }
}

/// [v] rounded down to a multiple of [grid].
BigInt floorToGrid(BigInt v, BigInt grid) => v - v % grid;

/// [v] rounded up to a multiple of [grid].
BigInt ceilToGrid(BigInt v, BigInt grid) {
  final r = v % grid;
  return r == BigInt.zero ? v : v + grid - r;
}

/// The b2e relayer fee in groth for [route], rounded up to the route's
/// grid; null when a price is missing (quote nothing rather than guess).
BigInt? b2eRelayerFeeGroth(
  BridgeRoute route,
  BridgeRelayerGas gas,
  BridgePrices prices, {
  double margin = kBridgeFeeMargin,
}) {
  final ethUsd = prices.of('ethereum');
  final assetUsd = prices.of(route.coingeckoId);
  if (ethUsd == null || assetUsd == null) return null;
  final costUsd = route.relayGas * gas.maxFeePerGas.toDouble() / 1e18 * ethUsd;
  final groth = costUsd / assetUsd * 1e8 * margin;
  if (!groth.isFinite || groth <= 0) return null;
  return ceilToGrid(BigInt.from(groth.ceil()), route.beamGrid);
}

/// The e2b relayer fee in Ethereum units for [route] (0.02 BEAM worth),
/// rounded up to the route's Ethereum grid; null when a price is missing.
BigInt? e2bRelayerFee(BridgeRoute route, BridgePrices prices) {
  if (route.isBeam) {
    return BigInt.from((kBridgeE2bFeeBeam * 1e8).round());
  }
  final beamUsd = prices.of('beam');
  final assetUsd = prices.of(route.coingeckoId);
  if (beamUsd == null || assetUsd == null) return null;
  final units =
      kBridgeE2bFeeBeam * beamUsd / assetUsd * math.pow(10, route.ethDecimals);
  if (!units.isFinite || units <= 0) return null;
  return ceilToGrid(BigInt.from(units.ceil()), route.ethGrid);
}

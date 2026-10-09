/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What a crossing would do before anything is sent: its amounts and fees
// in each chain's own units, the reasons it cannot go (in plain words, for
// the screens to show as they are), and how long it takes. Built by
// `BridgeController.quote`.

import 'dart:typed_data';

import 'bridge_fees.dart';
import 'bridge_routes.dart';
import 'bridge_sides.dart';

/// How long crossings take, from 1,575 crossings indexed in 2026
/// (the project notes, C.3).
abstract final class BridgeTiming {
  /// To Ethereum: 61 BEAM blocks and the payout (p50 64–69 min).
  static const toEthereum = Duration(minutes: 65);

  /// To Ethereum, the slow tail when Ethereum gas is high (BEAM route p90
  /// ~11 h; the others ~3 h).
  static Duration toEthereumSlowest(BridgeRoute r) =>
      r.isBeam ? const Duration(hours: 11) : const Duration(hours: 3);

  /// To BEAM: the bridge brings it in 1.5–2 min (p50), then the claim.
  static const toBeam = Duration(minutes: 2);

  /// Not paid this long after the 61 blocks: waiting for gas.
  static const gasWait = Duration(minutes: 30);

  /// Not on BEAM this long after the lock: "not delivered yet".
  static const deliveryWait = Duration(minutes: 30);

  /// A claim whose sending threw and that is still claimable after this
  /// long did not go out: it may be claimed again (by the user).
  static const claimWait = Duration(minutes: 10);

  /// An approval not mined after this long ends the crossing (nothing was
  /// locked).
  static const approveWait = Duration(minutes: 30);
}

/// Prices older than this refuse a crossing to Ethereum (its fee follows
/// them); to BEAM the fee is about $0.0002 and an hour-old price will do
/// (06_beam_bridge.md, F.6).
const kBridgeToEthereumPriceAge = Duration(minutes: 10);
const kBridgeToBeamPriceAge = Duration(hours: 1);

/// A review older than this is checked again before anything is sent.
const kBridgeReviewAge = Duration(minutes: 15);

extension BridgeRouteUnits on BridgeRoute {
  /// Decimals a crossing can carry both ways: 8, or fewer when Ethereum
  /// has fewer (USDT: 6). Typing more would be floored away.
  int get movableDecimals => ethDecimals < BridgeRoute.beamDecimals
      ? ethDecimals
      : BridgeRoute.beamDecimals;

  String sourceSymbol(BridgeDirection d) =>
      d == BridgeDirection.toEthereum ? beamSymbol : ethSymbol;

  String destinationSymbol(BridgeDirection d) =>
      d == BridgeDirection.toEthereum ? ethSymbol : beamSymbol;

  int sourceDecimals(BridgeDirection d) =>
      d == BridgeDirection.toEthereum ? BridgeRoute.beamDecimals : ethDecimals;

  int destinationDecimals(BridgeDirection d) =>
      d == BridgeDirection.toEthereum ? ethDecimals : BridgeRoute.beamDecimals;

  /// The grid an amount leaving through [d] must sit on.
  BigInt sourceGrid(BridgeDirection d) =>
      d == BridgeDirection.toEthereum ? beamGrid : ethGrid;
}

// ----------------------------------------------------------------- quote

enum BridgeBlockCode {
  /// Nothing to move yet.
  noAmount,

  /// A token or the pipe is paused, blacklisted or charging a fee.
  frozen,

  /// Prices or Ethereum gas could not be read, or are too old.
  noPrice,

  /// A node did not answer.
  network,

  /// The bridge fee is as much as the amount or more.
  belowFee,

  /// Above the bridge's limit for one crossing.
  aboveMax,

  /// Not enough of the coin being moved.
  notEnough,

  /// Not enough BEAM for the BEAM network fee of the send.
  noBeamForFee,

  /// Not enough ETH for the Ethereum network fee.
  noEthForGas,

  /// The BEAM wallet cannot pay for claiming it on BEAM.
  noClaimFee,

  /// The amount cannot be carried (too small to arrive, off the grid).
  badAmount,
}

/// Why a crossing cannot go as it is, in plain words.
class BridgeBlock {
  const BridgeBlock(this.code, this.title, [this.detail]);

  final BridgeBlockCode code;
  final String title;
  final String? detail;

  @override
  String toString() => 'BridgeBlock(${code.name}: $title)';
}

enum BridgeWarningCode { highFee }

class BridgeWarning {
  const BridgeWarning(this.code, this.title, [this.detail]);

  final BridgeWarningCode code;
  final String title;
  final String? detail;
}

/// What can be read about a route before any amount: whether it is
/// frozen, the bridge fee now, the prices it follows.
class BridgeConditions {
  const BridgeConditions({
    required this.route,
    required this.direction,
    required this.at,
    this.freezes = const [],
    this.fee,
    this.feeNow,
    this.prices,
    this.gas,
    this.block,
  });

  final BridgeRoute route;
  final BridgeDirection direction;
  final DateTime at;
  final List<BridgeFreeze> freezes;

  /// To Ethereum: the least the bridge accepts right now, in groth; [fee]
  /// is this plus room for gas to rise before it pays ([kBridgeFeeMargin]).
  final BigInt? feeNow;

  /// The bridge fee in the source chain's units; null when it cannot be
  /// priced (then [block] says why).
  final BigInt? fee;
  final BridgePrices? prices;
  final BridgeRelayerGas? gas;

  /// Frozen, no price, or no answer.
  final BridgeBlock? block;
}

/// The balances a crossing draws on.
class BridgeBalances {
  const BridgeBalances({
    required this.source,
    required this.beam,
    required this.eth,
  });

  /// Of what leaves, in the source chain's units.
  final BigInt source;

  /// BEAM in the BEAM wallet, groth (its network fees).
  final BigInt beam;

  /// ETH in the Ethereum wallet, wei (its network fees); null going to
  /// Ethereum, where none is spent.
  final BigInt? eth;
}

/// What one crossing would do, priced, and whether it can go.
class BridgeQuote {
  const BridgeQuote({
    required this.route,
    required this.direction,
    required this.amount,
    required this.receives,
    required this.beamNetworkFee,
    required this.ethAddress,
    required this.balances,
    required this.at,
    this.fee,
    this.feeNow,
    this.plan,
    this.receiveKey,
    this.prices,
    this.warnings = const [],
    this.block,
  });

  final BridgeRoute route;
  final BridgeDirection direction;

  /// What leaves besides the fees (source units, on the route's grid).
  final BigInt amount;

  /// The bridge fee, paid to the bridge operator (source units); null
  /// when it cannot be priced.
  final BigInt? fee;

  /// To Ethereum: the bridge's own price now, in groth ([fee] adds room
  /// for gas rising before it pays; what it does not need, it keeps).
  final BigInt? feeNow;

  /// What arrives (destination units).
  final BigInt receives;

  /// BEAM network fee: of the send (to Ethereum), or of the claim (to
  /// BEAM), groth.
  final BigInt beamNetworkFee;

  /// To BEAM: the Ethereum transactions and their network fee.
  final EthPipeLockPlan? plan;

  /// To BEAM: the key the BEAM pipe pays this wallet with.
  final Uint8List? receiveKey;

  /// The user's Ethereum address (paid, or paying).
  final String ethAddress;

  final BridgeBalances balances;
  final BridgePrices? prices;
  final List<BridgeWarning> warnings;
  final BridgeBlock? block;
  final DateTime at;

  bool get toEthereum => direction == BridgeDirection.toEthereum;

  bool get canMove => block == null;

  /// Everything leaving the source wallet in its own coin.
  BigInt get totalSource =>
      amount +
      (fee ?? BigInt.zero) +
      (toEthereum && route.isBeam ? beamNetworkFee : BigInt.zero) +
      (!toEthereum && route.isNativeEth && plan != null
          ? plan!.maxGasCost
          : BigInt.zero);
}

/// A crossing checked and ready to send after the PIN.
class BridgePrepared {
  const BridgePrepared({
    required this.quote,
    required this.at,
    this.send,
    this.receiveKey,
    this.plan,
  });

  final BridgeQuote quote;
  final DateTime at;

  /// To Ethereum: the BEAM `send`, decoded and checked.
  final BeamPipePrepared? send;

  /// To BEAM: the key, read again, and the transactions priced again.
  final Uint8List? receiveKey;
  final EthPipeLockPlan? plan;

  /// The BEAM network fee: decoded from the built send, or the claim's.
  BigInt get beamNetworkFee => send?.networkFee ?? kBridgeClaimFeeGroth;

  /// To BEAM: the most the Ethereum transactions can cost.
  BigInt? get ethNetworkFee => plan?.maxGasCost;
}

/// The review is too old to send as it is.
class BridgeReviewExpired implements Exception {
  const BridgeReviewExpired();

  @override
  String toString() => 'BridgeReviewExpired';
}

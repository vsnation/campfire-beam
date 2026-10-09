/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// One buy, as Campfire keeps it on this device. The deposit address is the
// buy's only handle at buybeam.my: with it alone, where the buy is can
// always be asked again, after a restart or on another day.

import 'buybeam_client.dart';

class BuyBeamOrder {
  BuyBeamOrder({
    required this.depositAddress,
    required this.assetId,
    required this.symbol,
    required this.chain,
    required this.decimals,
    required this.sendAmount,
    required this.sendAmountRaw,
    required this.beamAddress,
    required this.beamWalletId,
    required this.refundAddress,
    required this.createdAt,
    this.beamEstimate,
    this.deadline,
    this.etaSeconds,
    this.lastState,
    this.beamTxId,
    this.terminal = false,
    this.sandbox = false,
    this.updatedAt,
  });

  factory BuyBeamOrder.fromJson(Map<String, dynamic> j) => BuyBeamOrder(
    depositAddress: j['depositAddress'] as String,
    assetId: j['assetId'] as String,
    symbol: j['symbol'] as String,
    chain: j['chain'] as String,
    decimals: (j['decimals'] as num).toInt(),
    sendAmount: j['sendAmount'] as String,
    sendAmountRaw: BigInt.parse(j['sendAmountRaw'] as String),
    beamAddress: j['beamAddress'] as String,
    beamWalletId: j['beamWalletId'] as String,
    refundAddress: j['refundAddress'] as String,
    createdAt: DateTime.parse(j['createdAt'] as String),
    beamEstimate: (j['beamEstimate'] as num?)?.toDouble(),
    deadline: j['deadline'] == null
        ? null
        : DateTime.parse(j['deadline'] as String),
    etaSeconds: (j['etaSeconds'] as num?)?.toInt(),
    lastState: j['state'] == null
        ? null
        : BuyBeamState.parse(j['state'] as String),
    beamTxId: j['beamTxId'] as String?,
    terminal: j['terminal'] as bool? ?? false,
    sandbox: j['sandbox'] as bool? ?? false,
    updatedAt: j['updatedAt'] == null
        ? null
        : DateTime.parse(j['updatedAt'] as String),
  );

  /// Where the user pays, and the buy's only handle.
  final String depositAddress;
  final String assetId;
  final String symbol;

  /// The coin's chain id ("btc", "eth"…).
  final String chain;
  final int decimals;

  /// Exactly what to send, as typed ("0.0122").
  final String sendAmount;
  final BigInt sendAmountRaw;

  /// The new BEAM address made for this buy.
  final String beamAddress;
  final String beamWalletId;
  final String refundAddress;
  final DateTime createdAt;

  /// The BEAM it buys, as buybeam.my said when it was ordered.
  final double? beamEstimate;
  final DateTime? deadline;
  final int? etaSeconds;
  final BuyBeamState? lastState;

  /// The BEAM transaction that delivered it.
  final String? beamTxId;

  /// buybeam.my will not change it again.
  final bool terminal;

  /// buybeam.my's test mode: nothing to pay.
  final bool sandbox;
  final DateTime? updatedAt;

  bool get isOpen => !terminal;

  String get chainName => BuyBeamAsset(
    assetId: assetId,
    symbol: symbol,
    blockchain: chain,
    decimals: decimals,
  ).chainName;

  BuyBeamOrder withStatus(BuyBeamOrderStatus s, DateTime at) => BuyBeamOrder(
    depositAddress: depositAddress,
    assetId: assetId,
    symbol: symbol,
    chain: chain,
    decimals: decimals,
    sendAmount: sendAmount,
    sendAmountRaw: sendAmountRaw,
    beamAddress: beamAddress,
    beamWalletId: beamWalletId,
    refundAddress: refundAddress,
    createdAt: createdAt,
    beamEstimate: s.beamEstimate ?? beamEstimate,
    deadline: s.deadline ?? deadline,
    etaSeconds: etaSeconds,
    lastState: s.state,
    beamTxId: s.beamTxId ?? beamTxId,
    terminal: s.terminal,
    sandbox: sandbox,
    updatedAt: at,
  );

  /// The same buy as far as the user can see (nothing to write).
  bool sameAs(BuyBeamOrder o) =>
      o.depositAddress == depositAddress &&
      o.lastState == lastState &&
      o.beamTxId == beamTxId &&
      o.terminal == terminal &&
      o.deadline == deadline &&
      o.beamEstimate == beamEstimate;

  Map<String, dynamic> toJson() => {
    'depositAddress': depositAddress,
    'assetId': assetId,
    'symbol': symbol,
    'chain': chain,
    'decimals': decimals,
    'sendAmount': sendAmount,
    'sendAmountRaw': sendAmountRaw.toString(),
    'beamAddress': beamAddress,
    'beamWalletId': beamWalletId,
    'refundAddress': refundAddress,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (beamEstimate != null) 'beamEstimate': beamEstimate,
    if (deadline != null) 'deadline': deadline!.toUtc().toIso8601String(),
    if (etaSeconds != null) 'etaSeconds': etaSeconds,
    if (lastState != null) 'state': lastState!.wire,
    if (beamTxId != null) 'beamTxId': beamTxId,
    'terminal': terminal,
    'sandbox': sandbox,
    if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
  };
}

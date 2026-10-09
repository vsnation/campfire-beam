/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// One crossing between the user's own BEAM wallet and their own Ethereum
// wallet, as Campfire remembers it: what was sent, every transaction id
// and message id the two chains gave back, and where the money is now.
//
// A record is the only thing that ties a BEAM transaction to the Ethereum
// payout it pays for (or an Ethereum lock to the BEAM claim), so it is
// written before every step that cannot be undone and right after each
// one returns (`bridge_store.dart`), and it survives the app being closed.

import 'bridge_routes.dart';

/// Where a crossing is.
///
/// To Ethereum: [quoted] → [sending] → [sent] → [confirmed] → [paid], or
/// [waitingForGas] on the way, or [failed] (nothing left the wallet), or
/// [unknown] (the BEAM wallet did not say whether it sent).
///
/// To BEAM: [approving] → [locking] → [locked] → [delivered] →
/// [claiming] → [claimed], or [notDeliveredYet] on the way, or
/// [lockFailed] (nothing was locked), or [unknown] (Ethereum did not say
/// whether the lock was sent).
enum BridgeCrossingState {
  /// Priced, nothing sent. Never stored: a record starts at the first
  /// step that cannot be undone.
  quoted,

  /// To Ethereum: the BEAM transaction is being handed to the wallet.
  sending,

  /// To Ethereum: the BEAM transaction is sent ([BridgeCrossing.beamTxId]).
  sent,

  /// To Ethereum: mined at [BridgeCrossing.height] as BEAM-side message
  /// [BridgeCrossing.msgId]; the bridge pays after 61 blocks.
  confirmed,

  /// To Ethereum: the coins are in the Ethereum wallet.
  paid,

  /// To Ethereum: due, not paid: Ethereum gas costs more right now than
  /// the fee that was paid; the bridge retries about every 30 minutes.
  waitingForGas,

  /// To Ethereum: the BEAM transaction failed; nothing left the wallet.
  failed,

  /// To BEAM: letting the bridge take the token (one or two Ethereum
  /// transactions before the lock).
  approving,

  /// To BEAM: the lock is being sent, or is sent
  /// ([BridgeCrossing.lockHash]) and not yet mined.
  locking,

  /// To BEAM: locked on Ethereum as message [BridgeCrossing.msgId].
  locked,

  /// To BEAM: the bridge brought it to BEAM; it can be claimed.
  delivered,

  /// To BEAM: the claim is being sent, or is sent
  /// ([BridgeCrossing.claimTxId]).
  claiming,

  /// To BEAM: the coins are in the BEAM wallet.
  claimed,

  /// To BEAM: the lock did not happen; nothing was locked.
  lockFailed,

  /// To BEAM: locked more than 30 minutes ago and not on BEAM yet.
  notDeliveredYet,

  /// A transaction may or may not have gone out (the wallet threw after
  /// it may have broadcast it). Campfire keeps looking; it never sends
  /// again by itself.
  unknown;

  /// Nothing more will happen to it.
  bool get isFinal =>
      this == paid || this == failed || this == claimed || this == lockFailed;

  /// It ended with the coins where the user wanted them.
  bool get isDone => this == paid || this == claimed;

  static BridgeCrossingState parse(String wire) => values.firstWhere(
    (s) => s.name == wire,
    orElse: () => throw FormatException('unknown crossing state "$wire"'),
  );
}

class BridgeCrossing {
  BridgeCrossing({
    required this.id,
    required this.routeId,
    required this.direction,
    required this.state,
    required this.amount,
    required this.receives,
    required this.relayerFee,
    required this.beamNetworkFee,
    required this.beamWalletId,
    required this.ethWalletId,
    required this.ethAddress,
    required this.createdAt,
    required this.updatedAt,
    BigInt? ethNetworkFee,
    this.beamReceiveKey,
    this.approveHashes = const [],
    this.lockHash,
    this.beamTxId,
    this.claimTxId,
    this.msgId,
    this.countBefore,
    this.height,
    this.dueAt,
    this.lockedAt,
    this.deliveredAt,
    this.claimStartedAt,
    this.finishedAt,
    this.lastError,
    this.autoClaim = false,
  }) : ethNetworkFee = ethNetworkFee ?? BigInt.zero;

  factory BridgeCrossing.fromJson(Map<String, dynamic> j) {
    BigInt big(String k) => BigInt.parse(j[k] as String);
    DateTime? time(String k) =>
        j[k] == null ? null : DateTime.parse(j[k] as String);
    final direction = j['direction'] as String;
    return BridgeCrossing(
      id: j['id'] as String,
      routeId: j['route'] as String,
      direction: BridgeDirection.values.firstWhere(
        (d) => d.name == direction,
        orElse: () => throw FormatException('direction "$direction"'),
      ),
      state: BridgeCrossingState.parse(j['state'] as String),
      amount: big('amount'),
      receives: big('receives'),
      relayerFee: big('relayerFee'),
      beamNetworkFee: big('beamNetworkFee'),
      ethNetworkFee: big('ethNetworkFee'),
      beamWalletId: j['beamWalletId'] as String,
      ethWalletId: j['ethWalletId'] as String,
      ethAddress: j['ethAddress'] as String,
      beamReceiveKey: j['beamReceiveKey'] as String?,
      approveHashes: [
        for (final h in (j['approveHashes'] as List?) ?? const []) h as String,
      ],
      lockHash: j['lockHash'] as String?,
      beamTxId: j['beamTxId'] as String?,
      claimTxId: j['claimTxId'] as String?,
      msgId: j['msgId'] as int?,
      countBefore: j['countBefore'] as int?,
      height: j['height'] as int?,
      createdAt: time('createdAt')!,
      updatedAt: time('updatedAt')!,
      dueAt: time('dueAt'),
      lockedAt: time('lockedAt'),
      deliveredAt: time('deliveredAt'),
      claimStartedAt: time('claimStartedAt'),
      finishedAt: time('finishedAt'),
      lastError: j['lastError'] as String?,
      autoClaim: j['autoClaim'] as bool? ?? false,
    );
  }

  final String id;
  final String routeId;
  final BridgeDirection direction;
  final BridgeCrossingState state;

  /// What leaves the source wallet besides the fees, in the source chain's
  /// units: groth to Ethereum, Ethereum units (wei for ETH) to BEAM.
  final BigInt amount;

  /// What arrives, in the destination chain's units: Ethereum units to
  /// Ethereum, groth to BEAM.
  final BigInt receives;

  /// The bridge fee, in the source chain's units (locked with [amount]).
  final BigInt relayerFee;

  /// The BEAM network fee in groth: of the send (to Ethereum) or of the
  /// claim (to BEAM).
  final BigInt beamNetworkFee;

  /// To BEAM: the most the Ethereum transactions could cost, in wei.
  final BigInt ethNetworkFee;

  final String beamWalletId;
  final String ethWalletId;

  /// The Ethereum wallet's address: paid to Ethereum, the sender to BEAM.
  final String ethAddress;

  /// To BEAM: the 33-byte key the BEAM pipe pays, hex.
  final String? beamReceiveKey;

  /// To BEAM: the allowance transactions sent before the lock, in order.
  final List<String> approveHashes;

  /// To BEAM: the `sendFunds` transaction.
  final String? lockHash;

  /// To Ethereum: the BEAM `send` transaction.
  final String? beamTxId;

  /// To BEAM: the BEAM claim transaction.
  final String? claimTxId;

  /// The bridge's message id: BEAM-side (to Ethereum) or Ethereum-side (to
  /// BEAM). Once known, no other crossing of the same route and direction
  /// may have it.
  final int? msgId;

  /// To Ethereum: the BEAM pipe's message count just before the send; the
  /// send's message is above it.
  final int? countBefore;

  /// To Ethereum: the BEAM block of the send. To BEAM: the Ethereum block
  /// of the lock.
  final int? height;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// To Ethereum: when the 61 confirmations were first seen.
  final DateTime? dueAt;

  /// To BEAM: when the lock was seen mined.
  final DateTime? lockedAt;

  /// To BEAM: when it was first seen on BEAM.
  final DateTime? deliveredAt;

  /// To BEAM: when the claim was handed to the wallet.
  final DateTime? claimStartedAt;

  final DateTime? finishedAt;

  /// What went wrong last, in plain words; null when nothing did.
  final String? lastError;

  /// To BEAM: claim without asking once it arrives, while Campfire is open.
  final bool autoClaim;

  BridgeRoute get route => bridgeRouteById(routeId);

  bool get toEthereum => direction == BridgeDirection.toEthereum;

  bool get isOpen => !state.isFinal;

  /// Unchanged fields kept; pass [clearError] to drop [lastError].
  BridgeCrossing copyWith({
    BridgeCrossingState? state,
    BigInt? amount,
    BigInt? receives,
    BigInt? relayerFee,
    BigInt? beamNetworkFee,
    BigInt? ethNetworkFee,
    String? beamReceiveKey,
    List<String>? approveHashes,
    String? lockHash,
    String? beamTxId,
    String? claimTxId,
    int? msgId,
    int? countBefore,
    int? height,
    DateTime? updatedAt,
    DateTime? dueAt,
    DateTime? lockedAt,
    DateTime? deliveredAt,
    DateTime? claimStartedAt,
    DateTime? finishedAt,
    String? lastError,
    bool clearError = false,
    bool? autoClaim,
  }) => BridgeCrossing(
    id: id,
    routeId: routeId,
    direction: direction,
    state: state ?? this.state,
    amount: amount ?? this.amount,
    receives: receives ?? this.receives,
    relayerFee: relayerFee ?? this.relayerFee,
    beamNetworkFee: beamNetworkFee ?? this.beamNetworkFee,
    ethNetworkFee: ethNetworkFee ?? this.ethNetworkFee,
    beamWalletId: beamWalletId,
    ethWalletId: ethWalletId,
    ethAddress: ethAddress,
    beamReceiveKey: beamReceiveKey ?? this.beamReceiveKey,
    approveHashes: approveHashes ?? this.approveHashes,
    lockHash: lockHash ?? this.lockHash,
    beamTxId: beamTxId ?? this.beamTxId,
    claimTxId: claimTxId ?? this.claimTxId,
    msgId: msgId ?? this.msgId,
    countBefore: countBefore ?? this.countBefore,
    height: height ?? this.height,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    dueAt: dueAt ?? this.dueAt,
    lockedAt: lockedAt ?? this.lockedAt,
    deliveredAt: deliveredAt ?? this.deliveredAt,
    claimStartedAt: claimStartedAt ?? this.claimStartedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    lastError: clearError ? null : (lastError ?? this.lastError),
    autoClaim: autoClaim ?? this.autoClaim,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'route': routeId,
    'direction': direction.name,
    'state': state.name,
    'amount': '$amount',
    'receives': '$receives',
    'relayerFee': '$relayerFee',
    'beamNetworkFee': '$beamNetworkFee',
    'ethNetworkFee': '$ethNetworkFee',
    'beamWalletId': beamWalletId,
    'ethWalletId': ethWalletId,
    'ethAddress': ethAddress,
    if (beamReceiveKey != null) 'beamReceiveKey': beamReceiveKey,
    if (approveHashes.isNotEmpty) 'approveHashes': approveHashes,
    if (lockHash != null) 'lockHash': lockHash,
    if (beamTxId != null) 'beamTxId': beamTxId,
    if (claimTxId != null) 'claimTxId': claimTxId,
    if (msgId != null) 'msgId': msgId,
    if (countBefore != null) 'countBefore': countBefore,
    if (height != null) 'height': height,
    'createdAt': _iso(createdAt),
    'updatedAt': _iso(updatedAt),
    if (dueAt != null) 'dueAt': _iso(dueAt!),
    if (lockedAt != null) 'lockedAt': _iso(lockedAt!),
    if (deliveredAt != null) 'deliveredAt': _iso(deliveredAt!),
    if (claimStartedAt != null) 'claimStartedAt': _iso(claimStartedAt!),
    if (finishedAt != null) 'finishedAt': _iso(finishedAt!),
    if (lastError != null) 'lastError': lastError,
    'autoClaim': autoClaim,
  };

  static String _iso(DateTime t) => t.toUtc().toIso8601String();

  @override
  String toString() =>
      'BridgeCrossing($id, $routeId ${direction.name}, ${state.name})';
}

/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../models/isar/models/blockchain_data/transaction.dart';
import '../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../wallets/beam/contracts/airdrop/airdrop_constants.dart';
import '../../../wallets/beam/contracts/bans/bans_constants.dart';
import '../../../wallets/beam/contracts/burn/blackhole_constants.dart';
import '../../../wallets/beam/contracts/dex/dex_constants.dart';
import '../../../wallets/beam/contracts/minter/minter_constants.dart';
import '../../../wallets/beam/models/beam_transaction.dart';
import '../../../wallets/beam/tx/beam_tx_actions.dart';

/// Which BEAM contract a contract transaction talked to, when Campfire
/// knows it. Anything else is an unnamed app.
enum BeamContractKind {
  dex,
  names,
  airdrop,
  minter,
  burn,
  other;

  static BeamContractKind of(Iterable<String> contractIds) {
    for (final cid in contractIds) {
      switch (cid) {
        case kDexContractId:
          return dex;
        case kBansCid:
          return names;
        case kAirdropContractId:
          return airdrop;
        case kMinterContractId:
          return minter;
        case kBlackHoleContractId:
          return burn;
      }
    }
    return other;
  }
}

/// A BEAM transaction as the history and details screens need it, rebuilt
/// read-only from the [TransactionV2] that `BeamTxMapper` stored.
///
/// Nothing here talks to the core. What Campfire's cache does not hold —
/// the per-asset funds of a contract call — is read separately
/// (`pBeamContractFunds`) and passed in where it is shown.
@immutable
class BeamTxView {
  const BeamTxView._({
    required this.walletId,
    required this.txid,
    required this.status,
    required this.txType,
    required this.direction,
    required this.assetId,
    required this.amount,
    required this.paidFee,
    required this.timestamp,
    this.coreFee,
    this.kernelId,
    this.comment,
    this.failureReason,
    this.height,
    this.counterparty,
    this.contractIds = const [],
    this.appName,
    this.isSplit = false,
  });

  /// Null unless [tx] is a BEAM transaction.
  static BeamTxView? of(TransactionV2 tx) {
    final Map<String, Object?> od;
    try {
      final decoded = tx.otherData == null ? null : jsonDecode(tx.otherData!);
      if (decoded is! Map) return null;
      od = decoded.cast<String, Object?>();
    } on FormatException {
      return null;
    }
    if (od[TxV2OdKeys.isBeamTransaction] != true) return null;

    final statusName = od[TxV2OdKeys.beamTxStatus];
    final typeName = od[TxV2OdKeys.beamTxType];
    final status = BeamTxStatus.values.firstWhere(
      (s) => s.name == statusName,
      orElse: () => BeamTxStatus.unknown,
    );
    final txType = BeamTxType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => BeamTxType.unknown,
    );

    // The mapper keeps the wallet's own arithmetic consistent (see
    // BeamTxMapper), so Campfire's helpers give the right numbers.
    final BigInt amount;
    if (tx.type == TransactionType.outgoing) {
      amount = tx
          .getAmountSentFromThisWallet(
            fractionDigits: _groth,
            subtractFee: true,
          )
          .raw;
    } else {
      amount = tx.getAmountReceivedInThisWallet(fractionDigits: _groth).raw;
    }

    String? first(List<String> a) =>
        a.isEmpty || a.first.isEmpty ? null : a.first;
    final String? counterparty = switch (tx.type) {
      TransactionType.incoming =>
        tx.inputs.isEmpty ? null : first(tx.inputs.first.addresses),
      _ => tx.outputs.isEmpty ? null : first(tx.outputs.first.addresses),
    };

    final ids = od[TxV2OdKeys.beamContractIds];
    final comment = od[TxV2OdKeys.beamComment];
    return BeamTxView._(
      walletId: tx.walletId,
      txid: tx.txid,
      status: status,
      txType: txType,
      direction: tx.type,
      assetId: od[TxV2OdKeys.beamAssetId] as int? ?? 0,
      amount: amount,
      paidFee: tx.getFee(fractionDigits: _groth).raw,
      coreFee: BigInt.tryParse('${od[TxV2OdKeys.beamFee]}'),
      timestamp: tx.timestamp,
      kernelId: _nonEmpty(od[TxV2OdKeys.beamKernelId]),
      comment: comment is String && comment.trim().isNotEmpty ? comment : null,
      failureReason: _nonEmpty(od[TxV2OdKeys.beamFailureReason]),
      height: tx.height,
      counterparty: tx.type == TransactionType.unknown ? null : counterparty,
      contractIds: ids is List
          ? List.unmodifiable(ids.whereType<String>())
          : const [],
      appName: _nonEmpty(od[TxV2OdKeys.beamAppName]),
      isSplit: od[TxV2OdKeys.beamSplit] == true,
    );
  }

  static const _groth = 8;

  static String? _nonEmpty(Object? v) =>
      v is String && v.trim().isNotEmpty ? v : null;

  final String walletId;

  /// The core's own id for the transaction (32 hex). Not something the
  /// explorer knows; [kernelId] is.
  final String txid;
  final BeamTxStatus status;
  final BeamTxType txType;

  /// incoming, outgoing or sentToSelf, as the mapper decided it.
  final TransactionType direction;

  /// Asset of a plain payment. Contract calls are stored in BEAM terms.
  final int assetId;

  /// What moved, without the fee: sent, received, or (contract) the net
  /// BEAM part.
  final BigInt amount;

  /// The fee this wallet paid (0 for incoming payments).
  final BigInt paidFee;

  /// The fee as the core reported it, also for incoming payments.
  final BigInt? coreFee;

  /// Unix seconds.
  final int timestamp;
  final String? kernelId;
  final String? comment;
  final String? failureReason;

  /// Confirmations at [chainHeight] (the wallet's current height), counted
  /// as the core counts them: blocks on top of the proof height. Null when
  /// the transaction is in no block yet or the tip is unknown.
  int? confirmationsAt(int chainHeight) {
    final h = height;
    if (h == null || h <= 0 || chainHeight <= 0) return null;
    return chainHeight > h ? chainHeight - h : 0;
  }

  /// Proof height of a completed transaction.
  final int? height;

  /// The other wallet's address: the receiver of an outgoing payment, the
  /// sender of an incoming one. Empty for contract calls.
  final String? counterparty;
  final List<String> contractIds;

  /// Name the dApp gave itself. Not verified by anyone.
  final String? appName;

  /// The wallet's own coins split into new ones (Split coins): nothing left
  /// the wallet but the fee, and there is no one to give a proof to.
  final bool isSplit;

  bool get isContract => txType == BeamTxType.contract;
  bool get isIncoming => direction == TransactionType.incoming;
  bool get isToSelf => direction == TransactionType.sentToSelf;
  bool get isCompleted => status == BeamTxStatus.completed;
  bool get isInFlight =>
      status == BeamTxStatus.pending ||
      status == BeamTxStatus.inProgress ||
      status == BeamTxStatus.registering ||
      status == BeamTxStatus.confirming ||
      status == BeamTxStatus.unknown;
  bool get isFailed => status == BeamTxStatus.failed;
  bool get isCancelled => status == BeamTxStatus.canceled;

  BeamContractKind get contractKind => BeamContractKind.of(contractIds);

  /// The same transaction in the core's terms, for [BeamTxActions].
  BeamTransaction toCore() => BeamTransaction(
    txId: txid,
    statusCode: status.code,
    statusString: status.name,
    txTypeCode: txType.code,
    txTypeString: txType.name,
    sender: isIncoming ? (counterparty ?? '') : '',
    receiver: isIncoming ? '' : (counterparty ?? ''),
    comment: comment ?? '',
    createTime: timestamp,
    assetId: isContract ? null : assetId,
    value: isContract ? null : amount,
    fee: coreFee,
    income: isIncoming,
    kernel: kernelId,
    failureReason: failureReason,
    height: height,
  );

  bool get canCancel => BeamTxActions.canCancel(toCore());
  bool get canDelete => BeamTxActions.canDelete(toCore());
  bool get canExportProof => !isSplit && BeamTxActions.canExportProof(toCore());

  /// A completed plain payment this wallet received: the receiver is the
  /// one who checks a proof the sender gives them.
  bool get canCheckProof =>
      isCompleted && isIncoming && txType == BeamTxType.simple;
}

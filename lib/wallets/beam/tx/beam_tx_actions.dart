/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../models/beam_address.dart';
import '../models/beam_call_results.dart';
import '../models/beam_transaction.dart';

/// What the transaction details screen may offer, decided exactly as the
/// core decides it, so a button never appears only to fail.
abstract final class BeamTxActions {
  /// `TxDescription::canCancel` (`wallet/core/common.cpp:946`): pending or
  /// in progress. The core can still refuse once the kernel is being
  /// registered; the UI then says so instead of showing an error code.
  static bool canCancel(BeamTransaction tx) =>
      tx.status == BeamTxStatus.pending ||
      tx.status == BeamTxStatus.inProgress;

  /// `TxDescription::canDelete` (`common.cpp:952`): only finished ones.
  /// Deleting removes the wallet's record only; nothing changes on chain.
  static bool canDelete(BeamTransaction tx) =>
      tx.status == BeamTxStatus.completed ||
      tx.status == BeamTxStatus.failed ||
      tx.status == BeamTxStatus.canceled;

  /// A payment proof exists for a completed payment this wallet sent.
  static bool canExportProof(BeamTransaction tx) =>
      tx.status == BeamTxStatus.completed &&
      tx.income == false &&
      tx.txType == BeamTxType.simple;

  /// One line for the status chip, in plain words. Regular (SBBS)
  /// payments need both wallets online, which is the most common reason a
  /// payment seems stuck; the text says so.
  static String statusLine(BeamTransaction tx) {
    final incoming = tx.income ?? false;
    return switch (tx.status) {
      BeamTxStatus.pending ||
      BeamTxStatus.inProgress when _interactive(tx) =>
        incoming
            ? 'Waiting for the sender to finish'
            : 'Waiting for the receiver\'s wallet to come online',
      BeamTxStatus.pending || BeamTxStatus.inProgress => 'In progress',
      BeamTxStatus.registering => 'Sending to the network',
      BeamTxStatus.confirming => 'Waiting for confirmation',
      BeamTxStatus.completed => incoming ? 'Received' : 'Sent',
      BeamTxStatus.canceled => 'Cancelled',
      BeamTxStatus.failed => _failure(tx.failureReason),
      BeamTxStatus.unknown => 'Unknown status',
    };
  }

  static bool _interactive(BeamTransaction tx) =>
      tx.txType == BeamTxType.simple &&
      (tx.addressType == null ||
          tx.addressType == BeamAddressType.regular ||
          tx.addressType == BeamAddressType.regularNew);

  static String _failure(String? reason) {
    final r = (reason ?? '').trim();
    if (r.isEmpty) return 'Failed';
    final lower = r.toLowerCase();
    if (lower.contains('expired')) {
      return 'Expired: the other wallet did not respond in time. '
          'Nothing was sent.';
    }
    if (lower.contains('inputs missing') || lower.contains('spent')) {
      return 'Failed: the coins were already spent elsewhere. '
          'Nothing was sent.';
    }
    if (lower.contains('cancel')) return 'Cancelled by the other side';
    return 'Failed: $r';
  }
}

/// A payment proof checked by the core, put into words.
class BeamProofVerdict {
  const BeamProofVerdict._(this.valid, this.sentence);

  /// [info] from `verify_payment_proof`; [describeAmount] formats the amount
  /// with its asset (the UI's formatter).
  factory BeamProofVerdict.of(
    BeamPaymentProofInfo info, {
    required String Function(BigInt amount, int assetId) describeAmount,
  }) {
    if (!info.isValid) {
      return const BeamProofVerdict._(
        false,
        'This proof is not valid. It does not show that the payment '
        'happened.',
      );
    }
    return BeamProofVerdict._(
      true,
      'Valid: ${describeAmount(info.amount, info.assetId)} was paid from '
      '${_short(info.sender)} to ${_short(info.receiver)} '
      '(kernel ${_short(info.kernel)}).',
    );
  }

  final bool valid;
  final String sentence;

  static String _short(String s) =>
      s.length <= 16 ? s : '${s.substring(0, 8)}…${s.substring(s.length - 6)}';
}

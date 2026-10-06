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
      tx.status == BeamTxStatus.pending || tx.status == BeamTxStatus.inProgress;

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
      BeamTxStatus.pending || BeamTxStatus.inProgress when _interactive(tx) =>
        incoming
            ? 'Waiting for the sender to finish'
            : 'Waiting for the receiver\'s wallet to come online',
      BeamTxStatus.pending || BeamTxStatus.inProgress => 'In progress',
      BeamTxStatus.registering => 'Sending to the network',
      BeamTxStatus.confirming => 'Waiting for confirmation',
      BeamTxStatus.completed => incoming ? 'Received' : 'Sent',
      BeamTxStatus.canceled => 'Cancelled',
      BeamTxStatus.failed => _failure(tx),
      BeamTxStatus.unknown => 'Unknown status',
    };
  }

  static bool _interactive(BeamTransaction tx) =>
      tx.txType == BeamTxType.simple &&
      (tx.addressType == null ||
          tx.addressType == BeamAddressType.regular ||
          tx.addressType == BeamAddressType.regularNew);

  /// What a failed transaction's status line says when the core's message
  /// is not one [failureSentence] knows. The core's own words stay behind
  /// "Copy technical details"; they are not written for people.
  static const notCompleted = 'Not completed. Nothing was sent.';

  static String _failure(BeamTransaction tx) {
    final r = (tx.failureReason ?? '').trim();
    if (r.isEmpty) return 'Failed';
    return failureSentence(r, interactive: _interactive(tx)) ?? notCompleted;
  }

  /// Plain words for a failure message the core really sends
  /// (`BEAM_TX_FAILURE_REASON_MAP`, wallet/core/common.h, tag
  /// beam-7.5.14493), or null when [reason] is empty or not one of them.
  /// A failed BEAM transaction never reached a block, so every sentence
  /// says that nothing was sent. [interactive] is a regular payment, where
  /// a timeout means the other wallet never answered.
  static String? failureSentence(String? reason, {required bool interactive}) {
    final r = (reason ?? '').trim().toLowerCase();
    if (r.isEmpty) return null;
    const nothing = 'Nothing was sent.';
    // Order matters: "Address is expired" must not read as a timeout.
    if (r.contains('address is expired')) {
      return 'Not sent: the receiving address has expired. $nothing '
          'Ask for a new address.';
    }
    if (r.contains('timed out') || r.contains('expired')) {
      return interactive
          ? 'Expired: the other wallet did not respond in time. $nothing'
          : 'Expired: it was not added to a block in time. $nothing';
    }
    if (r.contains('inputs missing') || r.contains('spent')) {
      return 'Failed: the coins were already spent elsewhere. $nothing';
    }
    if (r.contains('failed to register')) {
      return 'Not accepted by the network. $nothing';
    }
    if (r.contains('not enough inputs')) {
      return 'Not sent: not enough coins were free to pay it. $nothing';
    }
    if (r.contains('fee is too small')) {
      return 'Not sent: the network fee was too low. $nothing';
    }
    if (r.contains('fee is too large') || r.contains('fee is too big')) {
      return 'Not sent: the fee would have been too large. $nothing';
    }
    if (r.contains('not signed by the receiver')) {
      return 'Not sent: the receiver did not sign the payment. $nothing';
    }
    if (r.contains('transaction parameters')) {
      return 'The other wallet could not be reached. $nothing';
    }
    if (r.contains('no voucher') || r.contains('cannot get vouchers')) {
      return "Not sent: the receiver's offline address has no one-time "
          'keys left. Ask them to open their wallet or send a new '
          'address. $nothing';
    }
    if (r.contains('disabled in the receiver wallet')) {
      return "Not sent: the receiver's wallet does not accept tokens. "
          '$nothing';
    }
    if (r.contains('aborted by the user')) return 'Cancelled';
    if (r.contains('cancel')) return 'Cancelled by the other side. $nothing';
    if (r.contains('send wallet logs') ||
        r.contains('not valid') ||
        r.contains('kernel') ||
        r.contains('key keeper') ||
        r.contains('invalid state')) {
      return 'The wallet could not complete it. $nothing';
    }
    return null;
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
      '(transaction ID ${_short(info.kernel)}).',
    );
  }

  final bool valid;
  final String sentence;

  static String _short(String s) =>
      s.length <= 16 ? s : '${s.substring(0, 8)}…${s.substring(s.length - 6)}';
}

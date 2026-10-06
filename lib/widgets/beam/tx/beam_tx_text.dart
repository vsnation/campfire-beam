/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../utilities/amount/amount.dart';
import '../../../utilities/amount/amount_formatter.dart';
import '../../../utilities/amount/amount_unit.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/models/beam_transaction.dart';
import '../../../wallets/beam/tx/beam_tx_actions.dart';
import 'beam_tx_view.dart';

/// One asset's movement in a transaction, from the wallet's side:
/// positive arrived, negative left.
typedef BeamFundsLine = ({int assetId, BigInt delta});

/// Everything the BEAM history says, in plain words. No widget code, so
/// every sentence can be tested on its own.
abstract final class BeamTxText {
  // ----------------------------------------------------------------- titles

  /// The first line of a history entry: what happened.
  static String title(BeamTxView v, {List<BeamFundsLine>? funds}) {
    if (v.isContract) return contractLabel(v, funds: funds);
    if (v.isCancelled) return 'Cancelled';
    if (v.isFailed) return v.isIncoming ? 'Not received' : 'Not sent';
    if (v.isCompleted) {
      return v.isIncoming
          ? 'Received'
          : v.isToSelf
          ? 'Sent to yourself'
          : 'Sent';
    }
    return v.isIncoming
        ? 'Receiving'
        : v.isToSelf
        ? 'Sending to yourself'
        : 'Sending';
  }

  /// What a contract transaction was, when Campfire knows the contract.
  /// [funds] (from the core) tells a swap from a liquidity move.
  static String contractLabel(BeamTxView v, {List<BeamFundsLine>? funds}) {
    final out = funds?.where((f) => f.delta < BigInt.zero).length ?? 0;
    final inn = funds?.where((f) => f.delta > BigInt.zero).length ?? 0;
    switch (v.contractKind) {
      case BeamContractKind.dex:
        if (funds == null) return 'DEX';
        if (out == 1 && inn == 1) return 'DEX swap';
        if (out >= 2 && inn == 0) return 'Added to a DEX pool';
        if (inn >= 2 && out == 0) return 'Taken from a DEX pool';
        return 'DEX';
      case BeamContractKind.names:
        return 'Name payment';
      case BeamContractKind.airdrop:
        if (funds == null) return 'Airdrop';
        if (inn > 0 && out == 0) return 'Airdrop claim';
        if (out > 0 && inn == 0) return 'Airdrop created';
        return 'Airdrop';
      case BeamContractKind.minter:
        return 'Token minter';
      case BeamContractKind.burn:
        return 'Burn';
      case BeamContractKind.other:
        return 'Contract call';
    }
  }

  /// Who the transaction was with, for contract calls.
  static String contractParty(BeamContractKind kind) => switch (kind) {
    BeamContractKind.dex => 'BEAM DEX',
    BeamContractKind.names => 'BEAM name service',
    BeamContractKind.airdrop => 'Airdrop vouchers',
    BeamContractKind.minter => 'BEAM token minter',
    BeamContractKind.burn => 'Burn address (nothing can come back)',
    BeamContractKind.other => 'An app on BEAM',
  };

  // ----------------------------------------------------------------- status

  /// The status line: [BeamTxActions.statusLine], except for the failure
  /// messages the core really sends (`BEAM_TX_FAILURE_REASON_MAP`,
  /// `wallet/core/common.h`), which it would otherwise show verbatim.
  ///
  /// A failure neither knows ends in a plain "Not completed. Nothing was
  /// sent." rather than the core's own words; those stay behind "Copy
  /// technical details".
  static String status(BeamTxView v) {
    if (v.isFailed) {
      final plain = failure(v);
      if (plain != null) return plain;
    }
    // Only a pending or in-progress payment can be cancelled, so nothing
    // left the wallet.
    if (v.isCancelled) return 'Cancelled. $_nothing';
    // "Sent" fits a payment, not a swap or a claim.
    if (v.isContract && v.isCompleted) return 'Completed';
    final line = BeamTxActions.statusLine(v.toCore());
    if (v.isFailed &&
        (line == 'Failed' ||
            (line.startsWith('Failed: ') && !line.contains('Nothing')))) {
      return kNotCompleted;
    }
    return line;
  }

  static const kNotCompleted = 'Not completed. Nothing was sent.';
  static const _nothing = 'Nothing was sent.';

  /// The status line under a list entry, which already has a title: no
  /// "Cancelled" twice.
  static String? entryStatus(BeamTxView v) {
    if (v.isCompleted) return null;
    if (v.isCancelled) return _nothing;
    return status(v);
  }

  /// The fee line: a payment that never went through paid none.
  static String fee(BeamTxView v, AmountFormatter beam) {
    if (v.isFailed || v.isCancelled) return 'None: nothing was sent';
    if (v.isIncoming && !v.isContract) return 'Paid by the sender';
    return amount(v.paidFee, 0, beam);
  }

  /// Plain words for the core's failure message, or null when the core's
  /// text is one [BeamTxActions] already explains (or nothing known).
  static String? failure(BeamTxView v) {
    final r = (v.failureReason ?? '').toLowerCase();
    if (r.isEmpty) return null;
    const nothing = 'Nothing was sent.';
    // Order matters: "Address is expired" must not read as a timeout.
    if (r.contains('address is expired')) {
      return 'Not sent: the receiving address has expired. $nothing '
          'Ask for a new address.';
    }
    if (r.contains('timed out')) {
      return _interactive(v)
          ? 'Expired: the other wallet did not respond in time. $nothing'
          : 'Expired: it was not added to a block in time. $nothing';
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
    if (r.contains('not signed by the receiver')) {
      return 'Not sent: the receiver did not sign the payment. $nothing';
    }
    if (r.contains('transaction parameters')) {
      return 'The other wallet could not be reached. $nothing';
    }
    if (r.contains('disabled in the receiver wallet')) {
      return "Not sent: the receiver's wallet does not accept tokens. "
          '$nothing';
    }
    if (r.contains('aborted by the user')) return 'Cancelled';
    if (r.contains('send wallet logs') ||
        r.contains('not valid') ||
        r.contains('kernel')) {
      return 'The wallet could not complete it. $nothing';
    }
    return null;
  }

  /// The core's own text, kept for support. Shown only behind "Copy".
  static String? technical(BeamTxView v) => v.failureReason;

  static bool _interactive(BeamTxView v) => v.txType == BeamTxType.simple;

  /// How the status line should look.
  static BeamTxTone tone(BeamTxView v) {
    if (v.isCompleted) return BeamTxTone.done;
    if (v.isFailed) return BeamTxTone.failed;
    if (v.isCancelled) return BeamTxTone.neutral;
    return BeamTxTone.waiting;
  }

  // ---------------------------------------------------------------- amounts

  /// The funds a list entry shows: the core's per-asset movements of a
  /// contract call when known, otherwise what Campfire stored (the BEAM
  /// part for contract calls).
  static List<BeamFundsLine> funds(
    BeamTxView v, {
    List<BeamAssetAmount>? contractAmounts,
  }) {
    if (v.isContract && contractAmounts != null) {
      // The core's sign is from the contract's side: positive is locked
      // into it (left the wallet).
      final byAsset = <int, BigInt>{};
      for (final a in contractAmounts) {
        byAsset[a.assetId] = (byAsset[a.assetId] ?? BigInt.zero) - a.amount;
      }
      final lines = [
        for (final e in byAsset.entries)
          if (e.value != BigInt.zero) (assetId: e.key, delta: e.value),
      ];
      // BEAM first, then by asset id: the order never jumps around.
      lines.sort((a, b) => a.assetId.compareTo(b.assetId));
      return lines;
    }
    if (v.amount == BigInt.zero) return const [];
    final delta = v.isIncoming ? v.amount : -v.amount;
    return [(assetId: v.isContract ? 0 : v.assetId, delta: delta)];
  }

  /// "4,864.10722456 CHAD", "0.00069843 BEAM", "1.00000000 #188" for an
  /// asset Campfire does not vouch for. BEAM follows the user's unit and
  /// decimals settings, other assets the same decimals in whole units.
  static String amount(
    BigInt raw,
    int assetId,
    AmountFormatter beam, {
    bool sign = false,
  }) {
    final value = Amount(rawValue: raw.abs(), fractionDigits: 8);
    final String text;
    if (assetId == 0) {
      text = beam.format(value);
    } else {
      final asset = BeamAssetCatalog.display(assetId, null);
      text = AmountFormatter(
        unit: AmountUnit.normal,
        locale: beam.locale,
        coin: beam.coin,
        maxDecimals: beam.maxDecimals,
      ).format(value, overrideUnit: asset.symbol);
    }
    if (!sign || raw == BigInt.zero) return text;
    return raw < BigInt.zero ? '−$text' : '+$text';
  }

  /// "a1b2c3d4…e5f6a7". Full value is always one tap away (copy).
  static String short(String s, {int head = 8, int tail = 6}) =>
      s.length <= head + tail + 1
      ? s
      : '${s.substring(0, head)}…${s.substring(s.length - tail)}';

  // ---------------------------------------------------------------- actions

  static const cancelTitle = 'Cancel this payment?';
  static const cancelMessage = 'Nothing has been sent yet.';
  static const cancelConfirm = 'Cancel payment';
  static const cancelKeep = 'Keep waiting';
  static const cancelDone = 'Payment cancelled. Nothing was sent.';
  static const cancelTooLate =
      'Too late to cancel: it is already being added to a block';

  static const deleteTitle = 'Remove this record from your wallet?';
  static const deleteMessage = 'Nothing changes on the blockchain.';
  static const deleteConfirm = 'Remove record';
  static const deleteKeep = 'Keep it';
  static const deleteDone = 'Record removed from this wallet';
  static const deleteRefused =
      'This record cannot be removed while the payment is still in progress';

  static const notConnected =
      'Campfire is still connecting to the BEAM network. '
      'Try again in a moment.';

  static const proofNone =
      "No proof is available for this payment: the receiver's address "
      'does not support payment proofs.';
  static const proofNotAProof =
      "This text is not a payment proof. Ask the sender to send the whole "
      'proof again.';

  /// [BeamProofVerdict]'s sentence names the kernel; on screen that id is
  /// the "transaction ID" (the word "kernel" stays behind the info button).
  static String plainVerdict(String sentence) =>
      sentence.replaceFirst('(kernel ', '(transaction ID ');

  static const explorerInfo =
      'BEAM calls this the kernel ID. Block explorers look a transaction up '
      'by it. It does not show the amount or who paid whom.';
}

/// Colour family of a status line.
enum BeamTxTone { done, waiting, failed, neutral }

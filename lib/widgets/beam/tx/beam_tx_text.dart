/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../l10n/l10n.dart';
import '../../../models/isar/models/beam/beam_asset_contract.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/amount/amount_formatter.dart';
import '../../../utilities/amount/amount_unit.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/assets/beam_asset_registry.dart';
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
    if (v.isSplit) return splitTitle(v);
    final l = appL10n;
    if (v.isCancelled) return l.txTitleCancelled;
    if (v.isFailed) {
      return v.isIncoming ? l.txTitleNotReceived : l.txTitleNotSent;
    }
    if (v.isCompleted) {
      return v.isIncoming
          ? l.txTitleReceived
          : v.isToSelf
          ? l.txTitleSentToYourself
          : l.txTitleSent;
    }
    return v.isIncoming
        ? l.txTitleReceiving
        : v.isToSelf
        ? l.txTitleSendingToYourself
        : l.txTitleSending;
  }

  /// A split of the wallet's own coins, by where it is.
  static String splitTitle(BeamTxView v) {
    final l = appL10n;
    if (v.isCancelled) return l.txSplitTitleCancelled;
    if (v.isFailed) return l.txSplitTitleFailed;
    if (v.isCompleted) return l.txSplitTitleDone;
    return l.txSplitTitleInProgress;
  }

  /// What a split moved, under its fee (the only thing that left). Short:
  /// the list gives it the width of the amount above it.
  static String splitDetail(BeamTxView v, AmountFormatter beam) =>
      appL10n.txSplitDetail(amount(v.amount, v.assetId, beam));

  /// What a contract transaction was, when Campfire knows the contract.
  /// [funds] (from the core) tells a swap from a liquidity move.
  static String contractLabel(BeamTxView v, {List<BeamFundsLine>? funds}) {
    final out = funds?.where((f) => f.delta < BigInt.zero).length ?? 0;
    final inn = funds?.where((f) => f.delta > BigInt.zero).length ?? 0;
    final l = appL10n;
    switch (v.contractKind) {
      case BeamContractKind.dex:
        if (funds == null) return l.txContractDex;
        if (out == 1 && inn == 1) return l.txContractDexSwap;
        if (out >= 2 && inn == 0) return l.txContractDexAdded;
        if (inn >= 2 && out == 0) return l.txContractDexTaken;
        return l.txContractDex;
      case BeamContractKind.names:
        return l.txContractNamePayment;
      case BeamContractKind.airdrop:
        if (funds == null) return l.txContractAirdrop;
        if (inn > 0 && out == 0) return l.txContractAirdropClaim;
        if (out > 0 && inn == 0) return l.txContractAirdropCreated;
        return l.txContractAirdrop;
      case BeamContractKind.minter:
        return l.txContractMinter;
      case BeamContractKind.burn:
        return l.txContractBurn;
      case BeamContractKind.other:
        return l.txContractCall;
    }
  }

  /// Who the transaction was with, for contract calls.
  static String contractParty(BeamContractKind kind) => switch (kind) {
    BeamContractKind.dex => appL10n.txPartyDex,
    BeamContractKind.names => appL10n.txPartyNames,
    BeamContractKind.airdrop => appL10n.txPartyAirdrop,
    BeamContractKind.minter => appL10n.txPartyMinter,
    BeamContractKind.burn => appL10n.txPartyBurn,
    BeamContractKind.other => appL10n.txPartyOther,
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
    final l = appL10n;
    if (v.isCancelled) return l.txStatusCancelledNothingSent;
    // "Sent" fits a payment, not a swap or a claim.
    if (v.isContract && v.isCompleted) return l.txStatusCompleted;
    // A split waits for no one: no "waiting for the receiver".
    if (v.isSplit) {
      return switch (v.status) {
        BeamTxStatus.completed => l.txSplitStatusCompleted,
        BeamTxStatus.registering => l.txSplitStatusRegistering,
        BeamTxStatus.confirming => l.txStatusConfirming,
        _ => l.txSplitStatusInProgress,
      };
    }
    final line = BeamTxActions.statusLine(v.toCore());
    if (v.isFailed && line == BeamTxActions.failed) return kNotCompleted;
    return line;
  }

  static String get kNotCompleted => BeamTxActions.notCompleted;

  /// The status line under a list entry, which already has a title: no
  /// "Cancelled" twice.
  static String? entryStatus(BeamTxView v) {
    if (v.isCompleted) return null;
    if (v.isCancelled) return appL10n.txNothingSent;
    return status(v);
  }

  /// The fee line: a payment that never went through paid none.
  static String fee(BeamTxView v, AmountFormatter beam) {
    if (v.isFailed || v.isCancelled) return appL10n.txFeeNone;
    if (v.isIncoming && !v.isContract) return appL10n.txFeePaidBySender;
    return amount(v.paidFee, 0, beam);
  }

  /// Plain words for the core's failure message, or null when the core's
  /// text is one [BeamTxActions] already explains (or nothing known).
  static String? failure(BeamTxView v) => BeamTxActions.failureSentence(
    v.failureReason,
    interactive: _interactive(v),
  );

  /// The core's own text, kept for support. Shown only behind "Copy".
  static String? technical(BeamTxView v) => v.failureReason;

  static bool _interactive(BeamTxView v) =>
      v.txType == BeamTxType.simple && !v.isSplit;

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

  /// The details screen's name for a payment's asset: "BEAM", "Gothic
  /// Crown (CROWN)", a DEX liquidity token as everywhere else ("BEAM/FOMO
  /// LP", "BEAM/BB #3 LP"), and "Asset #557 — not verified by Campfire"
  /// for anything else. [cached] is Campfire's row for the asset: an LP
  /// token's row names unverified sides from their on-chain metadata, which
  /// the DEX's pool list alone cannot ("BEAM/#3 LP").
  static String assetName(int assetId, {BeamAssetContract? cached}) {
    if (cached != null && cached.assetId == assetId && cached.isPoolShare) {
      // Today's look of the row: an older version cached "BEAM / FOMO pool
      // share".
      return BeamAssetRegistry.refreshLook(cached).name;
    }
    final a = BeamAssetCatalog.display(assetId, null);
    if (a.isPoolShare) return a.name;
    if (a.verified) {
      return a.name == a.symbol ? a.symbol : '${a.name} (${a.symbol})';
    }
    return appL10n.txAssetUnverified(a.idLabel);
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
    // An asset in its own decimals (pinned, or read from its metadata this run;
    // 8 until then).
    final asset = BeamAssetCatalog.display(assetId, null);
    final value = Amount(
      rawValue: raw.abs(),
      fractionDigits: assetId == 0 ? 8 : (asset.decimals ?? 8),
    );
    final String text;
    if (assetId == 0) {
      text = beam.format(value);
    } else {
      text = AmountFormatter(
        unit: AmountUnit.normal,
        locale: beam.locale,
        coin: beam.coin,
        maxDecimals: asset.decimals ?? beam.maxDecimals,
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

  static String get cancelTitle => appL10n.txCancelTitle;
  static String get cancelMessage => appL10n.txCancelMessage;
  static String get cancelConfirm => appL10n.txCancelConfirm;
  static String get cancelKeep => appL10n.txCancelKeep;
  static String get cancelDone => appL10n.txCancelDone;
  static String get cancelTooLate => appL10n.txCancelTooLate;

  static String get deleteTitle => appL10n.txDeleteTitle;
  static String get deleteMessage => appL10n.txDeleteMessage;
  static String get deleteConfirm => appL10n.txDeleteConfirm;
  static String get deleteKeep => appL10n.txDeleteKeep;
  static String get deleteDone => appL10n.txDeleteDone;
  static String get deleteRefused => appL10n.txDeleteRefused;

  static String get notConnected => appL10n.txNotConnected;

  static String get proofNone => appL10n.txProofNone;
  static String get proofNotAProof => appL10n.txProofNotAProof;

  /// [BeamProofVerdict]'s sentence, as shown. It already calls the kernel
  /// the "transaction ID" (the word "kernel" stays behind the info button).
  static String plainVerdict(String sentence) => sentence;

  static String get explorerInfo => appL10n.txExplorerInfo;
}

/// Colour family of a status line.
enum BeamTxTone { done, waiting, failed, neutral }

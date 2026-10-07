/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6) — one history entry:
//   Job:  say what happened to this payment, how much, and whether it is
//         still moving — at a glance, without opening it.
//   CTA:  the whole entry opens its details (no buttons in a list).
//   Taps: open wallet → entry (1).
//
// Exit-intent (§1.7):
//   * "Is my payment stuck?" → an unfinished entry says why in plain words
//     ("Waiting for the receiver's wallet to come online").
//   * "Did I lose money?" → failed entries say "Nothing was sent".
//   * "What was this app thing?" → contract calls are named (DEX swap, Name
//     payment, Airdrop claim…) and show what left and what arrived.

import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../pages/wallet_view/transaction_views/tx_v2/transaction_v2_details_view.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/amount/amount_formatter.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/format.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../desktop/desktop_dialog.dart';
import 'beam_tx_backend.dart';
import 'beam_tx_icon.dart';
import 'beam_tx_text.dart';
import 'beam_tx_view.dart';

/// The text of one entry, shared by the card and the desktop row.
class BeamTxEntryText {
  BeamTxEntryText._(
    this.title,
    this.primary,
    this.secondary,
    this.status,
    this.muted,
  );

  factory BeamTxEntryText.of(
    BeamTxView v, {
    required AmountFormatter formatter,
    required bool signed,
    List<BeamFundsLine>? contractFunds,
    BeamTxFiat? fiat,
  }) {
    // Nothing moved for a failed or cancelled payment: no "−", and the
    // amount is shown muted.
    final stopped = v.isFailed || v.isCancelled;
    final lines = v.isContract && contractFunds != null
        ? contractFunds
        : BeamTxText.funds(v);
    final String primary;
    String? secondary;
    if (lines.isEmpty) {
      // A contract call that moved nothing but its fee.
      primary = BeamTxText.amount(-v.paidFee, 0, formatter, sign: !stopped);
      secondary = 'Network fee';
    } else if (v.isToSelf && !v.isContract) {
      // Only the fee left the wallet; the amount moved between its own
      // addresses. "−0.01 BEAM" would read as money gone.
      primary = BeamTxText.amount(-v.paidFee, 0, formatter, sign: !stopped);
      secondary =
          '${BeamTxText.amount(v.amount, v.assetId, formatter)} moved to '
          'your own address';
    } else {
      // What arrived reads first: "+4,864 CHAD" above "−0.07 BEAM".
      final ordered = [
        ...lines.where((l) => l.delta > BigInt.zero),
        ...lines.where((l) => l.delta <= BigInt.zero),
      ];
      final many = ordered.length > 1;
      primary = BeamTxText.amount(
        ordered.first.delta,
        ordered.first.assetId,
        formatter,
        sign: !stopped && (signed || many || v.isContract),
      );
      if (many) {
        secondary = ordered
            .skip(1)
            .map(
              (l) => BeamTxText.amount(
                l.delta,
                l.assetId,
                formatter,
                sign: !stopped,
              ),
            )
            .join(' · ');
      } else if (fiat != null && !stopped && ordered.first.assetId == 0) {
        final value =
            Amount(
              rawValue: ordered.first.delta.abs(),
              fractionDigits: 8,
            ).decimal *
            fiat.price;
        final text = value
            .toAmount(fractionDigits: 2)
            .fiatString(locale: fiat.locale);
        final sign = !signed
            ? ''
            : ordered.first.delta < BigInt.zero
            ? '−'
            : '+';
        // "−0.00 USD" reads as nothing; it is something, just under a cent.
        final cent = Decimal.parse('0.01');
        final tiny = value > Decimal.zero && value < cent;
        final centText = cent
            .toAmount(fractionDigits: 2)
            .fiatString(locale: fiat.locale);
        secondary = tiny
            ? 'under $centText ${fiat.currency}'
            : '$sign$text ${fiat.currency}';
      }
    }
    return BeamTxEntryText._(
      BeamTxText.title(v, funds: contractFunds),
      primary,
      secondary,
      BeamTxText.entryStatus(v),
      stopped,
    );
  }

  final String title;
  final String primary;
  final String? secondary;

  /// Failed or cancelled: the amount never moved.
  final bool muted;

  /// Shown only while unfinished, failed or cancelled.
  final String? status;
}

/// Colour of a status line in Campfire's palette.
Color beamToneColor(BuildContext context, BeamTxTone tone) {
  final c = Theme.of(context).extension<StackColors>()!;
  return switch (tone) {
    BeamTxTone.done => c.accentColorGreen,
    BeamTxTone.waiting => c.accentColorOrange,
    BeamTxTone.failed => c.textError,
    BeamTxTone.neutral => c.textSubtitle1,
  };
}

/// Opens the details exactly as Campfire's history does.
Future<void> openBeamTxDetails(
  BuildContext context, {
  required TransactionV2 transaction,
  required CryptoCurrency coin,
  required bool isDesktop,
}) async {
  if (isDesktop) {
    await showDialog<void>(
      context: context,
      builder: (context) => DesktopDialog(
        maxHeight: MediaQuery.of(context).size.height - 64,
        maxWidth: 640,
        child: TransactionV2DetailsView(
          transaction: transaction,
          coin: coin,
          walletId: transaction.walletId,
        ),
      ),
    );
  } else {
    unawaited(
      Navigator.of(context).pushNamed(
        TransactionV2DetailsView.routeName,
        arguments: (
          tx: transaction,
          coin: coin,
          walletId: transaction.walletId,
        ),
      ),
    );
  }
}

/// The per-asset funds of a contract call once the core has answered.
List<BeamFundsLine>? watchBeamContractFunds(WidgetRef ref, BeamTxView v) {
  if (!v.isContract) return null;
  final amounts = ref
      .watch(pBeamContractFunds((walletId: v.walletId, txid: v.txid)))
      .asData
      ?.value;
  if (amounts == null) return null;
  return BeamTxText.funds(v, contractAmounts: amounts);
}

/// A BEAM entry in Campfire's transaction list: `TransactionCardV2`'s
/// layout, with BEAM's own status words.
class BeamTransactionCard extends ConsumerWidget {
  const BeamTransactionCard({
    super.key,
    required this.transaction,
    required this.view,
    required this.coin,
  });

  final TransactionV2 transaction;
  final BeamTxView view;
  final CryptoCurrency coin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDesktop = ref.watch(pBeamTxIsDesktop);
    final text = BeamTxEntryText.of(
      view,
      formatter: ref.watch(pAmountFormatter(coin)),
      signed: isDesktop,
      contractFunds: watchBeamContractFunds(ref, view),
      fiat: ref.watch(pBeamTxFiat(view.walletId)),
    );
    final colors = Theme.of(context).extension<StackColors>()!;

    return Material(
      color: colors.popupBG,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          Constants.size.circularBorderRadius,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: RawMaterialButton(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              Constants.size.circularBorderRadius,
            ),
          ),
          onPressed: () => openBeamTxDetails(
            context,
            transaction: transaction,
            coin: coin,
            isDesktop: isDesktop,
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                BeamTxIcon(view: view),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                text.title,
                                style: STextStyles.itemSubtitle12(context),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            flex: 2,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Text(
                                text.primary,
                                style: STextStyles.itemSubtitle12(context)
                                    .copyWith(
                                      color: text.muted
                                          ? colors.textSubtitle1
                                          : null,
                                    ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // The date keeps its size; a long second amount
                          // shrinks instead.
                          Text(
                            Format.extractDateFrom(view.timestamp),
                            style: STextStyles.label(context),
                          ),
                          if (text.secondary != null) const SizedBox(width: 10),
                          if (text.secondary != null)
                            Expanded(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: Text(
                                  text.secondary!,
                                  style: STextStyles.label(context),
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (text.status != null) const SizedBox(height: 4),
                      if (text.status != null)
                        Text(
                          text.status!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: STextStyles.label(context).copyWith(
                            color: beamToneColor(
                              context,
                              BeamTxText.tone(view),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A BEAM row of the desktop "all transactions" table:
/// `DesktopTransactionCardRow`'s layout with BEAM's status words.
class BeamTransactionRow extends ConsumerWidget {
  const BeamTransactionRow({
    super.key,
    required this.transaction,
    required this.view,
    required this.coin,
  });

  final TransactionV2 transaction;
  final BeamTxView view;
  final CryptoCurrency coin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = BeamTxEntryText.of(
      view,
      formatter: ref.watch(pAmountFormatter(coin)),
      signed: true,
      contractFunds: watchBeamContractFunds(ref, view),
      fiat: ref.watch(pBeamTxFiat(view.walletId)),
    );
    final colors = Theme.of(context).extension<StackColors>()!;
    final dark = STextStyles.desktopTextExtraExtraSmall(context)
        .copyWith(color: colors.textDark);

    return Material(
      color: colors.popupBG,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          Constants.size.circularBorderRadius,
        ),
      ),
      child: RawMaterialButton(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            Constants.size.circularBorderRadius,
          ),
        ),
        onPressed: () => openBeamTxDetails(
          context,
          transaction: transaction,
          coin: coin,
          isDesktop: true,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          child: Row(
            children: [
              BeamTxIcon(view: view),
              const SizedBox(width: 12),
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(text.title, style: dark),
                    if (text.status != null)
                      Text(
                        text.status!,
                        style: STextStyles.label(context).copyWith(
                          color: beamToneColor(context, BeamTxText.tone(view)),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  Format.extractDateFrom(view.timestamp),
                  style: STextStyles.label(context),
                ),
              ),
              Expanded(
                flex: 6,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      text.primary,
                      style: text.muted
                          ? dark.copyWith(color: colors.textSubtitle1)
                          : dark,
                    ),
                    if (text.secondary != null)
                      Text(
                        text.secondary!,
                        style: STextStyles.desktopTextExtraExtraSmall(context),
                      ),
                  ],
                ),
              ),
              SvgPicture.asset(
                Assets.svg.circleInfo,
                width: 20,
                height: 20,
                colorFilter: ColorFilter.mode(
                  colors.textSubtitle2,
                  BlendMode.srcIn,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

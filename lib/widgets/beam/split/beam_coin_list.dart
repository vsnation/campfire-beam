/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Each coin of one asset, read-only, from Split coins ("See each coin"):
// how much it holds and whether it can be spent now. The technical word
// for coins never shows.

import 'package:flutter/material.dart';

import '../../../l10n/amount_text.dart';
import '../../../l10n/l10n.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/models/beam_utxo.dart';
import '../../../wallets/beam/utxo/beam_coins.dart';
import '../airdrop/beam_layout.dart';
import '../airdrop/beam_units.dart';

/// What the coin list says, in plain words, so each line can be tested.
abstract final class BeamCoinListText {
  static String title(String symbol) => appL10n.splitCoinListTitle(symbol);

  /// "3 ready to spend · 1 not yet".
  static String summary(BeamCoinSummary coins) {
    final ready = coins.available.length;
    final waiting = coins.locked.length;
    if (waiting == 0) return appL10n.splitCoinListReady(ready);
    return appL10n.splitCoinListReadyWaiting(ready, waiting);
  }

  /// One coin's state. BEAM coins worth no more than a payment's fee are
  /// said to be too small: spending one costs more than it holds.
  static String status(BeamUtxo coin) {
    final l = appL10n;
    switch (coin.status) {
      case BeamUtxoStatus.available:
        if (coin.isShielded) return l.splitCoinReadyPrivate;
        if (coin.assetId == 0 && coin.amount <= BeamFees.minimum) {
          return l.splitCoinTooSmall;
        }
        return l.splitCoinReady;
      case BeamUtxoStatus.maturing:
        final h = coin.maturity;
        return h == null
            ? l.splitCoinReadySoon
            : l.splitCoinReadySoonAfterBlock(_grouped(h));
      case BeamUtxoStatus.incoming:
        return l.splitCoinArriving;
      case BeamUtxoStatus.outgoing:
        return l.splitCoinInPayment;
      case BeamUtxoStatus.unavailable ||
          BeamUtxoStatus.spent ||
          BeamUtxoStatus.consumed ||
          BeamUtxoStatus.unknown:
        return l.splitCoinNotSpendable;
    }
  }

  static String get note => appL10n.splitCoinListNote;

  static String get empty => appL10n.splitCoinListEmpty;

  /// 4073500 -> "4,073,500" ("4 073 500" in Russian).
  static String _grouped(int n) => groupThousands(n.toString());
}

/// Shows [coins] of one asset: a sheet on a phone, a dialog on desktop.
Future<void> showBeamCoinList({
  required BuildContext context,
  required BeamCoinSummary coins,
  required String symbol,
  int? places,
}) {
  final desktop = BeamLayoutScope.isDesktop(context);
  final rows = [...coins.available, ...coins.locked];
  Widget list(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final sub = STextStyles.itemSubtitle(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            BeamCoinListText.title(symbol),
            key: const ValueKey('coin-list-title'),
            style: desktop
                ? STextStyles.desktopH3(context)
                : STextStyles.pageTitleH2(context),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            rows.isEmpty
                ? BeamCoinListText.empty
                : BeamCoinListText.summary(coins),
            key: const ValueKey('coin-list-summary'),
            style: sub,
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              for (final (i, c) in rows.indexed)
                Container(
                  key: ValueKey('coin-row-$i'),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: i == rows.length - 1
                            ? Colors.transparent
                            : colors.background,
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        BeamUnits.withSymbol(c.amount, symbol, places: places),
                        style: STextStyles.titleBold12(context),
                      ),
                      const SizedBox(height: 2),
                      Text(BeamCoinListText.status(c), style: sub),
                    ],
                  ),
                ),
              // Part of the list, so it scrolls with the coins instead of
              // taking room from them on a small phone.
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  BeamCoinListText.note,
                  style: STextStyles.label(context),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  if (desktop) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Theme.of(context).extension<StackColors>()!.popupBG,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
          child: list(context),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).extension<StackColors>()!.popupBG,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: list(context),
      ),
    ),
  );
}

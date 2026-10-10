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

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/models/beam_utxo.dart';
import '../../../wallets/beam/utxo/beam_coins.dart';
import '../airdrop/beam_layout.dart';
import '../airdrop/beam_units.dart';

/// What the coin list says, in plain words, so each line can be tested.
abstract final class BeamCoinListText {
  static String title(String symbol) => 'Your $symbol coins';

  /// "3 ready to spend · 1 on its way".
  static String summary(BeamCoinSummary coins) {
    final ready = coins.available.length;
    final waiting = coins.locked.length;
    final head = ready == 1 ? '1 ready to spend' : '$ready ready to spend';
    if (waiting == 0) return head;
    return '$head · ${waiting == 1 ? '1 not yet' : '$waiting not yet'}';
  }

  /// One coin's state. BEAM coins worth no more than a payment's fee are
  /// said to be too small: spending one costs more than it holds.
  static String status(BeamUtxo coin) {
    switch (coin.status) {
      case BeamUtxoStatus.available:
        if (coin.isShielded) return 'Ready to spend · private';
        if (coin.assetId == 0 && coin.amount <= BeamFees.minimum) {
          return 'Too small to be worth spending';
        }
        return 'Ready to spend';
      case BeamUtxoStatus.maturing:
        final h = coin.maturity;
        return h == null
            ? 'Ready soon'
            : 'Ready soon (after block ${_grouped(h)})';
      case BeamUtxoStatus.incoming:
        return 'Arriving';
      case BeamUtxoStatus.outgoing:
        return "In a payment that hasn't finished";
      case BeamUtxoStatus.unavailable ||
          BeamUtxoStatus.spent ||
          BeamUtxoStatus.consumed ||
          BeamUtxoStatus.unknown:
        return 'Not spendable right now';
    }
  }

  static const note =
      'Each payment uses one or more coins and gives the rest back as a new '
      'coin. More coins let several payments go at once.';

  static const empty = 'No coins yet. Coins that arrive show up here.';

  /// 4073500 -> "4,073,500".
  static String _grouped(int n) => n.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
}

/// Shows [coins] of one asset: a sheet on a phone, a dialog on desktop.
Future<void> showBeamCoinList({
  required BuildContext context,
  required BeamCoinSummary coins,
  required String symbol,
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
                        BeamUnits.withSymbol(c.amount, symbol),
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

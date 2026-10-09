/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A coin from another chain (icon, ticker, chain) and an unfinished NEAR
// Intents swap, as the NEAR Intents screens show them.

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/ethereum/near_intents/near_intents_store.dart';
import '../../../wallets/ethereum/near_intents/one_click_client.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../uniswap/uniswap_format.dart';

/// A round icon with the coin's letters on a colour made from its id, so
/// copies never borrow a real coin's picture (no network for icons).
class NearIntentsCoinIcon extends StatelessWidget {
  const NearIntentsCoinIcon({super.key, required this.token, this.size = 24});

  final OneClickToken token;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hue = token.assetId.codeUnits.fold(7, (h, c) => (h * 31 + c) % 360);
    final clean = token.symbol.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final letters = clean.isEmpty
        ? '?'
        : clean
              .substring(0, clean.length >= 3 ? 3 : clean.length)
              .toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: HSLColor.fromAHSL(1, hue.toDouble(), 0.5, 0.42).toColor(),
      ),
      child: Text(
        letters,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * (letters.length > 2 ? 0.3 : 0.38),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Icon, ticker and chain for the amount field's coin button.
class NearIntentsCoinChip extends StatelessWidget {
  const NearIntentsCoinChip({super.key, required this.token});

  final OneClickToken token;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        NearIntentsCoinIcon(token: token, size: 20),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                token.symbol,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: STextStyles.smallMed14(context)
                    .copyWith(color: colors.textDark),
              ),
              Text(
                token.chainName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: STextStyles.label(context)
                    .copyWith(color: colors.textSubtitle1, fontSize: 10),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Waiting for your 0.001 BTC…" — an unfinished swap, tap to open it.
class NearIntentsOpenSwapCard extends StatelessWidget {
  const NearIntentsOpenSwapCard({
    super.key,
    required this.swap,
    required this.onTap,
  });

  final NearIntentsSwap swap;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final amount =
        '${UniFormat.exact(swap.quote.amountIn, swap.origin.decimals)} '
        '${swap.origin.symbol}';
    final what = switch (swap.lastState) {
      OneClickState.knownDepositTx ||
      OneClickState.processing => 'Swapping your $amount into ETH…',
      OneClickState.incompleteDeposit => 'Less than $amount arrived',
      _ => 'Waiting for your $amount',
    };
    return DexCard(
      key: Key('ni-open-${swap.depositAddress}'),
      onTap: onTap,
      child: Row(
        children: [
          NearIntentsCoinIcon(token: swap.origin, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(what, style: STextStyles.titleBold12(context)),
                Text(
                  'NEAR Intents · tap to see the deposit address',
                  style: STextStyles.label(context)
                      .copyWith(color: colors.textSubtitle1),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: colors.textSubtitle1,
          ),
        ],
      ),
    );
  }
}

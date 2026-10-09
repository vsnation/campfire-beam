/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Small pieces shared by the Uniswap screens: a token's icon and name, a
// route in words, and the warning for a token Campfire does not vouch for.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../themes/coin_icon_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/ethereum/uniswap/uniswap_models.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import 'uniswap_deps.dart';
import 'uniswap_format.dart';

/// A token's round icon: ETH's and BEAM's own (for ETH, WETH and WBEAM),
/// else its first letters on a colour made from its address, so a copy
/// never borrows a real token's picture.
class UniTokenIcon extends ConsumerWidget {
  const UniTokenIcon({super.key, required this.token, this.size = 24});

  final UniToken token;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CryptoCurrency? coin = token.isEthLike
        ? Ethereum(CryptoCurrencyNetwork.main)
        : token.address == kWbeamToken.address
        ? Beam(CryptoCurrencyNetwork.main)
        : null;
    if (coin != null) {
      // A theme without this coin's icon gets the letters below.
      String? path;
      try {
        path = ref.watch(coinIconProvider(coin));
      } catch (_) {
        path = null;
      }
      if (path != null && File(path).existsSync()) {
        return SvgPicture.file(File(path), width: size, height: size);
      }
    }
    final hue = int.parse(token.address.substring(2, 8), radix: 16) % 360;
    final clean = token.symbol.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final letters = clean.isEmpty
        ? '?'
        : clean.substring(0, clean.length >= 2 ? 2 : 1).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: HSLColor.fromAHSL(1, hue.toDouble(), 0.45, 0.42).toColor(),
      ),
      child: Text(
        letters,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.38,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Icon and ticker for the amount field's token button.
class UniTokenChip extends StatelessWidget {
  const UniTokenChip({super.key, required this.token, required this.deps});

  final UniToken token;
  final UniswapDeps deps;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        UniTokenIcon(token: token, size: 20),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 110),
          child: Text(
            token.symbol,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: STextStyles.smallMed14(context)
                .copyWith(color: colors.textDark),
          ),
        ),
        if (!deps.isVerified(token)) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.warning_amber_rounded,
            size: 14,
            color: colors.accentColorRed,
          ),
        ],
      ],
    );
  }
}

/// "ETH → WBEAM · Uniswap v4, 1% pool" — the route in words.
String uniRouteText(UniQuote q, UniswapDeps deps) {
  String sym(String currency) {
    if (currency == UniToken.eth.address) return 'ETH';
    if (currency == q.tokenIn.address) return q.tokenIn.symbol;
    if (currency == q.tokenOut.address) return q.tokenOut.symbol;
    return deps.token(currency)?.symbol ?? UniFormat.short(currency);
  }

  final hops = q.route.hops;
  final path = [
    sym(hops.first.currencyIn),
    for (final h in hops) sym(h.currencyOut),
  ];
  // ETH ⇄ WETH conversions on the way are the router's own; keep "ETH".
  final names = path.map(
    (s) => s == 'WETH' && !q.tokenIn.isWeth && !q.tokenOut.isWeth ? 'ETH' : s,
  );
  return names.join(' → ');
}

/// "v4 · 1%" for each pool of the route.
String uniPoolsText(UniRoute route) => [
  for (final h in route.hops)
    '${h.pool.version.label} · ${UniFormat.fee(h.pool.fee)}'
        '${h.pool is UniV4Pool && (h.pool as UniV4Pool).hasHooks ? ' · hook' : ''}',
].join(', then ');

/// Warns about a token Campfire does not vouch for: anyone can make a token
/// called "USDT".
class UniUnverifiedWarning extends StatelessWidget {
  const UniUnverifiedWarning({
    super.key,
    required this.token,
    required this.deps,
  });

  final UniToken token;
  final UniswapDeps deps;

  @override
  Widget build(BuildContext context) {
    if (deps.isVerified(token)) return const SizedBox.shrink();
    final colors = Theme.of(context).extension<StackColors>()!;
    final copied = deps.impersonates(token);
    final text = copied != null
        ? 'Not the real ${copied.symbol}: this token only uses its name. '
              'Address ${UniFormat.short(token.address)}.'
        : '${token.symbol} is not on Campfire\'s list. Check its address '
              '(${UniFormat.short(token.address)}) before you swap.';
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 14,
            color: colors.accentColorRed,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
              key: Key('uni-unverified-${token.address}'),
              style: STextStyles.label(context).copyWith(
                color: colors.accentColorRed,
                fontFeatures: kAddressFontFeatures,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Pay with BTC, ZEC or LTC" — opens NEAR Intents.
class UniPayWithOtherCoinCard extends StatelessWidget {
  const UniPayWithOtherCoinCard({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return DexCard(
      key: const Key('uni-pay-other-coin'),
      onTap: onTap,
      child: Row(
        children: [
          Icon(Icons.swap_horiz_rounded, size: 22, color: colors.textDark),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pay with BTC, ZEC or LTC',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: STextStyles.smallMed14(
                    context,
                  ).copyWith(color: colors.textDark),
                ),
                Text(
                  'Or any other coin, through NEAR Intents',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: STextStyles.label(
                    context,
                  ).copyWith(color: colors.textSubtitle1),
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

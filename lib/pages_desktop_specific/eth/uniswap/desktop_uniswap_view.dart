/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The desktop Uniswap swap, in the layout of the BEAM DEX
// (`desktop_beam_dex_view.dart`): the swap form on the left, every
// Uniswap pool between the two tokens on the right.
//
// Spec: as `uniswap_swap_view.dart`; on desktop the
// pools are beside the form instead of one tap away.

import 'package:flutter/material.dart';

import '../../../pages/eth/uniswap/uniswap_deps.dart';
import '../../../pages/eth/uniswap/uniswap_pools_view.dart';
import '../../../pages/eth/uniswap/uniswap_swap_view.dart';
import '../../../pages/eth/uniswap/uniswap_widgets.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/ethereum/uniswap/uniswap_models.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/desktop/desktop_app_bar.dart';
import '../../../widgets/desktop/desktop_scaffold.dart';
import '../../../widgets/rounded_white_container.dart';

class DesktopUniswapView extends StatefulWidget {
  const DesktopUniswapView({
    super.key,
    required this.deps,
    this.showHeader = true,
    this.initialAmount,
    this.onPayWithOtherCoin,
    this.onBuyNativeBeam,
  });

  final UniswapDeps deps;

  /// ETH to start with (from NEAR Intents).
  final BigInt? initialAmount;

  /// Opens NEAR Intents; null hides the link.
  final VoidCallback? onPayWithOtherCoin;

  /// Opens Buy BEAM for a BEAM wallet; null hides the link.
  final VoidCallback? onBuyNativeBeam;

  /// False inside the side menu's page, which has its own title.
  final bool showHeader;

  @override
  State<DesktopUniswapView> createState() => _DesktopUniswapViewState();
}

class _DesktopUniswapViewState extends State<DesktopUniswapView> {
  UniToken _a = UniToken.eth;
  UniToken _b = kWbeamToken;
  UniQuote? _quote;

  @override
  Widget build(BuildContext context) {
    final body = Padding(
      padding: const EdgeInsets.only(left: 24, right: 24, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Swap on Uniswap, straight from this wallet',
                  style: STextStyles.desktopTextExtraExtraSmall(context),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  'Uniswap pools',
                  style: STextStyles.desktopTextExtraExtraSmall(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ListView(
                    children: [
                      RoundedWhiteContainer(
                        padding: const EdgeInsets.all(24),
                        child: UniswapSwapView(
                          deps: widget.deps,
                          embedded: true,
                          initialAmount: widget.initialAmount,
                          onPairChanged: (a, b) => setState(() {
                            _a = a;
                            _b = b;
                          }),
                          onQuoteChanged: (q) => setState(() => _quote = q),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ListView(
                    children: [
                      // Beside the form, so its button stays on screen.
                      if (widget.onPayWithOtherCoin != null) ...[
                        UniPayWithOtherCoinCard(
                          onTap: widget.onPayWithOtherCoin!,
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (widget.onBuyNativeBeam != null) ...[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: CustomTextButton(
                            key: const Key('uni-buy-native-beam'),
                            text: 'Want BEAM in your BEAM wallet instead?',
                            onTap: widget.onBuyNativeBeam,
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      RoundedWhiteContainer(
                        padding: const EdgeInsets.all(24),
                        child: UniswapPoolsView(
                          deps: widget.deps,
                          a: _a,
                          b: _b,
                          quote: _quote,
                          embedded: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (!widget.showHeader) return body;
    return DesktopScaffold(
      appBar: DesktopAppBar(
        isCompactHeight: true,
        leading: Padding(
          padding: const EdgeInsets.only(left: 24),
          child: Text('Swap', style: STextStyles.desktopH3(context)),
        ),
      ),
      body: body,
    );
  }
}

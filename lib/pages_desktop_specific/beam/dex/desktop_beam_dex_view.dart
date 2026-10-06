/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
// 1. ONE job: swap one asset for another; the pools sit beside the form
//    the way Campfire's desktop exchange puts recent trades beside it.
// 2. Primary CTA: "Swap now" (the pools column has only the secondary
//    "Create a pool").
// 3. Clicks from app open: wallet → Swap (2), amount, "Swap now" (3);
//    pool screens and confirmations open as Campfire desktop dialogs.

import 'package:flutter/material.dart';

import '../../../pages/beam/dex/beam_dex_pools_view.dart';
import '../../../pages/beam/dex/beam_dex_swap_view.dart';
import '../../../utilities/text_styles.dart';
import '../../../widgets/beam/dex/dex_deps.dart';
import '../../../widgets/desktop/desktop_app_bar.dart';
import '../../../widgets/desktop/desktop_scaffold.dart';
import '../../../widgets/rounded_white_container.dart';

/// The desktop DEX: the swap form on the left, the pools on the right, in
/// the layout of `DesktopExchangeView`.
class DesktopBeamDexView extends StatelessWidget {
  const DesktopBeamDexView({
    super.key,
    required this.deps,
    this.initialPayAsset = 0,
    this.initialReceiveAsset,
  });

  final BeamDexDeps deps;
  final int initialPayAsset;
  final int? initialReceiveAsset;

  @override
  Widget build(BuildContext context) {
    return DesktopScaffold(
      appBar: DesktopAppBar(
        isCompactHeight: true,
        leading: Padding(
          padding: const EdgeInsets.only(left: 24),
          child: Text('Swap', style: STextStyles.desktopH3(context)),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.only(left: 24, right: 24, bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Swap one asset for another',
                    style: STextStyles.desktopTextExtraExtraSmall(context),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'Pools',
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
                          child: BeamDexSwapView(
                            deps: deps,
                            embedded: true,
                            initialPayAsset: initialPayAsset,
                            initialReceiveAsset: initialReceiveAsset,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: BeamDexPoolsView(deps: deps, embedded: true)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

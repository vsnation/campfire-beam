/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The side menu's Buy BEAM page: "What do you want to buy?" beside the
// menu. BEAM opens the Buy BEAM form (a dialog) for the BEAM wallet used
// last; WBEAM on Ethereum opens the side menu's Swap page for the
// Ethereum wallet, with WBEAM to receive. Like the Bridge page it has no
// wallet chip: each card finds (or creates) its own wallet.
//
// Spec (USER_PSYCHOLOGY §6): as `buy_chooser_view.dart`. Clicks from app
// open: Buy BEAM (1), a card (2), then the form's button (3).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../pages/beam/buy/buy_beam_wiring.dart';
import '../../../pages/beam/buy/buy_chooser_view.dart';
import '../../../widgets/beam/sidebar/beam_sidebar.dart';
import '../sidebar/beam_sidebar_scaffold.dart';

class BuySidebarPage extends ConsumerWidget {
  const BuySidebarPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Open buys are followed from the moment the menu shows this page.
    BuyBeamWiring.start();
    return BeamSidebarScaffold(
      title: BeamSidebarDestination.buy.label,
      showWallet: false,
      body: BuyChooserView(
        deps: buyChooserDepsFor(ref, isDesktop: true),
        embedded: true,
      ),
    );
  }
}

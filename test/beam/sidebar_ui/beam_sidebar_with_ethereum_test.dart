/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The BEAM side menu once the build also has Ethereum: its BEAM pages act
// on BEAM wallets only, a BEAM wallet added while an Ethereum one exists is
// picked up at once (Campfire announces wallet changes only in single-coin
// builds upstream; the BEAM build keeps announcing them), and having an
// Ethereum wallet open in My Campfire changes nothing for the BEAM pages.
// Swap is the exception: it lists BEAM and Ethereum
// wallets and shows Uniswap for an Ethereum one.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages_desktop_specific/beam/dex/desktop_beam_dex_view.dart';
import 'package:stackwallet/pages_desktop_specific/beam/sidebar/beam_sidebar_assets_page.dart';
import 'package:stackwallet/pages_desktop_specific/eth/uniswap/desktop_uniswap_view.dart';
import 'package:stackwallet/widgets/beam/sidebar/swap_sidebar_wallets.dart';
import 'package:stackwallet/pages_desktop_specific/beam/sidebar/beam_sidebar_section.dart';
import 'package:stackwallet/pages_desktop_specific/desktop_menu.dart';
import 'package:stackwallet/providers/global/active_wallet_provider.dart';
import 'package:stackwallet/widgets/beam/sidebar/beam_sidebar.dart';

import '../eth_ui/eth_ui_harness.dart';
import 'sidebar_harness.dart';

/// The real menu beside a real section (as
/// beam_sidebar_real_wallets_test.dart).
class _MenuAnd extends StatelessWidget {
  const _MenuAnd(this.destination);

  final BeamSidebarDestination destination;

  @override
  Widget build(BuildContext context) => Material(
    child: Row(
      children: [
        const DesktopMenu(),
        const SizedBox(width: 1),
        Expanded(child: BeamSidebarSection(destination: destination)),
      ],
    ),
  );
}

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  // First: the database has only an Ethereum wallet.
  testWidgets('an Ethereum wallet is not a BEAM wallet; a BEAM wallet added '
      'next to it shows up at once', (tester) async {
    final eth = await openEthWallet(tester, name: 'Ethereum');
    final container = await pumpSidebar(
      tester,
      home: const _MenuAnd(BeamSidebarDestination.assets),
    );
    expect(container.read(pBeamSidebarWallet).hasWallets, isFalse);
    expect(find.byKey(const Key('beamSidebarNoWallet')), findsOneWidget);

    final beam = await openBeamWallet(tester, db, core: SidebarCore());
    await settle(tester, rounds: 3);
    expect(container.read(pBeamSidebarWallets).map((w) => w.walletId), [
      beam.walletId,
    ]);
    expect(find.byType(BeamSidebarAssetsPage), findsOneWidget);

    // The Ethereum wallet open in My Campfire: the BEAM pages keep the
    // BEAM wallet, and nothing breaks.
    container.read(currentWalletIdProvider.notifier).state = eth.walletId;
    await settle(tester, rounds: 2);
    expect(container.read(pBeamSidebarWallet).wallet?.walletId, beam.walletId);
    expect(container.read(pBeamSidebarWalletChoice), isNot(eth.walletId));
    expect(
      tester.widget<Text>(find.byKey(const Key('beamSidebarWalletName'))).data,
      'Everyday BEAM',
    );
    await finishSidebar(tester);
  });

  // The database now has both wallets.
  testWidgets('Swap: Uniswap for the Ethereum wallet, the BEAM DEX for the '
      'BEAM wallet', (tester) async {
    final container = await pumpSidebar(
      tester,
      home: const _MenuAnd(BeamSidebarDestination.swap),
    );
    final wallets = container.read(pSwapSidebarWallets);
    expect(wallets.length, 2);
    final eth = wallets.firstWhere((w) => w.info.name == 'Ethereum');
    final beam = wallets.firstWhere((w) => w.info.name == 'Everyday BEAM');

    container.read(currentWalletIdProvider.notifier).state = eth.walletId;
    await settle(tester, rounds: 3);
    // The Uniswap page reads the wallet's address from its database first.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await settle(tester, rounds: 3);
    expect(find.byType(DesktopUniswapView), findsOneWidget);
    expect(find.byType(DesktopBeamDexView), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const Key('beamSidebarWalletName'))).data,
      'Ethereum',
    );
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/swap_with_ethereum_wallet_open.png'),
    );

    container.read(pSwapSidebarWalletChoice.notifier).choose(beam.walletId);
    await settle(tester, rounds: 3);
    expect(find.byType(DesktopBeamDexView), findsOneWidget);
    expect(find.byType(DesktopUniswapView), findsNothing);
    // The Uniswap page asked the (unreachable) RPC for balances and fees;
    // let those requests time out before the tree goes.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(minutes: 2));
    // Choosing it started the BEAM wallet (the first test had closed it).
    await tester.runAsync(beam.exit);
    await finishSidebar(tester);
  });
}

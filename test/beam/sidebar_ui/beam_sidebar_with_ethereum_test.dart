/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The BEAM side menu once the build also has Ethereum: its pages act on
// BEAM wallets only, a BEAM wallet added while an Ethereum one exists is
// picked up at once (Campfire announces wallet changes only in single-coin
// builds upstream; the BEAM build keeps announcing them), and having an
// Ethereum wallet open in My Campfire changes nothing for the BEAM pages.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages_desktop_specific/beam/dex/desktop_beam_dex_view.dart';
import 'package:stackwallet/pages_desktop_specific/beam/sidebar/beam_sidebar_section.dart';
import 'package:stackwallet/pages_desktop_specific/desktop_menu.dart';
import 'package:stackwallet/providers/global/active_wallet_provider.dart';
import 'package:stackwallet/widgets/beam/sidebar/beam_sidebar.dart';

import '../eth_ui/eth_ui_harness.dart';
import 'sidebar_harness.dart';

/// The real menu beside the real Swap section (as
/// beam_sidebar_real_wallets_test.dart).
class _MenuAndSwap extends StatelessWidget {
  const _MenuAndSwap();

  @override
  Widget build(BuildContext context) => const Material(
    child: Row(
      children: [
        DesktopMenu(),
        SizedBox(width: 1),
        Expanded(
          child: BeamSidebarSection(destination: BeamSidebarDestination.swap),
        ),
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
    final container = await pumpSidebar(tester, home: const _MenuAndSwap());
    expect(container.read(pBeamSidebarWallet).hasWallets, isFalse);
    expect(find.byKey(const Key('beamSidebarNoWallet')), findsOneWidget);

    final beam = await openBeamWallet(tester, db, core: SidebarCore());
    await settle(tester, rounds: 3);
    expect(container.read(pBeamSidebarWallets).map((w) => w.walletId), [
      beam.walletId,
    ]);
    expect(find.byType(DesktopBeamDexView), findsOneWidget);

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
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/swap_with_ethereum_wallet_open.png'),
    );
    await finishSidebar(tester);
  });
}

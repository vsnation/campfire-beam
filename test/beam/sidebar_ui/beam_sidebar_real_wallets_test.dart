/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The side menu over Campfire's REAL wallet list (no override): a page
// that offers "Create a BEAM wallet" picks up the wallet as soon as it
// exists; and a wallet whose core is not running is started in the
// background while its page shows at once (R11).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages_desktop_specific/beam/dex/desktop_beam_dex_view.dart';
import 'package:stackwallet/pages_desktop_specific/beam/sidebar/beam_sidebar_section.dart';
import 'package:stackwallet/pages_desktop_specific/desktop_menu.dart';
import 'package:stackwallet/widgets/beam/sidebar/beam_sidebar.dart';

import 'sidebar_harness.dart';

/// The real menu beside the real Swap section, without My Campfire (whose
/// wallet list keeps a subscription past its life in tests, see
/// pumpSidebar).
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

  // First: the database has no wallet yet.
  testWidgets('a new wallet replaces "Create a BEAM wallet" by itself', (
    tester,
  ) async {
    final container = await pumpSidebar(tester, home: const _MenuAndSwap());
    expect(find.byKey(const Key('beamSidebarNoWallet')), findsOneWidget);
    expect(container.read(pBeamSidebarWallet).hasWallets, isFalse);

    final wallet = await openBeamWallet(tester, db, core: SidebarCore());
    await settle(tester, rounds: 3);
    expect(container.read(pBeamSidebarWallets).map((w) => w.walletId), [
      wallet.walletId,
    ]);
    expect(find.byKey(const Key('beamSidebarNoWallet')), findsNothing);
    expect(find.byType(DesktopBeamDexView), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('beamSidebarWalletName'))).data,
      'Everyday BEAM',
    );
    await finishSidebar(tester);
  });

  testWidgets('a wallet that is not running is started in the background; '
      'its page shows at once', (tester) async {
    final wallet = await openBeamWallet(
      tester,
      db,
      core: SidebarCore(),
      name: 'Closed BEAM',
    );
    await tester.runAsync(wallet.exit);
    expect(wallet.isOpen, isFalse);

    await pumpSidebar(tester, wallets: [wallet]);
    await tester.tap(find.byKey(BeamSidebarDestination.swap.menuKey));
    await tester.pump();
    // The page is there on the next frame, not after the core.
    expect(find.byType(DesktopBeamDexView), findsOneWidget);

    // The start was asked from inside the widget zone: let real I/O and
    // the fake clock take turns until the core is up.
    for (var i = 0; i < 40 && !wallet.isOpen; i++) {
      await settle(tester, rounds: 1);
    }
    expect(wallet.isOpen, isTrue);
    await settle(tester, rounds: 2);
    expect(find.byType(DesktopBeamDexView), findsOneWidget);
    // Its pollers were created in this test's clock: stop them here.
    await tester.runAsync(wallet.exit);
    await tester.pump();
    await finishSidebar(tester);
  });
}

/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The screens Ethereum changes for everyone, on the 1280 × 800 desktop
// window and a 375 × 667 phone: My Campfire, "Add wallet" and Settings ›
// Nodes. The same code renders the BEAM-only build (no Ethereum wallet,
// "Add wallet" goes straight to BEAM) and the build with Ethereum (a BEAM
// and an Ethereum wallet, the coin picker), so the goldens of both builds
// compare one to one.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/settings_views/global_settings_view/manage_nodes_views/manage_nodes_view.dart';
import 'package:stackwallet/pages/wallets_view/wallets_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/my_stack_view.dart';
import 'package:stackwallet/pages_desktop_specific/settings/desktop_settings_view.dart';
import 'package:stackwallet/pages_desktop_specific/settings/settings_menu.dart';
import 'package:stackwallet/providers/global/node_service_provider.dart';
import 'package:stackwallet/providers/global/price_provider.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/utilities/util.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/isar/providers/all_wallets_info_provider.dart';

import '../wiring_ui/wiring_harness.dart';
import 'eth_ui_harness.dart';

/// The wallets My Campfire lists: a BEAM wallet, and an Ethereum wallet
/// when the build has Ethereum.
Future<List<WalletInfo>> _openWallets(WidgetTester tester, WiringDb db) async {
  final beam = await openBeamWallet(tester, db, name: 'Everyday BEAM');
  return [
    beam.info,
    if (buildHasEthereum) (await openEthWallet(tester, name: 'Ethereum')).info,
  ];
}

List<Override> _overrides(List<WalletInfo> infos) => [
  pAllWalletsInfo.overrideWithValue(infos),
  priceAnd24hChangeNotifierProvider.overrideWithValue(NoPrices()),
  nodeServiceChangeNotifierProvider.overrideWithValue(testNodeService()),
];

Finder _addWallet(bool desktop) =>
    find.text(desktop ? 'Add new wallet' : 'Add new', findRichText: true);

Widget _phone(Widget child) => Builder(
  builder: (context) => Scaffold(
    backgroundColor: Theme.of(context).extension<StackColors>()!.background,
    body: child,
  ),
);

void main() {
  final db = WiringDb();
  setUpAll(() async {
    await db.open();
    await openNodeHive();
  });
  tearDownAll(() async {
    await closeNodeHive();
    await db.close();
  });

  for (final desktop in [true, false]) {
    final where = desktop ? 'desktop' : 'phone';
    group(where, () {
      // Campfire's own widgets ask Util.isDesktop; the tests run on a desktop.
      setUp(() => Util.debugIsDesktop = desktop);
      tearDown(() => Util.debugIsDesktop = null);

      testWidgets('My Campfire ($where)', (tester) async {
        final infos = await _openWallets(tester, db);
        await pumpWiring(
          tester,
          desktop ? const MyStackView() : _phone(const WalletsView()),
          desktop: desktop,
          overrides: _overrides(infos),
        );
        expect(_addWallet(desktop), findsOneWidget);
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/my_campfire_$where.png'),
        );
        await finish(tester);
      });

      testWidgets('Add wallet ($where)', (tester) async {
        final infos = await _openWallets(tester, db);
        await pumpWiring(
          tester,
          desktop ? const MyStackView() : _phone(const WalletsView()),
          desktop: desktop,
          overrides: _overrides(infos),
        );
        await tester.tap(_addWallet(desktop));
        await settle(tester);
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/add_wallet_$where.png'),
        );
        await finish(tester);
      });

      testWidgets('Settings › Nodes ($where)', (tester) async {
        final infos = await _openWallets(tester, db);
        await pumpWiring(
          tester,
          desktop ? const DesktopSettingsView() : const ManageNodesView(),
          desktop: desktop,
          overrides: [
            ..._overrides(infos),
            // "Nodes" in the desktop settings menu.
            selectedSettingsMenuItemStateProvider.overrideWithProvider(
              StateProvider<int>((_) => 5),
            ),
          ],
        );
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/nodes_$where.png'),
        );
        await finish(tester);
      });
    });
  }
}

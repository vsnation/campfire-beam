/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A side-menu item always opens on its first page, in Campfire's REAL
// desktop home: chosen from another item, or clicked again while shown.
// The bug this guards (macOS app, 2026-10-06): My Campfire → a wallet →
// dApps → Notifications → My Campfire landed back on the dApp, not on the
// wallet list. And the node chip follows the wallet open in My Campfire.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_claim_voucher_view.dart';
import 'package:stackwallet/pages/beam/dapps/dapp_store_view.dart';
import 'package:stackwallet/pages/beam/minter/beam_mint_token_view.dart';
import 'package:stackwallet/pages/beam/names/beam_names_home_view.dart';
import 'package:stackwallet/pages_desktop_specific/beam/dex/desktop_beam_dex_view.dart';
import 'package:stackwallet/pages_desktop_specific/beam/sidebar/beam_sidebar_assets_page.dart';
import 'package:stackwallet/pages_desktop_specific/beam/sidebar/beam_sidebar_hub_page.dart';
import 'package:stackwallet/pages_desktop_specific/beam/sidebar/beam_sidebar_section.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/my_stack_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/beam_desktop_asset_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/desktop_wallet_view.dart';
import 'package:stackwallet/pages_desktop_specific/settings/settings_menu/desktop_support_view.dart';
import 'package:stackwallet/providers/desktop/desktop_open_wallet_request.dart';
import 'package:stackwallet/providers/global/active_wallet_provider.dart';
import 'package:stackwallet/widgets/beam/sidebar/beam_sidebar.dart';

import 'sidebar_harness.dart';

/// Whether the route showing [f] is the top one of its navigator.
bool _onTop(WidgetTester tester, Finder f) =>
    ModalRoute.of(tester.element(f.first))!.isCurrent;

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  testWidgets('My Campfire opens on the wallet list: from another item, '
      'and when clicked again', (tester) async {
    final wallet = await openBeamWallet(tester, db, core: SidebarCore());
    final container = await pumpSidebar(tester, wallets: [wallet]);

    // My Campfire → the wallet → its dApps (as in the report).
    Future<void> openWalletAndDapps() async {
      Navigator.of(tester.element(find.byType(MyStackView)))
          .pushNamed(DesktopWalletView.routeName, arguments: wallet.walletId)
          .ignore();
      await settle(tester, rounds: 2);
      expect(find.byType(DesktopWalletView), findsOneWidget);
      expect(container.read(currentWalletIdProvider), wallet.walletId);
      Navigator.of(tester.element(find.byType(DesktopWalletView)))
          .pushNamed(DappStoreView.routeName, arguments: wallet)
          .ignore();
      await settle(tester, rounds: 2);
      expect(_onTop(tester, find.byType(DappStoreView)), isTrue);
    }

    await openWalletAndDapps();
    // Another item, then My Campfire: the wallet list, not the dApps.
    await tapMenu(tester, const ValueKey('support'));
    expect(find.byType(DesktopSupportView), findsOneWidget);
    await tapMenu(tester, const ValueKey('myStack'));
    expect(find.byType(DappStoreView), findsNothing);
    expect(find.byType(DesktopWalletView), findsNothing);
    expect(_onTop(tester, find.byType(MyStackView)), isTrue);
    expect(container.read(currentWalletIdProvider), isNull);
    expect(wallet.shouldAutoSync, isFalse);

    // The same from a BEAM item.
    await openWalletAndDapps();
    await tapMenu(tester, BeamSidebarDestination.swap.menuKey);
    expect(find.byType(DesktopBeamDexView), findsOneWidget);
    await tapMenu(tester, const ValueKey('myStack'));
    expect(find.byType(DesktopWalletView), findsNothing);
    expect(_onTop(tester, find.byType(MyStackView)), isTrue);

    // And clicked again while it shows the wallet.
    await openWalletAndDapps();
    await tapMenu(tester, const ValueKey('myStack'));
    expect(find.byType(DesktopWalletView), findsNothing);
    expect(_onTop(tester, find.byType(MyStackView)), isTrue);
    await finishSidebar(tester);
  });

  // The restore dialog's "Open my wallet" on desktop: it cannot reach My
  // Campfire's navigator, so it asks the desktop home.
  testWidgets('an open-wallet request shows that wallet in My Campfire, '
      'from any item', (tester) async {
    final wallet = await openBeamWallet(tester, db, core: SidebarCore());
    final container = await pumpSidebar(tester, wallets: [wallet]);
    await tapMenu(tester, const ValueKey('support'));
    expect(find.byType(DesktopSupportView), findsOneWidget);

    container.read(desktopOpenWalletRequestProvider.state).state =
        wallet.walletId;
    // Opening runs the wallet's init/open (real I/O) under a loading overlay.
    await settle(tester, rounds: 10);
    expect(find.text('Opening ${wallet.info.name}'), findsNothing);
    expect(find.byType(DesktopWalletView), findsOneWidget);
    expect(_onTop(tester, find.byType(DesktopWalletView)), isTrue);
    expect(container.read(currentWalletIdProvider), wallet.walletId);
    expect(container.read(desktopOpenWalletRequestProvider), isNull);
    await finishSidebar(tester);
  });

  testWidgets('a BEAM item clicked again goes back to its first page; '
      'at its first page nothing is rebuilt', (tester) async {
    final wallet = await openBeamWallet(tester, db, core: SidebarCore());
    await pumpSidebar(tester, wallets: [wallet]);

    // Airdrops → Claim a code → Airdrops: the three tasks.
    await tapMenu(tester, BeamSidebarDestination.airdrops.menuKey);
    final section = tester.state(find.byType(BeamSidebarSection));
    await tester.tap(find.byKey(const Key('beamAirdropClaim')));
    await settle(tester, rounds: 2);
    expect(find.byType(BeamClaimVoucherView), findsOneWidget);
    await tapMenu(tester, BeamSidebarDestination.airdrops.menuKey);
    expect(find.byType(BeamClaimVoucherView), findsNothing);
    expect(_onTop(tester, find.byType(BeamSidebarHubPage)), isTrue);
    // The page was popped to, not rebuilt.
    expect(tester.state(find.byType(BeamSidebarSection)), same(section));

    // Clicked again on its first page: nothing happens.
    await tapMenu(tester, BeamSidebarDestination.airdrops.menuKey);
    expect(tester.state(find.byType(BeamSidebarSection)), same(section));
    expect(find.byType(BeamSidebarHubPage), findsOneWidget);

    // Swap, Names and dApps open their own screens as dialogs on desktop;
    // a page pushed in their area goes the same way.
    for (final (d, page) in [
      (BeamSidebarDestination.swap, DesktopBeamDexView),
      (BeamSidebarDestination.names, BeamNamesHomeView),
      (BeamSidebarDestination.dapps, DappStoreView),
    ]) {
      await tapMenu(tester, d.menuKey);
      Navigator.of(tester.element(find.byType(page)))
          .push(
            MaterialPageRoute<void>(
              builder: (_) => const Material(child: Text('a page under it')),
            ),
          )
          .ignore();
      await settle(tester, rounds: 2);
      expect(find.text('a page under it'), findsOneWidget, reason: d.label);
      await tapMenu(tester, d.menuKey);
      expect(find.text('a page under it'), findsNothing, reason: d.label);
      expect(_onTop(tester, find.byType(page)), isTrue, reason: d.label);
    }

    // Assets → FOMO → Assets: the list.
    await tapMenu(tester, BeamSidebarDestination.assets.menuKey);
    await tester.tap(find.byKey(const Key('beamSidebarAssetRow174')));
    await settle(tester, rounds: 2);
    expect(find.byType(BeamDesktopAssetView), findsOneWidget);
    await tapMenu(tester, BeamSidebarDestination.assets.menuKey);
    expect(find.byType(BeamDesktopAssetView), findsNothing);
    expect(_onTop(tester, find.byType(BeamSidebarAssetsPage)), isTrue);

    // Tokens → Create a token → another item → Tokens: the three tasks.
    await tapMenu(tester, BeamSidebarDestination.tokens.menuKey);
    await tester.tap(find.byKey(const Key('beamTokensCreate')));
    await settle(tester, rounds: 2);
    expect(find.byType(BeamMintTokenView), findsOneWidget);
    await tapMenu(tester, BeamSidebarDestination.swap.menuKey);
    await tapMenu(tester, BeamSidebarDestination.tokens.menuKey);
    expect(find.byType(BeamMintTokenView), findsNothing);
    expect(_onTop(tester, find.byType(BeamSidebarHubPage)), isTrue);
    await finishSidebar(tester);
  });

  testWidgets('Campfire\'s own items too: Support clicked again', (
    tester,
  ) async {
    await pumpSidebar(tester, wallets: const []);
    await tapMenu(tester, const ValueKey('support'));
    Navigator.of(tester.element(find.byType(DesktopSupportView)))
        .push(
          MaterialPageRoute<void>(
            builder: (_) => const Material(child: Text('a page under it')),
          ),
        )
        .ignore();
    await settle(tester, rounds: 2);
    expect(find.text('a page under it'), findsOneWidget);
    await tapMenu(tester, const ValueKey('support'));
    expect(find.text('a page under it'), findsNothing);
    expect(_onTop(tester, find.byType(DesktopSupportView)), isTrue);
    await finishSidebar(tester);
  });

  testWidgets('the node chip shows the wallet open in My Campfire', (
    tester,
  ) async {
    final synced = await openBeamWallet(tester, db, core: SidebarCore());
    final behind = await openBeamWallet(
      tester,
      db,
      core: SidebarCore(),
      explorerHeight: kTip + 42,
      name: 'Behind BEAM',
    );
    final container = await pumpSidebar(tester, wallets: [synced, behind]);
    String chip() => tester
        .widget<Text>(find.byKey(const Key('beamSidebarNodeChipLabel')))
        .data!;

    // Two wallets running, none opened yet: nothing to report on.
    expect(chip(), 'Not connected');

    // As DesktopWalletView does when the user opens a wallet.
    container.read(currentWalletIdProvider.notifier).state = behind.walletId;
    await settle(tester, rounds: 1);
    expect(chip(), 'Catching up');

    container.read(currentWalletIdProvider.notifier).state = synced.walletId;
    await settle(tester, rounds: 1);
    expect(chip(), 'Public node');

    // Tor switched off in Settings reads as off, not as a fault.
    expect(
      tester
          .widget<Tooltip>(find.byKey(const Key('beamSidebarTorTooltip')))
          .message,
      'Tor is off',
    );
    await finishSidebar(tester);
  });
}

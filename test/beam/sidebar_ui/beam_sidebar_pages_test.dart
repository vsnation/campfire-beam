/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The BEAM pages of the side menu, in Campfire's REAL desktop home: each
// opens beside the menu (not as a dialog) under the side menu's header,
// on the right wallet: the one open in My Campfire or picked (remembered),
// else the only one; several and none chosen → a picker; none → "Create a
// BEAM wallet". Goldens go to docs/beam/screenshots/B-SIDEBAR/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/add_wallet_views/create_or_restore_wallet_view/create_or_restore_wallet_view.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_airdrop_batches_view.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_claim_voucher_view.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_create_airdrop_view.dart';
import 'package:stackwallet/pages/beam/dapps/dapp_store_view.dart';
import 'package:stackwallet/pages/beam/minter/beam_burn_view.dart';
import 'package:stackwallet/pages/beam/minter/beam_mint_token_view.dart';
import 'package:stackwallet/pages/beam/minter/beam_my_tokens_view.dart';
import 'package:stackwallet/pages/beam/names/beam_names_home_view.dart';
import 'package:stackwallet/pages/token_view/beam_assets_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/beam_desktop_asset_view.dart';
import 'package:stackwallet/pages_desktop_specific/beam/dex/desktop_beam_dex_view.dart';
import 'package:stackwallet/pages_desktop_specific/beam/sidebar/beam_sidebar_assets_page.dart';
import 'package:stackwallet/pages_desktop_specific/beam/sidebar/beam_sidebar_hub_page.dart';
import 'package:stackwallet/pages_desktop_specific/desktop_menu.dart';
import 'package:stackwallet/providers/global/active_wallet_provider.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_host.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/widgets/beam/sidebar/beam_sidebar.dart';
import 'package:stackwallet/widgets/beam/wiring/beam_wallet_listenables.dart';

import 'sidebar_harness.dart';

String _chipName(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('beamSidebarWalletName'))).data!;

String _title(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('beamSidebarTitle'))).data!;

/// The page's own header (built for the wallet screen) is laid out but
/// clipped away: what sits at its title's place is the side menu's header.
void _ownHeaderHidden(WidgetTester tester, Type page, String ownTitle) {
  final hidden = find
      .descendant(of: find.byType(page), matching: find.text(ownTitle))
      .first;
  final at = tester.getCenter(hidden);
  expect(at.dy, lessThan(82), reason: 'laid out above the body');
  final hits = tester.hitTestOnBinding(at).path.map((e) => e.target);
  expect(hits, isNot(contains(tester.renderObject(hidden))));
}

/// Checks every BEAM page uses [wallet]; leaves the menu on Tokens.
Future<void> _expectAllOn(WidgetTester tester, BeamWallet wallet) async {
  final wiring = BeamWalletWiring.of(wallet);

  await tapMenu(tester, BeamSidebarDestination.swap.menuKey);
  expect(_title(tester), 'Swap');
  expect(_chipName(tester), wallet.info.name);
  expect(
    tester.widget<DesktopBeamDexView>(find.byType(DesktopBeamDexView)).deps,
    same(wiring.dex),
  );

  await tapMenu(tester, BeamSidebarDestination.assets.menuKey);
  expect(_title(tester), 'Assets');
  expect(
    tester
        .widget<BeamSidebarAssetsPage>(find.byType(BeamSidebarAssetsPage))
        .wallet,
    same(wallet),
  );

  await tapMenu(tester, BeamSidebarDestination.names.menuKey);
  expect(_title(tester), 'Names');
  expect(
    tester.widget<BeamNamesHomeView>(find.byType(BeamNamesHomeView)).deps,
    same(wiring.names),
  );

  await tapMenu(tester, BeamSidebarDestination.dapps.menuKey);
  expect(_title(tester), 'dApps');
  expect(
    tester.widget<DappStoreView>(find.byType(DappStoreView)).host,
    same(DappHost.of(wallet)),
  );

  await tapMenu(tester, BeamSidebarDestination.airdrops.menuKey);
  expect(_title(tester), 'Airdrops');
  await tester.tap(find.byKey(const Key('beamAirdropClaim')));
  await settle(tester, rounds: 2);
  expect(
    tester
        .widget<BeamClaimVoucherView>(find.byType(BeamClaimVoucherView))
        .service,
    same(wiring.airdrop),
  );

  await tapMenu(tester, BeamSidebarDestination.tokens.menuKey);
  expect(_title(tester), 'Tokens');
  await tester.tap(find.byKey(const Key('beamTokensCreate')));
  await settle(tester, rounds: 2);
  expect(
    tester.widget<BeamMintTokenView>(find.byType(BeamMintTokenView)).service,
    same(wiring.minter),
  );
}

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  testWidgets('Swap, Assets and Names open beside the menu, under its '
      'header, on the one wallet', (tester) async {
    final wallet = await openBeamWallet(tester, db, core: SidebarCore());
    await pumpSidebar(tester, wallets: [wallet]);

    // Swap: the desktop DEX (form beside the pools) in the content area.
    await tapMenu(tester, BeamSidebarDestination.swap.menuKey);
    expect(find.byType(DesktopBeamDexView), findsOneWidget);
    expect(find.byKey(const Key('beamDesktopDexDialog')), findsNothing);
    expect(_title(tester), 'Swap');
    expect(_chipName(tester), 'Everyday BEAM');
    expect(
      find.byKey(const Key('beamSidebarWalletSwitch')),
      findsNothing,
      reason: 'one wallet: nothing to switch to',
    );
    _ownHeaderHidden(tester, DesktopBeamDexView, 'Swap');
    // Beside the menu, not over it.
    expect(tester.getTopLeft(find.byType(DesktopBeamDexView)).dx, 226);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/swap_selected.png'),
    );

    // Assets: every asset of value with its fiat value.
    await tapMenu(tester, BeamSidebarDestination.assets.menuKey);
    expect(find.byType(BeamSidebarAssetsPage), findsOneWidget);
    expect(find.byKey(const Key('beamSidebarAssetRow0')), findsOneWidget);
    expect(find.byKey(const Key('beamSidebarAssetRow174')), findsOneWidget);
    expect(find.textContaining('USD'), findsWidgets);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/assets_selected.png'),
    );
    // A row opens the asset beside the menu, with a way back.
    await tester.tap(find.byKey(const Key('beamSidebarAssetRow174')));
    await settle(tester, rounds: 2);
    expect(find.byType(BeamDesktopAssetView), findsOneWidget);
    await closeRouteOf(tester, find.byType(BeamDesktopAssetView));
    expect(find.byType(BeamSidebarAssetsPage), findsOneWidget);
    // "See all": Campfire's full BEAM asset list (hide / show).
    await tester.tap(find.byKey(const Key('beamSidebarAssetsSeeAll')));
    await settle(tester, rounds: 2);
    expect(find.byType(BeamSidebarAllAssetsPage), findsOneWidget);
    expect(find.byType(BeamAssetsView), findsOneWidget);
    await tester.tap(find.byKey(const Key('beamSidebarBack')));
    await settle(tester, rounds: 2);
    expect(find.byType(BeamSidebarAllAssetsPage), findsNothing);
    expect(find.byType(BeamSidebarAssetsPage), findsOneWidget);

    // Names: the names home, its own back arrow gone.
    await tapMenu(tester, BeamSidebarDestination.names.menuKey);
    expect(find.byType(BeamNamesHomeView), findsOneWidget);
    expect(_title(tester), 'Names');
    _ownHeaderHidden(tester, BeamNamesHomeView, 'Names');
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/names_selected.png'),
    );

    // dApps: the store.
    await tapMenu(tester, BeamSidebarDestination.dapps.menuKey);
    expect(find.byType(DappStoreView), findsOneWidget);
    _ownHeaderHidden(tester, DappStoreView, 'dApps');

    // Airdrops: three tasks; each opens beside the menu and comes back.
    await tapMenu(tester, BeamSidebarDestination.airdrops.menuKey);
    expect(find.byType(BeamSidebarHubPage), findsOneWidget);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/airdrops_selected.png'),
    );
    for (final (key, page) in [
      ('beamAirdropClaim', BeamClaimVoucherView),
      ('beamAirdropMine', BeamAirdropBatchesView),
      ('beamAirdropCreate', BeamCreateAirdropView),
    ]) {
      await tester.tap(find.byKey(Key(key)));
      await settle(tester, rounds: 2);
      expect(find.byType(page), findsOneWidget, reason: key);
      expect(tester.getTopLeft(find.byType(page)).dx, 226, reason: key);
      await closeRouteOf(tester, find.byType(page));
      expect(find.byType(BeamSidebarHubPage), findsOneWidget, reason: key);
    }

    await tapMenu(tester, BeamSidebarDestination.tokens.menuKey);
    for (final (key, page) in [
      ('beamTokensCreate', BeamMintTokenView),
      ('beamTokensMine', BeamMyTokensView),
      ('beamTokensBurn', BeamBurnView),
    ]) {
      await tester.tap(find.byKey(Key(key)));
      await settle(tester, rounds: 2);
      expect(find.byType(page), findsOneWidget, reason: key);
      await closeRouteOf(tester, find.byType(page));
      expect(find.byType(BeamSidebarHubPage), findsOneWidget, reason: key);
    }
    await finishSidebar(tester);
  });

  testWidgets('the remembered wallet is used, and switching is one click '
      'away and remembered', (tester) async {
    final everyday = await openBeamWallet(tester, db, core: SidebarCore());
    final savings = await openBeamWallet(
      tester,
      db,
      core: SidebarCore(),
      name: 'Savings BEAM',
    );
    final memory = MemoryWalletMemory(savings.walletId);
    await pumpSidebar(tester, wallets: [everyday, savings], memory: memory);
    await _expectAllOn(tester, savings);

    // Switch from the header.
    await tapMenu(tester, BeamSidebarDestination.swap.menuKey);
    expect(find.byKey(const Key('beamSidebarWalletSwitch')), findsOneWidget);
    await tester.tap(find.byKey(const Key('beamSidebarWalletSwitch')));
    await settle(tester, rounds: 1);
    await tester.tap(
      find.byKey(Key('beamSidebarWalletOption_${everyday.walletId}')),
    );
    await settle(tester, rounds: 2);
    expect(_chipName(tester), 'Everyday BEAM');
    expect(
      tester.widget<DesktopBeamDexView>(find.byType(DesktopBeamDexView)).deps,
      same(BeamWalletWiring.of(everyday).dex),
    );
    expect(memory.writes.last, everyday.walletId);
    await finishSidebar(tester);
  });

  testWidgets('the wallet open in My Campfire is the one the pages use', (
    tester,
  ) async {
    final a = await openBeamWallet(tester, db, core: SidebarCore());
    final b = await openBeamWallet(
      tester,
      db,
      core: SidebarCore(),
      name: 'Savings BEAM',
    );
    final memory = MemoryWalletMemory(a.walletId);
    final container = await pumpSidebar(
      tester,
      wallets: [a, b],
      memory: memory,
    );
    // As DesktopWalletView does when the user opens a wallet.
    container.read(currentWalletIdProvider.notifier).state = b.walletId;
    await tester.pump();
    await _expectAllOn(tester, b);
    expect(memory.value, b.walletId);
    await finishSidebar(tester);
  });

  testWidgets('several wallets, none chosen: a compact picker at the top; '
      'one click opens the page on it', (tester) async {
    final a = await openBeamWallet(tester, db, core: SidebarCore());
    final b = await openBeamWallet(
      tester,
      db,
      core: SidebarCore(),
      name: 'Savings BEAM',
    );
    final memory = MemoryWalletMemory();
    await pumpSidebar(tester, wallets: [a, b], memory: memory);
    await tapMenu(tester, BeamSidebarDestination.swap.menuKey);
    expect(find.byKey(const Key('beamSidebarWalletPicker')), findsOneWidget);
    expect(find.byType(DesktopBeamDexView), findsNothing);
    expect(_title(tester), 'Swap');
    // At the top: the picker starts right under the header.
    expect(
      tester.getTopLeft(find.byKey(const Key('beamSidebarWalletPicker'))).dy,
      lessThan(120),
    );
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/wallet_picker.png'),
    );
    await tester.tap(find.byKey(Key('beamSidebarPick_${b.walletId}')));
    await settle(tester, rounds: 2);
    expect(find.byType(DesktopBeamDexView), findsOneWidget);
    expect(_chipName(tester), 'Savings BEAM');
    expect(memory.writes, [b.walletId]);
    // Every other page now uses it too, without asking again.
    await tapMenu(tester, BeamSidebarDestination.names.menuKey);
    expect(find.byKey(const Key('beamSidebarWalletPicker')), findsNothing);
    expect(_chipName(tester), 'Savings BEAM');
    await finishSidebar(tester);
  });

  testWidgets('Bridge opens beside the menu; with no Ethereum wallet it '
      'offers to add one', (tester) async {
    final wallet = await openBeamWallet(tester, db, core: SidebarCore());
    await pumpSidebar(tester, wallets: [wallet]);
    await tapMenu(tester, BeamSidebarDestination.bridge.menuKey);
    expect(_title(tester), 'Bridge');
    expect(find.byKey(const Key('bridge-no-wallet')), findsOneWidget);
    expect(find.text('Add an Ethereum wallet'), findsOneWidget);
    expect(find.byKey(const Key('beamSidebarWalletChip')), findsNothing);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/bridge_selected.png'),
    );
    await finishSidebar(tester);
  });

  testWidgets('no BEAM wallet: one button, "Create a BEAM wallet"', (
    tester,
  ) async {
    await pumpSidebar(tester, wallets: const []);
    for (final d in BeamSidebarDestination.values) {
      await tapMenu(tester, d.menuKey);
      // The bridge says so in its own form (it needs a wallet of each).
      expect(
        find.byKey(
          Key(
            d == BeamSidebarDestination.bridge
                ? 'bridge-no-wallet'
                : 'beamSidebarNoWallet',
          ),
        ),
        findsOneWidget,
      );
      expect(_title(tester), d.label);
      expect(find.byKey(const Key('beamSidebarWalletChip')), findsNothing);
    }
    await tapMenu(tester, BeamSidebarDestination.swap.menuKey);
    expect(find.text('Create a BEAM wallet'), findsOneWidget);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/no_wallet.png'),
    );
    await tester.tap(find.byKey(const Key('beamSidebarCreateWallet')));
    await settle(tester, rounds: 2);
    expect(find.byType(CreateOrRestoreWalletView), findsOneWidget);
    await finishSidebar(tester);
  });

  testWidgets('the wallet screen\'s feature row can open a page in the menu', (
    tester,
  ) async {
    final a = await openBeamWallet(tester, db, core: SidebarCore());
    final b = await openBeamWallet(
      tester,
      db,
      core: SidebarCore(),
      name: 'Savings BEAM',
    );
    final memory = MemoryWalletMemory(a.walletId);
    await pumpSidebar(tester, wallets: [a, b], memory: memory);
    final context = tester.element(find.byType(DesktopMenu));
    expect(
      openBeamFeatureInSidebar(
        context,
        b,
        BeamSidebarDestination.names.feature,
      ),
      isTrue,
    );
    await settle(tester, rounds: 2);
    expect(find.byType(BeamNamesHomeView), findsOneWidget);
    expect(_chipName(tester), 'Savings BEAM');
    await finishSidebar(tester);
  });
}

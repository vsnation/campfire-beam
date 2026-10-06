/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The desktop wallet screen (Campfire's real DesktopWalletView, 1280 × 800,
// the Linux window) for a REAL BeamWallet: the feature row holds exactly the
// BEAM features, each opens its page, Assets sit beside Send / Receive, the
// Send tab is dimmed with the reason while the wallet is behind, and
// "Address list" opens the BEAM list. Goldens are copied to
// docs/beam/screenshots/B-WIRING/.
//
//   scripts/beam/host_test.sh --no-analyze --update-goldens --copy-goldens \
//       test/beam/wiring_ui

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_airdrop_batches_view.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_claim_voucher_view.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_create_airdrop_view.dart';
import 'package:stackwallet/pages/beam/dapps/dapp_store_view.dart';
import 'package:stackwallet/pages/beam/minter/beam_burn_view.dart';
import 'package:stackwallet/pages/beam/minter/beam_mint_token_view.dart';
import 'package:stackwallet/pages/beam/minter/beam_my_tokens_view.dart';
import 'package:stackwallet/pages/beam/names/beam_names_home_view.dart';
import 'package:stackwallet/pages/token_view/beam_assets_view.dart';
import 'package:stackwallet/pages_desktop_specific/addresses/desktop_wallet_addresses_view.dart';
import 'package:stackwallet/pages_desktop_specific/beam/dex/desktop_beam_dex_view.dart';
import 'package:stackwallet/pages_desktop_specific/beam/node/desktop_beam_node_sync_dialog.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/desktop_wallet_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_wallet_features.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/more_features/more_features_dialog.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/wallet_options_button.dart';
import 'package:stackwallet/widgets/beam/receive/beam_address_list.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_wallet_home.dart';
import 'package:stackwallet/widgets/beam/wiring/beam_features.dart';
import 'package:stackwallet/widgets/desktop/secondary_button.dart';

import 'wiring_harness.dart';

/// Every label Campfire's desktop feature row can show for another coin.
const _otherCoinsLabels = [
  'Privatize funds',
  'Buy',
  'PayNym',
  'Coin control',
  'Spark coins',
  'MWEB outputs',
  'Ordinals',
  'MonKey',
  'Fusion',
  'Churn',
  'Domains',
  'Staking',
  'Sign/Verify',
  'Masternodes',
];

const _beamLabels = [
  'Swap',
  'Names',
  'dApps',
  'Airdrops',
  'Tokens',
  'Node & sync',
];

Finder _rowButton(String label) => find
    .descendant(
      of: find.byType(DesktopWalletFeatures),
      matching: find.widgetWithText(SecondaryButton, label),
    )
    .first;

/// The labels on the feature row itself, left to right.
List<String> _rowLabels(WidgetTester tester) => [
  for (final b in tester.widgetList<SecondaryButton>(
    find.descendant(
      of: find.byType(DesktopWalletFeatures),
      matching: find.byType(SecondaryButton),
    ),
  ))
    b.label!,
];

/// Opens [label] from the row, or from "More" when the row has no room.
Future<void> _openFeature(WidgetTester tester, String label) async {
  if (find
      .descendant(
        of: find.byType(DesktopWalletFeatures),
        matching: find.widgetWithText(SecondaryButton, label),
      )
      .evaluate()
      .isNotEmpty) {
    await tester.tap(_rowButton(label));
  } else {
    await tester.tap(_rowButton('More'));
    await settle(tester, rounds: 1);
    await tester.tap(
      find.descendant(
        of: find.byType(MoreFeaturesDialog),
        matching: find.text(label),
      ),
    );
  }
  await settle(tester, rounds: 2);
}

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  testWidgets('the feature row holds exactly the BEAM features, most used '
      'first, and nothing of other coins', (tester) async {
    final wallet = await openBeamWallet(tester, db);
    await pumpWiring(
      tester,
      DesktopWalletView(walletId: wallet.walletId),
      desktop: true,
    );

    final row = _rowLabels(tester);
    expect(row.last, 'More', reason: 'six features do not fit at 1280 px');
    final onRow = row.sublist(0, row.length - 1);
    expect(onRow, _beamLabels.sublist(0, onRow.length));
    for (final l in _otherCoinsLabels) {
      expect(find.text(l), findsNothing, reason: '$l is not a BEAM feature');
    }
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/desktop_wallet_features.png'),
    );

    await tester.tap(_rowButton('More'));
    await settle(tester, rounds: 1);
    final more = [
      for (final t in tester.widgetList<Text>(
        find.descendant(
          of: find.byType(MoreFeaturesDialog),
          matching: find.byType(Text),
        ),
      ))
        t.data,
    ];
    final rest = _beamLabels.sublist(onRow.length);
    for (final l in rest) {
      expect(more, contains(l));
    }
    expect([...onRow, ...more.where(_beamLabels.contains)], _beamLabels);
    for (final l in _otherCoinsLabels) {
      expect(more, isNot(contains(l)));
    }
    expect(find.byType(MoreFeaturesDialog), findsOneWidget);
    // Campfire's switches (address reuse, RBF, MWEB…) are not BEAM's.
    expect(find.text('Reuse receiving address'), findsNothing);
    expect(find.text('Reset Spark electrumx cache'), findsNothing);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/desktop_more_features.png'),
    );
    await finish(tester);
  });

  testWidgets('desktop labels and phone labels are the same words', (
    tester,
  ) async {
    for (final e in kBeamWalletFeatures.entries) {
      expect(e.value.label, e.key.label);
      expect(e.value.description, e.key.description);
    }
    expect(BeamFeature.desktopRow.map((f) => f.label).toList(), _beamLabels);
  });

  testWidgets('each feature opens its page', (tester) async {
    final wallet = await openBeamWallet(tester, db);
    await pumpWiring(
      tester,
      DesktopWalletView(walletId: wallet.walletId),
      desktop: true,
    );

    // Swap: the desktop DEX (form beside the pools) in a large dialog.
    await _openFeature(tester, 'Swap');
    expect(find.byKey(const Key('beamDesktopDexDialog')), findsOneWidget);
    expect(find.byType(DesktopBeamDexView), findsOneWidget);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/desktop_swap.png'),
    );
    await closeRouteOf(tester, find.byType(DesktopBeamDexView));
    expect(find.byType(DesktopBeamDexView), findsNothing);

    await _openFeature(tester, 'Names');
    expect(find.byType(BeamNamesHomeView), findsOneWidget);
    await closeRouteOf(tester, find.byType(BeamNamesHomeView));

    await _openFeature(tester, 'dApps');
    expect(find.byType(DappStoreView), findsOneWidget);
    await closeRouteOf(tester, find.byType(DappStoreView));

    // Airdrops: three tasks; the most common first.
    await _openFeature(tester, 'Airdrops');
    expect(find.byKey(const Key('beamFeatureMenu')), findsOneWidget);
    expect(find.text('Claim a code'), findsOneWidget);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/desktop_airdrops_menu.png'),
    );
    for (final (key, page) in [
      ('beamAirdropClaim', BeamClaimVoucherView),
      ('beamAirdropMine', BeamAirdropBatchesView),
      ('beamAirdropCreate', BeamCreateAirdropView),
    ]) {
      if (find.byKey(const Key('beamFeatureMenu')).evaluate().isEmpty) {
        await _openFeature(tester, 'Airdrops');
      }
      await tester.tap(find.byKey(Key(key)));
      await settle(tester, rounds: 2);
      expect(find.byType(page), findsOneWidget, reason: key);
      await closeRouteOf(tester, find.byType(page));
    }

    for (final (key, page) in [
      ('beamTokensCreate', BeamMintTokenView),
      ('beamTokensMine', BeamMyTokensView),
      ('beamTokensBurn', BeamBurnView),
    ]) {
      await _openFeature(tester, 'Tokens');
      await tester.tap(find.byKey(Key(key)));
      await settle(tester, rounds: 2);
      expect(find.byType(page), findsOneWidget, reason: key);
      await closeRouteOf(tester, find.byType(page));
    }

    await _openFeature(tester, 'Node & sync');
    expect(find.byType(DesktopBeamNodeSyncDialog), findsOneWidget);
    await closeRouteOf(tester, find.byType(DesktopBeamNodeSyncDialog));
    await finish(tester);
  });

  testWidgets('Assets sit beside Send / Receive; history is a tab', (
    tester,
  ) async {
    final wallet = await openBeamWallet(tester, db);
    await pumpWiring(
      tester,
      DesktopWalletView(walletId: wallet.walletId),
      desktop: true,
    );
    expect(find.text('Assets'), findsOneWidget);
    expect(find.text('Recent activity'), findsNothing);
    expect(find.byType(BeamAssetsView), findsOneWidget);
    expect(find.text('FOMO'), findsWidgets);
    expect(find.text('Transactions'), findsWidgets);
    // Not Ethereum's "Edit tokens" (BEAM lists every asset it holds).
    expect(find.text('Edit'), findsNothing);
    await finish(tester);
  });

  testWidgets('the Send tab is dimmed, with the reason, while the wallet is '
      'behind; normal once synced', (tester) async {
    final behind = await openBeamWallet(
      tester,
      db,
      explorerHeight: kTip + 42,
      name: 'Behind BEAM',
    );
    final container = await pumpWiring(
      tester,
      DesktopWalletView(walletId: behind.walletId),
      desktop: true,
    );
    final reason = container.read(pBeamHome(behind.walletId)).sendPausedReason;
    expect(
      reason,
      'Sending is paused while the wallet catches up (42 blocks behind).',
    );
    expect(find.byKey(const Key('beamDesktopSendTabDisabled')), findsOneWidget);
    final tip = tester.widget<Tooltip>(
      find.byKey(const Key('beamDesktopSendTabReason')),
    );
    expect(tip.message, reason);
    expect(reason, isNotNull);
    for (final text in tester.widgetList<Text>(
      find.descendant(
        of: find.byKey(const Key('beamDesktopSendTabDisabled')),
        matching: find.byType(Text),
      ),
    )) {
      expect(text.style!.color!.a, closeTo(0.35, 0.01));
    }
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/desktop_send_tab_paused.png'),
    );
    await finish(tester);

    final synced = await openBeamWallet(tester, db, name: 'Synced BEAM');
    await pumpWiring(
      tester,
      DesktopWalletView(walletId: synced.walletId),
      desktop: true,
    );
    expect(find.byKey(const Key('beamDesktopSendTabEnabled')), findsOneWidget);
    expect(find.byKey(const Key('beamDesktopSendTabReason')), findsNothing);
    await finish(tester);
  });

  testWidgets('wallet options → Address list opens the BEAM list', (
    tester,
  ) async {
    final wallet = await openBeamWallet(tester, db);
    await pumpWiring(
      tester,
      DesktopWalletView(walletId: wallet.walletId),
      desktop: true,
    );
    await tester.tap(find.byType(WalletOptionsButton));
    await settle(tester, rounds: 1);
    await tester.tap(find.text('Address list'));
    await settle(tester, rounds: 2);
    expect(find.byKey(const Key('beamAddressListDialog')), findsOneWidget);
    expect(find.byType(BeamAddressList), findsOneWidget);
    expect(find.byType(DesktopWalletAddressesView), findsNothing);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/desktop_address_list.png'),
    );
    await finish(tester);
  });
}

/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The phone wallet screen (Campfire's real WalletView on a 375 × 667 phone)
// for a REAL BeamWallet: the bottom bar is Receive, Send, Buy, Swap, Assets
// and More, entirely on screen; More lists Names, dApps, Airdrops, Tokens and
// Node & sync; each entry opens its page. Goldens are copied to
// docs/beam/screenshots/B-WIRING/.
//
//   scripts/beam/host_test.sh --no-analyze --update-goldens --copy-goldens \
//       test/beam/wiring_ui

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_airdrop_batches_view.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_claim_voucher_view.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_create_airdrop_view.dart';
import 'package:stackwallet/pages/beam/buy/buy_beam_view.dart';
import 'package:stackwallet/pages/beam/buy/buy_beam_wiring.dart';
import 'package:stackwallet/pages/beam/dapps/dapp_store_view.dart';
import 'package:stackwallet/pages/beam/dex/beam_dex_swap_view.dart';
import 'package:stackwallet/pages/beam/minter/beam_burn_view.dart';
import 'package:stackwallet/pages/beam/minter/beam_mint_token_view.dart';
import 'package:stackwallet/pages/beam/minter/beam_my_tokens_view.dart';
import 'package:stackwallet/pages/beam/names/beam_names_home_view.dart';
import 'package:stackwallet/pages/beam/node/beam_node_sync_view.dart';
import 'package:stackwallet/pages/beam/split/beam_split_view.dart';
import 'package:stackwallet/pages/token_view/beam_assets_view.dart';
import 'package:stackwallet/pages/wallet_view/wallet_view.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_client.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_controller.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_store.dart';
import 'package:stackwallet/widgets/wallet_navigation_bar/components/wallet_navigation_bar_item.dart';
import 'package:stackwallet/widgets/wallet_navigation_bar/wallet_navigation_bar.dart';

import '../buy/buybeam_fakes.dart';
import 'wiring_harness.dart';

const _bar = ['Receive', 'Send', 'Buy', 'Swap', 'Assets', 'More'];
const _more = [
  'Names',
  'dApps',
  'Airdrops',
  'Tokens',
  'Node & sync',
  'Split coins',
  'Bridge',
];

/// The bar's "More" label is cross-faded (two Texts): the first is enough.
Finder _barText(String label) => find
    .descendant(
      of: find.byType(WalletNavigationBarItem),
      matching: find.text(label),
    )
    .first;

Finder _moreText(String label) => find.descendant(
  of: find.byType(WalletNavigationBarMoreItem),
  matching: find.text(label),
);

/// [f] is entirely inside the phone screen.
void _onScreen(WidgetTester tester, Finder f, String what) {
  final r = tester.getRect(f);
  expect(r.left, greaterThanOrEqualTo(0), reason: what);
  expect(r.top, greaterThanOrEqualTo(0), reason: what);
  expect(r.right, lessThanOrEqualTo(phone.width), reason: what);
  expect(r.bottom, lessThanOrEqualTo(phone.height), reason: what);
}

Future<void> _openBar(WidgetTester tester, String label) async {
  await tester.tap(_barText(label));
  await settle(tester, rounds: 2);
}

Future<void> _openMore(WidgetTester tester, String label) async {
  await tester.tap(_barText('More'));
  await settle(tester, rounds: 1);
  await tester.tap(_moreText(label));
  await settle(tester, rounds: 2);
}

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  testWidgets('the bar is Receive, Send, Buy, Swap, Assets, More — all on '
      'a 375 × 667 screen', (tester) async {
    final wallet = await openBeamWallet(tester, db);
    await pumpWiring(
      tester,
      WalletView(walletId: wallet.walletId),
      desktop: false,
    );

    final xs = <double>[];
    for (final l in _bar) {
      expect(
        find.descendant(
          of: find.byType(WalletNavigationBarItem),
          matching: find.text(l),
        ),
        findsWidgets,
        reason: l,
      );
      _onScreen(tester, _barText(l), l);
      xs.add(tester.getCenter(_barText(l)).dx);
    }
    expect(xs, orderedEquals([...xs]..sort()), reason: 'left to right');
    _onScreen(tester, find.byType(WalletNavigationBar), 'the bar');
    expect(find.byKey(const Key('beamSendEnabled')), findsOneWidget);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/phone_wallet_bar.png'),
    );
    await finish(tester);
  });

  testWidgets('More lists Names, dApps, Airdrops, Tokens, Node & sync, Split '
      'coins, Bridge', (tester) async {
    final wallet = await openBeamWallet(tester, db);
    await pumpWiring(
      tester,
      WalletView(walletId: wallet.walletId),
      desktop: false,
    );
    await tester.tap(_barText('More'));
    await settle(tester, rounds: 1);
    final labels = [
      for (final w in tester.widgetList<WalletNavigationBarMoreItem>(
        find.byType(WalletNavigationBarMoreItem),
      ))
        w.data.label,
    ];
    expect(labels, _more);
    for (final l in _more) {
      _onScreen(tester, _moreText(l), l);
    }
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/phone_more_sheet.png'),
    );
    await finish(tester);
  });

  // Seen on the iOS simulator: the More backdrop stopped at the notch and
  // the home indicator, leaving light bands above and below.
  testWidgets('with a notch and a home indicator, the More backdrop covers '
      'the whole screen', (tester) async {
    final wallet = await openBeamWallet(tester, db);
    await pumpWiring(
      tester,
      WalletView(walletId: wallet.walletId),
      desktop: false,
    );
    final dpr = tester.view.devicePixelRatio;
    tester.view.padding = FakeViewPadding(top: 59 * dpr, bottom: 34 * dpr);
    tester.view.viewPadding = FakeViewPadding(top: 59 * dpr, bottom: 34 * dpr);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await tester.pump();
    await tester.tap(_barText('More'));
    await settle(tester, rounds: 1);
    final backdrop = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.color != null &&
          w.color!.r == 0 &&
          (w.color!.a - 0.7).abs() < 0.01,
    );
    final r = tester.getRect(backdrop);
    expect(r.top, 0);
    expect(r.bottom, phone.height);
    // The buttons stay clear of the home indicator.
    expect(
      tester.getRect(_barText('More')).bottom,
      lessThanOrEqualTo(phone.height - 34),
    );
    await finish(tester);
  });

  testWidgets('each entry opens its page', (tester) async {
    final wallet = await openBeamWallet(tester, db);
    BuyBeamWiring.debugController = BuyBeamController(
      client: BuyBeamClient(clientFactory: FakeBuyBeamServer().client),
      store: MemoryBuyBeamStore(),
      autoPoll: false,
    );
    addTearDown(() => BuyBeamWiring.debugController = null);
    await pumpWiring(
      tester,
      WalletView(walletId: wallet.walletId),
      desktop: false,
    );

    // Buy: straight to the form, for this wallet (no BEAM-or-WBEAM).
    await _openBar(tester, 'Buy');
    expect(find.byType(BuyBeamView), findsOneWidget);
    expect(find.text('Arrives in Everyday BEAM'), findsOneWidget);
    expect(find.text('Get a BTC deposit address'), findsOneWidget);
    await closeRouteOf(tester, find.byType(BuyBeamView));

    await _openBar(tester, 'Swap');
    expect(find.byType(BeamDexSwapView), findsOneWidget);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/phone_swap.png'),
    );
    await closeRouteOf(tester, find.byType(BeamDexSwapView));

    await _openBar(tester, 'Assets');
    expect(find.byType(BeamAssetsView), findsOneWidget);
    await closeRouteOf(tester, find.byType(BeamAssetsView));

    await _openMore(tester, 'Names');
    expect(find.byType(BeamNamesHomeView), findsOneWidget);
    await closeRouteOf(tester, find.byType(BeamNamesHomeView));

    await _openMore(tester, 'dApps');
    expect(find.byType(DappStoreView), findsOneWidget);
    await closeRouteOf(tester, find.byType(DappStoreView));

    await _openMore(tester, 'Airdrops');
    expect(find.byKey(const Key('beamFeatureMenu')), findsOneWidget);
    for (final k in const [
      'beamAirdropClaim',
      'beamAirdropMine',
      'beamAirdropCreate',
    ]) {
      _onScreen(tester, find.byKey(Key(k)), k);
    }
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/phone_airdrops_menu.png'),
    );
    await tester.tap(find.byKey(const Key('beamAirdropClaim')));
    await settle(tester, rounds: 2);
    expect(find.byType(BeamClaimVoucherView), findsOneWidget);
    await closeRouteOf(tester, find.byType(BeamClaimVoucherView));
    for (final (key, page) in [
      ('beamAirdropMine', BeamAirdropBatchesView),
      ('beamAirdropCreate', BeamCreateAirdropView),
    ]) {
      await _openMore(tester, 'Airdrops');
      await tester.tap(find.byKey(Key(key)));
      await settle(tester, rounds: 2);
      expect(find.byType(page), findsOneWidget, reason: key);
      await closeRouteOf(tester, find.byType(page));
    }

    await _openMore(tester, 'Tokens');
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/phone_tokens_menu.png'),
    );
    await tester.tap(find.byKey(const Key('beamTokensCreate')));
    await settle(tester, rounds: 2);
    expect(find.byType(BeamMintTokenView), findsOneWidget);
    await closeRouteOf(tester, find.byType(BeamMintTokenView));
    for (final (key, page) in [
      ('beamTokensMine', BeamMyTokensView),
      ('beamTokensBurn', BeamBurnView),
    ]) {
      await _openMore(tester, 'Tokens');
      await tester.tap(find.byKey(Key(key)));
      await settle(tester, rounds: 2);
      expect(find.byType(page), findsOneWidget, reason: key);
      await closeRouteOf(tester, find.byType(page));
    }

    await _openMore(tester, 'Node & sync');
    expect(find.byType(BeamNodeSyncView), findsOneWidget);
    await closeRouteOf(tester, find.byType(BeamNodeSyncView));

    // Split coins: BEAM's coins, read from the core, the advice picked.
    await _openMore(tester, 'Split coins');
    await settle(tester, rounds: 2);
    expect(find.byType(BeamSplitView), findsOneWidget);
    expect(
      find.text('12.5 BEAM in 1 coin: one payment at a time'),
      findsOneWidget,
    );
    expect(find.text('Split into 3 coins'), findsOneWidget);
    await closeRouteOf(tester, find.byType(BeamSplitView));
    await finish(tester);
  });
}

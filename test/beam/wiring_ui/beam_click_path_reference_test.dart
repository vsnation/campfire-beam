/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Where to click in the 1280 × 800 Linux window for
// scripts/beam/docker/steps/beam_features_tour.sh. The real screens are laid
// out here at that size (with a panel the width of Campfire's 225 px menu
// where the app has its menu), the centre of every control the tour clicks
// is printed as `CLICKPATH <name> <x> <y> rect …`, and each `# @<name> x y`
// line of the script must fall inside that control.
//
// The recovery-phrase quiz uses invented words (never a real phrase); its
// word order is random, so it gets no golden, only coordinates.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/add_wallet_views/verify_recovery_phrase_view/sub_widgets/word_table_item.dart';
import 'package:stackwallet/pages/add_wallet_views/verify_recovery_phrase_view/verify_recovery_phrase_view.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_claim_voucher_view.dart';
import 'package:stackwallet/pages/beam/dapps/dapp_store_view.dart';
import 'package:stackwallet/pages/beam/minter/beam_mint_token_view.dart';
import 'package:stackwallet/pages/beam/names/beam_names_home_view.dart';
import 'package:stackwallet/pages_desktop_specific/beam/node/desktop_beam_node_sync_dialog.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/my_stack_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/desktop_wallet_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_wallet_features.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/more_features/more_features_dialog.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/wallet_options_button.dart';
import 'package:stackwallet/widgets/custom_buttons/app_bar_icon_button.dart';
import 'package:stackwallet/widgets/desktop/desktop_dialog_close_button.dart';
import 'package:stackwallet/widgets/desktop/secondary_button.dart';

import 'wiring_harness.dart';

const _script = 'scripts/beam/docker/steps/beam_features_tour.sh';

/// The click path's numbers, from its `# @name x y` lines.
Map<String, Offset> _scriptPoints() => {
  for (final line in File(_script).readAsLinesSync())
    if (RegExp(r'^#\s*@(\S+)\s+(\d+)\s+(\d+)').firstMatch(line) case final m?)
      m.group(1)!: Offset(double.parse(m.group(2)!), double.parse(m.group(3)!)),
};

final _points = _scriptPoints();

/// Where the script's clicks miss, collected so one run prints them all.
final _misses = <String>[];

/// Prints where [f] is and notes when the script does not click inside it.
void _point(WidgetTester tester, String name, Finder f) {
  final r = tester.getRect(f.first);
  final c = r.center;
  // ignore: avoid_print
  print('CLICKPATH $name ${c.dx.round()} ${c.dy.round()} rect $r');
  final s = _points[name];
  if (s == null) {
    _misses.add('the script has no "# @$name x y" line');
  } else if (!r.deflate(2).contains(s)) {
    _misses.add('$name: the script clicks $s, the control is at $r');
  }
}

/// Fails the test when any click of it misses.
void _checkClicks() {
  final m = List.of(_misses);
  _misses.clear();
  expect(m, isEmpty);
}

Finder _in(Finder parent, Finder child) =>
    find.descendant(of: parent, matching: child);

Finder _backOf(Type page) =>
    _in(find.byType(page), find.byType(AppBarIconButton)).first;

Finder _closeIn(Finder dialog) =>
    _in(dialog, find.byType(DesktopDialogCloseButton)).first;

Finder _rowButton(String l) => _in(
  find.byType(DesktopWalletFeatures),
  find.widgetWithText(SecondaryButton, l),
);

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  testWidgets('My Campfire with the tour\'s one wallet: its row (runs first)', (
    tester,
  ) async {
    await openBeamWallet(tester, db, name: 'Savings');
    await pumpWiring(tester, const MyStackView(), desktop: true);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/desktop_my_campfire_one_wallet.png'),
    );
    // The tour's only wallet: the first row of "All wallets".
    expect(find.text('Savings'), findsOneWidget);
    final open = find.text('Open wallet', findRichText: true);
    expect(open, findsOneWidget);
    _point(tester, 'openWallet', open);
    await finish(tester);
    _checkClicks();
  });

  testWidgets('recovery phrase quiz: first word and Verify', (tester) async {
    final wallet = await openBeamWallet(tester, db);
    const words = [
      'alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', //
      'golf', 'hotel', 'india', 'juliet', 'kilo', 'lima',
    ];
    await pumpWiring(
      tester,
      VerifyRecoveryPhraseView(wallet: wallet, mnemonic: words),
      desktop: true,
      frame: false,
    );
    expect(find.byType(WordTableItem), findsNWidgets(9));
    _point(tester, 'quizWord', find.byType(WordTableItem));
    _point(tester, 'quizVerify', find.text('Verify'));
    _point(tester, 'quizTitle', find.text('Verify recovery phrase'));
    await finish(tester);
    _checkClicks();
  });

  testWidgets('wallet screen: every feature, and the way back from it', (
    tester,
  ) async {
    final wallet = await openBeamWallet(tester, db, name: 'Savings');
    await pumpWiring(
      tester,
      DesktopWalletView(walletId: wallet.walletId),
      desktop: true,
    );
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/desktop_wallet_in_app_frame.png'),
    );

    const all = ['Swap', 'Names', 'dApps', 'Airdrops', 'Tokens', 'Node & sync'];
    final onRow = [
      for (final l in all)
        if (_rowButton(l).evaluate().isNotEmpty) l,
    ];
    // ignore: avoid_print
    print('CLICKPATH row: $onRow + More');
    String key(String l) => l.replaceAll(RegExp('[^A-Za-z]'), '');

    /// Opens [label] the way the script does, measuring each click.
    Future<void> open(String label) async {
      if (onRow.contains(label)) {
        _point(tester, 'row${key(label)}', _rowButton(label));
        await tester.tap(_rowButton(label).first);
      } else {
        _point(tester, 'rowMore', _rowButton('More'));
        await tester.tap(_rowButton('More').first);
        await settle(tester, rounds: 1);
        final item = _in(find.byType(MoreFeaturesDialog), find.text(label));
        _point(tester, 'more${key(label)}', item);
        await tester.tap(item.first);
      }
      await settle(tester, rounds: 2);
    }

    await open('Swap');
    _point(
      tester,
      'swapClose',
      _closeIn(find.byKey(const Key('beamDesktopDexDialog'))),
    );
    await closeRouteOf(tester, find.byKey(const Key('beamDesktopDexDialog')));

    await open('Names');
    _point(tester, 'namesBack', _backOf(BeamNamesHomeView));
    await closeRouteOf(tester, find.byType(BeamNamesHomeView));

    await open('dApps');
    _point(tester, 'dappsBack', _backOf(DappStoreView));
    await closeRouteOf(tester, find.byType(DappStoreView));

    await open('Airdrops');
    _point(tester, 'airdropsClaim', find.byKey(const Key('beamAirdropClaim')));
    await tester.tap(find.byKey(const Key('beamAirdropClaim')));
    await settle(tester, rounds: 2);
    _point(tester, 'claimBack', _backOf(BeamClaimVoucherView));
    await closeRouteOf(tester, find.byType(BeamClaimVoucherView));

    await open('Tokens');
    _point(tester, 'tokensCreate', find.byKey(const Key('beamTokensCreate')));
    await tester.tap(find.byKey(const Key('beamTokensCreate')));
    await settle(tester, rounds: 2);
    _point(tester, 'mintBack', _backOf(BeamMintTokenView));
    await closeRouteOf(tester, find.byType(BeamMintTokenView));

    await open('Node & sync');
    _point(
      tester,
      'nodeClose',
      _closeIn(find.byType(DesktopBeamNodeSyncDialog)),
    );
    await closeRouteOf(tester, find.byType(DesktopBeamNodeSyncDialog));

    // Wallet options → Address list.
    _point(tester, 'walletOptions', find.byType(WalletOptionsButton));
    await tester.tap(find.byType(WalletOptionsButton));
    await settle(tester, rounds: 1);
    _point(tester, 'addressList', find.text('Address list'));
    await tester.tap(find.text('Address list'));
    await settle(tester, rounds: 2);
    _point(
      tester,
      'addressListClose',
      _closeIn(find.byKey(const Key('beamAddressListDialog'))),
    );
    await closeRouteOf(tester, find.byKey(const Key('beamAddressListDialog')));

    // The history tab beside Send / Receive.
    _point(tester, 'tabTransactions', find.text('Transactions'));
    await finish(tester);
    _checkClicks();
  });
}

/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A restored wallet whose coins are still being found, on Campfire's real
// screens over a REAL BeamWallet (fake core, nothing found yet):
//   * My Campfire: the wallet row and its favourite card say "Scanning…",
//     never a bare "0.00000000 BEAM";
//   * the phone wallet (375 × 667): "Scanning… 43%" where the balance goes,
//     the percent said once more only in the banner, and a history that says
//     the coins are on their way — with nothing overflowing;
//   * the desktop wallet: history and assets side by side, each with its own
//     words and its own sticker;
//   * once the scan is over (up to date, nothing left to scan) the home is
//     plain again even though the "pending" flag stays set without a
//     private node, and a restored wallet with a balance says why its
//     history is empty (a restore finds coins, not past payments).
// Goldens are copied to docs/beam/screenshots/B-WIRING/.
//
//   scripts/beam/host_test.sh --no-analyze --update-goldens --copy-goldens \
//       test/beam/wiring_ui/beam_scanning_wallet_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/wallet_view/wallet_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/my_stack_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/desktop_wallet_view.dart';
import 'package:stackwallet/widgets/beam/stickers/beam_sticker.dart';
import 'package:stackwallet/widgets/beam/wiring/beam_desktop_wallet_tabs.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/supporting/beam_wallet_info_extension.dart';

import '../wallet/beam_wallet_test_support.dart';
import 'wiring_harness.dart';

/// A core that has found nothing for this wallet yet.
WiringCore _nothingFound() => WiringCore()..status = statusJson(height: kTip);

/// Marks [wallet] as restored and still being scanned (what restore does),
/// optionally a favourite, and waits until the wallet says so.
Future<void> _startScan(
  WidgetTester tester,
  WiringDb db,
  BeamWallet wallet, {
  bool favourite = false,
}) => tester.runAsync(() async {
  await wallet.info.updateExtraBeamWalletInfo(
    beamData: const ExtraBeamWalletInfo(
      restoreScanPending: true,
      restoreScanStartedAt: 1791300000,
    ),
    isar: db.isar,
  );
  if (favourite) await wallet.info.updateIsFavourite(true, isar: db.isar);
  expect(wallet.isScanningForCoins, isTrue);
});

/// The core reports how far its body scan is.
Future<void> _scanned(
  WidgetTester tester,
  FakeBeamHost host,
  int done,
  int total,
) => tester.runAsync(() async {
  host.lastTransport!.emit('ev_sync_progress', {
    'sync_requests_done': done,
    'sync_requests_total': total,
  });
  await Future<void>.delayed(const Duration(milliseconds: 100));
});

Finder _text(String s) => find.textContaining(s, findRichText: true);

/// Lets the history's database query finish (real I/O) and draw.
Future<void> _loadHistory(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await settle(tester);
}

String? _headline(WidgetTester tester) => tester
    .widget<SelectableText>(find.byKey(const Key('beamHomeSpendable')))
    .data;

/// The desktop wallet's Transactions tab (its label is cross-faded: two
/// Texts, the first is enough).
Finder _transactionsTab() => find
    .descendant(
      of: find.byType(BeamDesktopWalletTabs),
      matching: find.text('Transactions'),
    )
    .first;

BeamSticker _stickerOf(WidgetTester tester, Key key) =>
    tester.widget<BeamStickerImage>(find.byKey(key)).sticker;

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  // Runs first: wallets stay in this file's database, and My Campfire lists
  // all of them.
  testWidgets('My Campfire: a scanning wallet reads "Scanning…", not 0; '
      'one whose scan is over, or that was never restored, keeps its 0', (
    tester,
  ) async {
    final core = _nothingFound();
    final host = FakeBeamHost(replies: core.replies);
    final scanning = await openBeamWallet(
      tester,
      db,
      core: core,
      host: host,
      name: 'Restored',
    );
    await _startScan(tester, db, scanning, favourite: true);
    await _scanned(tester, host, 430, 1000);
    // Restored too, but up to date with nothing left to scan: its 0 is real.
    final done = await openBeamWallet(
      tester,
      db,
      core: _nothingFound(),
      name: 'Scanned',
    );
    await _startScan(tester, db, done);
    await openBeamWallet(tester, db, core: _nothingFound(), name: 'Empty');
    await pumpWiring(tester, const MyStackView(), desktop: true);

    for (final name in ['Restored', 'Scanned', 'Empty']) {
      expect(find.text(name), findsWidgets, reason: name);
    }
    // The scanning wallet: its row and its favourite card.
    expect(find.byKey(const Key('beamWalletRowScanning')), findsOneWidget);
    expect(find.byKey(const Key('beamFavoriteScanning')), findsOneWidget);
    // The other two rows are a plain, honest 0.
    expect(_text('0.00000000 BEAM'), findsNWidgets(2));
    expect(_text('0.00 USD'), findsNothing);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/desktop_my_campfire_scanning.png'),
    );
    await finish(tester);
  });

  testWidgets('phone 375 × 667: "Scanning… 43%" for a balance, the history '
      'on its way, nothing overflowing', (tester) async {
    final core = _nothingFound();
    final host = FakeBeamHost(replies: core.replies);
    final wallet = await openBeamWallet(tester, db, core: core, host: host);
    await _startScan(tester, db, wallet);
    await _scanned(tester, host, 430, 1000);
    // Overflows fail this test (tolerateKnownOverflows lets only
    // Campfire's own measuring row through).
    await pumpWiring(
      tester,
      WalletView(walletId: wallet.walletId),
      desktop: false,
    );
    await _loadHistory(tester);

    expect(_headline(tester), 'Scanning… 43%');
    expect(_text('0.00000000'), findsNothing);
    // The percent with its explanation: the banner, once.
    expect(_text('Scanning for your coins… 43%'), findsOneWidget);
    // The history says the coins are on their way.
    expect(find.text('Still looking for your coins'), findsOneWidget);
    expect(find.text('No transactions yet'), findsNothing);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/phone_wallet_scanning.png'),
    );
    await finish(tester);
  });

  testWidgets('desktop: history and assets side by side, each with its own '
      'words and sticker', (tester) async {
    final core = _nothingFound();
    final host = FakeBeamHost(replies: core.replies);
    final wallet = await openBeamWallet(tester, db, core: core, host: host);
    await _startScan(tester, db, wallet);
    await _scanned(tester, host, 430, 1000);
    await pumpWiring(
      tester,
      DesktopWalletView(walletId: wallet.walletId),
      desktop: true,
    );
    await tester.tap(_transactionsTab());
    await _loadHistory(tester);

    expect(_headline(tester), 'Scanning… 43%');
    expect(find.text('Still looking for your coins'), findsOneWidget);
    expect(find.text('Still looking for your assets'), findsOneWidget);
    final history = _stickerOf(tester, const Key('beamNoTxSticker'));
    final assets = _stickerOf(tester, const Key('beamAssetsEmptySticker'));
    expect(history, BeamMoments.coinsOnTheirWay);
    expect(assets, BeamMoments.emptyAssets);
    expect(history, isNot(assets));
    // Under the scanning banner the sticker shrinks so the whole button
    // shows; it used to be cut off at the bottom of the history.
    final receive = find.byKey(const Key('beamNoTxReceive'));
    final shown = tester.getRect(
      find
          .ancestor(of: receive, matching: find.byType(SingleChildScrollView))
          .first,
    );
    expect(tester.getRect(receive).bottom, lessThanOrEqualTo(shown.bottom));
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/desktop_wallet_scanning.png'),
    );
    await finish(tester);
  });

  testWidgets('desktop, not scanning: the two empty lists still differ', (
    tester,
  ) async {
    final wallet = await openBeamWallet(tester, db, core: _nothingFound());
    await pumpWiring(
      tester,
      DesktopWalletView(walletId: wallet.walletId),
      desktop: true,
    );
    await tester.tap(_transactionsTab());
    await _loadHistory(tester);
    expect(find.text('No transactions yet'), findsOneWidget);
    expect(find.text('No assets yet'), findsOneWidget);
    expect(
      _stickerOf(tester, const Key('beamNoTxSticker')),
      BeamMoments.emptyHistory,
    );
    expect(
      _stickerOf(tester, const Key('beamAssetsEmptySticker')),
      BeamMoments.emptyAssets,
    );
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/desktop_wallet_empty.png'),
    );
    await finish(tester);
  });

  testWidgets('phone: the scan is over without a private node — the plain '
      'home, and the history says why it is empty', (tester) async {
    // The real case: restored, 12.5 BEAM + 1,000 FOMO found, the wallet up
    // to date with nothing left to scan, the pending flag still set.
    final wallet = await openBeamWallet(tester, db);
    await _startScan(tester, db, wallet);
    await pumpWiring(
      tester,
      WalletView(walletId: wallet.walletId),
      desktop: false,
    );
    await _loadHistory(tester);

    expect(_headline(tester), '12.50000000 BEAM');
    expect(_text('Scanning'), findsNothing);
    expect(find.byKey(const Key('beamHomeFoundSoFar')), findsNothing);
    expect(find.byKey(const Key('beamHomeSyncBanner')), findsNothing);
    // Not "No transactions yet" next to a balance.
    expect(find.text('No transactions yet'), findsNothing);
    expect(find.text('No payments since the restore'), findsOneWidget);
    expect(
      _text("Payments from before the restore aren't listed"),
      findsOneWidget,
    );
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/phone_wallet_restored.png'),
    );
    await finish(tester);
  });
}

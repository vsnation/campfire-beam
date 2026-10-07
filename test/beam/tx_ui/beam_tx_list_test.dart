/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The BEAM history list: Campfire's own TransactionCardV2 and
// DesktopTransactionCardRow, which hand BEAM transactions to the BEAM
// widgets, rendered at 375 px (phone) and on desktop; and the empty state,
// also while a restored wallet's coins are still being found and in the
// short slot a 375 × 667 phone leaves it.
//
//   scripts/beam/host_test.sh --no-analyze --update-goldens test/beam/tx_ui

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:stackwallet/pages/receive_view/receive_view.dart';
import 'package:stackwallet/pages/wallet_view/transaction_views/tx_v2/all_transactions_v2_view.dart';
import 'package:stackwallet/pages/wallet_view/transaction_views/tx_v2/transaction_v2_card.dart';
import 'package:stackwallet/utilities/constants.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/widgets/beam/tx/beam_no_transactions.dart';
import 'package:stackwallet/widgets/beam/stickers/beam_sticker.dart';
import 'package:stackwallet/widgets/beam/tx/beam_transaction_card.dart';
import 'package:stackwallet/widgets/rounded_white_container.dart';

import 'tx_ui_harness.dart';

/// One of each state, newest first, as the wallet's history shows them.
List<Map<String, Object?>> _history() {
  var t = 1722600000;
  int next() => t -= 3600;
  return [
    simpleTxJson(seed: 1, status: BeamTxStatus.inProgress, createTime: next()),
    simpleTxJson(
      seed: 2,
      status: BeamTxStatus.inProgress,
      income: true,
      createTime: next(),
    ),
    simpleTxJson(seed: 3, status: BeamTxStatus.registering, createTime: next()),
    simpleTxJson(seed: 4, status: BeamTxStatus.confirming, createTime: next()),
    contractTxJson(seed: 5, createTime: next()),
    simpleTxJson(
      seed: 6,
      status: BeamTxStatus.completed,
      income: true,
      value: 250000000,
      createTime: next(),
    ),
    simpleTxJson(
      seed: 7,
      status: BeamTxStatus.completed,
      comment: 'Lunch',
      createTime: next(),
    ),
    simpleTxJson(
      seed: 8,
      status: BeamTxStatus.failed,
      failure: 'Transaction timed out',
      createTime: next(),
    ),
    simpleTxJson(
      seed: 9,
      status: BeamTxStatus.failed,
      failure: 'Inputs missing',
      createTime: next(),
    ),
    simpleTxJson(seed: 10, status: BeamTxStatus.canceled, createTime: next()),
    contractTxJson(seed: 11, dex: false, feeOnly: true, createTime: next()),
  ];
}

Widget _cards(List<TransactionV2> txs) => Builder(
  builder: (context) => Scaffold(
    backgroundColor: kColors.background,
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: RoundedWhiteContainer(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            for (final tx in txs)
              Container(
                decoration: BoxDecoration(
                  color: kColors.popupBG,
                  borderRadius: BorderRadius.circular(
                    Constants.size.circularBorderRadius,
                  ),
                ),
                child: TransactionCardV2(transaction: tx),
              ),
          ],
        ),
      ),
    ),
  ),
);

/// The empty history as the tests place it: top of a padded screen, 640 px
/// wide on desktop.
Widget _emptyFrame(bool desktop, VoidCallback onReceive) => Scaffold(
  backgroundColor: kColors.background,
  body: Padding(
    padding: const EdgeInsets.all(12),
    child: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: desktop ? 640 : null,
        child: BeamNoTransactions(walletId: kWalletId, onReceive: onReceive),
      ),
    ),
  ),
);

BeamSticker _sticker(WidgetTester tester) => tester
    .widget<BeamStickerImage>(find.byKey(const Key('beamNoTxSticker')))
    .sticker;

void main() {
  late List<Map<String, Object?>> json;
  late List<TransactionV2> txs;
  late FakeTxBackend fake;

  setUp(() {
    json = _history();
    txs = json.map(mapped).toList();
    fake = FakeTxBackend()..serveTxStatus(json);
  });

  testWidgets('phone: every state in Campfire\'s list card', (tester) async {
    setSurface(tester, desktop: false, h: 1000);
    await loadFonts(tester);
    await tester.pumpWidget(app(home: _cards(txs), fake: fake, desktop: false));
    await settle(tester);

    // Campfire's card handed every BEAM transaction to the BEAM card.
    expect(find.byType(BeamTransactionCard), findsNWidgets(txs.length));
    expect(
      find.text("Waiting for the receiver's wallet to come online"),
      findsWidgets,
    );
    expect(find.text('Waiting for the sender to finish'), findsOneWidget);
    expect(find.text('Sending to the network'), findsOneWidget);
    expect(find.text('Waiting for confirmation'), findsOneWidget);
    expect(
      find.text(
        'Expired: the other wallet did not respond in time. '
        'Nothing was sent.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Failed: the coins were already spent elsewhere. Nothing was sent.',
      ),
      findsOneWidget,
    );
    // The swap's other side came from the core (tx_status), not the cache.
    expect(find.text('DEX swap'), findsOneWidget);
    expect(find.text('+4,864.10722456 CHAD'), findsOneWidget);
    expect(find.text('−0.06984329 BEAM'), findsOneWidget);
    expect(find.text('Contract call'), findsOneWidget);
    expect(find.text('Network fee'), findsOneWidget);
    // A cancelled entry says what that meant, not "Cancelled" twice.
    expect(find.text('Nothing was sent.'), findsOneWidget);
    // Phone amounts carry no sign for plain payments, as in Campfire.
    expect(find.text('2.50000000 BEAM'), findsOneWidget);
    expect(fake.transport.callsTo('tx_status'), hasLength(2));

    await expectLater(
      find.byKey(kShot),
      matchesGoldenFile('goldens/tx_list_phone.png'),
    );
  });

  testWidgets('desktop: the same list with signed amounts', (tester) async {
    setSurface(tester, desktop: true, h: 1000);
    await loadFonts(tester);
    await tester.pumpWidget(
      app(
        home: Center(child: SizedBox(width: 640, child: _cards(txs))),
        fake: fake,
        desktop: true,
      ),
    );
    await settle(tester);
    expect(find.text('+2.50000000 BEAM'), findsOneWidget);
    expect(find.text('−0.10000000 BEAM'), findsWidgets);
    // Failed and cancelled payments moved nothing: no minus sign.
    expect(find.text('0.10000000 BEAM'), findsNWidgets(3));
    await expectLater(
      find.byKey(kShot),
      matchesGoldenFile('goldens/tx_list_desktop.png'),
    );
  });

  testWidgets('desktop "all transactions" rows', (tester) async {
    setSurface(tester, desktop: true, h: 1000);
    await loadFonts(tester);
    await tester.pumpWidget(
      app(
        home: Scaffold(
          backgroundColor: kColors.background,
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: RoundedWhiteContainer(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final tx in txs)
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: DesktopTransactionCardRow(
                        transaction: tx,
                        walletId: kWalletId,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        fake: fake,
        desktop: true,
      ),
    );
    await settle(tester);
    expect(find.byType(BeamTransactionRow), findsNWidgets(txs.length));
    expect(find.text('DEX swap'), findsOneWidget);
    await expectLater(
      find.byKey(kShot),
      matchesGoldenFile('goldens/tx_rows_desktop.png'),
    );
  });

  for (final desktop in [false, true]) {
    final name = desktop ? 'desktop' : 'phone';
    testWidgets('$name: empty history offers one tap to Receive', (
      tester,
    ) async {
      setSurface(tester, desktop: desktop, h: desktop ? 520 : 600);
      await loadFonts(tester);
      var receives = 0;
      await tester.pumpWidget(
        app(
          home: Scaffold(
            backgroundColor: kColors.background,
            body: Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: desktop ? 640 : null,
                  child: BeamNoTransactions(
                    walletId: kWalletId,
                    onReceive: () => receives++,
                  ),
                ),
              ),
            ),
          ),
          fake: FakeTxBackend(),
          desktop: desktop,
        ),
      );
      await settle(tester);
      expect(find.text('No transactions yet'), findsOneWidget);
      expect(_sticker(tester), BeamMoments.emptyHistory);
      // The button is on screen without scrolling.
      final button = tester.getRect(find.text('Receive BEAM'));
      expect(button.bottom, lessThan(desktop ? 520 : 600));
      await expectLater(
        find.byKey(kShot),
        matchesGoldenFile('goldens/empty_history_$name.png'),
      );
      await tester.tap(find.text('Receive BEAM'));
      await tester.pump();
      expect(receives, 1);
    });

    testWidgets('$name: during a restore scan, the coins are on their way', (
      tester,
    ) async {
      setSurface(tester, desktop: desktop, h: desktop ? 520 : 600);
      await loadFonts(tester);
      var receives = 0;
      await tester.pumpWidget(
        app(
          home: _emptyFrame(desktop, () => receives++),
          fake: FakeTxBackend(),
          desktop: desktop,
          coinScan: (percent: 43),
        ),
      );
      await settle(tester);
      // Not "nothing yet": the coins are still being found, and the list
      // will not fill with the past (a restore finds coins, not history).
      expect(find.text('No transactions yet'), findsNothing);
      expect(find.text('Still looking for your coins'), findsOneWidget);
      expect(
        find.text(
          'They show in your balance as they are found (43%). Payments from '
          "before the restore aren't listed: BEAM keeps no history on the "
          'chain.',
        ),
        findsOneWidget,
      );
      // Its own sticker, not the "send me beams" of an empty wallet.
      expect(_sticker(tester), BeamMoments.coinsOnTheirWay);
      final button = tester.getRect(find.text('Receive BEAM'));
      expect(button.bottom, lessThan(desktop ? 520 : 600));
      await expectLater(
        find.byKey(kShot),
        matchesGoldenFile('goldens/empty_history_scanning_$name.png'),
      );
      await tester.tap(find.text('Receive BEAM'));
      await tester.pump();
      expect(receives, 1);
    });

    testWidgets('$name: restored with a balance, the list says why it is '
        'empty', (tester) async {
      setSurface(tester, desktop: desktop, h: desktop ? 520 : 600);
      await loadFonts(tester);
      var receives = 0;
      await tester.pumpWidget(
        app(
          home: _emptyFrame(desktop, () => receives++),
          fake: FakeTxBackend(),
          desktop: desktop,
          restoredWithFunds: true,
        ),
      );
      await settle(tester);
      expect(find.text('No transactions yet'), findsNothing);
      expect(find.text('No payments since the restore'), findsOneWidget);
      expect(
        find.text(
          "Payments from before the restore aren't listed: BEAM keeps no "
          'history on the chain. Your balance is complete, and new payments '
          'appear here.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Payments you send'), findsNothing);
      final button = tester.getRect(find.text('Receive BEAM'));
      expect(button.bottom, lessThan(desktop ? 520 : 600));
      await expectLater(
        find.byKey(kShot),
        matchesGoldenFile('goldens/empty_history_restored_$name.png'),
      );
      await tester.tap(find.text('Receive BEAM'));
      await tester.pump();
      expect(receives, 1);
    });
  }

  test('a running scan outranks "restored with a balance"', () {
    expect(
      BeamNoTransactions.title((percent: 10), restoredWithFunds: true),
      'Still looking for your coins',
    );
    expect(
      BeamNoTransactions.title(null, restoredWithFunds: true),
      'No payments since the restore',
    );
    expect(BeamNoTransactions.title(null), 'No transactions yet');
  });

  testWidgets('a scan without a reported percent says no number', (
    tester,
  ) async {
    setSurface(tester, desktop: false);
    await loadFonts(tester);
    await tester.pumpWidget(
      app(
        home: const Scaffold(body: BeamNoTransactions(walletId: kWalletId)),
        fake: FakeTxBackend(),
        desktop: false,
        coinScan: (percent: null),
      ),
    );
    await settle(tester);
    expect(
      find.text(
        "They show in your balance as they are found. Payments from before "
        "the restore aren't listed: BEAM keeps no history on the chain.",
      ),
      findsOneWidget,
    );
  });

  // WalletView on a 375 × 667 phone leaves the empty history about 110 px
  // under the balance card and the asset list (it overflowed by 27 px).
  for (final room in [110.0, 300.0]) {
    testWidgets('phone: a ${room.round()} px slot never overflows; the '
        'sticker gives way and the rest scrolls', (tester) async {
      setSurface(tester, desktop: false, h: 667);
      await loadFonts(tester);
      var receives = 0;
      await tester.pumpWidget(
        app(
          home: Scaffold(
            backgroundColor: kColors.background,
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: room,
                child: BeamNoTransactions(
                  walletId: kWalletId,
                  onReceive: () => receives++,
                ),
              ),
            ),
          ),
          fake: FakeTxBackend(),
          desktop: false,
        ),
      );
      await settle(tester);
      // An overflow would have failed the test already; the words stay.
      expect(find.byKey(const Key('beamNoTxSticker')), findsNothing);
      expect(find.text('No transactions yet'), findsOneWidget);
      await tester.ensureVisible(find.text('Receive BEAM'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Receive BEAM'));
      await tester.pump();
      expect(receives, 1);
    });
  }

  testWidgets('desktop: a short slot shrinks the sticker before the words', (
    tester,
  ) async {
    setSurface(tester, desktop: true, h: 520);
    await loadFonts(tester);
    await tester.pumpWidget(
      app(
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              key: Key('slot'),
              width: 640,
              height: 300,
              child: BeamNoTransactions(walletId: kWalletId),
            ),
          ),
        ),
        fake: FakeTxBackend(),
        desktop: true,
      ),
    );
    await settle(tester);
    final size = tester.getSize(find.byKey(const Key('beamNoTxSticker')));
    expect(size.height, inExclusiveRange(64, 160));
    // The words and the button still fit without scrolling.
    expect(
      tester.getRect(find.text('Receive BEAM')).bottom,
      lessThanOrEqualTo(tester.getRect(find.byKey(const Key('slot'))).bottom),
    );
  });

  testWidgets('phone: "Receive BEAM" opens Campfire\'s receive screen', (
    tester,
  ) async {
    setSurface(tester, desktop: false);
    await loadFonts(tester);
    final routes = <RouteSettings>[];
    await tester.pumpWidget(
      app(
        home: const Scaffold(body: BeamNoTransactions(walletId: kWalletId)),
        fake: FakeTxBackend(),
        desktop: false,
        onGenerateRoute: (settings) {
          routes.add(settings);
          return MaterialPageRoute<void>(
            builder: (_) => const SizedBox(),
            settings: settings,
          );
        },
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Receive BEAM'));
    await tester.pumpAndSettle();
    expect(routes.single.name, ReceiveView.routeName);
    expect(routes.single.arguments, kWalletId);
  });
}

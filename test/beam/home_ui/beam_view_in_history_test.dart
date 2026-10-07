/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Seen in the DMG test: after a send, "View in history" closed the sheet and
// left the desktop wallet on its Send tab. It must bring the wallet's tabs
// to Transactions.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/widgets/beam/wiring/beam_desktop_wallet_tabs.dart';

import 'home_ui_support.dart';

const _walletId = 'history-test';

// Not const: the tabs assert that titles and children match.
Widget _tabs() => Scaffold(
  body: BeamDesktopWalletTabs(
    walletId: _walletId,
    titles: const ['Send', 'Receive', 'Transactions'],
    children: const [
      Text('send body'),
      Text('receive body'),
      Text('history body'),
    ],
  ),
);

void main() {
  testWidgets('a history request brings the tabs to Transactions, again '
      'after the user left it', (tester) async {
    await pumpHome(
      tester,
      frame: _tabs(),
      overrides: homeOverrides(
        source: FakeHomeSource(),
        balance: beamBalance(spendable: 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('send body'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(BeamDesktopWalletTabs)),
    );
    void request() =>
        container.read(pBeamShowHistoryRequest(_walletId).state).state++;

    request();
    await tester.pumpAndSettle();
    expect(find.text('history body'), findsOneWidget);
    expect(find.text('send body'), findsNothing);

    await tester.tap(find.text('Send').first);
    await tester.pumpAndSettle();
    expect(find.text('send body'), findsOneWidget);

    request();
    await tester.pumpAndSettle();
    expect(find.text('history body'), findsOneWidget);
  });

  testWidgets('another wallet\'s request changes nothing', (tester) async {
    await pumpHome(
      tester,
      frame: _tabs(),
      overrides: homeOverrides(
        source: FakeHomeSource(),
        balance: beamBalance(spendable: 1),
      ),
    );
    await tester.pumpAndSettle();
    ProviderScope.containerOf(
      tester.element(find.byType(BeamDesktopWalletTabs)),
    ).read(pBeamShowHistoryRequest('other').state).state++;
    await tester.pumpAndSettle();
    expect(find.text('send body'), findsOneWidget);
  });
}

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
Widget _bareTabs() => BeamDesktopWalletTabs(
  walletId: _walletId,
  titles: const ['Send', 'Receive', 'Transactions'],
  children: const [
    Text('send body'),
    Text('receive body'),
    Text('history body'),
  ],
);

Widget _tabs() => Scaffold(body: _bareTabs());

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

  testWidgets('a request from further down the page brings the tabs back '
      'into view', (tester) async {
    await pumpHome(
      tester,
      frame: Scaffold(
        body: ListView(
          children: [
            const SizedBox(height: 900),
            _bareTabs(),
            const SizedBox(height: 900),
          ],
        ),
      ),
      overrides: homeOverrides(
        source: FakeHomeSource(),
        balance: beamBalance(spendable: 1),
      ),
    );
    await tester.pumpAndSettle();
    // Scrolled so the tab labels sit above the top edge (as after scrolling
    // down to the Send button), the content still on screen.
    await tester.drag(find.byType(ListView), const Offset(0, -950));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byType(BeamDesktopWalletTabs)).dy,
      lessThan(0),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold)),
    );
    container.read(pBeamShowHistoryRequest(_walletId).state).state++;
    await tester.pumpAndSettle();
    final top = tester.getTopLeft(find.byType(BeamDesktopWalletTabs)).dy;
    expect(top, greaterThanOrEqualTo(0), reason: 'tab labels in view');
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

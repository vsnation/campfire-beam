/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The warning shown before a support channel opens: calm words, one
// button that says what it opens, and a way back.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/settings_views/global_settings_view/support_view.dart';

import '../airdrop_ui/beam_ui_harness.dart';

Future<void> _open(
  WidgetTester tester, {
  required bool desktop,
  required VoidCallback onOpen,
}) async {
  await pumpBeamPage(
    tester,
    Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => ScamWarningDialog(
                channel: 'Telegram',
                onUnderstandPressed: onOpen,
              ),
            ),
            child: const Text('Telegram'),
          ),
        ),
      ),
    ),
    desktop: desktop,
  );
  await tester.tap(find.text('Telegram'));
  await tester.pumpAndSettle();
}

void main() {
  for (final desktop in [false, true]) {
    final name = desktop ? 'desktop' : 'phone';

    testWidgets('$name: plain words and an "Open Telegram" button', (
      tester,
    ) async {
      await _open(tester, desktop: desktop, onOpen: () {});
      expect(find.text('Real support is always public'), findsOneWidget);
      expect(find.text('Open Telegram'), findsOneWidget);
      expect(find.textContaining('UNDERSTAND'), findsNothing);
      await expectScreen(tester, '${name}_scam_warning');
    });
  }

  testWidgets('"Open Telegram" opens it and closes the warning', (
    tester,
  ) async {
    var opened = 0;
    await _open(tester, desktop: false, onOpen: () => opened++);
    await tester.tap(find.text('Open Telegram'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.text('Real support is always public'), findsNothing);
  });

  testWidgets('Cancel closes it and opens nothing', (tester) async {
    var opened = 0;
    await _open(tester, desktop: false, onOpen: () => opened++);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(find.text('Real support is always public'), findsNothing);
  });
}

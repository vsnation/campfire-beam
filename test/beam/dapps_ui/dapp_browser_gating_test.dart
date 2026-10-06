/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Security review part 2, M-8 (tap-jacking): what decides when the
// approval sheet opens, and how the PIN screen may be passed.
//
// * The sheet never opens the moment a request arrives: a banner comes
//   first and either waits for "Review" or, when the user just tapped the
//   page, opens the review after a visible delay.
// * Only taps count as "the user just used the page", not scrolls or drags.
// * Biometrics never start by themselves on the dApp approval path.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/widgets/beam/dapps/dapp_approval_banner.dart';
import 'package:stackwallet/widgets/beam/dapps/dapp_manual_biometrics.dart';
import 'package:stackwallet/widgets/beam/dapps/dapp_tap_tracker.dart';

import 'dapp_ui_harness.dart';

void main() {
  group('banner', () {
    Future<List<bool>> pumpBanner(
      WidgetTester tester, {
      Duration? autoOpenAfter,
    }) async {
      await loadCampfireFonts(tester);
      final answers = <bool>[];
      await tester.pumpWidget(
        campfireApp(
          home: Scaffold(
            body: Column(
              children: [
                DappApprovalBanner(
                  dappName: 'Yield Farm',
                  isDesktop: false,
                  autoOpenAfter: autoOpenAfter,
                  onAnswer: answers.add,
                ),
              ],
            ),
          ),
        ),
      );
      return answers;
    }

    testWidgets('a request the user did not just ask for waits for Review', (
      tester,
    ) async {
      setSurface(tester, const Size(375, 812));
      final answers = await pumpBanner(tester);
      expect(find.text('Yield Farm asks for your approval'), findsOneWidget);
      expect(find.text('Opening the review…'), findsNothing);
      await tester.pump(const Duration(minutes: 1));
      expect(answers, isEmpty, reason: 'never opens by itself');
      await tester.tap(find.byKey(DappApprovalBanner.reviewKey));
      await tester.tap(find.byKey(DappApprovalBanner.reviewKey));
      expect(answers, [true], reason: 'answered once');
    });

    testWidgets('right after a tap on the page: opens after a visible '
        'delay, not at once', (tester) async {
      setSurface(tester, const Size(375, 812));
      final answers = await pumpBanner(
        tester,
        autoOpenAfter: DappApprovalBanner.openDelay,
      );
      expect(find.text('Opening the review…'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.pump();
      await tester.pump(
        DappApprovalBanner.openDelay - const Duration(milliseconds: 100),
      );
      expect(answers, isEmpty);
      await tester.pump(const Duration(milliseconds: 150));
      expect(answers, [true]);
    });

    testWidgets('Reject during the delay rejects, and nothing opens after', (
      tester,
    ) async {
      setSurface(tester, const Size(375, 812));
      final answers = await pumpBanner(
        tester,
        autoOpenAfter: DappApprovalBanner.openDelay,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(DappApprovalBanner.rejectKey));
      await tester.pump(const Duration(seconds: 2));
      expect(answers, [false]);
    });
  });

  group('tap tracker', () {
    final t0 = DateTime(2026, 10, 6, 12);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

    test('a tap counts', () {
      final t = DappTapTracker()
        ..down(1, const Offset(100, 100), at(0))
        ..up(1, const Offset(102, 101), at(120));
      expect(t.lastTap, at(120));
      expect(t.tappedWithin(const Duration(seconds: 10), at(5000)), isTrue);
      expect(t.tappedWithin(const Duration(seconds: 10), at(10200)), isFalse);
    });

    test('a scroll or drag does not', () {
      final t = DappTapTracker()
        ..down(1, const Offset(100, 400), at(0))
        ..up(1, const Offset(100, 120), at(200));
      expect(t.lastTap, isNull);
      expect(t.tappedWithin(const Duration(seconds: 10), at(300)), isFalse);
    });

    test('a long press or a cancelled pointer does not', () {
      final t = DappTapTracker()
        ..down(1, const Offset(10, 10), at(0))
        ..up(1, const Offset(10, 10), at(900))
        ..down(2, const Offset(10, 10), at(1000))
        ..cancel(2)
        ..up(2, const Offset(10, 10), at(1050));
      expect(t.lastTap, isNull);
    });
  });

  group('biometrics on the dApp approval PIN screen', () {
    test('the automatic first prompt is declined without prompting; the '
        'user\'s "Use biometrics" tap prompts', () async {
      var shown = 0;
      final b = DappManualBiometrics(
        prompt:
            ({
              required String cancelButtonText,
              required String localizedReason,
              required String title,
            }) async {
              shown++;
              return true;
            },
      );
      Future<bool> call() => b.authenticate(
        cancelButtonText: 'CANCEL',
        localizedReason: 'Authenticate to approve this dApp request',
        title: 'Approve dApp request',
      );
      // LockscreenView.initState -> _checkUseBiometrics -> authenticate.
      expect(await call(), isFalse);
      expect(shown, 0);
      expect(b.prompts, 0);
      // The "Use biometrics" button -> _checkUseBiometrics again.
      expect(await call(), isTrue);
      expect(shown, 1);
      expect(b.prompts, 1);
    });
  });
}

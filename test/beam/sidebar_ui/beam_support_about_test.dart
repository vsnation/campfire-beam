/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Support, About and the first screen's last line, on desktop and on a
// phone: BEAM's own channels (as beam.mw lists them) and this app's source
// code, where Stack Wallet's channels, terms and privacy policy used to be.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:stackwallet/pages/intro_view.dart';
import 'package:stackwallet/pages/settings_views/global_settings_view/about_view.dart';
import 'package:stackwallet/pages/settings_views/global_settings_view/support_view.dart';
import 'package:stackwallet/pages_desktop_specific/settings/settings_menu/desktop_about_view.dart';
import 'package:stackwallet/pages_desktop_specific/settings/settings_menu/desktop_support_view.dart';
import 'package:stackwallet/utilities/git_status.dart';

import 'sidebar_harness.dart';

/// Every channel, by the words on its button.
const _channels = [
  '@BeamSupport',
  'support@beam.mw',
  'GitHub Issues',
  '@BeamPrivacy',
  'r/beamprivacy',
  '@beamprivacy',
  'forum.beam.mw',
];

/// On a phone each row shows only its name (Campfire's own layout).
const _phoneNames = [
  'Support chat',
  'Email',
  'A bug in this app',
  'Telegram',
  'Discord',
  'Reddit',
  'X',
  'Forum',
];

void _all(List<String> texts) {
  for (final t in texts) {
    expect(find.text(t), findsOneWidget, reason: t);
  }
}

/// Nothing of Stack Wallet's own channels or documents is left.
void _noStackWallet() {
  for (final t in [
    'stackwallet',
    'stack_wallet',
    'Terms of service',
    'Privacy policy',
  ]) {
    expect(find.textContaining(t, findRichText: true), findsNothing, reason: t);
  }
}

/// Scrolls the scroll view inside [page] until [target] is in view.
Future<void> _scrollTo(WidgetTester tester, Type page, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: find
        .descendant(of: find.byType(page), matching: find.byType(Scrollable))
        .first,
  );
  await settle(tester);
}

Future<void> _golden(String name) =>
    expectLater(find.byKey(goldenKey), matchesGoldenFile('goldens/$name.png'));

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);
  // About shows the build's commit; a fixed one keeps its goldens stable.
  setUpAll(() => GitStatus.debugCommitHashOverride = '0' * 40);
  tearDownAll(() => GitStatus.debugCommitHashOverride = null);
  setUp(
    () => PackageInfo.setMockInitialValues(
      appName: 'Campfire',
      packageName: 'com.vsnation.campfirebeam',
      version: '1.1.0',
      buildNumber: '11',
      buildSignature: '',
    ),
  );

  group('desktop', () {
    testWidgets('Support: BEAM\'s channels, and GitHub for bugs in this '
        'app; the end of the list scrolls into view', (tester) async {
      final wallet = await openBeamWallet(tester, db, core: SidebarCore());
      await pumpSidebar(tester, wallets: [wallet]);
      await tapMenu(tester, const ValueKey('support'));

      expect(find.byType(DesktopSupportView), findsOneWidget);
      _all(_channels);
      _noStackWallet();
      await _golden('support');

      final last = find.text('forum.beam.mw');
      await _scrollTo(tester, DesktopSupportView, last);
      expect(
        tester.getRect(last).bottom,
        lessThanOrEqualTo(desktopWindow.height),
      );
      await _golden('support_end');
      await finishSidebar(tester);
    });

    testWidgets('a channel first warns about scammers, naming BEAM and the '
        'channel', (tester) async {
      final wallet = await openBeamWallet(tester, db, core: SidebarCore());
      await pumpSidebar(tester, wallets: [wallet]);
      await tapMenu(tester, const ValueKey('support'));

      await tester.tap(find.text('A bug in this app'));
      await settle(tester);
      expect(
        find.textContaining(
          'All official support for BEAM in GitHub Issues is provided ONLY',
          findRichText: true,
        ),
        findsOneWidget,
      );
      await _golden('support_warning');
      await finishSidebar(tester);
    });

    testWidgets('About: free and open source, with the source code and '
        'beam.mw', (tester) async {
      final wallet = await openBeamWallet(tester, db, core: SidebarCore());
      await pumpSidebar(tester, wallets: [wallet]);
      await tapMenu(tester, const ValueKey('about'));

      expect(find.byType(DesktopAboutView), findsOneWidget);
      expect(
        find.textContaining('is free and open source', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Source code', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('https://beam.mw', findRichText: true),
        findsOneWidget,
      );
      _noStackWallet();
      await _golden('about');
      await finishSidebar(tester);
    });
  });

  group('phone 375 x 667', () {
    testWidgets('Support: every channel, scrolling to the last', (
      tester,
    ) async {
      await pumpWiring(tester, const SupportView(), desktop: false);

      _all(_phoneNames);
      _noStackWallet();
      await _golden('support_phone');

      final last = find.text('Forum');
      await _scrollTo(tester, SupportView, last);
      expect(tester.getRect(last).bottom, lessThanOrEqualTo(phone.height));
      await _golden('support_phone_end');
      await finish(tester);
    });

    testWidgets('About', (tester) async {
      await pumpWiring(tester, const AboutView(), desktop: false);

      expect(
        find.textContaining('is free and open source', findRichText: true),
        findsOneWidget,
      );
      _noStackWallet();
      await _golden('about_phone');
      await finish(tester);
    });

    testWidgets('first screen: its last line, phone and desktop sizes', (
      tester,
    ) async {
      await pumpWiring(
        tester,
        const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PrivacyAndTOSText(isDesktop: false),
                SizedBox(height: 32),
                PrivacyAndTOSText(isDesktop: true),
              ],
            ),
          ),
        ),
        desktop: false,
        size: const Size(375, 200),
      );
      expect(
        find.textContaining('is free and open source', findRichText: true),
        findsNWidgets(2),
      );
      _noStackWallet();
      await _golden('intro_last_line');
      await finish(tester);
    });
  });
}

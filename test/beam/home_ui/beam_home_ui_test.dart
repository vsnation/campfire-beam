/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The BEAM wallet home in Campfire's light theme, on a 375 px phone and on
// desktop: balance and assets, name payments and the claim flow, and every
// honest-sync state. Each state is a golden; the PNGs are copied to
// docs/beam/screenshots/B-UI-HOME/.
//
//   scripts/beam/host_test.sh --no-analyze --update-goldens --copy-goldens \
//       test/beam/home_ui
//   scripts/beam/host_test.sh --no-analyze test/beam/home_ui

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/settings_views/wallet_settings_view/wallet_network_settings_view/wallet_network_settings_view.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_sync_tracker.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_errors.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';

import 'home_ui_support.dart';

const _golden = ValueKey<String>('beam-home-golden');

Future<void> _mobile(
  WidgetTester tester,
  FakeHomeSource source, {
  num spendable = 12.5,
  num pending = 0,
  Map<int, num> assets = const {},
  FakeAuth? auth,
  String? usdPerBeam = '0.0089',
}) async {
  useWindow(tester, mobileSize);
  await loadFonts(tester);
  await pumpHome(
    tester,
    frame: const MobileHomeFrame(),
    overrides: homeOverrides(
      source: source,
      balance: beamBalance(spendable: spendable, pending: pending),
      totals: {
        for (final e in assets.entries) e.key: assetTotals(e.key, e.value),
      },
      format: beamFormat(usdPerBeam: usdPerBeam),
      auth: auth,
    ),
  );
  await settleImages(tester);
  await precacheAllImages(tester);
  await _finishAnimations(tester);
}

/// Lets size animations (lines and banners sliding in) finish, so taps and
/// goldens see the final layout.
Future<void> _finishAnimations(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _desktop(
  WidgetTester tester,
  FakeHomeSource source, {
  num spendable = 12.5,
  num pending = 0.5,
  Map<int, num> assets = const {},
  FakeAuth? auth,
}) async {
  useWindow(tester, desktopSize, dpr: 1.5);
  await loadFonts(tester);
  await pumpHome(
    tester,
    frame: const DesktopHomeFrame(),
    overrides: homeOverrides(
      source: source,
      balance: beamBalance(spendable: spendable, pending: pending),
      totals: {
        for (final e in assets.entries) e.key: assetTotals(e.key, e.value),
      },
      auth: auth,
    ),
  );
  await settleImages(tester);
  await precacheAllImages(tester);
  await _finishAnimations(tester);
}

/// Unmounts the home (disposes its controller and timers).
Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

Finder _text(String s) => find.textContaining(s, findRichText: true);

/// The headline where the balance goes.
String? _spendable(WidgetTester tester) => tester
    .widget<SelectableText>(find.byKey(const Key('beamHomeSpendable')))
    .data;

/// The Send button sits inside the 375x812 phone screen: no scrolling.
void _sendVisible(WidgetTester tester, {required bool enabled}) {
  final f = find.byKey(Key(enabled ? 'beamSendEnabled' : 'beamSendDisabled'));
  expect(f, findsOneWidget);
  final r = tester.getRect(f);
  expect(r.bottom, lessThanOrEqualTo(mobileSize.height));
  expect(r.top, greaterThan(0));
}

void main() {
  group('mobile 375 px', () {
    testWidgets('synced with assets, fiat and the private node syncing', (
      tester,
    ) async {
      final source = FakeHomeSource(
        pools: [beamPool(174, 10000, 1000000)],
        privateNodeStatus: const BeamPrivateNodeStatus(
          phase: BeamPrivateNodePhase.downloading,
          percent: 43,
        ),
      );
      await _mobile(tester, source, pending: 0.5, assets: {174: 1000, 205: 50});

      expect(find.byKey(const Key('beamHomeSpendable')), findsOneWidget);
      expect(_text('12.5'), findsWidgets);
      // On the card, and on the dashboard's BEAM row.
      expect(_text('0.11 USD'), findsNWidgets(2));
      expect(_text('arriving'), findsOneWidget);
      expect(_text('With assets ≈ 23 BEAM'), findsOneWidget);
      expect(_text('1 asset has no price'), findsOneWidget);
      expect(_text('Private node syncing 43%'), findsOneWidget);
      expect(find.byKey(const Key('beamHomeSyncBanner')), findsNothing);
      expect(find.byKey(const Key('beamHomeNamePayments')), findsNothing);
      expect(source.pricerCalls, 1);
      _sendVisible(tester, enabled: true);

      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/mobile_synced_assets.png'),
      );
      await _done(tester);
    });

    testWidgets('catching up: banner after the grace period, progress, '
        'Send dimmed and says why', (tester) async {
      final source = FakeHomeSource(assessment: catchingUp(100));
      sendOpened = 0;
      await _mobile(tester, source);
      source.assessment = catchingUp(42, eta: const Duration(minutes: 3));
      await tester.pump();
      // The first seconds of catching up stay invisible (R11).
      expect(find.byKey(const Key('beamHomeSyncBanner')), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await settleImages(tester);
      await precacheAllImages(tester);
      await _finishAnimations(tester);

      expect(
        _text('Catching up: 42 blocks behind (about 42 minutes)'),
        findsOneWidget,
      );
      expect(_text("Sending is paused until it's done."), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('beamHomeSyncProgress')),
      );
      expect(bar.value, closeTo(0.58, 0.001));
      _sendVisible(tester, enabled: false);

      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/mobile_catching_up.png'),
      );

      await tester.tap(find.byKey(const Key('beamSendDisabled')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        _text('Sending is paused while the wallet catches up (42 blocks'),
        findsOneWidget,
      );
      expect(sendOpened, 0);
      await tester.pump(const Duration(seconds: 4));
      await _done(tester);
    });

    testWidgets('stalled at the HF6 boundary: at once, with the fix', (
      tester,
    ) async {
      pushedRoutes.clear();
      final source = FakeHomeSource(assessment: stalledAtHf6());
      await _mobile(tester, source);

      expect(_text('stuck on an old version'), findsOneWidget);
      expect(_text('3,928,666'), findsOneWidget);
      expect(_text('Try another node'), findsOneWidget);
      _sendVisible(tester, enabled: false);
      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/mobile_stalled_hf6.png'),
      );

      await tester.tap(find.byKey(const Key('beamHomeSyncAction')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(pushedRoutes, [WalletNetworkSettingsView.routeName]);
      await _done(tester);
    });

    testWidgets('restore scan, nothing found yet: never a bare zero', (
      tester,
    ) async {
      final source = FakeHomeSource(
        isScanningForCoins: true,
        scanProgress: const BeamScanProgress(430, 1000),
      );
      await _mobile(tester, source, spendable: 0);

      // The headline says it is scanning; no 0 BEAM, no 0.00 USD under it.
      expect(_spendable(tester), 'Scanning… 43%');
      expect(_text('0.00000000'), findsNothing);
      expect(_text('USD'), findsNothing);
      expect(find.byKey(const Key('beamHomeFoundSoFar')), findsNothing);
      // The percent and its explanation are said once, in the banner.
      expect(_text('Scanning for your coins… 43%'), findsOneWidget);
      expect(_text('may look low until this finishes'), findsOneWidget);
      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/mobile_restore_scanning.png'),
      );

      // The scan moves on: the headline follows.
      source.scanProgress = const BeamScanProgress(610, 1000);
      source.fireEvent();
      await _finishAnimations(tester);
      expect(_spendable(tester), 'Scanning… 61%');
      expect(_text('Scanning for your coins… 61%'), findsOneWidget);
      await _done(tester);
    });

    testWidgets('restore scan, coins found: the amount, "Found so far"', (
      tester,
    ) async {
      final source = FakeHomeSource(
        isScanningForCoins: true,
        scanProgress: const BeamScanProgress(610, 1000),
      );
      await _mobile(tester, source, spendable: 2.5);

      expect(_spendable(tester), '2.50000000 BEAM');
      expect(
        tester.widget<Text>(find.byKey(const Key('beamHomeFoundSoFar'))).data,
        'Found so far',
      );
      expect(_text('Scanning for your coins… 61%'), findsOneWidget);
      expect(_text('Scanning…'), findsNothing);
      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/mobile_restore_found_so_far.png'),
      );
      await _done(tester);
    });

    testWidgets('restore scan over without a private node (the pending '
        'flag stays set): the plain home, no banner, no "Found so far"', (
      tester,
    ) async {
      // What the app showed after a real restore: up to date, the core
      // reporting nothing left to scan, 2.79 BEAM found. (BEAM only: the
      // asset list reads Campfire's global prefs, which only this file's
      // first test may do; the wiring test covers a restore with assets.)
      final source = FakeHomeSource(isScanningForCoins: true);
      await _mobile(tester, source, spendable: 2.79);
      expect(_spendable(tester), '2.79000000 BEAM');
      expect(find.byKey(const Key('beamHomeFoundSoFar')), findsNothing);
      expect(find.byKey(const Key('beamHomeSyncBanner')), findsNothing);
      expect(_text('Scanning'), findsNothing);
      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/mobile_restore_scan_done.png'),
      );
      await _done(tester);
    });

    testWidgets('restore scan: the banner and "Found so far" go when it ends', (
      tester,
    ) async {
      final source = FakeHomeSource(
        assessment: catchingUp(40),
        isScanningForCoins: true,
        scanProgress: const BeamScanProgress(990, 1000),
      );
      await _mobile(tester, source, spendable: 2.79);
      expect(_text('Scanning for your coins… 99%'), findsOneWidget);
      expect(find.byKey(const Key('beamHomeFoundSoFar')), findsOneWidget);

      // The core reports the last bodies and the wallet is up to date.
      source.scanProgress = const BeamScanProgress(1000, 1000);
      source.assessment = synced();
      await _finishAnimations(tester);
      expect(_spendable(tester), '2.79000000 BEAM');
      expect(_text('Scanning'), findsNothing);
      expect(find.byKey(const Key('beamHomeFoundSoFar')), findsNothing);
      expect(find.byKey(const Key('beamHomeSyncBanner')), findsNothing);
      await _done(tester);
    });

    testWidgets('scan finished: the plain balance, no qualifier', (
      tester,
    ) async {
      await _mobile(tester, FakeHomeSource(), spendable: 0);
      expect(_spendable(tester), '0.00000000 BEAM');
      expect(find.byKey(const Key('beamHomeFoundSoFar')), findsNothing);
      expect(_text('Scanning'), findsNothing);
      await _done(tester);
    });

    testWidgets('core not installed: the plain message, Send off', (
      tester,
    ) async {
      final source = FakeHomeSource(
        assessment: connecting,
        isOpen: false,
        coreProblem: const BeamWalletException(
          BeamWalletProblem.coreNotInstalled,
          BeamWalletMessages.coreNotInstalled,
        ),
      );
      await _mobile(tester, source, spendable: 0.05);

      expect(find.text('BEAM core not installed'), findsOneWidget);
      expect(_text('Nothing was lost'), findsOneWidget);
      expect(find.byKey(const Key('beamHomeSyncAction')), findsNothing);
      // The cached balance still shows.
      expect(_text('0.05'), findsWidgets);
      _sendVisible(tester, enabled: false);
      // No inbox read without a core.
      expect(source.inboxReads, 0);
      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/mobile_core_not_installed.png'),
      );
      await _done(tester);
    });

    testWidgets('name payments: one asset', (tester) async {
      final source = FakeHomeSource(
        inbox: inboxOf({
          'alice': {0: g(2.5)},
        }),
      );
      await _mobile(tester, source);
      expect(_text('Sent to your name alice.beam: 2.5 BEAM'), findsOneWidget);
      expect(find.text('Claim'), findsOneWidget);
      // Never added into the spendable balance.
      expect(_text('15.0'), findsNothing);
      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/mobile_names_one_asset.png'),
      );
      await _done(tester);
    });

    testWidgets('name payments: several assets and names', (tester) async {
      final source = FakeHomeSource(
        inbox: inboxOf({
          'alice': {0: g(2)},
          'bob': {0: g(0.5), 174: g(1000)},
        }),
      );
      await _mobile(tester, source);
      expect(
        _text('Sent to your names: 2.5 BEAM + 1,000 FOMO'),
        findsOneWidget,
      );
      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/mobile_names_several_assets.png'),
      );
      await _done(tester);
    });

    testWidgets('claim: sheet with the built fee → PIN → executed once → '
        'inbox re-read at once → done', (tester) async {
      final auth = FakeAuth();
      final source = FakeHomeSource(
        inbox: inboxOf({
          'alice': {0: g(2.5)},
        }),
      );
      await _mobile(tester, source, auth: auth);
      expect(source.inboxReads, 1);

      await tester.tap(find.byKey(const Key('beamHomeClaim')));
      await tester.pumpAndSettle();
      expect(source.holds, ['claim name payments']);
      expect(source.prepareCalls, 1);
      expect(_text('Claim what was sent to alice.beam'), findsOneWidget);
      expect(_text('Pays its own fee'), findsOneWidget);
      expect(find.text('Network fee'), findsOneWidget);
      expect(find.text('0.011 BEAM'), findsOneWidget);
      expect(find.text('Your balance changes by'), findsOneWidget);
      expect(find.text('+2.489 BEAM'), findsOneWidget);
      // One line each: the label never leaves "by" on a line of its own.
      expect(
        tester.getSize(find.text('Your balance changes by')).height,
        tester.getSize(find.text('+2.489 BEAM')).height,
      );
      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/mobile_claim_sheet.png'),
      );

      // The PIN is refused: nothing is sent.
      auth.answer = false;
      await tester.tap(find.byKey(const Key('beamClaimConfirm')));
      await tester.pumpAndSettle();
      expect(auth.prompts, 1);
      expect(source.executed, isEmpty);
      expect(_text('Not confirmed, so nothing was claimed.'), findsOneWidget);

      // Confirmed: sent exactly once, then the inbox is read again at once
      // (the 1-hour throttle proves the read was forced).
      auth.answer = true;
      source.inbox = null; // claimed: nothing waits any more
      await tester.tap(find.byKey(const Key('beamClaimConfirm')));
      await tester.pump();
      await tester.pump();
      expect(auth.prompts, 2);
      expect(source.executed, hasLength(1));
      expect(source.executed.single.summary.fee, BigInt.from(1100000));
      await settleImages(tester);
      expect(source.inboxReads, 2);
      expect(find.byKey(const Key('beamClaimDoneSticker')), findsOneWidget);
      expect(_text('Claim sent'), findsOneWidget);
      expect(
        _text('Your balance changes by +2.489 BEAM once'),
        findsOneWidget,
      );
      // Let the Beam girl finish her one-shot celebration.
      await tester.pump(const Duration(seconds: 5));
      await settleImages(tester);
      await precacheAllImages(tester);
      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/mobile_claim_done.png'),
      );

      // A second tap cannot send again: the sheet is in its done state.
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(source.executed, hasLength(1));
      expect(source.releases, 1);
      // The line is gone from the home.
      expect(find.byKey(const Key('beamHomeNamePayments')), findsNothing);
      await _done(tester);
    });

    testWidgets('claim of BEAM worth no more than the fee: warned first', (
      tester,
    ) async {
      final source = FakeHomeSource(
        inbox: inboxOf({
          'alice': {0: g(0.005)},
        }),
      );
      await _mobile(tester, source, auth: FakeAuth());
      await tester.tap(find.byKey(const Key('beamHomeClaim')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('beamClaimWarning')), findsOneWidget);
      expect(_text('gains you nothing'), findsOneWidget);
      // Warned, not forbidden.
      final confirm = tester.widget<PrimaryButton>(
        find.byKey(const Key('beamClaimConfirm')),
      );
      expect(confirm.enabled, isTrue);
      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/mobile_claim_sheet_fee_warning.png'),
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(source.executed, isEmpty);
      expect(source.releases, 1);
      await _done(tester);
    });

    testWidgets('claim while catching up: explained, button off, no build', (
      tester,
    ) async {
      final source = FakeHomeSource(
        assessment: catchingUp(42),
        inbox: inboxOf({
          'alice': {0: g(2.5)},
        }),
      );
      await _mobile(tester, source, auth: FakeAuth());
      await tester.tap(find.byKey(const Key('beamHomeClaim')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('beamClaimBlocker')), findsOneWidget);
      expect(source.prepareCalls, 0);
      final confirm = tester.widget<PrimaryButton>(
        find.byKey(const Key('beamClaimConfirm')),
      );
      expect(confirm.enabled, isFalse);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await _done(tester);
    });
  });

  group('desktop', () {
    testWidgets('synced, assets, private node, name payments', (tester) async {
      final source = FakeHomeSource(
        pools: [beamPool(174, 10000, 1000000)],
        privateNodeStatus: const BeamPrivateNodeStatus(
          phase: BeamPrivateNodePhase.active,
          onPrivateNode: true,
        ),
        inbox: inboxOf({
          'alice': {0: g(2.5), 174: g(1000)},
        }),
      );
      await _desktop(tester, source, assets: {174: 1000, 205: 50});
      expect(_text('Private node'), findsOneWidget);
      expect(
        _text('Sent to your name alice.beam: 2.5 BEAM + 1,000 FOMO'),
        findsOneWidget,
      );
      expect(_text('With assets ≈ 23 BEAM'), findsOneWidget);
      expect(find.byKey(const Key('beamHomeSyncBanner')), findsNothing);
      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/desktop_synced_names.png'),
      );
      await _done(tester);
    });

    testWidgets('restore scan, nothing found yet: "Scanning…", said once', (
      tester,
    ) async {
      final source = FakeHomeSource(
        isScanningForCoins: true,
        scanProgress: const BeamScanProgress(430, 1000),
      );
      await _desktop(tester, source, spendable: 0, pending: 0);
      expect(_spendable(tester), 'Scanning… 43%');
      expect(_text('0.00000000'), findsNothing);
      expect(_text('USD'), findsNothing);
      expect(_text('Scanning for your coins… 43%'), findsOneWidget);
      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/desktop_restore_scanning.png'),
      );
      await _done(tester);
    });

    testWidgets('stalled at the HF6 boundary', (tester) async {
      final source = FakeHomeSource(assessment: stalledAtHf6());
      await _desktop(tester, source);
      expect(_text('stuck on an old version'), findsOneWidget);
      expect(_text('Try another node'), findsOneWidget);
      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/desktop_stalled_hf6.png'),
      );
      await _done(tester);
    });

    testWidgets('claim dialog: what the balance really gains, the fee '
        'taken out of the BEAM', (tester) async {
      final source = FakeHomeSource(
        inbox: inboxOf({
          'alice': {0: g(2.5)},
          'bob': {174: g(1000)},
        }),
      );
      await _desktop(tester, source, auth: FakeAuth());
      await tester.tap(find.byKey(const Key('beamHomeClaim')));
      await tester.pumpAndSettle();
      expect(find.text('Your balance changes by'), findsOneWidget);
      expect(find.text('+2.489 BEAM, +1,000 FOMO'), findsOneWidget);
      // A short window (this one is 460 px) scrolls the sheet rather than
      // overflowing it; the claim button is reachable.
      await tester.ensureVisible(find.byKey(const Key('beamClaimConfirm')));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('beamClaimConfirm'))).bottom,
        lessThanOrEqualTo(desktopSize.height),
      );
      // The picture at the usual 1280 x 800.
      useWindow(tester, const Size(1280, 800), dpr: 1.5);
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(_golden),
        matchesGoldenFile('goldens/desktop_claim_dialog.png'),
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(source.executed, isEmpty);
      await _done(tester);
    });
  });
}

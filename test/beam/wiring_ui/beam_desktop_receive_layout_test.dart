/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// B-RECEIVE-LAYOUT, on Campfire's real DesktopWalletView (1280 × 800, the
// Linux window) over a REAL BeamWallet whose coins are still being found,
// so the scanning banner shows under the header:
//   * Receive: the address and "Copy address" are in view without
//     scrolling (seen in the DMG test: Copy below the fold, and only the
//     narrow column scrolled);
//   * the page scrolls as ONE (the mouse wheel over the banner or over the
//     column moves the whole page; the column has no scrolling of its own),
//     and only where it must: the Transactions tab fits, nothing scrolls;
//   * a short window keeps the columns usable and scrolls the page to them.
//
//   scripts/beam/host_test.sh --no-analyze --update-goldens --copy-goldens \
//       test/beam/wiring_ui/beam_desktop_receive_layout_test.dart

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/token_view/my_tokens_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/desktop_wallet_view.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/supporting/beam_wallet_info_extension.dart';
import 'package:stackwallet/widgets/beam/receive/beam_receive_widgets.dart';
import 'package:stackwallet/widgets/beam/wiring/beam_desktop_wallet_tabs.dart';

import '../wallet/beam_wallet_test_support.dart';
import 'wiring_harness.dart';

/// The desktop app bar's height: nothing of the page shows above it.
const _appBarBottom = 82.0;

const _page = Key('beamDesktopWalletPage');

/// A restored wallet, open on a core that has found 43% so far: the
/// scanning banner shows.
Future<BeamWallet> _scanningWallet(WidgetTester tester, WiringDb db) async {
  final core = WiringCore()..status = statusJson(height: kTip);
  final host = FakeBeamHost(replies: core.replies);
  final wallet = await openBeamWallet(tester, db, core: core, host: host);
  await tester.runAsync(() async {
    await wallet.info.updateExtraBeamWalletInfo(
      beamData: const ExtraBeamWalletInfo(
        restoreScanPending: true,
        restoreScanStartedAt: 1791300000,
      ),
      isar: db.isar,
    );
    host.lastTransport!.emit('ev_sync_progress', {
      'sync_requests_done': 430,
      'sync_requests_total': 1000,
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  return wallet;
}

Future<void> _tab(WidgetTester tester, String title) async {
  await tester.tap(
    find
        .descendant(
          of: find.byType(BeamDesktopWalletTabs),
          matching: find.text(title),
        )
        .first,
  );
  await settle(tester);
}

ScrollPosition _pagePosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(of: find.byKey(_page), matching: find.byType(Scrollable))
          .first,
    )
    .position;

/// Fails unless [finder] is wholly inside the window, under the app bar.
void _inWindow(WidgetTester tester, Finder finder, Size window) {
  final r = tester.getRect(finder);
  expect(r.top, greaterThanOrEqualTo(_appBarBottom), reason: '$finder top');
  expect(r.bottom, lessThanOrEqualTo(window.height), reason: '$finder below');
  expect(r.left, greaterThanOrEqualTo(0), reason: '$finder left');
  expect(r.right, lessThanOrEqualTo(window.width), reason: '$finder right');
}

/// A mouse wheel turned by [dy] with the pointer over [over].
Future<void> _wheel(WidgetTester tester, Finder over, double dy) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(tester.getCenter(over)));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  testWidgets('Receive with the scanning banner: the address and "Copy '
      'address" are in view; the page scrolls as one', (tester) async {
    final wallet = await _scanningWallet(tester, db);
    await pumpWiring(
      tester,
      DesktopWalletView(walletId: wallet.walletId),
      desktop: true,
    );
    await _tab(tester, 'Receive');

    final banner = find.byKey(const Key('beamHomeSyncBanner'));
    expect(banner, findsOneWidget);
    expect(find.textContaining('Scanning for your coins'), findsOneWidget);
    _inWindow(tester, find.byKey(BeamReceiveKeys.qr), desktopWindow);
    _inWindow(tester, find.byKey(BeamReceiveKeys.address), desktopWindow);
    _inWindow(tester, find.byKey(BeamReceiveKeys.copy), desktopWindow);
    // Copy sits right under the address, beside the QR.
    final address = tester.getRect(find.byKey(BeamReceiveKeys.address));
    final copy = tester.getRect(find.byKey(BeamReceiveKeys.copy));
    final qr = tester.getRect(find.byKey(BeamReceiveKeys.qr));
    expect(copy.top, greaterThan(address.bottom));
    expect(copy.left, greaterThan(qr.right));
    // Room to spare: a taller header or banner does not push it out.
    expect(copy.bottom, lessThanOrEqualTo(desktopWindow.height - 100));
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/desktop_receive_scanning.png'),
    );

    // The only thing that scrolls the Receive column is the page.
    final scrollers = find.ancestor(
      of: find.byKey(BeamReceiveKeys.copy),
      matching: find.byType(Scrollable),
    );
    expect(scrollers, findsOneWidget);
    expect(
      find.descendant(of: find.byKey(_page), matching: scrollers),
      findsOneWidget,
    );

    // The rest of Receive is below the fold; the wheel over the banner (not
    // the column) brings it up, header and all.
    final position = _pagePosition(tester);
    expect(position.maxScrollExtent, greaterThan(0));
    final bannerTop = tester.getRect(banner).top;
    await _wheel(tester, banner, 600);
    expect(position.pixels, position.maxScrollExtent);
    expect(tester.getRect(banner).top, lessThan(bannerTop));
    _inWindow(tester, find.byKey(BeamReceiveKeys.share), desktopWindow);
    _inWindow(tester, find.byKey(BeamReceiveKeys.moreWays), desktopWindow);
    _inWindow(tester, find.byKey(BeamReceiveKeys.allAddresses), desktopWindow);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/desktop_receive_scrolled.png'),
    );

    // The wheel over the column itself moves the page too.
    await _wheel(tester, find.byKey(BeamReceiveKeys.moreWays), -600);
    expect(position.pixels, 0);
    await finish(tester);
  });

  testWidgets('only where it must: the Transactions tab fits the window, '
      'nothing scrolls', (tester) async {
    final wallet = await _scanningWallet(tester, db);
    await pumpWiring(
      tester,
      DesktopWalletView(walletId: wallet.walletId),
      desktop: true,
    );
    await _tab(tester, 'Transactions');
    expect(find.byKey(const Key('beamHomeSyncBanner')), findsOneWidget);
    expect(_pagePosition(tester).maxScrollExtent, lessThan(0.5));
    // The assets column reaches the bottom margin, as before.
    final assets = tester.getRect(find.byType(MyTokensView));
    expect(assets.bottom, closeTo(desktopWindow.height - 24, 0.5));
    await finish(tester);
  });

  testWidgets('a short window: the columns keep their height and the page '
      'scrolls to them', (tester) async {
    final wallet = await _scanningWallet(tester, db);
    const short = Size(1280, 600);
    await pumpWiring(
      tester,
      DesktopWalletView(walletId: wallet.walletId),
      desktop: true,
      size: short,
    );
    await _tab(tester, 'Transactions');
    expect(tester.getRect(find.byType(MyTokensView)).height, 360);
    final position = _pagePosition(tester);
    expect(position.maxScrollExtent, greaterThan(0));
    await _wheel(tester, find.byKey(const Key('beamHomeSyncBanner')), 600);
    expect(
      tester.getRect(find.byType(MyTokensView)).bottom,
      lessThanOrEqualTo(short.height),
    );
    await finish(tester);
  });
}

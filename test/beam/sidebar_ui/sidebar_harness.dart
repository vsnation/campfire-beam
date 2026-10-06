/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Set-up for the side-menu tests: Campfire's REAL DesktopHomeView (its real
// DesktopMenu and content area) in the Linux app's 1280 × 800 window, over
// REAL BeamWallets on fake cores (the wiring tests' harness), Campfire's
// light theme and the app's routes.
//
// Nothing real: mnemonics are generated per test, addresses and amounts are
// invented, and the BEAM price used for fiat values (0.0287 USD) is made up
// for the layout only. The DEX pools are the public mainnet `pools_view`
// recorded for the DEX tests.

import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages_desktop_specific/desktop_home_view.dart';
import 'package:stackwallet/pages_desktop_specific/desktop_menu_item.dart';
import 'package:stackwallet/providers/global/notifications_provider.dart';
import 'package:stackwallet/providers/global/prefs_provider.dart';
import 'package:stackwallet/providers/global/shopin_bit_service_provider.dart';
import 'package:stackwallet/providers/global/trades_service_provider.dart';
import 'package:stackwallet/providers/global/wallets_provider.dart';
import 'package:stackwallet/route_generator.dart';
import 'package:stackwallet/services/wallets.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/themes/theme_providers.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/utilities/amount/amount_formatter.dart';
import 'package:stackwallet/utilities/prefs.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/isar/providers/all_wallets_info_provider.dart';
import 'package:stackwallet/wallets/isar/providers/wallet_info_provider.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/widgets/beam/airdrop/beam_layout.dart';
import 'package:stackwallet/widgets/beam/sidebar/beam_sidebar.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_wallet_home.dart';
import 'package:stackwallet/widgets/beam/wiring/beam_wallet_listenables.dart';

import '../contracts/bans/bans_fixtures.dart' show bansResult;
import '../contracts/dex/dex_fixtures.dart';
import '../names_ui/names_ui_harness.dart' show answer, userView;
import '../wiring_ui/wiring_harness.dart';

export '../wiring_ui/wiring_harness.dart';

/// The wiring tests' core, also answering the contract views the side-menu
/// pages open with: the DEX's `pools_view` (the recorded mainnet pools, so
/// Swap lists pools and FOMO has a price) and the BANS views of a wallet
/// with no name yet (recorded `my_key` / `view_params`, an empty
/// `view_domain`). Any other contract call is left unanswered, as a core
/// that cannot reach the contract would.
class SidebarCore extends WiringCore {
  @override
  Map<String, Object?> replies() => {
    ...super.replies(),
    'invoke_contract': (Map<String, Object?> p) {
      final args = '${p['args']}';
      final action = RegExp(r'action=([a-z_]+)').firstMatch(args)?.group(1);
      return switch (action) {
        'pools_view' =>
          (dexEnvelope('pools_view')['result']! as Map).cast<String, Object?>(),
        'my_key' => bansResult('my_key'),
        'view_params' => bansResult('view_params'),
        'view_domain' => answer('{"domains": []}'),
        'view' => userView(),
        _ => throw StateError('no recorded answer for $args'),
      };
    },
  };
}

/// Campfire's settings for the desktop home (auto-lock off).
class SidebarPrefs extends TestPrefs {
  SidebarPrefs({this.prices = false});

  final bool prices;

  @override
  bool get externalCalls => prices;

  @override
  AutoLockInfo get autoLockInfo => (enabled: false, minutes: 10);
}

/// The remembered wallet, in memory.
class MemoryWalletMemory implements BeamSidebarWalletMemory {
  MemoryWalletMemory([this.value]);

  String? value;
  final List<String> writes = [];

  @override
  String? read() => value;

  @override
  Future<void> write(String walletId) async {
    value = walletId;
    writes.add(walletId);
  }
}

/// A made-up BEAM price, for the layout of fiat values only.
final kLayoutPrice = Decimal.parse('0.0287');

ProviderContainer? _container;

/// Pumps [home] (default: Campfire's real desktop home) in a [size] window
/// (default 1280 × 800). [wallets] fixes the BEAM wallet list (null: the
/// real one, from Campfire's database); [memory] is the remembered wallet.
/// With [prices], fiat values use [kLayoutPrice].
///
/// With [wallets] fixed, My Campfire lists [myCampfire] (default: none).
/// Two upstream singletons make that necessary in tests: Campfire's
/// wallet-list watcher (`pAllWalletsInfo`) is process-wide and ends with
/// the first container, and My Campfire's wallet list (`WalletsOverview`)
/// never cancels its `WalletsChangedEvent` subscription, so a wallet added
/// in a later test reaches an unmounted list. The app has one container
/// and never unmounts that list. A test that shows wallets in My Campfire
/// must therefore be the last of its file to add one.
Future<ProviderContainer> pumpSidebar(
  WidgetTester tester, {
  Widget home = const DesktopHomeView(),
  List<BeamWallet>? wallets,
  List<WalletInfo> myCampfire = const [],
  MemoryWalletMemory? memory,
  Size size = desktopWindow,
  bool prices = true,
  List<Override> overrides = const [],
}) async {
  await loadFonts(tester);
  tolerateKnownOverflows();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  BeamWalletWiring.debugDesktopLayout = true;
  addTearDown(() => BeamWalletWiring.debugDesktopLayout = null);
  BeamSidebar.debugEnabled ??= true;
  addTearDown(() => BeamSidebar.debugEnabled = null);

  final colors = StackColors.fromStackColorTheme(campfireLight);
  final container = ProviderContainer(
    overrides: [
      prefsChangeNotifierProvider.overrideWithValue(
        SidebarPrefs(prices: prices),
      ),
      tradesServiceProvider.overrideWithValue(NoTrades()),
      notificationsProvider.overrideWithValue(NoNotifications()),
      pAnyGlobalUnreadNotifications.overrideWithValue(false),
      pWallets.overrideWithValue(Wallets.sharedInstance),
      themeProvider.overrideWithProvider(
        StateProvider<StackTheme>((ref) => campfireLight),
      ),
      pBeamSidebarWalletMemory.overrideWithValue(
        memory ?? MemoryWalletMemory(),
      ),
      if (wallets != null) ...[
        pBeamSidebarWallets.overrideWithValue(wallets),
        pAllWalletsInfo.overrideWithValue(myCampfire),
      ],
      if (prices)
        pBeamHomeFormat.overrideWithProvider(
          (walletId) => Provider<BeamHomeFormat>((ref) {
            final coin = ref.watch(pWalletCoin(walletId));
            return BeamHomeFormat(
              formatBeam: ref.watch(pAmountFormatter(coin)).format,
              pricesOn: true,
              price: kLayoutPrice,
              currency: 'USD',
              fractionDigits: coin.fractionDigits,
            );
          }),
        ),
      ...overrides,
    ],
  );
  _dispose();
  _container = container;
  addTearDown(() async {
    if (_container == null) return;
    await tester.pumpWidget(const SizedBox());
    _dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appThemeData(colors),
        onGenerateRoute: RouteGenerator.generateRoute,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: BeamLayoutScope(
            desktop: true,
            child: RepaintBoundary(key: goldenKey, child: child!),
          ),
        ),
        home: home,
      ),
    ),
  );
  await settle(tester);
  return container;
}

/// Lets work the pages started (core calls, Isar writes such as the asset
/// registry and the market cache) finish: real I/O completes during
/// `runAsync`, its continuations run on the next frame. An Isar write left
/// half-done holds the database's write lock, and the next test's wallet
/// would wait on it for ever.
Future<void> drain(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Ends a test: lets started work finish, stops auto-sync and the wallets'
/// wiring, unmounts, and lets short timers finish inside the test (as the
/// wiring tests' `finish`).
Future<void> finishSidebar(WidgetTester tester) async {
  await drain(tester);
  for (final w in Wallets.sharedInstance.wallets) {
    w.shouldAutoSync = false;
  }
  await tester.pumpWidget(const SizedBox());
  _dispose();
  for (final w in Wallets.sharedInstance.wallets) {
    unawaited(BeamWalletWiring.forget(w.walletId));
  }
  await drain(tester, rounds: 3);
  await tester.pump(const Duration(seconds: 6));
}

void _dispose() {
  final c = _container;
  _container = null;
  if (c == null) return;
  // Campfire's Isar watchers are disposed twice with their container (the
  // app never disposes it); only that assertion is tolerated.
  runZonedGuarded(c.dispose, (e, _) {
    final m = '$e';
    if (!(m.contains('Watcher') && m.contains('was used after being'))) {
      throw e;
    }
  });
}

/// Selects a side-menu item by its key and lets the page settle.
Future<void> tapMenu(WidgetTester tester, Key key) async {
  await tester.tap(find.byKey(key));
  await settle(tester, rounds: 2);
}

/// The menu's item labels, top to bottom (Exit included).
List<String> menuLabels(WidgetTester tester) {
  final items = find.byWidgetPredicate((w) => w is DesktopMenuItem);
  final list = items.evaluate().toList()
    ..sort(
      (a, b) => tester
          .getTopLeft(find.byWidget(a.widget))
          .dy
          .compareTo(tester.getTopLeft(find.byWidget(b.widget)).dy),
    );
  return [for (final e in list) (e.widget as DesktopMenuItem).label];
}

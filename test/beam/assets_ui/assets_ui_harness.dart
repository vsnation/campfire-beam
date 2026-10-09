/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Rendering set-up for the asset screens: Campfire's own light theme and
// Inter, the phone or desktop layout, and provider overrides that point
// the screens at a test BeamWallet and the recorded DEX pools.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:stackwallet/models/exchange/response_objects/trade.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/pages/token_view/sub_widgets/beam_asset_layout.dart';
import 'package:stackwallet/providers/global/prefs_provider.dart';
import 'package:stackwallet/providers/global/trades_service_provider.dart';
import 'package:stackwallet/providers/global/wallets_provider.dart';
import 'package:stackwallet/services/trade_service.dart';
import 'package:stackwallet/services/wallets.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/themes/theme_providers.dart';
import 'package:stackwallet/utilities/amount/amount_unit.dart';
import 'package:stackwallet/utilities/prefs.dart';
import 'package:stackwallet/utilities/stack_file_system.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_holdings.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_providers.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_balance_mapper.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/providers/beam/current_beam_asset_wallet_provider.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/impl/sub_wallets/beam_asset_wallet.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_wallet_home.dart'
    show BeamCoinScan, pBeamCoinScan;

final StackTheme campfireLight = () {
  final zip = File('asset_sources/default_themes/campfire/light.zip')
      .readAsBytesSync();
  final themeJson = ZipDecoder()
      .decodeBytes(zip)
      .files
      .singleWhere((f) => f.name == 'theme.json');
  final json = jsonDecode(utf8.decode(themeJson.content as List<int>)) as Map;
  return StackTheme.fromJson(json: Map<String, dynamic>.from(json));
}();

/// Unpacks Campfire's light theme under [themesDir] the way the app
/// installs it, so theme icons (transaction icons…) load from real files.
void installCampfireTheme(Directory themesDir) {
  final zip = File('asset_sources/default_themes/campfire/light.zip')
      .readAsBytesSync();
  for (final f in ZipDecoder().decodeBytes(zip).files) {
    if (!f.isFile) continue;
    File('${themesDir.path}/${campfireLight.themeId}/${f.name}')
      ..createSync(recursive: true)
      ..writeAsBytesSync(f.content as List<int>);
  }
  StackFileSystem.themesDir = themesDir;
}

/// The parts of the app's ThemeData the widgets read (lib/main.dart).
ThemeData appThemeData(StackColors colors) => ThemeData(
  extensions: [colors],
  highlightColor: colors.highlight,
  brightness: colors.brightness,
  fontFamily: GoogleFonts.inter().fontFamily,
  splashColor: Colors.transparent,
  // As lib/main.dart: no Material 3 tint under a scrolled app bar.
  appBarTheme: AppBarTheme(
    centerTitle: false,
    backgroundColor: colors.background,
    surfaceTintColor: colors.background,
    elevation: 0,
  ),
  textButtonTheme: TextButtonThemeData(
    style: ButtonStyle(
      overlayColor: WidgetStateProperty.all(colors.splash),
      minimumSize: WidgetStateProperty.all<Size>(const Size(46, 46)),
      foregroundColor: WidgetStateProperty.all(colors.buttonTextSecondary),
      backgroundColor: WidgetStateProperty.all<Color>(
        colors.buttonBackSecondary,
      ),
      shape: WidgetStateProperty.all<OutlinedBorder>(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(1000)),
      ),
    ),
  ),
);

/// Campfire's settings as the asset screens read them, without Hive. A new
/// one per test: a ProviderScope disposes its ChangeNotifiers.
class TestPrefs extends ChangeNotifier implements Prefs {
  @override
  bool get externalCalls => false;

  @override
  String get currency => 'USD';

  @override
  AmountUnit amountUnit(CryptoCurrency coin) => AmountUnit.normal;

  @override
  int maxDecimals(CryptoCurrency coin) => Prefs.defaultMaxDecimals(coin);

  @override
  bool get hideBlockExplorerWarning => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// No exchange trades (the real service reads Hive).
class NoTrades extends TradesService {
  @override
  List<Trade> get trades => const [];
}

/// A 375 × 667 phone, rendered at 2×.
const phone = Size(375, 667);

/// A 1280 × 800 desktop window, at 1×.
const desktopWindow = Size(1280, 800);

const goldenKey = ValueKey('beam-assets-golden');

Future<void> loadFonts(WidgetTester tester) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  await tester.runAsync(() async {
    for (final w in [
      FontWeight.w400,
      FontWeight.w500,
      FontWeight.w600,
      FontWeight.w700,
    ]) {
      GoogleFonts.inter(fontWeight: w);
    }
    await GoogleFonts.pendingFonts();
  });
}

/// Pumps [home] in the phone or desktop layout. [wallet] is what the asset
/// screens find for its id, [market] what the DEX answers (null: prices not
/// loaded), [assetWallet] the asset being viewed, and [totals] replaces the
/// wallet's cached per-asset totals when given. [coinScan] is a restore
/// scan still looking for the wallet's coins.
Future<void> pumpAssets(
  WidgetTester tester,
  Widget home, {
  required BeamWallet wallet,
  required bool desktop,
  BeamAssetMarket? market,
  BeamAssetWallet? assetWallet,
  Map<int, BeamCachedAssetTotals>? totals,
  Set<int>? hidden,
  BeamCoinScan? coinScan,
}) async {
  await loadFonts(tester);
  final size = desktop ? desktopWindow : phone;
  final ratio = desktop ? 1.0 : 2.0;
  tester.view.physicalSize = size * ratio;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  final colors = StackColors.fromStackColorTheme(campfireLight);
  final container = ProviderContainer(
    overrides: [
      prefsChangeNotifierProvider.overrideWithValue(TestPrefs()),
      tradesServiceProvider.overrideWithValue(NoTrades()),
      pWallets.overrideWithValue(Wallets.sharedInstance),
      themeProvider.overrideWithProvider(
        StateProvider<StackTheme>((ref) => campfireLight),
      ),
      pBeamWallet.overrideWithProvider(
        (id) => Provider<BeamWallet?>((ref) => wallet),
      ),
      pBeamAssetMarket.overrideWithProvider(
        (id) => FutureProvider<BeamAssetMarket?>((ref) async => market),
      ),
      if (totals != null)
        pBeamAssetTotals.overrideWithProvider(
          (id) => Provider<Map<int, BeamCachedAssetTotals>>((ref) => totals),
        ),
      if (hidden != null)
        pBeamHiddenAssetIds.overrideWithProvider(
          (id) => Provider<Set<int>>((ref) => hidden),
        ),
      beamAssetWalletStateProvider.overrideWithValue(
        StateController<BeamAssetWallet?>(assetWallet),
      ),
      if (coinScan != null)
        pBeamCoinScan.overrideWithProvider(
          (id) => Provider.autoDispose<BeamCoinScan?>((ref) => coinScan),
        ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    // Campfire's WalletInfo watcher (`_wiProvider`) is disposed twice when
    // its container is: by its own onDispose and by ChangeNotifierProvider.
    // Debug builds assert on the second; the app never disposes its
    // container, so only that assertion is tolerated. Disposing stops the
    // Isar watchers, which Isar.close() would otherwise wait for.
    runZonedGuarded(container.dispose, (e, _) {
      if (!'$e'.contains('Watcher<WalletInfo> was used after being')) {
        throw e;
      }
    });
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: BeamAssetLayout(
        desktop: desktop,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appThemeData(colors),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: RepaintBoundary(key: goldenKey, child: child),
          ),
          home: home,
        ),
      ),
    ),
  );
  await settle(tester);
}

/// Lets real image and SVG decoding finish (outside the fake clock), then
/// repaints.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        final img = e.widget as Image;
        await precacheImage(img.image, e);
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

/// What the desktop wallet page puts around the embedded asset list.
Widget desktopFrame(Widget child) => Builder(
  builder: (context) => Material(
    color: Theme.of(context).extension<StackColors>()!.background,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 460),
          const SizedBox(width: 16),
          Expanded(child: child),
        ],
      ),
    ),
  ),
);

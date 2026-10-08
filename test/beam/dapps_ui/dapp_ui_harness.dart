/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Shared set-up for the dApp UI widget and golden tests: Campfire's own
// light theme and Inter fonts (as test/beam/screenshot_smoke_test.dart),
// Riverpod overrides for the theme, and fakes of the wallet link.
//
// Goldens are platform-specific (font rasterisation differs between macOS
// and Linux): these were generated and are compared on macOS through
// scripts/beam/host_test.sh.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/themes/theme_providers.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_identity.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_wallet_link.dart';
import 'package:stackwallet/wallets/beam/models/beam_asset_info.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';

StackTheme campfireLightTheme() {
  final zip = File('asset_sources/default_themes/campfire/light.zip')
      .readAsBytesSync();
  final themeJson = ZipDecoder()
      .decodeBytes(zip)
      .files
      .singleWhere((f) => f.name == 'theme.json');
  final json = jsonDecode(utf8.decode(themeJson.content as List<int>)) as Map;
  return StackTheme.fromJson(json: Map<String, dynamic>.from(json));
}

/// The parts of the app's ThemeData (lib/main.dart) the widgets read.
ThemeData campfireThemeData(StackColors colors) => ThemeData(
  extensions: [colors],
  highlightColor: colors.highlight,
  brightness: colors.brightness,
  fontFamily: GoogleFonts.inter().fontFamily,
  splashColor: Colors.transparent,
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

/// Loads Inter from the bundled google_fonts/ assets before the first
/// layout, so goldens show text rather than the test font's boxes.
Future<void> loadCampfireFonts(WidgetTester tester) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  await tester.runAsync(() async {
    for (final w in [
      FontWeight.w400,
      FontWeight.w500,
      FontWeight.w600,
      FontWeight.w700,
    ]) {
      GoogleFonts.inter(fontWeight: w);
      GoogleFonts.inter(fontWeight: w, fontStyle: FontStyle.italic);
    }
    await GoogleFonts.pendingFonts();
    // Material icons (the warning triangle): flutter_test does not load
    // the icon font by itself, so goldens would show a box instead.
    try {
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    } catch (_) {
      // Not bundled: icons render as boxes, nothing else changes.
    }
  });
}

void setSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Campfire's app shell around [home]: theme, provider overrides, and a
/// [RepaintBoundary] under [boundaryKey] for goldens.
Widget campfireApp({
  required Widget home,
  Key boundaryKey = const ValueKey('golden'),
  GlobalKey<NavigatorState>? navigatorKey,
  RouteFactory? onGenerateRoute,
}) {
  final theme = campfireLightTheme();
  final colors = StackColors.fromStackColorTheme(theme);
  return ProviderScope(
    overrides: [
      themeProvider.overrideWithProvider(StateProvider((ref) => theme)),
    ],
    child: RepaintBoundary(
      key: boundaryKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        theme: campfireThemeData(colors),
        onGenerateRoute: onGenerateRoute,
        home: home,
      ),
    ),
  );
}

/// Decodes every [Image] on screen for real (flutter_test only does that
/// inside runAsync), so goldens show the bundled asset icons.
Future<void> precacheImages(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate()) {
      final image = element.widget as Image;
      await precacheImage(image.image, element);
    }
  });
  await tester.pumpAndSettle();
}

/// Lets asset SVGs and images load for real (asset reads and decoding run
/// outside flutter_test's fake clock), then pumps: goldens of the store show
/// the bundled dApp icons.
Future<void> settleIcons(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() async {
    for (final e in find.byType(Image).evaluate()) {
      // A missing image is the widget's errorBuilder's business.
      await precacheImage((e.widget as Image).image, e, onError: (_, _) {});
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await tester.pumpAndSettle();
}

/// A wallet link with fixed answers.
class FakeWalletLink implements DappWalletLink {
  FakeWalletLink({
    required this.root,
    this.transport,
    this.balances,
    this.metadata = const {},
    this.blocked,
    this.valuer,
  });

  final String root;
  BeamTransport? transport;
  Map<int, BigInt>? balances;
  Map<int, BeamAssetMetadata> metadata;
  String? blocked;
  DappAssetValuer? valuer;
  int holds = 0;
  int releases = 0;

  @override
  Future<String> dappsRoot() async => root;

  @override
  BeamTransport dappTransport(DappIdentity dapp) => transport!;

  @override
  Future<Map<int, BigInt>?> availableBalances() async => balances;

  @override
  Future<BeamAssetMetadata?> assetMetadata(int assetId) async =>
      metadata[assetId];

  @override
  Future<DappAssetValuer?> assetValuer() async => valuer;

  @override
  String? get spendBlockedReason => blocked;

  /// What the dApp screen's wallet line reads; change it with [setWait].
  DappWalletWait? wait;
  final _changes = StreamController<void>.broadcast();
  int retries = 0;

  /// The wallet's state changes to [next], and says so (no polling).
  void setWait(DappWalletWait? next) {
    wait = next;
    _changes.add(null);
  }

  @override
  DappWalletWait? get walletWait => wait;

  @override
  Stream<void> get walletChanges => _changes.stream;

  @override
  Future<void> retryConnection() async => retries++;

  @override
  void Function() holdForApproval(String reason) {
    holds++;
    var done = false;
    return () {
      if (done) return;
      done = true;
      releases++;
    };
  }
}

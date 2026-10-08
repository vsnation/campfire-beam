/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Pumps a BEAM contract screen the way the app shows it: Campfire's own
// light theme (asset_sources/default_themes/campfire/light.zip), the
// relevant part of lib/main.dart's ThemeData, bundled Inter, and the
// riverpod theme provider that Campfire's Background widget reads.
//
// Phone layout: 375 x 812 logical pixels at 2x. Desktop: 1280 x 800 at 1x.
// Note: Campfire's own PrimaryButton and text fields pick their text
// styles from Util.isDesktop, which is true on the macOS test host, so in
// phone goldens those two widgets keep their desktop font sizes; the
// layout around them is the phone one (BeamLayoutScope).

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
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/widgets/beam/airdrop/beam_layout.dart';
import 'package:stackwallet/widgets/beam/airdrop/beam_spend_auth.dart';

const phoneSize = Size(375, 812);
const desktopSize = Size(1280, 800);

StackTheme? _theme;

StackTheme campfireLightTheme() => _theme ??= () {
  final zip = File('asset_sources/default_themes/campfire/light.zip')
      .readAsBytesSync();
  final themeJson = ZipDecoder()
      .decodeBytes(zip)
      .files
      .singleWhere((f) => f.name == 'theme.json');
  final json = jsonDecode(utf8.decode(themeJson.content as List<int>)) as Map;
  return StackTheme.fromJson(json: Map<String, dynamic>.from(json));
}();

OutlineInputBorder _border(Color c) => OutlineInputBorder(
  borderSide: BorderSide(width: 0, color: c),
  borderRadius: BorderRadius.circular(8),
);

ThemeData appThemeData(StackColors colors) => ThemeData(
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
  appBarTheme: AppBarTheme(
    centerTitle: false,
    backgroundColor: colors.background,
    surfaceTintColor: colors.background,
    elevation: 0,
  ),
  inputDecorationTheme: InputDecorationTheme(
    focusColor: colors.textFieldDefaultBG,
    fillColor: colors.textFieldDefaultBG,
    filled: true,
    contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
    enabledBorder: _border(colors.textFieldDefaultBG),
    focusedBorder: _border(colors.textFieldDefaultBG),
    errorBorder: _border(colors.textFieldDefaultBG),
    disabledBorder: _border(colors.textFieldDefaultBG),
    focusedErrorBorder: _border(colors.textFieldDefaultBG),
  ),
);

/// Loads Inter before the first layout (TOOLCHAIN.md §3).
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
    await _loadMaterialIcons();
  });
}

bool _iconsLoaded = false;

/// The Material icon font ships with every Flutter app but not with
/// flutter_tester; without it icons render as boxes. It is read from the
/// running SDK (…/bin/cache/artifacts/engine/<host>/flutter_tester).
Future<void> _loadMaterialIcons() async {
  if (_iconsLoaded) return;
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 3; i++) {
    dir = dir.parent;
  }
  final font = File(
    '${dir.path}/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (!font.existsSync()) return;
  final bytes = font.readAsBytesSync();
  final loader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
  _iconsLoaded = true;
}

/// Shows [page] as the app would, in the phone or desktop layout.
Future<void> pumpBeamPage(
  WidgetTester tester,
  Widget page, {
  bool desktop = false,
  Size? size,
}) async {
  await loadFonts(tester);
  size ??= desktop ? desktopSize : phoneSize;
  final ratio = desktop ? 1.0 : 2.0;
  tester.view.physicalSize = size * ratio;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  final theme = campfireLightTheme();
  final colors = StackColors.fromStackColorTheme(theme);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        themeProvider.overrideWithValue(StateController<StackTheme>(theme)),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appThemeData(colors),
        // Stills instead of Lottie animations: a golden needs one frame.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: BeamLayoutScope(desktop: desktop, child: child!),
        ),
        home: page,
      ),
    ),
  );
  await tester.pump();
}

/// Lets real asynchronous work (asset images) finish, then settles.
Future<void> settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    for (final e in find.byType(Image).evaluate()) {
      final image = (e.widget as Image).image;
      await precacheImage(image, e);
    }
  });
  await tester.pumpAndSettle();
}

/// Compares the whole screen with `goldens/<name>.png`.
Future<void> expectScreen(WidgetTester tester, String name) async {
  await settle(tester);
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

/// Shader bytes read once, synchronously: `File.readAsBytes` is real I/O,
/// which never completes inside a widget test's fake clock.
class MemoryShaderSource implements ShaderSource {
  MemoryShaderSource([this.directory = 'assets/beam/shaders']);

  final String directory;
  final _cache = <String, Uint8List>{};

  @override
  Future<Uint8List> read(String name) async =>
      _cache[name] ??= File('$directory/$name').readAsBytesSync();
}

/// The PIN / password gate, answered without a screen.
class FakeAuth {
  FakeAuth({this.answer = true});

  bool answer;
  final reasons = <String>[];

  Future<bool> call(BuildContext context, {required String reason}) async {
    reasons.add(reason);
    return answer;
  }

  BeamSpendAuthorizer get authorizer => call;
}

const syncedHeight = 4068189;

BeamSyncAssessment synced() => const BeamSynced(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.agrees,
  walletHeight: syncedHeight,
  networkHeight: syncedHeight,
);

BeamSyncAssessment catchingUp() => const BeamSyncCatchingUp(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.aheadOfWallet,
  blockInterval: Duration(seconds: 60),
  walletHeight: syncedHeight - 42,
  networkHeight: syncedHeight,
  blocksBehind: 42,
);

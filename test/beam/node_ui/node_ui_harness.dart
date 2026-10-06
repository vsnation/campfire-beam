/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Rendering harness for the node UI goldens: Campfire's own light theme
// (asset_sources/default_themes/campfire/light.zip), the bundled Inter
// fonts, a fake panel source with ready-made snapshots, and helpers to let
// SVG and image decoding finish before a golden is taken.

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
import 'package:stackwallet/utilities/constants.dart';
import 'package:stackwallet/wallets/beam/host/beam_host.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_disk.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_panel_model.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_panel_source.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/widgets/beam/node/beam_node_widgets.dart';

StackTheme _theme() {
  final zip = File(
    'asset_sources/default_themes/campfire/light.zip',
  ).readAsBytesSync();
  final json = jsonDecode(
    utf8.decode(
      ZipDecoder()
              .decodeBytes(zip)
              .files
              .singleWhere((f) => f.name == 'theme.json')
              .content
          as List<int>,
    ),
  );
  return StackTheme.fromJson(json: Map<String, dynamic>.from(json as Map));
}

final StackTheme campfireLight = _theme();

OutlineInputBorder _border(Color c) => OutlineInputBorder(
  borderSide: BorderSide(width: 1, color: c),
  borderRadius: BorderRadius.circular(Constants.size.circularBorderRadius),
);

/// The parts of the app's ThemeData (lib/main.dart) these screens read.
ThemeData appTheme(StackColors colors) => ThemeData(
  extensions: [colors],
  highlightColor: colors.highlight,
  brightness: colors.brightness,
  fontFamily: GoogleFonts.inter().fontFamily,
  splashColor: Colors.transparent,
  unselectedWidgetColor: colors.radioButtonBorderDisabled,
  appBarTheme: AppBarTheme(
    centerTitle: false,
    backgroundColor: colors.background,
    surfaceTintColor: colors.background,
    elevation: 0,
  ),
  checkboxTheme: CheckboxThemeData(
    splashRadius: 0,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    checkColor: WidgetStateColor.resolveWith(
      (s) => s.contains(WidgetState.selected)
          ? colors.checkboxIconChecked
          : colors.checkboxBGChecked,
    ),
    fillColor: WidgetStateColor.resolveWith(
      (s) => s.contains(WidgetState.selected)
          ? colors.checkboxBGChecked
          : colors.checkboxBorderEmpty,
    ),
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

bool _fontsLoaded = false;

/// Inter (bundled google_fonts) and Material icons before the first layout;
/// otherwise goldens show the test font's square glyphs.
Future<void> loadFonts(WidgetTester tester) async {
  if (_fontsLoaded) return;
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
    final root =
        Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/development/flutter-3.47.2';
    final icons = File(
      '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(ByteData.sublistView(icons.readAsBytesSync())),
        );
      await loader.load();
    }
  });
  _fontsLoaded = true;
}

/// A 375 × 812 phone, rendered at 2×.
const phone = Size(375, 812);

/// The smallest phone the primary CTA must fit on without scrolling.
const smallPhone = Size(375, 667);

/// A 1280 × 800 desktop window.
const desktopWindow = Size(1280, 800);

const goldenKey = ValueKey('node-ui-golden');

/// Pumps [home] in Campfire's theme. [desktop] forces the node widgets'
/// layout (the test host is a Mac, where Campfire is always "desktop").
Future<void> pumpNodeUi(
  WidgetTester tester,
  Widget home, {
  Size size = phone,
  double pixelRatio = 2,
  bool? desktop,
  List<Override> overrides = const [],
}) async {
  await loadFonts(tester);
  tester.view.physicalSize = size * pixelRatio;
  tester.view.devicePixelRatio = pixelRatio;
  addTearDown(tester.view.reset);
  final colors = StackColors.fromStackColorTheme(campfireLight);
  Widget child = home;
  if (desktop != null) child = BeamNodeLayout(desktop: desktop, child: child);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        themeProvider.overrideWithProvider(
          StateProvider<StackTheme>((ref) => campfireLight),
        ),
        ...overrides,
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme(colors),
        builder: (context, child) =>
            RepaintBoundary(key: goldenKey, child: child),
        home: child,
      ),
    ),
  );
  await settle(tester);
}

/// Lets SVG and image decoding (real async work) finish, then repaints.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        final img = e.widget as Image;
        await precacheImage(img.image, e);
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump();
  }
}

/// The widget with [key] is fully inside a [size] screen (no scrolling).
void expectOnScreen(WidgetTester tester, Key key, Size size) {
  final rect = tester.getRect(find.byKey(key));
  expect(rect.top, greaterThanOrEqualTo(0), reason: '$key top');
  expect(rect.bottom, lessThanOrEqualTo(size.height), reason: '$key bottom');
  expect(rect.left, greaterThanOrEqualTo(0), reason: '$key left');
  expect(rect.right, lessThanOrEqualTo(size.width), reason: '$key right');
}

// ------------------------------------------------------------------ fakes

/// A panel source driven by the test.
class FakeNodePanelSource implements BeamNodePanelSource {
  FakeNodePanelSource(this._current);

  BeamNodePanelSnapshot _current;
  final _controller = StreamController<BeamNodePanelSnapshot>.broadcast();
  final actions = <BeamNodePanelAction>[];
  final toggles = <bool>[];
  int refreshes = 0;
  bool disposed = false;

  @override
  BeamNodePanelSnapshot get current => _current;

  @override
  Stream<BeamNodePanelSnapshot> get changes => _controller.stream;

  void set(BeamNodePanelSnapshot s) {
    _current = s;
    _controller.add(s);
  }

  @override
  Future<void> perform(BeamNodePanelAction action) async =>
      actions.add(action);

  /// Like the coordinator: off moves the node to "off".
  @override
  Future<void> setPrivateNodeEnabled(bool enabled) async {
    toggles.add(enabled);
    set(
      enabled
          ? _current.copyWith(privateNodeEnabled: true)
          : _current.copyWith(
              privateNodeEnabled: false,
              privateNode: const BeamPrivateNodeStatus(
                phase: BeamPrivateNodePhase.off,
              ),
            ),
    );
  }

  @override
  Future<void> refresh() async => refreshes++;

  @override
  void dispose() {
    disposed = true;
    unawaited(_controller.close());
  }
}

// -------------------------------------------------------- snapshot parts

const int tip = 4068266;
const publicNode = BeamNodeEndpoint('eu-nodes.mainnet.beam.mw', 8100);
const ownNode = BeamNodeEndpoint('127.0.0.1', 40123, isOwned: true);

const syncedPublic = BeamSynced(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.agrees,
  walletHeight: tip,
  networkHeight: tip,
);

const syncedPrivate = BeamSynced(
  node: BeamNodeKind.privateNode,
  explorerCheck: BeamExplorerCheck.agrees,
  walletHeight: tip,
  networkHeight: tip,
);

const walletBehind = BeamSyncCatchingUp(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.agrees,
  blockInterval: Duration(minutes: 1),
  walletHeight: tip - 42,
  networkHeight: tip,
  blocksBehind: 42,
);

const notConnected = BeamSyncNotConnected(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.unavailable,
  networkReachable: true,
  walletHeight: tip - 3,
  networkHeight: tip,
);

BeamNodeDiskCheck disk(double freeGiB, {double nodeGiB = 0}) =>
    const BeamNodeDiskPolicy().check(
      BeamNodeDiskSpace(
        freeBytes: (freeGiB * kBeamGiB).round(),
        nodeBytes: (nodeGiB * kBeamGiB).round(),
      ),
    );

BeamNodePanelSnapshot snap({
  BeamSyncAssessment assessment = syncedPublic,
  BeamNodeEndpoint? node = publicNode,
  bool supported = true,
  bool enabled = true,
  BeamPrivateNodeStatus? privateNode,
  BeamNodeDiskCheck? diskCheck,
  String? coreProblem,
}) => BeamNodePanelSnapshot(
  assessment: assessment,
  node: node,
  privateNodeSupported: supported,
  privateNodeEnabled: enabled,
  privateNode: privateNode,
  disk: diskCheck,
  coreProblem: coreProblem,
);

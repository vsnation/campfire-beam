/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Shared set-up for the DEX screen tests: real BeamDexService instances
// over a FakeTransport answering from the recorded mainnet fixtures in
// test/beam/contracts/dex/fixtures, Campfire's own light theme and fonts,
// and helpers to render goldens at phone and desktop sizes.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/themes/theme_providers.dart';
import 'package:stackwallet/utilities/constants.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/contracts/common/shader_output.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_dex_service.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_pool.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/models/beam_wallet_status.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/widgets/beam/dex/dex_deps.dart';

const dexFixtureDir = 'test/beam/contracts/dex/fixtures';

/// A recorded fixture's `result`.
Map<String, Object?> recorded(String name) =>
    ((jsonDecode(File('$dexFixtureDir/$name.json').readAsStringSync())
                as Map)['result']!
            as Map)
        .cast<String, Object?>();

/// A synthetic yas-serialized raw_data vector (see the DEX module's
/// `tool/gen_invoke_vectors.cpp`).
List<int> rawVector(String name) {
  final json = jsonDecode(
    File('$dexFixtureDir/raw_data_vectors.json').readAsStringSync(),
  ) as Map;
  final hex = (json['vectors']! as Map)[name]! as String;
  return [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

/// The real DEX swap kernel wallet-api built on mainnet (0.1 BEAM → FOMO,
/// never sent), and the args it was built from.
({List<int> raw, String args}) realTradeBuild() {
  final f = (jsonDecode(
    File('$dexFixtureDir/trade_built_raw_data.json').readAsStringSync(),
  ) as Map).cast<String, Object?>();
  final raw = base64.decode(
    (f['result']! as Map)['raw_data_base64']! as String,
  );
  return (raw: raw, args: f['args']! as String);
}

/// The recorded pools, parsed by the app's own model.
List<BeamPool> recordedPools() {
  final out = ShaderOutput.decode(recorded('pools_view')['output']! as String);
  return [
    for (final row in ShaderOutput.list(out['res'], 'res'))
      BeamPool.fromJson(ShaderOutput.map(row, 'res[]')),
  ];
}

BeamPool recordedPool(int aid1, int aid2, BeamPoolKind kind) => recordedPools()
    .singleWhere((p) => p.aid1 == aid1 && p.aid2 == aid2 && p.kind == kind);

/// A built-transaction answer: what wallet-api returns for `create_tx:
/// false`.
Map<String, Object?> built(List<int> raw) => {
  'output': '{}',
  'txid': '00000000000000000000000000000000',
  'raw_data': raw,
};

class MemoryShaderSource implements ShaderSource {
  MemoryShaderSource(this.bytes);

  final Uint8List bytes;

  @override
  Future<Uint8List> read(String name) => Future.value(bytes);
}

/// The pinned AMM shader's bytes, read once (synchronously: a real file
/// read never completes inside a widget test's fake clock).
final Uint8List ammShaderBytes = File('assets/beam/shaders/$kAmmAppShaderName')
    .readAsBytesSync();

/// A wallet core that answers `invoke_contract` by exact `args` from
/// [routes] and records every `process_invoke_data`.
class DexUiFake {
  DexUiFake(this.routes, {this.txId = 'ab12cd34ef56ab12cd34ef56ab12cd34'}) {
    transport = FakeTransport({
      'invoke_contract': (Map<String, Object?> p) {
        final args = p['args']! as String;
        seenArgs.add(args);
        final route = routes[args];
        if (route == null) throw StateError('unexpected args: $args');
        return route();
      },
      'process_invoke_data': (Map<String, Object?> p) {
        executed.add(List<int>.from(p['data']! as List));
        return {'txid': txId};
      },
    });
    service = BeamDexService(
      BeamApi(transport),
      ammAppShader(MemoryShaderSource(ammShaderBytes)),
    );
  }

  final Map<String, Object? Function()> routes;
  final String txId;
  final seenArgs = <String>[];
  final executed = <List<int>>[];
  late final FakeTransport transport;
  late final BeamDexService service;
}

BeamAssetTotals totals(int assetId, BigInt available) {
  final z = BigInt.zero;
  return BeamAssetTotals(
    assetId: assetId,
    available: available,
    availableRegular: available,
    availableMp: z,
    receiving: z,
    receivingRegular: z,
    receivingMp: z,
    sending: z,
    sendingRegular: z,
    sendingMp: z,
    maturing: z,
    maturingRegular: z,
    maturingMp: z,
    change: z,
    locked: z,
  );
}

const synced = BeamSynced(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.agrees,
  walletHeight: 4068244,
  networkHeight: 4068244,
);

const catchingUp = BeamSyncCatchingUp(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.aheadOfWallet,
  blockInterval: Duration(minutes: 1),
  walletHeight: 4068202,
  networkHeight: 4068244,
  blocksBehind: 42,
);

/// The PIN gate as a test double: records each call and answers [result].
class FakeGate {
  FakeGate([this.result = true]);

  bool? result;
  final reasons = <String>[];

  Future<bool?> call(BuildContext context, {required String reason}) async {
    reasons.add(reason);
    return result;
  }
}

BeamDexDeps makeDeps(
  DexUiFake fake, {
  BeamSyncAssessment sync = synced,
  Map<int, BigInt> balances = const {},
  bool desktop = false,
  FakeGate? gate,
  BeamDexFiat? fiat,
}) {
  final g = gate ?? FakeGate();
  return BeamDexDeps(
    dex: fake.service,
    sync: ValueNotifier<BeamSyncAssessment>(sync),
    balances: ValueNotifier<Map<int, BeamAssetTotals>>({
      for (final e in balances.entries) e.key: totals(e.key, e.value),
    }),
    authenticate: g.call,
    fiat: fiat == null ? null : ValueNotifier<BeamDexFiat?>(fiat),
    isDesktop: desktop,
  );
}

BigInt beam(String s) {
  final parts = s.split('.');
  final frac = (parts.length > 1 ? parts[1] : '').padRight(8, '0');
  return BigInt.parse(parts[0]) * BigInt.from(100000000) + BigInt.parse(frac);
}

// ---------------------------------------------------------------- rendering

StackTheme _theme() {
  final zip = File('asset_sources/default_themes/campfire/light.zip')
      .readAsBytesSync();
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

/// The parts of the app's ThemeData (lib/main.dart) the DEX screens read.
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

/// Inter (bundled google_fonts) and Material icons, before the first
/// layout; otherwise goldens show the test font's square glyphs.
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
        ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await loader.load();
    }
  });
  _fontsLoaded = true;
}

/// A 375 × 667 phone (iPhone SE / 8), rendered at 2× for readable goldens.
const phone = Size(375, 667);

/// A 1280 × 800 desktop window.
const desktopWindow = Size(1280, 800);

const goldenKey = ValueKey('dex-golden');

Future<void> pumpDex(
  WidgetTester tester,
  Widget home, {
  Size size = phone,
  double pixelRatio = 2,
}) async {
  await loadFonts(tester);
  tester.view.physicalSize = size * pixelRatio;
  tester.view.devicePixelRatio = pixelRatio;
  addTearDown(tester.view.reset);
  final colors = StackColors.fromStackColorTheme(campfireLight);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        themeProvider.overrideWithProvider(
          StateProvider<StackTheme>((ref) => campfireLight),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme(colors),
        // Around the navigator, so pushed pages, dialogs and sheets are
        // in the golden too.
        // Reduce motion: the Beam girl's animated stickers render their
        // matching still, so goldens are deterministic.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: RepaintBoundary(key: goldenKey, child: child),
        ),
        home: home,
      ),
    ),
  );
}

/// Lets real image and SVG decoding finish (they run outside the fake
/// clock), then repaints.
Future<void> settleImages(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        final img = e.widget as Image;
        await precacheImage(img.image, e);
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pump();
  }
}

/// Types [text] into the field with [key] and waits out the 500 ms quote
/// debounce and the quote itself.
Future<void> typeAmount(WidgetTester tester, Key key, String text) async {
  await tester.enterText(find.byKey(key), text);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
  await tester.pump();
}

/// The text a [Text] or [SelectableText] with [key] shows.
String textOf(WidgetTester tester, Key key) {
  final w = tester.widget(find.byKey(key));
  if (w is Text) return w.data ?? w.textSpan!.toPlainText();
  if (w is SelectableText) return w.data ?? w.textSpan!.toPlainText();
  throw StateError('not a text widget: $w');
}

/// Fails if the widget with [key] is not fully inside the screen.
void expectOnScreen(WidgetTester tester, Key key, Size screen) {
  final r = tester.getRect(find.byKey(key));
  expect(r.top, greaterThanOrEqualTo(0), reason: '$key starts above');
  expect(r.left, greaterThanOrEqualTo(0), reason: '$key starts left');
  expect(r.bottom, lessThanOrEqualTo(screen.height), reason: '$key below');
  expect(r.right, lessThanOrEqualTo(screen.width), reason: '$key right');
}

bool get isMacHost => Platform.isMacOS && !kIsWeb;

/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Shared set-up for the Names (BANS) screen tests: a real BeamBansService
// over a FakeTransport answering from the recorded mainnet fixtures in
// test/beam/contracts/bans/fixtures, Campfire's own light theme and fonts,
// and helpers to render goldens at phone and desktop sizes.
//
// Where no recording exists (renew, transfer, list, sale proceeds) the
// transactions are built by [rawCall], a byte-exact copy of the core's
// serialisation: a test below proves it reproduces the recorded register
// kernel byte for byte. Those are labelled "synthetic" where used.
//
// Nothing here can reach a real wallet: the only transport is FakeTransport,
// and every `process_invoke_data` is recorded in [NamesUiFake.executed].

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
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans.dart';
import 'package:stackwallet/wallets/beam/models/beam_wallet_status.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/widgets/beam/names/names_deps.dart';

import '../contracts/bans/bans_fixtures.dart';

export '../contracts/bans/bans_fixtures.dart';

/// The wallet's block in every test: the height the fixtures were recorded
/// at, with its block time (2026-10-06 08:45 UTC).
const tipHeight = 4068103;
const tipTimestamp = 1791276300;

const blocksPerDay = 1440;

/// A `view_name` / `my_key` style answer around a shader [output].
Map<String, Object?> answer(String output) => {
  'output': output,
  'txid': '00000000000000000000000000000000',
};

/// A built-transaction answer: what wallet-api returns for `create_tx:
/// false`.
Map<String, Object?> built(List<int> raw) => {
  'output': '{}',
  'txid': '00000000000000000000000000000000',
  'raw_data': raw,
};

/// `view_name` for a name owned by [key], expiring at [expire], optionally
/// listed at [price] groth of [aid].
Map<String, Object?> viewName(
  String key,
  int expire, {
  int? price,
  int aid = 0,
}) => answer(
  jsonEncode({
    'res': {
      'key': key,
      'hExpire': expire,
      'price': ?(price == null ? null : {'aid': aid, 'amount': price}),
    },
  }),
);

/// `view_domain` for [names] (name → expiry, optional sale price) owned by
/// [key].
Map<String, Object?> viewDomain(
  Map<String, int> names, {
  String key = fakeMyKey,
  Map<String, int> prices = const {},
}) => answer(
  jsonEncode({
    'domains': [
      for (final e in names.entries)
        {
          'name': e.key,
          'key': key,
          'hExpire': e.value,
          'price': ?(prices[e.key] == null
              ? null
              : {'aid': 0, 'amount': prices[e.key]}),
        },
    ],
  }),
);

/// `role=user,action=view` on a Campfire core (privilege 1).
Map<String, Object?> userView({
  Map<int, int> saleProceeds = const {},
  List<Map<String, Object?>> payments = const [],
}) => answer(
  jsonEncode({
    'res': {
      'domains': <Object?>[],
      'raw': [
        for (final e in saleProceeds.entries) {'aid': e.key, 'amount': e.value},
      ],
      'anon': payments,
    },
  }),
);

// ------------------------------------------------- raw_data (yas) builder

List<int> _u(int v) {
  if (v < 128) return [0x80 | v];
  final b = <int>[];
  for (var x = v; x > 0; x >>= 8) {
    b.add(x & 0xff);
  }
  return [b.length, ...b];
}

List<int> _s(int v) {
  final a = v.abs();
  final sign = v < 0 ? 0x80 : 0;
  if (a < 64) return [sign | 0x40 | a];
  final b = <int>[];
  for (var x = a; x > 0; x >>= 8) {
    b.add(x & 0xff);
  }
  return [sign | b.length, ...b];
}

List<int> hexBytes(String h) => [
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
];

List<int> _le(int v, int n) => [
  for (var i = 0; i < n; i++) (v >> (8 * i)) & 0xff,
];

List<int> _name(String n) => [n.length, ...n.codeUnits];

/// One plain contract call serialised the way the core writes `raw_data`
/// (`bvm2::ContractInvokeData`, yas compacted little-endian).
List<int> rawCall({
  required int method,
  required String cid,
  required List<int> args,
  required String comment,
  Map<int, int> spend = const {},
  int signatures = 0,
  int charge = 80150,
}) => [
  ..._u(1),
  ..._u(method),
  ..._u(args.length),
  ...args,
  ..._u(signatures),
  for (var i = 0; i < signatures; i++) ...List.filled(32, 0x11 + i),
  ..._u(charge),
  ..._u(comment.length),
  ...comment.codeUnits,
  ..._u(spend.length),
  for (final e in spend.entries) ...[..._u(e.key), ..._s(e.value)],
  ...hexBytes(cid),
];

/// A registration of [name] for [periods] at [amount] groth.
List<int> registerRaw(String name, int periods, int amount) => rawCall(
  method: BansMethod.register,
  cid: kBansCid,
  args: [...hexBytes(fakeMyKey), periods, ..._name(name)],
  comment: BansKernelComment.register,
  spend: {0: amount},
);

/// Synthetic: a renewal of [name] for [periods] at [amount] groth.
List<int> extendRaw(String name, int periods, int amount) => rawCall(
  method: BansMethod.extend,
  cid: kBansCid,
  args: [periods, ..._name(name)],
  comment: BansKernelComment.extend,
  spend: {0: amount},
);

/// Synthetic: a transfer of [name] to [key], signed by this wallet's key.
List<int> setOwnerRaw(String name, String key) => rawCall(
  method: BansMethod.setOwner,
  cid: kBansCid,
  args: [...hexBytes(key), ..._name(name)],
  comment: BansKernelComment.setOwner,
  signatures: 1,
);

/// Synthetic: a listing of [name] at [amount] of [aid] (0 unlists).
List<int> setPriceRaw(String name, int aid, int amount) => rawCall(
  method: BansMethod.setPrice,
  cid: kBansCid,
  args: [..._le(aid, 4), ..._le(amount, 8), ..._name(name)],
  comment: BansKernelComment.setPrice,
  signatures: 1,
);

/// Synthetic: a claim of [amount] of [aid] in sale proceeds from the vault.
List<int> claimRaw(int aid, int amount) => rawCall(
  method: BansMethod.vaultWithdraw,
  cid: vaultCid,
  args: [...hexBytes(fakeMyKey), ..._le(aid, 4), ..._le(amount, 8)],
  comment: BansKernelComment.receiveRaw,
  spend: {aid: -amount},
  signatures: 1,
);

/// The recorded 1-year price of a 5+ character name (register5).
const price5 = 116213166091;

// ---------------------------------------------------------------- the core

class MemoryShaderSource implements ShaderSource {
  MemoryShaderSource(this.bytes);

  final Uint8List bytes;

  @override
  Future<Uint8List> read(String name) => Future.value(bytes);
}

/// The pinned BANS shader's bytes, read once (synchronously: a real file
/// read never completes inside a widget test's fake clock).
final Uint8List bansShaderBytes = File('assets/beam/shaders/$kBansShaderName')
    .readAsBytesSync();

/// A wallet core that answers `invoke_contract` from [routes], keyed by
/// `action:name`, then `action`. A route is a fixture name (String), an
/// answer map, or a function of the call count returning either.
class NamesUiFake {
  NamesUiFake(this.routes, {this.txId = 'ab12cd34ef56ab12cd34ef56ab12cd34'}) {
    transport = FakeTransport({
      'wallet_status': {
        'current_height': tipHeight,
        'current_state_hash': 'ab' * 32,
        'current_state_timestamp': tipTimestamp,
        'prev_state_hash': 'cd' * 32,
        'is_in_sync': true,
      },
      'invoke_contract': (Map<String, Object?> p) {
        // Plain throws, not expect(): this runs inside guarded test calls
        // such as enterText. A violation surfaces as a failed call.
        if (p['create_tx'] != false) {
          throw StateError('create_tx must be false');
        }
        if ((p['contract']! as List).length != kBansShaderSize) {
          throw StateError('not the pinned BANS shader');
        }
        final args = p['args']! as String;
        seenArgs.add(args);
        final action = RegExp(r'action=([a-z_]+)').firstMatch(args)!.group(1)!;
        final name = RegExp(r'name=([^,]*)').firstMatch(args)?.group(1);
        final key = routes.containsKey('$action:$name')
            ? '$action:$name'
            : action;
        final route = routes[key];
        if (route == null) throw StateError('no route for $args');
        final n = counts[key] = (counts[key] ?? 0) + 1;
        final r = route is Object? Function(int) ? route(n) : route;
        return r is String ? bansEnvelope(r) : r;
      },
      'process_invoke_data': (Map<String, Object?> p) {
        executed.add(List<int>.from(p['data']! as List));
        return {'txid': txId};
      },
    });
    service = BeamBansService(
      BeamApi(transport),
      null,
      shader: bansAppShader(MemoryShaderSource(bansShaderBytes)),
    );
  }

  final Map<String, Object?> routes;
  final String txId;
  final seenArgs = <String>[];
  final counts = <String, int>{};
  final executed = <List<int>>[];
  late final FakeTransport transport;
  late final BeamBansService service;

  /// Every shader call asked only for a build (`create_tx: false`) with
  /// the pinned shader, and nothing was sent except [executed].
  void expectOnlyBuilds() {
    for (final c in transport.callsTo('invoke_contract')) {
      expect(c.params['create_tx'], isFalse);
      expect((c.params['contract']! as List).length, kBansShaderSize);
    }
    expect(
      transport.callsTo('process_invoke_data'),
      hasLength(executed.length),
    );
  }

  /// The actions asked of the shader, in order.
  List<String> get actions => [
    for (final a in seenArgs)
      RegExp(r'action=([a-z_]+)').firstMatch(a)!.group(1)!,
  ];
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
  walletHeight: tipHeight,
  networkHeight: tipHeight,
);

const catchingUp = BeamSyncCatchingUp(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.aheadOfWallet,
  blockInterval: Duration(minutes: 1),
  walletHeight: tipHeight - 42,
  networkHeight: tipHeight,
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

BigInt beam(String s) {
  final parts = s.split('.');
  final frac = (parts.length > 1 ? parts[1] : '').padRight(8, '0');
  return BigInt.parse(parts[0]) * BigInt.from(100000000) + BigInt.parse(frac);
}

BeamNamesDeps makeDeps(
  NamesUiFake fake, {
  BeamSyncAssessment sync = synced,
  Map<int, BigInt>? balances,
  bool desktop = false,
  FakeGate? gate,
  VoidCallback? onAddFunds,
}) {
  final g = gate ?? FakeGate();
  return BeamNamesDeps(
    bans: fake.service,
    sync: ValueNotifier<BeamSyncAssessment>(sync),
    balances: ValueNotifier<Map<int, BeamAssetTotals>>({
      for (final e in (balances ?? {0: beam('150000')}).entries)
        e.key: totals(e.key, e.value),
    }),
    authenticate: g.call,
    onAddFunds: onAddFunds,
    isDesktop: desktop,
  );
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

ThemeData appTheme(StackColors colors) => ThemeData(
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

/// Wraps the whole navigator, so pushed pages and dialogs are captured.
const goldenKey = ValueKey('names-golden');

Future<void> pumpNames(
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
        // Stills instead of animations: deterministic goldens.
        builder: (context, child) => RepaintBoundary(
          key: goldenKey,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
        ),
        home: home,
      ),
    ),
  );
}

/// Opens [page] from a button the way the app does (pushed on mobile, a
/// dialog on desktop), so a test can drive it and see what it pops.
class Launcher extends StatelessWidget {
  const Launcher({super.key, required this.open, this.onResult});

  final Future<Object?> Function(BuildContext context) open;
  final void Function(Object? result)? onResult;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const Key('launch'),
        onPressed: () async {
          final result = await open(context);
          onResult?.call(result);
        },
        child: const Text('open'),
      ),
    ),
  );
}

/// Lets real image decoding finish (it runs outside the fake clock), then
/// repaints.
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

/// Lets the BANS calls and any pushes finish.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// Types [text] into the field with [key] and waits out the lookup
/// debounce and the lookup itself.
Future<void> typeName(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('names-register-field')), text);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await settle(tester);
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

Future<void> golden(WidgetTester tester, String name) async {
  await settleImages(tester);
  await expectLater(
    find.byKey(goldenKey),
    matchesGoldenFile('goldens/$name.png'),
  );
}

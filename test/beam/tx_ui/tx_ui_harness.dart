/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Shared setup for the BEAM history / details tests: transactions built from
// the sanitized `tx_list.json` fixture and mapped through the committed
// BeamTxMapper, a fake core (FakeTransport), Campfire's light theme with its
// own tx icons, and the Inter font, so goldens look like the app.
//
// Every id, kernel and address below is made up (`fakeHex`); the fixture's
// own ids are replaced before anything is rendered.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/themes/theme_providers.dart';
import 'package:stackwallet/utilities/amount/amount_formatter.dart';
import 'package:stackwallet/utilities/amount/amount_unit.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_tx_mapper.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/providers/wallet_info_provider.dart';
import 'package:stackwallet/widgets/beam/tx/beam_tx_backend.dart';

const kWalletId = 'beam-tx-ui-test-wallet';
final kBeam = Beam(CryptoCurrencyNetwork.main);

/// A made-up hex string: never a real id, kernel or address.
String fakeHex(int seed, int length) => List.generate(
  length,
  (i) => '0123456789abcdef'[(seed * 7 + i * 3 + i ~/ 5) % 16],
).join();

final kOwnAddress = fakeHex(1, 66);
final kPeerAddress = fakeHex(2, 66);

// ------------------------------------------------------------------ fixtures

List<Map<String, Object?>> _fixture() {
  final env = jsonDecode(
    File('test/beam/fixtures/tx_list.json').readAsStringSync(),
  ) as Map<String, Object?>;
  return [
    for (final e in env['result']! as List<Object?>)
      Map<String, Object?>.from(e! as Map),
  ];
}

/// The fixture's completed regular payment (`"status_string": "sent"`).
Map<String, Object?> _simpleBase() =>
    _fixture().firstWhere((t) => t['tx_type'] == 0 && t['status'] == 3);

/// The fixture's DEX-shaped contract call: BEAM out, asset 187 in.
Map<String, Object?> _swapBase() =>
    _fixture().firstWhere((t) => t['comment'] == 'Sample note 23');

/// The fixture's fee-only contract call.
Map<String, Object?> _feeOnlyBase() => _fixture().firstWhere(
  (t) => t['tx_type'] == 12 && t['fee_only'] == true && t['status'] == 3,
);

/// One BEAM transaction as the core reports it, rebuilt from the fixture
/// with synthetic ids.
Map<String, Object?> simpleTxJson({
  required int seed,
  required BeamTxStatus status,
  bool income = false,
  String? failure,
  String comment = '',
  int value = 10000000,
  int createTime = 1722558627,
}) {
  final t = _simpleBase();
  t['txId'] = fakeHex(seed, 32);
  t['status'] = status.code;
  t['status_string'] = status.name;
  t['income'] = income;
  t['value'] = value;
  t['comment'] = comment;
  t['create_time'] = createTime;
  t['sender'] = income ? kPeerAddress : kOwnAddress;
  t['receiver'] = income ? kOwnAddress : kPeerAddress;
  t.remove('sender_identity');
  t.remove('receiver_identity');
  if (status == BeamTxStatus.completed) {
    t['kernel'] = fakeHex(seed + 100, 64);
  } else {
    t.remove('kernel');
    t.remove('height');
    t.remove('confirmations');
  }
  if (failure != null) {
    t['failure_reason'] = failure;
  } else {
    t.remove('failure_reason');
  }
  return t;
}

/// A contract call from the fixture. [dex] points it at the DEX contract so
/// Campfire knows what it was; otherwise it keeps an unknown contract id.
Map<String, Object?> contractTxJson({
  required int seed,
  bool dex = true,
  bool feeOnly = false,
  int? otherAsset,
  int createTime = 1721672252,
}) {
  final t = feeOnly ? _feeOnlyBase() : _swapBase();
  t['txId'] = fakeHex(seed, 32);
  t['kernel'] = fakeHex(seed + 100, 64);
  t['status'] = BeamTxStatus.completed.code;
  t['create_time'] = createTime;
  t.remove('failure_reason');
  final invoke = [
    for (final i in t['invoke_data']! as List<Object?>)
      Map<String, Object?>.from(i! as Map),
  ];
  for (final i in invoke) {
    i['contract_id'] = dex ? kDexContractId : fakeHex(seed + 200, 64);
    if (otherAsset != null) {
      i['amounts'] = [
        for (final a in i['amounts']! as List<Object?>)
          {
            ...Map<String, Object?>.from(a! as Map),
            if ((a as Map)['asset_id'] != 0) 'asset_id': otherAsset,
            if (a['asset_id'] != 0) 'amount': -100000000,
          },
      ];
    }
  }
  t['invoke_data'] = invoke;
  return t;
}

/// [json] through the committed mapper, as the wallet stores it.
TransactionV2 mapped(Map<String, Object?> json) => BeamTxMapper.map(
  BeamTransaction.fromJson(json),
  walletId: kWalletId,
  ownAddresses: {kOwnAddress},
);

// ------------------------------------------------------------- fake backend

/// A [BeamTxBackend] over a [FakeTransport], recording what the screens do.
class FakeTxBackend {
  FakeTxBackend([Map<String, Object?> replies = const {}])
    : transport = FakeTransport(replies);

  final FakeTransport transport;
  int refreshes = 0;
  final forgotten = <String>[];
  final opened = <Uri>[];
  final shared = <String>[];
  bool skipWarning = false;
  final _records = StreamController<TransactionV2?>.broadcast();

  /// Answers `tx_status` for [txs] the way the core does.
  void serveTxStatus(List<Map<String, Object?>> txs) {
    transport.reply(
      'tx_status',
      (Map<String, Object?> params) =>
          txs.firstWhere((t) => t['txId'] == params['txId']),
    );
  }

  /// The wallet re-stored [tx] (e.g. after a refresh).
  void update(TransactionV2? tx) => _records.add(tx);

  late final BeamTxBackend backend = BeamTxBackend(
    api: () => BeamApi(transport),
    refresh: () async => refreshes++,
    forget: (txid) async => forgotten.add(txid),
    watch: (_) => _records.stream,
    explorerUri: kBeam.defaultBlockExplorer,
    openUrl: (uri) async {
      opened.add(uri);
      return true;
    },
    share: (text) async => shared.add(text),
    skipExplorerWarning: () => skipWarning,
    setSkipExplorerWarning: (skip) => skipWarning = skip,
  );
}

// -------------------------------------------------------------------- theme

StackTheme _campfireLight() {
  final zip = File('asset_sources/default_themes/campfire/light.zip')
      .readAsBytesSync();
  final themeJson = ZipDecoder()
      .decodeBytes(zip)
      .files
      .singleWhere((f) => f.name == 'theme.json');
  final json = jsonDecode(utf8.decode(themeJson.content as List<int>)) as Map;
  return StackTheme.fromJson(json: Map<String, dynamic>.from(json));
}

/// Campfire's tx icons from the light theme, unpacked once per run.
class _ThemeIcons implements IThemeAssets {
  _ThemeIcons(this.dir);

  final String dir;

  String _svg(String name) => '$dir/assets/svg/$name';

  @override
  String get send => _svg('tx-icon-send.svg');
  @override
  String get sendPending => _svg('tx-icon-send-pending.svg');
  @override
  String get sendCancelled => _svg('tx-icon-send-failed.svg');
  @override
  String get receive => _svg('tx-icon-receive.svg');
  @override
  String get receivePending => _svg('tx-icon-receive-pending.svg');
  @override
  String get receiveCancelled => _svg('tx-icon-receive-failed.svg');

  @override
  dynamic noSuchMethod(Invocation invocation) => '';
}

_ThemeIcons? _icons;

_ThemeIcons _themeIcons() {
  final cached = _icons;
  if (cached != null) return cached;
  final dir = Directory.systemTemp.createTempSync('cfb_txui_theme');
  final zip = File('asset_sources/default_themes/campfire/light.zip')
      .readAsBytesSync();
  for (final f in ZipDecoder().decodeBytes(zip).files) {
    if (f.isFile && f.name.startsWith('assets/svg/tx-icon-')) {
      File('${dir.path}/${f.name}')
        ..createSync(recursive: true)
        ..writeAsBytesSync(f.content as List<int>);
    }
  }
  return _icons = _ThemeIcons(dir.path);
}

final StackTheme _light = _campfireLight();
final StackColors kColors = StackColors.fromStackColorTheme(_light);

// The parts of lib/main.dart's ThemeData that Campfire's widgets read.
ThemeData _appTheme(StackColors colors) => ThemeData(
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

/// Inter from the bundled google_fonts/ assets, before the first layout.
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

/// Phone: 375 × 812 logical at 2×. Desktop: 1100 × 820 at 1×.
void setSurface(WidgetTester tester, {required bool desktop, double? h}) {
  if (desktop) {
    tester.view.physicalSize = Size(1100, h ?? 820);
    tester.view.devicePixelRatio = 1.0;
  } else {
    tester.view.physicalSize = Size(750, (h ?? 812) * 2);
    tester.view.devicePixelRatio = 2.0;
  }
  addTearDown(tester.view.reset);
}

const kShot = ValueKey('beam-tx-ui-shot');

/// [home] inside Campfire's theme with every BEAM provider faked.
Widget app({
  required Widget home,
  required FakeTxBackend fake,
  required bool desktop,
  RouteFactory? onGenerateRoute,
}) {
  return RepaintBoundary(
    key: kShot,
    child: ProviderScope(
      overrides: [
        pBeamTxIsDesktop.overrideWithValue(desktop),
        pBeamTxBackend.overrideWithProvider(
          (_) => Provider<BeamTxBackend>((_) => fake.backend),
        ),
        pBeamTxFiat.overrideWithProvider(
          (_) => Provider<BeamTxFiat?>((_) => null),
        ),
        pAmountFormatter.overrideWithProvider(
          (coin) => Provider<AmountFormatter>(
            (_) => AmountFormatter(
              unit: AmountUnit.normal,
              locale: 'en_US',
              coin: coin,
              maxDecimals: 8,
            ),
          ),
        ),
        pWalletCoin.overrideWithProvider(
          (_) => Provider<CryptoCurrency>((_) => kBeam),
        ),
        themeAssetsProvider.overrideWithValue(
          StateController<IThemeAssets>(_themeIcons()),
        ),
        // Background reads the theme for an optional background image.
        themeProvider.overrideWithValue(StateController<StackTheme>(_light)),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _appTheme(kColors),
        home: home,
        onGenerateRoute: onGenerateRoute,
      ),
    ),
  );
}

/// Lets SVG files and sticker images load (real IO and decoding) and every
/// animation finish.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() async {
    for (final e in find.byType(Image).evaluate()) {
      await precacheImage((e.widget as Image).image, e);
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });
  await tester.pumpAndSettle();
}

/// Captures what was copied to the clipboard.
List<String> captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

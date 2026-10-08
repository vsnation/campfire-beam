/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Shared set-up for the BEAM Send screen tests: Campfire's own light theme
// and Inter fonts, a ProviderScope with only what the send flow reads, and
// a backend whose name lookups and name payments run the real
// BeamBansService over FakeTransport (recorded wallet-api answers), while
// the wallet part (sync, balances, prepareSend/confirmSend) is scripted and
// logged. The real BeamWallet path is covered by
// beam_send_backend_wallet_test.dart.
//
// No real key, password or address: keys are public chain data from the
// BANS fixtures, addresses are BEAM core test vectors.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:isar_community/isar.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/providers/desktop/storage_crypto_handler_provider.dart';
import 'package:stackwallet/themes/coin_image_provider.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/themes/theme_providers.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/utilities/constants.dart';
import 'package:stackwallet/utilities/desktop_password_service.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_catalog.dart';
import 'package:stackwallet/wallets/beam/models/beam_asset_info.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_send_rules.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_errors.dart';
import 'package:stackwallet/wallets/models/tx_data.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_backend.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_widgets.dart';

import '../contracts/bans/bans_fixtures.dart';
import '../wallet/beam_wallet_test_support.dart' show openTestMainDb;

const kTip = 4068103;

/// 1 BEAM in groth.
final BigInt beam1 = BigInt.from(100000000);

BigInt g(num beam) => BigInt.from((beam * 100000000).round());

/// A regular BEAM address (public BEAM core test vector).
String vectorAddress(String type) =>
    ((jsonDecode(
                  File('test/beam/fixtures/beam_core_address_vectors.json')
                      .readAsStringSync(),
                ) as Map)['valid']
                as List)
            .cast<Map<String, Object?>>()
            .firstWhere((v) => v['type'] == type)['address']!
        as String;

const synced = BeamSynced(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.agrees,
  walletHeight: kTip,
  networkHeight: kTip,
);

const catchingUp = BeamSyncCatchingUp(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.agrees,
  blockInterval: Duration(seconds: 60),
  walletHeight: kTip - 42,
  networkHeight: kTip,
  blocksBehind: 42,
);

// ---------------------------------------------------------------- shader

class _BytesSource implements ShaderSource {
  _BytesSource(this._bytes);

  final Uint8List _bytes;

  @override
  Future<Uint8List> read(String name) async => _bytes;
}

/// The pinned BANS shader, read synchronously (widget tests cannot await
/// real file I/O) and still checked against its pin by PinnedShader.
PinnedShader syncRepoShader() => bansAppShader(
  _BytesSource(File('assets/beam/shaders/$kBansShaderName').readAsBytesSync()),
);

// ------------------------------------------------------------- core fakes

Map<String, Object?> invokeEnvelope(String output, {List<int>? raw}) => {
  'jsonrpc': '2.0',
  'id': 1,
  'result': {'output': output, 'txid': '0' * 32, 'raw_data': ?raw},
};

/// `view_name` output for a registered name.
String viewNameOutput(String key, int hExpire) =>
    '{"res": {"key": "$key","hExpire": $hExpire}}';

/// Answers `invoke_contract` by action and name. [names] maps a name to a
/// fixture name, an envelope, or an Exception to throw.
class BansCore {
  BansCore() {
    transport = FakeTransport({
      'wallet_status': (Map<String, Object?> _) => {
        'current_height': kTip,
        'current_state_hash': 'ab' * 32,
        'current_state_timestamp': 1791276300,
        'prev_state_hash': 'cd' * 32,
        'is_in_sync': true,
      },
      'invoke_contract': _invoke,
      'process_invoke_data': (Map<String, Object?> _) => {'txid': sentTxId},
    });
  }

  late final FakeTransport transport;
  final Map<String, Object?> names = {
    'beam': 'view_name_beam',
    'onhold': 'view_name_hold',
    'listed': 'view_name_listed',
    'nobody': 'view_name_free',
  };

  /// A `pay` builds the recorded `pay_beam` kernel (12345 groth of BEAM to
  /// `beam`, fee 0.011 BEAM), whatever the name.
  String payFixture = 'pay_beam';
  String sentTxId = 'ee' * 16;

  /// When set, `view_name` answers from here instead (owner changes).
  Object? Function(String name)? override;

  static String _action(Map<String, Object?> p) =>
      RegExp(r'action=([a-z_]+)').firstMatch(p['args']! as String)!.group(1)!;

  Object? _invoke(Map<String, Object?> p) {
    final action = _action(p);
    final name = RegExp(r'name=([^,]*)')
        .firstMatch(p['args']! as String)
        ?.group(1);
    switch (action) {
      case 'view_params':
        return bansEnvelope('view_params');
      case 'pay':
        return bansEnvelope(payFixture);
      case 'view_name':
        final o = override?.call(name!);
        final reply = o ?? names[name];
        if (reply == null) return bansEnvelope('view_name_free');
        if (reply is String) {
          return reply.startsWith('{')
              ? invokeEnvelope(reply)
              : bansEnvelope(reply);
        }
        return reply;
    }
    throw StateError('no fixture for $action');
  }

  List<String> get actions => [
    for (final c in transport.callsTo('invoke_contract')) _action(c.params),
  ];

  int get broadcasts => transport.callsTo('process_invoke_data').length;
}

// ----------------------------------------------------------- the backend

class _Hold implements BeamSendHold {
  _Hold(this._log);

  final List<String> _log;
  bool released = false;

  @override
  void release() {
    if (released) return;
    released = true;
    _log.add('release');
  }
}

/// Wallet side scripted, BANS side real over [BansCore].
class ScriptedBackend implements BeamSendBackend {
  ScriptedBackend({
    this._sync = synced,
    Map<int, BigInt>? balances,
    BansCore? core,
  }) : balances = balances ?? {0: g(2)},
       core = core ?? BansCore() {
    bans = BeamBansService(
      BeamApi(this.core.transport),
      null,
      shader: syncRepoShader(),
    );
  }

  final BansCore core;
  late final BeamBansService bans;
  Map<int, BigInt> balances;
  BeamSyncAssessment _sync;
  final _syncs = StreamController<BeamSyncAssessment>.broadcast();

  /// Every wallet-side call, in order: prepareSend, confirmSend,
  /// preparePay, executePay, hold, release, note:<txid>, refresh.
  final List<String> log = [];
  final List<TxData> confirmed = [];
  String addressTxId = 'ab' * 16;
  Object? confirmError;

  void setSync(BeamSyncAssessment a) {
    _sync = a;
    _syncs.add(a);
  }

  @override
  BeamSyncAssessment get syncAssessment => _sync;

  @override
  Stream<BeamSyncAssessment> get syncAssessments => _syncs.stream;

  @override
  Map<int, BigInt> spendable() => Map.of(balances);

  /// Change on its way back from unfinished payments, per asset.
  Map<int, BigInt> back = {};

  @override
  Map<int, BigInt> returning() => Map.of(back);

  /// On-chain metadata of unverified assets, by id.
  final Map<int, String> metadata = {};

  @override
  BeamAssetDisplay asset(int assetId) => BeamAssetCatalog.display(
    assetId,
    metadata[assetId] == null
        ? null
        : BeamAssetMetadata.parse(metadata[assetId]!),
  );

  @override
  Future<void> loadAssetNames(Iterable<int> assetIds) async {}

  @override
  Future<BansResolution> resolveName(BansName name) => bans.resolve(name);

  @override
  Future<BigInt> estimateAddressFee(BigInt amount) async => kBeamDefaultFee;

  /// Mirrors BeamWallet.prepareSend's rules (sync, address type, BEAM only,
  /// the fee out of a whole-balance send).
  @override
  Future<TxData> prepareSend(TxData txData) async {
    log.add('prepareSend');
    BeamSendRules.checkSynced(_sync);
    final r = txData.recipients!.single;
    final mode = BeamSendMode.forType(BeamSendRules.checkAddress(r.address));
    final other = txData.otherData;
    if (other != null && (jsonDecode(other) as Map)['assetId'] != 0) {
      throw const BeamWalletException(
        BeamWalletProblem.other,
        'Sending Confidential Assets is not available yet.',
      );
    }
    final fee = mode.minimumFee;
    final send = BeamSendRules.checkAmount(
      amount: r.amount.raw,
      fee: fee,
      available: balances[0] ?? BigInt.zero,
    );
    return txData.copyWith(
      recipients: [
        r.copyWith(amount: Amount(rawValue: send, fractionDigits: 8)),
      ],
      fee: Amount(rawValue: fee, fractionDigits: 8),
    );
  }

  @override
  Future<String> confirmSend(TxData txData) async {
    log.add('confirmSend');
    final e = confirmError;
    if (e != null) throw e;
    confirmed.add(txData);
    return addressTxId;
  }

  @override
  Future<BansPrepared> preparePay(
    BansName name,
    int assetId,
    BigInt amount, {
    required String expectedOwnerKey,
  }) {
    log.add('preparePay');
    return bans.preparePay(
      name,
      assetId,
      amount,
      expectedOwnerKey: expectedOwnerKey,
    );
  }

  @override
  Future<String> executePay(BansPrepared prepared) {
    log.add('executePay');
    beamCheckCanSpend(this);
    return bans.execute(prepared);
  }

  @override
  BeamSendHold holdNodeSwitch(String reason, {Duration? maxHold}) {
    log.add('hold');
    return _Hold(log);
  }

  @override
  Future<void> saveNote(String txId, String note) async =>
      log.add('note:$txId');

  @override
  void refresh() => log.add('refresh');
}

// ------------------------------------------------------------ the theme

Map<String, dynamic> _campfireThemeJson() {
  final zip = File('asset_sources/default_themes/campfire/light.zip')
      .readAsBytesSync();
  final themeJson = ZipDecoder()
      .decodeBytes(zip)
      .files
      .singleWhere((f) => f.name == 'theme.json');
  final json = Map<String, dynamic>.from(
    jsonDecode(utf8.decode(themeJson.content as List<int>)) as Map,
  );
  // Theme files live in the app's data folder, which tests do not have;
  // drop the one optional file asset the send flow would read (the
  // loading GIF falls back to Campfire's bundled Lottie loader).
  final assets = Map<String, dynamic>.from(json['assets'] as Map);
  assets['loading_gif'] = null;
  json['assets'] = assets;
  return json;
}

final StackTheme campfireLight = StackTheme.fromJson(
  json: _campfireThemeJson(),
);

/// The parts of the app's ThemeData (lib/main.dart, MaterialApp.theme)
/// the send flow reads: buttons, app bar, filled input fields.
ThemeData campfireThemeData(StackColors colors) {
  InputBorder border() => OutlineInputBorder(
    borderSide: BorderSide(width: 1, color: colors.textFieldDefaultBG),
    borderRadius: BorderRadius.circular(Constants.size.circularBorderRadius),
  );
  return ThemeData(
    extensions: [colors],
    highlightColor: colors.highlight,
    brightness: colors.brightness,
    fontFamily: GoogleFonts.inter().fontFamily,
    unselectedWidgetColor: colors.radioButtonBorderDisabled,
    splashColor: Colors.transparent,
    buttonTheme: ButtonThemeData(splashColor: colors.splash),
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
    primaryColor: colors.accentColorDark,
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
      enabledBorder: border(),
      focusedBorder: border(),
      errorBorder: border(),
      disabledBorder: border(),
      focusedErrorBorder: border(),
    ),
  );
}

/// Desktop password check: "correct horse" opens, anything else does not.
class FakeDps implements DPS {
  final List<String> tried = [];

  @override
  Future<bool> verifyPassphrase(String passphrase) async {
    tried.add(passphrase);
    return passphrase == 'correct horse';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
    }
    await GoogleFonts.pendingFonts();
  });
}

const goldenKey = ValueKey('beam-send-golden');

/// A phone (375 x 667, the smallest common screen) or a desktop window.
Future<void> setScreen(WidgetTester tester, {required bool desktop}) async {
  tester.view.physicalSize = desktop
      ? const Size(1280, 860)
      : const Size(375 * 2, 667 * 2);
  tester.view.devicePixelRatio = desktop ? 1.0 : 2.0;
  addTearDown(tester.view.reset);
}

/// Pumps [home] in Campfire's theme with only what the send flow reads.
/// Animations are off, as with the system's reduce-motion setting, so the
/// Beam girl shows her still sticker and goldens are stable.
Future<FakeDps> pumpCampfire(
  WidgetTester tester, {
  required Widget home,
  required bool desktop,
  String homeRouteName = '/',
}) async {
  await loadCampfireFonts(tester);
  final colors = StackColors.fromStackColorTheme(campfireLight);
  final dps = FakeDps();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        themeProvider.overrideWithProvider(
          StateProvider<StackTheme>((ref) => campfireLight),
        ),
        coinImageSecondaryProvider.overrideWithProvider(
          (coin) => Provider<String>((_) => 'none.png'),
        ),
        storageCryptoHandlerProvider.overrideWithValue(dps),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: campfireThemeData(colors),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: RepaintBoundary(
            key: goldenKey,
            child: BeamSendLayout(desktop: desktop, child: child!),
          ),
        ),
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: RouteSettings(name: homeRouteName),
          builder: (context) => desktop
              ? Scaffold(
                  backgroundColor: colors.background,
                  body: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: 600,
                        child: SingleChildScrollView(child: home),
                      ),
                    ),
                  ),
                )
              : home,
        ),
      ),
    ),
  );
  await tester.pump();
  return dps;
}

/// Waits out the name lookup debounce and the fake core.
Future<void> settleLookup(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump();
  await tester.pump();
}

/// Lets bundled images and SVGs finish loading (real I/O) before a golden.
Future<void> settleAssets(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final e in find.byType(Image).evaluate()) {
      final image = (e.widget as Image).image;
      await precacheImage(image, e);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pump();
  await tester.pump();
}

/// Opens the test Isar (beam_wallet_test_support.openTestMainDb), retrying
/// while another test file in the same run is still downloading the Isar
/// core library to the same path (a half-written file fails to load).
Future<Isar> openTestMainDbShared(Directory dir) async {
  for (var attempt = 1; ; attempt++) {
    try {
      return await openTestMainDb(dir);
    } catch (e) {
      if (attempt >= 5) rethrow;
      await Future<void>.delayed(Duration(seconds: 2 * attempt));
    }
  }
}

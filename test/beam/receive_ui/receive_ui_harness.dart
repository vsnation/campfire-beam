/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Shared set-up for the BEAM Receive screen tests: a real BeamWallet whose
// core sessions run on FakeTransport (beam_wallet_test_support.dart), the
// sanitized addr_list fixture, Campfire's own light theme and fonts, and
// the real Campfire screens (ReceiveView, DesktopReceive,
// WalletAddressesView) with their BEAM branches.
//
// No real address, key or name: addresses come from the sanitized fixtures
// or are synthetic; the BANS name "alice" and its key are made up.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:isar_community/isar.dart';
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/providers/global/wallets_provider.dart';
import 'package:stackwallet/route_generator.dart';
import 'package:stackwallet/services/wallets.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/themes/theme_providers.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_service.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_process.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_progress.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_services.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';
import 'package:stackwallet/widgets/beam/receive/beam_receive_backend.dart';

import '../wallet/beam_wallet_test_support.dart';

const chainHeight = 4100000;

// ------------------------------------------------------------- fixtures

List<Map<String, Object?>> fixtureAddrs() =>
    ((jsonDecode(File('test/beam/fixtures/addr_list.json').readAsStringSync())
                as Map)['result']!
            as List)
        .cast<Map<String, Object?>>()
        .map(Map<String, Object?>.of)
        .toList();

/// The fixture's one unexpired address (regular, never expires).
String fixtureCurrent() => fixtureAddrs()
    .singleWhere((a) => a['expired'] == false)['address']! as String;

/// A sanitized fixture token of [type] (offline, max_privacy,
/// public_offline).
String fixtureToken(String type) =>
    fixtureAddrs().firstWhere((a) => a['type'] == type)['address']! as String;

/// A synthetic regular (hex) address, distinct per [n].
String syntheticRegular(int n) =>
    '5e${n.toRadixString(16).padLeft(2, '0')}${'7c' * 31}';

const fakeBansKey =
    '5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a00';

/// The pinned BANS shader, read synchronously (a real file read never
/// completes inside a widget test's fake clock).
final Uint8List bansShaderBytes = File(
  'assets/beam/shaders/$kBansShaderName',
).readAsBytesSync();

class MemoryShaderSource implements ShaderSource {
  MemoryShaderSource(this.bytes);

  final Uint8List bytes;

  @override
  Future<Uint8List> read(String name) => Future.value(bytes);
}

/// The wallet core as every fake session presents it. Mutable between
/// steps; all sessions share it, so a node switch keeps the same state.
class ReceiveCore {
  ReceiveCore({List<Map<String, Object?>>? addrs})
    : addrs = addrs ?? fixtureAddrs();

  List<Map<String, Object?>> addrs;
  final created = <Map<String, Object?>>[];
  final edited = <Map<String, Object?>>[];
  final deleted = <Map<String, Object?>>[];
  final bansActions = <String>[];

  /// BANS names this wallet owns; null makes the core refuse the BANS
  /// key (an unpatched core without privilege 1).
  List<String>? names = const [];
  int _made = 0;

  /// Made-address create times count up from here (seconds).
  int createTime = 1790000000;

  Map<String, Object?> _entry(String address, String type, int at) => {
    'address': address,
    'category': '',
    'comment': '',
    'create_time': at,
    'duration': type == 'regular' || type == 'public_offline' ? 0 : 5270400,
    'expired': false,
    'identity': '${'cd' * 31}${_made.toRadixString(16).padLeft(2, '0')}',
    'own': true,
    'own_id': 9000 + _made,
    'own_id_str': '${9000 + _made}',
    'type': type,
    'wallet_id': type == 'regular' ? address : 'ab' * 33,
  };

  Map<String, Object?> replies() => {
    'ev_subunsub': true,
    'wallet_status': (Map<String, Object?> _) =>
        statusJson(height: chainHeight, available: BigInt.from(5000000)),
    'addr_list': (Map<String, Object?> _) => [
      for (final a in addrs) Map<String, Object?>.of(a),
    ],
    'tx_list': (Map<String, Object?> _) => const <Object?>[],
    'create_address': (Map<String, Object?> p) {
      created.add(p);
      _made++;
      final type = p['type'] as String? ?? 'regular';
      final token = type == 'regular'
          ? syntheticRegular(_made)
          : fixtureToken(type);
      addrs = [...addrs, _entry(token, type, createTime + _made)];
      return token;
    },
    'edit_address': (Map<String, Object?> p) {
      edited.add(p);
      addrs = [
        for (final a in addrs)
          a['address'] == p['address'] && p['comment'] != null
              ? ({...a, 'comment': p['comment']})
              : a,
      ];
      return 'done';
    },
    'delete_address': (Map<String, Object?> p) {
      deleted.add(p);
      addrs = addrs.where((a) => a['address'] != p['address']).toList();
      return 'done';
    },
    'invoke_contract': (Map<String, Object?> p) {
      final args = p['args']! as String;
      final action = RegExp(r'action=([a-z_]+)').firstMatch(args)![1]!;
      bansActions.add(action);
      final mine = names;
      if (mine == null) {
        // How a core without the BANS privilege refuses the key derivation.
        throw const BeamRpcException(
          -32603,
          'Shader error',
          'get_PkEx: not allowed',
        );
      }
      final output = switch (action) {
        'my_key' => {
          'res': {'key': fakeBansKey},
        },
        'view_domain' => {
          'domains': [
            for (final n in mine)
              {'name': n, 'key': fakeBansKey, 'hExpire': chainHeight + 400000},
          ],
        },
        _ => throw StateError('unexpected BANS action $action'),
      };
      return {'output': jsonEncode(output), 'txid': ''};
    },
  };
}

/// A private beam-node that does what the test tells it.
class FakePrivateNode implements BeamPrivateNode {
  final _controller = StreamController<BeamNodeProgress>.broadcast();
  String? keyReceived;

  @override
  int? port = 40123;

  @override
  BeamNodeProgress progress = const BeamNodeProgress();

  @override
  Stream<BeamNodeProgress> get progressStream => _controller.stream;

  void emit(BeamNodeProgress next) {
    progress = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  @override
  Future<void> start({
    required String ownerKey,
    required String password,
  }) async {
    keyReceived = ownerKey;
    emit(progress.copyWith(ownerAccounts: 1));
  }

  @override
  Future<void> stop() async {
    if (!_controller.isClosed) await _controller.close();
  }
}

// --------------------------------------------------------------- world

/// One BEAM wallet on a fake core, plus what the screens did with it.
class ReceiveWorld {
  ReceiveWorld._(this.root, this.core, this.host, this.explorer, this.secure);

  final String root;
  final ReceiveCore core;
  final FakeBeamHost host;
  final FakeExplorer explorer;
  final FakeSecureStorage secure;
  final nodes = <FakePrivateNode>[];
  final log = <String>[];
  final shared = <String>[];
  final nodeSettingsOpened = <bool>[];
  late BeamWallet wallet;

  /// Creates the world and installs its environment. [privateNodeDevice]:
  /// this device can run the private node; [privateNodeOn]: the setting.
  static Future<ReceiveWorld> create(
    Directory tmp, {
    ReceiveCore? core,
    bool privateNodeDevice = true,
    bool privateNodeOn = false,
  }) async {
    final root = (await Directory(
      '${tmp.path}/root-${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true)).path;
    final c = core ?? ReceiveCore();
    final w = ReceiveWorld._(
      root,
      c,
      FakeBeamHost(replies: c.replies),
      FakeExplorer(chainHeight),
      FakeSecureStorage(),
    );
    BeamWalletEnvironment.instance = BeamWalletEnvironment(
      beamRoot: () async => root,
      createHost: (_) => w.host,
      createExplorer: () => w.explorer,
      createPrivateNode: privateNodeDevice
          ? (_, _) {
              final n = FakePrivateNode();
              w.nodes.add(n);
              return n;
            }
          : null,
      privateNodeSetting: BeamFixedPrivateNodeSetting(privateNodeOn),
      explorerPollInterval: const Duration(milliseconds: 200),
      statusPollInterval: const Duration(hours: 1),
      eventDebounce: const Duration(milliseconds: 20),
      privateNodeStartDelay: Duration.zero,
      log: w.log.add,
    );
    return w;
  }

  /// Creates the wallet (a fresh 12-word phrase), opens it and waits for
  /// live data. Call inside `tester.runAsync`.
  Future<BeamWallet> openWallet({
    bool open = true,
    bool waitLive = true,
  }) async {
    final info = WalletInfo.createNew(
      coin: Beam(CryptoCurrencyNetwork.main),
      name: 'beam receive test',
    );
    wallet =
        await Wallet.create(
              walletInfo: info,
              mainDB: MainDB.instance,
              secureStorageInterface: secure,
              nodeService: FakeNodeService(
                beamTestNode('eu-nodes.mainnet.beam.mw', 8100),
              ),
              prefs: FakePrefs(),
              mnemonic: bip39.generateMnemonic(),
              mnemonicPassphrase: '',
            )
            as BeamWallet;
    await wallet.init();
    Wallets.sharedInstance.addWallet(wallet);
    if (!open) return wallet;
    await wallet.open();
    if (waitLive) {
      await wallet.whenLive.timeout(const Duration(seconds: 10));
      await waitFor(
        () => wallet.info.cachedReceivingAddress.isNotEmpty,
        what: 'cached receiving address',
      );
    }
    return wallet;
  }

  /// Moves the wallet onto its private node and waits until the core
  /// confirms it holds the owner key (`own_node == true`). Call inside
  /// `tester.runAsync`, after [openWallet] with the private node on.
  Future<void> confirmOwnNode() async {
    await wallet.whenCanSend.timeout(const Duration(seconds: 10));
    await waitFor(() => nodes.isNotEmpty, what: 'node created');
    await waitFor(() => nodes.single.keyReceived != null, what: 'owner key');
    await waitFor(() => wallet.isOpen, what: 'reopened after bring-up');
    nodes.single.emit(
      nodes.single.progress.copyWith(
        phase: BeamNodePhase.txReplicationOn,
        myTipHeight: chainHeight,
        myTipAt: DateTime.now(),
        ownerAccounts: 1,
      ),
    );
    await waitFor(() => host.switches.isNotEmpty, what: 'switch to node');
    await waitFor(
      () => host.sessions.last.node.isOwned,
      what: 'owned session',
    );
    final owned = host.sessions.last.transport;
    await waitFor(() {
      owned.emit('ev_connection_changed', {
        'node_connected': true,
        'own_node': true,
      });
      return wallet.privateNodeStatus?.privateReceiveAvailable ?? false;
    }, what: 'own node confirmed');
    await waitFor(
      () => wallet.isOpen && (wallet.currentNode?.isOwned ?? false),
      what: 'wallet on the owned session',
    );
  }

  /// The screens' backend: the production one for [wallet], with the BANS
  /// shader read from the repo, and share / node settings recorded.
  BeamReceiveBackend backend() => BeamReceiveBackend.forWallet(
    wallet,
    myNames: () => beamPayableNames(
      BeamBansService(
        BeamWalletServices.of(wallet).api,
        null,
        shader: bansAppShader(MemoryShaderSource(bansShaderBytes)),
      ),
    ),
    share: (text) async => shared.add(text),
    // Campfire's cache update writes to Isar, which must not start inside
    // the widget test's fake clock (its write lock would never be freed).
    forgetAddress: (address) =>
        Zone.root.run(() => beamForgetAddress(wallet, address)),
    openNodeSettings: (context, {required desktop}) =>
        nodeSettingsOpened.add(desktop),
  );

  /// Calls the screens made to the core, over every session.
  List<FakeCallRecord> callsTo(String method) => [
    for (final s in host.sessions)
      for (final c in s.transport.callsTo(method))
        FakeCallRecord(c.method, c.params),
  ];

  Future<void> close() async {
    await wallet.exit();
  }
}

class FakeCallRecord {
  const FakeCallRecord(this.method, this.params);

  final String method;
  final Map<String, Object?> params;
}

/// The API a screen would use, for direct assertions.
BeamApi apiOf(BeamWallet wallet) => BeamWalletServices.of(wallet).api;

// ------------------------------------------------------------- rendering

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

const goldenKey = ValueKey('receive-golden');

/// Pumps [home] with the app's theme, routes and providers, the BEAM
/// receive backend replaced by [backend].
Future<void> pumpScreen(
  WidgetTester tester,
  Widget home, {
  required BeamReceiveBackend backend,
  Size size = phone,
  double pixelRatio = 2,
}) async {
  await loadFonts(tester);
  tester.view.physicalSize = size * pixelRatio;
  tester.view.devicePixelRatio = pixelRatio;
  addTearDown(tester.view.reset);
  final colors = StackColors.fromStackColorTheme(campfireLight);
  // Never disposed: Campfire's wallet-info Watcher is disposed twice when a
  // ProviderContainer goes away (ChangeNotifierProvider plus its own
  // onDispose), which the app never does but a test teardown would.
  final container = ProviderContainer(
    overrides: [
      themeProvider.overrideWithProvider(
        StateProvider<StackTheme>((ref) => campfireLight),
      ),
      pWallets.overrideWithValue(Wallets.sharedInstance),
      pBeamReceiveBackend.overrideWithProvider(
        (walletId) => Provider<BeamReceiveBackend?>((_) => backend),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme(colors),
        onGenerateRoute: RouteGenerator.generateRoute,
        home: RepaintBoundary(key: goldenKey, child: home),
      ),
    ),
  );
}

/// Lets core calls (microtasks), SVG and image decoding (real I/O) finish,
/// then repaints.
Future<void> settle(WidgetTester tester, {int rounds = 4}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        final img = e.widget as Image;
        await precacheImage(img.image, e);
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    // Route and dialog transitions run on the fake clock.
    await tester.pump(const Duration(milliseconds: 350));
  }
}

/// Fails if the widget found by [finder] is not fully inside [screen].
void expectOnScreen(WidgetTester tester, Finder finder, Size screen) {
  final r = tester.getRect(finder);
  expect(r.top, greaterThanOrEqualTo(0), reason: '$finder starts above');
  expect(r.left, greaterThanOrEqualTo(0), reason: '$finder starts left');
  expect(r.bottom, lessThanOrEqualTo(screen.height), reason: '$finder below');
  expect(r.right, lessThanOrEqualTo(screen.width), reason: '$finder right');
}

/// Lets flush bars and their timers run out.
Future<void> drainToasts(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

/// The host this runs on renders fonts the way the goldens were made.
bool get isMacHost => Platform.isMacOS;

/// Shared by every test file: one Isar for all wallets.
class ReceiveDb {
  static Directory? _tmp;

  static Future<Directory> open() async {
    final existing = _tmp;
    if (existing != null) return existing;
    // Isar's own macOS core from the pub cache: a widget test cannot
    // download it (its HTTP client is a stub), and the host workdir is
    // re-synced before every run.
    final lib = _pubCacheIsarCore();
    if (lib != null) {
      await Isar.initializeIsarCore(libraries: {Abi.current(): lib});
    }
    final tmp = await Directory.systemTemp.createTemp('beam_receive_ui_');
    await openTestMainDb(Directory('${tmp.path}/isar')..createSync());
    return _tmp = tmp;
  }
}

String? _pubCacheIsarCore() {
  if (!Platform.isMacOS) return null;
  final cache =
      Platform.environment['PUB_CACHE'] ??
      '${Platform.environment['HOME']}/.pub-cache';
  final f = File(
    '$cache/hosted/pub.dev/isar_community_flutter_libs-${Isar.version}'
    '/macos/libisar.dylib',
  );
  return f.existsSync() ? f.path : null;
}

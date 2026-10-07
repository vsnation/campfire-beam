/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Shared set-up for the wiring tests: a REAL BeamWallet (fake host whose
// sessions run on FakeTransport, fake explorer, fake secure storage, a real
// Isar) registered in Campfire's Wallets, Campfire's own light theme
// installed as the app installs it (theme icons are files), Inter, and the
// app's RouteGenerator, so every entry point opens what the app opens.
//
// No real key, password or address: the mnemonic is generated per test,
// the address is made up, the amounts are invented.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/models/exchange/response_objects/trade.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/providers/global/notifications_provider.dart';
import 'package:stackwallet/providers/global/prefs_provider.dart';
import 'package:stackwallet/providers/global/trades_service_provider.dart';
import 'package:stackwallet/providers/global/wallets_provider.dart';
import 'package:stackwallet/route_generator.dart';
import 'package:stackwallet/services/notifications_service.dart';
import 'package:stackwallet/services/trade_service.dart';
import 'package:stackwallet/services/wallets.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/themes/theme_providers.dart';
import 'package:stackwallet/utilities/amount/amount_unit.dart';
import 'package:stackwallet/utilities/constants.dart';
import 'package:stackwallet/utilities/enums/backup_frequency_type.dart';
import 'package:stackwallet/utilities/enums/sync_type_enum.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/utilities/prefs.dart';
import 'package:stackwallet/utilities/stack_file_system.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_services.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';
import 'package:stackwallet/widgets/beam/airdrop/beam_layout.dart';
import 'package:stackwallet/widgets/beam/wiring/beam_wallet_listenables.dart';

import '../asset_wallet/asset_test_support.dart' show openAssetTestDb;
import '../wallet/beam_wallet_test_support.dart';

const kTip = 4068103;

BigInt g(num beam) => BigInt.from((beam * 100000000).round());

const kMyAddress =
    '1111111111111111111111111111111111111111111111111111111111111111aa';

/// A 375 × 667 phone (the smallest common screen), at 2×.
const phone = Size(375, 667);

/// The Linux app's 1280 × 800 window, at 1×.
const desktopWindow = Size(1280, 800);

const goldenKey = ValueKey('beam-wiring-golden');

// ------------------------------------------------------------------ core

/// What the fake wallet core answers: 12.5 BEAM and 1,000 FOMO, synced at
/// [kTip] unless [status] is changed.
class WiringCore {
  Map<String, Object?> status = statusJson(
    height: kTip,
    available: g(12.5),
    extraTotals: [totalsJson(174, available: g(1000))],
  );

  Map<String, Object?> replies() => {
    'ev_subunsub': true,
    'wallet_status': (Map<String, Object?> _) => status,
    'addr_list': (Map<String, Object?> _) => [ownAddressJson(kMyAddress)],
    'tx_list': (Map<String, Object?> _) => <Object?>[],
  };
}

/// The test Isar, opened once per file (setUpAll) and closed after.
class WiringDb {
  late Directory tmp;
  late Isar isar;

  Future<void> open() async {
    tmp = await Directory.systemTemp.createTemp('beam_wiring_test_');
    // The widget-test binding blocks HTTP; the Isar core is fetched once.
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    try {
      for (var attempt = 1; ; attempt++) {
        try {
          isar = await openAssetTestDb(
            Directory(p.join(tmp.path, 'isar'))..createSync(recursive: true),
          );
          break;
        } catch (_) {
          // Another test file may still be downloading the Isar core.
          if (attempt >= 5) rethrow;
          await Future<void>.delayed(Duration(seconds: 2 * attempt));
        }
      }
    } finally {
      HttpOverrides.global = saved;
    }
    installCampfireTheme(Directory(p.join(tmp.path, 'themes')));
    // Campfire's desktop home asks path_provider for folders; tests have no
    // platform plugin, so every folder is one under this test's temp dir.
    final folders = Directory(p.join(tmp.path, 'folders'))..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => folders.path,
        );
  }

  /// Closes the Isar. A watcher whose cancellation was scheduled in a
  /// test's fake-async zone can keep `close` waiting for ever; the test
  /// process ends after this anyway, so it is not waited for past 10 s.
  Future<void> close() async {
    await isar
        .close(deleteFromDisk: true)
        .timeout(const Duration(seconds: 10), onTimeout: () => false);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // Left for the OS to clean up with the rest of its temp folder.
    }
  }
}

/// A real BEAM wallet over [core], open and live, registered in Campfire's
/// [Wallets] like a wallet the user opened. [explorerHeight] above [kTip]
/// leaves the wallet behind (sending paused). Pass [host] to push core
/// events to the wallet (its transport is `host.lastTransport`).
Future<BeamWallet> openBeamWallet(
  WidgetTester tester,
  WiringDb db, {
  WiringCore? core,
  int explorerHeight = kTip,
  String name = 'Everyday BEAM',
  FakeBeamHost? host,
  Future<Map<int, String>> Function()? readAssetTable,
}) async {
  final c = core ?? WiringCore();
  late BeamWallet wallet;
  await tester.runAsync(() async {
    final root = (await Directory(
      p.join(db.tmp.path, 'root-${DateTime.now().microsecondsSinceEpoch}'),
    ).create(recursive: true)).path;
    final fakeHost = host ?? FakeBeamHost(replies: c.replies);
    BeamWalletEnvironment.instance = BeamWalletEnvironment(
      beamRoot: () async => root,
      createHost: (_) => fakeHost,
      createExplorer: () => FakeExplorer(explorerHeight),
      privateNodeSetting: const BeamFixedPrivateNodeSetting(false),
      explorerPollInterval: const Duration(hours: 1),
      statusPollInterval: const Duration(hours: 1),
      eventDebounce: const Duration(milliseconds: 20),
      privateNodeStartDelay: Duration.zero,
      readAssetTable: readAssetTable,
      log: (_) {},
    );
    wallet = await Wallet.create(
      walletInfo: WalletInfo.createNew(
        coin: Beam(CryptoCurrencyNetwork.main),
        name: name,
      ),
      mainDB: MainDB.instance,
      secureStorageInterface: FakeSecureStorage(),
      nodeService: FakeNodeService(
        beamTestNode('eu-nodes.mainnet.beam.mw', 8100),
      ),
      prefs: FakePrefs(),
      mnemonic: bip39.generateMnemonic(),
      mnemonicPassphrase: '',
    ) as BeamWallet;
    await wallet.init();
    await wallet.open();
    await wallet.whenLive.timeout(const Duration(seconds: 5));
    if (explorerHeight <= kTip) {
      await wallet.whenCanSend.timeout(const Duration(seconds: 5));
    } else {
      // Behind: wait until the verdict says so.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (wallet.syncAssessment.canSpend ||
          wallet.syncAssessment.walletHeight == null) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    Wallets.sharedInstance.addWallet(wallet);
  });
  addTearDown(
    () => tester.runAsync(() async {
      await BeamWalletWiring.forget(wallet.walletId);
      await BeamWalletServices.forget(wallet.walletId);
      await wallet.exit();
    }),
  );
  return wallet;
}

// ----------------------------------------------------------------- theme

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
/// installs it, so theme icons (coin icon, exchange icon…) load from files.
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

OutlineInputBorder _border(Color c) => OutlineInputBorder(
  borderSide: BorderSide(width: 1, color: c),
  borderRadius: BorderRadius.circular(Constants.size.circularBorderRadius),
);

/// The parts of the app's ThemeData (lib/main.dart) the widgets read.
ThemeData appThemeData(StackColors colors) => ThemeData(
  extensions: [colors],
  highlightColor: colors.highlight,
  brightness: colors.brightness,
  fontFamily: GoogleFonts.inter().fontFamily,
  unselectedWidgetColor: colors.radioButtonBorderDisabled,
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
    enabledBorder: _border(colors.textFieldDefaultBG),
    focusedBorder: _border(colors.textFieldDefaultBG),
    errorBorder: _border(colors.textFieldDefaultBG),
    disabledBorder: _border(colors.textFieldDefaultBG),
    focusedErrorBorder: _border(colors.textFieldDefaultBG),
  ),
);

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

// ----------------------------------------------------------------- prefs

/// Campfire's settings as these screens read them, without Hive. A new one
/// per test: a ProviderScope disposes its ChangeNotifiers.
class TestPrefs extends ChangeNotifier implements Prefs {
  @override
  bool get externalCalls => false;

  @override
  String get currency => 'USD';

  @override
  AmountUnit amountUnit(CryptoCurrency coin) => AmountUnit.normal;

  @override
  int maxDecimals(CryptoCurrency coin) => coin.fractionDigits;

  @override
  bool get hideBlockExplorerWarning => true;

  @override
  bool get enableExchange => false;

  @override
  bool get enableCoinControl => false;

  @override
  bool get advancedFiroFeatures => false;

  @override
  bool get isAutoBackupEnabled => false;

  @override
  BackupFrequencyType get backupFrequencyType =>
      BackupFrequencyType.afterClosingAWallet;

  @override
  SyncingType get syncType => SyncingType.allWalletsOnStartup;

  @override
  List<String> get walletIdsSyncOnStartup => const [];

  @override
  bool get useTor => false;

  @override
  bool get showTestNetCoins => false;

  @override
  bool get showFavoriteWallets => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// No exchange trades (the real service reads Hive).
class NoTrades extends TradesService {
  @override
  List<Trade> get trades => const [];
}

/// No notifications (the real service reads Hive).
class NoNotifications extends ChangeNotifier implements NotificationsService {
  @override
  bool hasUnreadNotificationsFor(String walletId) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Overflow errors this suite does not fail on, each with its reason:
///
/// * `static_overflow_row.dart`: Campfire's StaticOverflowRow (the desktop
///   wallet's feature row) lays all its buttons out once to measure them
///   before it moves the ones that do not fit under "More"; that one
///   measuring frame overflows on purpose (upstream behaviour).
///
/// Every other overflow still fails the test. (The BEAM empty history used
/// to overflow a 375 × 667 phone by 27 px; it now fits, so it is no longer
/// tolerated.)
void tolerateKnownOverflows() {
  const known = ['static_overflow_row.dart'];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    final text = details.toString();
    if (text.contains('overflowed') && known.any(text.contains)) return;
    previous?.call(details);
  };
  addTearDown(() => FlutterError.onError = previous);
}

// --------------------------------------------------------------- pumping

/// Pumps [home] as the app shows it: [desktop] (1280 × 800) or a 375 × 667
/// phone, Campfire's theme, Wallets with the test wallet, and the app's own
/// routes. Returns the provider container.
Future<ProviderContainer> pumpWiring(
  WidgetTester tester,
  Widget home, {
  required bool desktop,
  Size? size,
  bool frame = true,
}) async {
  await loadFonts(tester);
  tolerateKnownOverflows();
  final s = size ?? (desktop ? desktopWindow : phone);
  final ratio = desktop ? 1.0 : 2.0;
  tester.view.physicalSize = s * ratio;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  BeamWalletWiring.debugDesktopLayout = desktop;
  addTearDown(() => BeamWalletWiring.debugDesktopLayout = null);
  final colors = StackColors.fromStackColorTheme(campfireLight);
  final container = ProviderContainer(
    overrides: [
      prefsChangeNotifierProvider.overrideWithValue(TestPrefs()),
      tradesServiceProvider.overrideWithValue(NoTrades()),
      notificationsProvider.overrideWithValue(NoNotifications()),
      pWallets.overrideWithValue(Wallets.sharedInstance),
      themeProvider.overrideWithProvider(
        StateProvider<StackTheme>((ref) => campfireLight),
      ),
    ],
  );
  _disposeContainer();
  _container = container;
  addTearDown(() async {
    if (_container == null) return; // finish() already did this
    await tester.pumpWidget(const SizedBox());
    _disposeContainer();
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
            desktop: desktop,
            child: RepaintBoundary(key: goldenKey, child: child!),
          ),
        ),
        home: desktop && frame ? DesktopAppFrame(child: home) : home,
      ),
    ),
  );
  await settle(tester);
  return container;
}

/// Campfire's desktop window around a screen, as DesktopHomeView lays it
/// out: the 225 px side menu (here an empty panel of its width), a 1 px gap,
/// and the screen in its own navigator, so pages open beside the menu and
/// dialogs over the whole window. Coordinates in desktop goldens are the
/// Linux window's (1280 × 800).
class DesktopAppFrame extends StatelessWidget {
  const DesktopAppFrame({super.key, required this.child});

  static const menuWidth = 225.0;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Material(
      color: colors.background,
      child: Row(
        children: [
          Container(
            key: const Key('desktopMenuPlaceholder'),
            width: menuWidth,
            color: colors.popupBG,
          ),
          Container(width: 1, color: colors.background),
          Expanded(
            child: Navigator(
              onGenerateRoute: (s) => s.name == Navigator.defaultRouteName
                  ? MaterialPageRoute<void>(settings: s, builder: (_) => child)
                  : RouteGenerator.generateRoute(s),
            ),
          ),
        ],
      ),
    );
  }
}

/// Closes the route (page, dialog or sheet) that shows [what], whatever
/// sits above it (a flush bar is a route of its own).
Future<void> closeRouteOf(WidgetTester tester, Finder what) async {
  final ctx = tester.element(what.first);
  final route = ModalRoute.of(ctx)!;
  final nav = Navigator.of(ctx);
  if (route.isCurrent) {
    nav.pop();
  } else {
    nav.removeRoute(route);
  }
  await settle(tester, rounds: 2);
}

/// Ends a test that showed a wallet screen: the wallet views turn on
/// Campfire's auto-sync (a 30 s ping timer), and the home's controller has
/// timers of its own. Stops them and unmounts, inside the test body, where
/// the binding checks for pending timers.
Future<void> finish(WidgetTester tester) async {
  for (final w in Wallets.sharedInstance.wallets) {
    w.shouldAutoSync = false;
  }
  await tester.pumpWidget(const SizedBox());
  _disposeContainer();
  // Release each wiring here, in the test's zone, so its Isar watcher is
  // really cancelled (the later teardown runs outside it).
  for (final w in Wallets.sharedInstance.wallets) {
    unawaited(BeamWalletWiring.forget(w.walletId));
  }
  await tester.pump(const Duration(seconds: 6));
}

ProviderContainer? _container;

/// Disposes the last pumped container (its auto-dispose providers, e.g. the
/// wallet home's controller and its timer, end with it).
void _disposeContainer() {
  final c = _container;
  _container = null;
  if (c == null) return;
  // Campfire's Isar watchers (wallet info, favourite wallets) are disposed
  // twice when their container is (the app never disposes it); only that
  // assertion is tolerated.
  runZonedGuarded(c.dispose, (e, _) {
    final m = '$e';
    if (!(m.contains('Watcher') && m.contains('was used after being'))) {
      throw e;
    }
  });
}

/// Lets real image and SVG decoding finish (outside the fake clock), then
/// lets frames and short timers run.
Future<void> settle(WidgetTester tester, {int rounds = 3}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        final img = e.widget as Image;
        // An animated GIF (Campfire's loading logo) may never report done.
        await precacheImage(
          img.image,
          e,
        ).timeout(const Duration(seconds: 2), onTimeout: () {});
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    // A route's transition starts on the first frame after it is pushed or
    // popped; further frames then run it to the end (a page transition on
    // macOS takes about 500 ms).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }
}

/// The Material icon font, read from the running SDK (flutter_tester ships
/// without it; icons would render as boxes).
Future<void> loadMaterialIcons(WidgetTester tester) async {
  await tester.runAsync(() async {
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 3; i++) {
      dir = dir.parent;
    }
    final font = File(
      '${dir.path}/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (!font.existsSync()) return;
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
    await loader.load();
  });
}

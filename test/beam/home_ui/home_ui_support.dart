/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Shared pieces for the BEAM wallet home tests: Campfire's light theme and
// fonts, a fake BeamHomeSource, the provider overrides that stand in for
// Isar / Hive / the price service, and frames that place the real home
// widgets the way WalletView (mobile) and DesktopWalletView (desktop) do.
// Every value is made up: no real address, key, name or amount.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:stackwallet/models/balance.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/pages/wallet_view/sub_widgets/wallet_summary.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/beam_desktop_wallet_summary.dart';
import 'package:stackwallet/services/event_bus/events/global/wallet_sync_status_changed_event.dart';
import 'package:stackwallet/themes/coin_card_provider.dart';
import 'package:stackwallet/themes/coin_icon_provider.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/themes/theme_providers.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/utilities/amount/amount_formatter.dart';
import 'package:stackwallet/utilities/amount/amount_unit.dart';
import 'package:stackwallet/utilities/text_styles.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_inbox_monitor.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_models.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_service.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_pool.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/price/beam_asset_pricer.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_holdings.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_providers.dart'
    show pBeamAssetHoldings, pBeamAssetMarket, pBeamHiddenAssetIds;
import 'package:stackwallet/wallets/beam/assets/beam_asset_registry.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_balance_mapper.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_sync_tracker.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_errors.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/providers/wallet_info_provider.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_claim_sheet.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_home_source.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_wallet_home.dart';
import 'package:stackwallet/widgets/rounded_white_container.dart';
import 'package:stackwallet/widgets/wallet_navigation_bar/components/icons/receive_nav_icon.dart';
import 'package:stackwallet/widgets/wallet_navigation_bar/components/wallet_navigation_bar_item.dart';
import 'package:stackwallet/widgets/wallet_navigation_bar/wallet_navigation_bar.dart';

const kHomeWalletId = 'beam-home-ui-test';

final Beam kBeam = Beam(CryptoCurrencyNetwork.main);

BigInt g(num beam) => BigInt.from((beam * 100000000).round());

// ------------------------------------------------------------------ theme

Map<String, dynamic> _themeJson() {
  final zip = ZipDecoder().decodeBytes(
    File('asset_sources/default_themes/campfire/light.zip').readAsBytesSync(),
  );
  final file = zip.files.singleWhere((f) => f.name == 'theme.json');
  return Map<String, dynamic>.from(
    jsonDecode(utf8.decode(file.content as List<int>)) as Map,
  );
}

StackTheme campfireLightTheme() => StackTheme.fromJson(json: _themeJson());

/// The BEAM card colour from Campfire's theme (`coin.beam`).
Color beamCoinColor() {
  final coin = (_themeJson()['colors'] as Map)['coin'] as Map;
  return Color(int.parse(coin['beam'] as String));
}

/// Campfire's small BEAM icon from the theme, written to a temp file (the
/// app reads it from the theme directory the same way).
String beamIconPath() {
  final out = File('${Directory.systemTemp.path}/cfb_home_beam_icon.svg');
  if (!out.existsSync()) {
    final zip = ZipDecoder().decodeBytes(
      File('asset_sources/default_themes/campfire/light.zip').readAsBytesSync(),
    );
    final svg = zip.files.singleWhere(
      (f) => f.name.endsWith('coin_icons/small/Beam.svg'),
    );
    out.writeAsBytesSync(svg.content as List<int>);
  }
  return out.path;
}

/// The parts of the app's ThemeData the widgets read (lib/main.dart).
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
);

/// Inter, loaded before the first layout (the project notes §3).
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

/// Lets real I/O (SVG and image decoding, asset loads) finish, then pumps.
Future<void> settleImages(WidgetTester tester, {int rounds = 4}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Decodes every image on screen for real, so goldens never catch an
/// image half-loaded.
Future<void> precacheAllImages(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final e in find.byType(Image).evaluate()) {
      final widget = e.widget as Image;
      await precacheImage(widget.image, e);
    }
  });
  await tester.pump();
}

// ------------------------------------------------------------- fake core

/// A [BeamHomeSource] whose every value the test sets.
class FakeHomeSource implements BeamHomeSource {
  FakeHomeSource({
    BeamSyncAssessment? assessment,
    this.isOpen = true,
    this.isScanningForCoins = false,
    this.scanProgress,
    this.privateNodeStatus,
    this.coreProblem,
    this.inbox,
    this.pools = const [],
    Duration inboxMinInterval = const Duration(hours: 1),
  }) : _assessment = assessment ?? synced() {
    // A long throttle by default, so a read that happens anyway proves it
    // was forced (after a claim) or was the first one.
    bansInbox = BansInboxMonitor(_readInbox, minInterval: inboxMinInterval);
  }

  BeamSyncAssessment _assessment;
  BansInbox? inbox;
  List<BeamPool> pools;

  /// Thrown by the next inbox read instead of answering.
  Object? inboxError;

  final _assessments = StreamController<BeamSyncAssessment>.broadcast();
  final _events = StreamController<void>.broadcast();
  final _txs = StreamController<void>.broadcast();

  int inboxReads = 0;
  int pricerCalls = 0;
  int prepareCalls = 0;
  final List<BansPrepared> executed = [];
  final List<String> holds = [];
  int releases = 0;
  int retries = 0;

  /// What prepareClaimAll answers; null builds one from the inbox.
  BansPrepared? prepared;
  Object? prepareError;
  Object? executeError;
  Completer<void>? prepareGate;

  @override
  bool isOpen;

  @override
  bool isScanningForCoins;

  @override
  BeamScanProgress? scanProgress;

  @override
  BeamPrivateNodeStatus? privateNodeStatus;

  @override
  BeamWalletException? coreProblem;

  @override
  late final BansInboxMonitor bansInbox;

  Future<BansInbox> _readInbox() async {
    inboxReads++;
    final e = inboxError;
    if (e != null) throw e;
    return inbox ??
        const BansInbox(domains: [], saleProceeds: [], payments: []);
  }

  set assessment(BeamSyncAssessment a) {
    _assessment = a;
    _assessments.add(a);
  }

  @override
  BeamSyncAssessment get syncAssessment => _assessment;

  @override
  Stream<BeamSyncAssessment> get syncAssessments => _assessments.stream;

  @override
  bool get canSpend => _assessment.canSpend;

  /// Tells the home that getters changed (like Campfire's event bus).
  void fireEvent() => _events.add(null);

  void fireTransactionsChanged() => _txs.add(null);

  @override
  Stream<void> get walletEvents => _events.stream;

  @override
  Stream<void> get transactionsChanged => _txs.stream;

  @override
  Future<BeamAssetPricer> pricer() async {
    pricerCalls++;
    return BeamAssetPricer(pools);
  }

  @override
  Future<BansPrepared> prepareClaimAll() async {
    prepareCalls++;
    final gate = prepareGate;
    if (gate != null) await gate.future;
    final e = prepareError;
    if (e != null) throw e;
    return prepared ?? claimFor(inbox);
  }

  @override
  Future<String> executeClaim(BansPrepared prepared) async {
    executed.add(prepared);
    final e = executeError;
    if (e != null) throw e;
    return 'fe' * 16;
  }

  @override
  VoidCallback holdNodeSwitch(String reason) {
    holds.add(reason);
    return () => releases++;
  }

  @override
  Future<void> retry() async => retries++;
}

/// The claim transaction the core would build for [inbox], fee 0.011.
BansPrepared claimFor(BansInbox? inbox, {BigInt? fee}) {
  final totals = <int, BigInt>{};
  for (final p in inbox?.payments ?? const <BansIncomingPayment>[]) {
    totals[p.assetId] = (totals[p.assetId] ?? BigInt.zero) + p.amount;
  }
  for (final a in inbox?.saleProceeds ?? const <BansAmount>[]) {
    totals[a.assetId] = (totals[a.assetId] ?? BigInt.zero) + a.amount;
  }
  return BansPrepared(
    action: BansAction.claimAll,
    args: 'role=user,action=receive_all',
    rawData: const [1, 2, 3],
    invokeData: const BeamInvokeData(entries: []),
    summary: BansSummary(
      action: BansAction.claimAll,
      youPay: const [],
      youReceive: [for (final e in totals.entries) BansAmount(e.key, e.value)],
      fee: fee ?? kBansClaimFeeGroth,
      paidTo: 'this wallet',
      contractId: 'vault',
      comments: const [],
    ),
  );
}

BansInbox inboxOf(Map<String, Map<int, BigInt>> byName) => BansInbox(
  domains: const [],
  saleProceeds: const [],
  payments: [
    for (final n in byName.entries)
      for (final a in n.value.entries)
        BansIncomingPayment(
          oneTimeKey: '${n.key}-${a.key}',
          assetId: a.key,
          amount: a.value,
          name: n.key,
        ),
  ],
);

// ----------------------------------------------------------- assessments

const _height = 4100000;

BeamSynced synced({BeamNodeKind node = BeamNodeKind.publicNode}) => BeamSynced(
  node: node,
  explorerCheck: BeamExplorerCheck.agrees,
  walletHeight: _height,
  networkHeight: _height,
);

BeamSyncCatchingUp catchingUp(int behind, {Duration? eta}) =>
    BeamSyncCatchingUp(
      node: BeamNodeKind.publicNode,
      explorerCheck: BeamExplorerCheck.aheadOfWallet,
      blockInterval: const Duration(seconds: 60),
      walletHeight: _height - behind,
      networkHeight: _height,
      blocksBehind: behind,
      eta: eta,
    );

/// A node frozen at the block before HF6, as pre-7.5.14493 cores are.
BeamSyncStalled stalledAtHf6() => const BeamSyncStalled(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.aheadOfWallet,
  reason: BeamStallReason.stuckBelowHardFork,
  blockInterval: Duration(seconds: 60),
  forkHeight: beamMainnetHf6Height,
  walletHeight: beamMainnetHf6Height - 1,
  networkHeight: _height,
  blocksBehind: _height - (beamMainnetHf6Height - 1),
  tipAge: Duration(days: 98),
);

const connecting = BeamSyncConnecting(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.unavailable,
);

// --------------------------------------------------------- campfire data

Balance beamBalance({required num spendable, num pending = 0}) {
  Amount a(num v) => Amount(rawValue: g(v), fractionDigits: 8);
  return Balance(
    total: a(spendable + pending),
    spendable: a(spendable),
    blockedTotal: a(0),
    pendingSpendable: a(pending),
  );
}

BeamCachedAssetTotals assetTotals(int id, num available) =>
    BeamCachedAssetTotals(
      assetId: id,
      available: g(available),
      receiving: BigInt.zero,
      sending: BigInt.zero,
      maturing: BigInt.zero,
      change: BigInt.zero,
    );

/// Campfire's real amount formatter (8 decimals, normal unit) and price
/// display, with a made-up price.
BeamHomeFormat beamFormat({String? usdPerBeam = '0.0089'}) {
  final formatter = AmountFormatter(
    unit: AmountUnit.normal,
    locale: 'en_US',
    coin: kBeam,
    maxDecimals: 8,
  );
  return BeamHomeFormat(
    formatBeam: formatter.format,
    pricesOn: usdPerBeam != null,
    price: usdPerBeam == null ? null : Decimal.parse(usdPerBeam),
    currency: 'USD',
    locale: 'en_US',
  );
}

/// A pool pricing [aid]: [beam] BEAM against [units] of the asset.
BeamPool beamPool(int aid, num beam, num units, {int lp = 900}) => BeamPool(
  aid1: 0,
  aid2: aid,
  kind: BeamPoolKind.high,
  tok1: g(beam),
  tok2: g(units),
  ctl: g(1000),
  lpToken: lp,
);

/// Records PIN prompts and answers them.
class FakeAuth {
  FakeAuth({this.answer = true});

  bool answer;
  int prompts = 0;

  BeamAuthGate gate(CryptoCurrency coin, {required bool isDesktop}) =>
      (context) async {
        prompts++;
        return answer;
      };
}

List<Override> homeOverrides({
  required FakeHomeSource source,
  required Balance balance,
  Map<int, BeamCachedAssetTotals> totals = const {},
  BeamHomeFormat? format,
  FakeAuth? auth,
}) {
  final icon = beamIconPath();
  final color = beamCoinColor();
  return [
    pBeamHomeSource.overrideWithProvider((_) => Provider((_) => source)),
    pWalletCoin.overrideWithProvider((_) => Provider((_) => kBeam)),
    pWalletBalance.overrideWithProvider((_) => Provider((_) => balance)),
    pBeamAssetTotals.overrideWithProvider(
      (_) => Provider((_) => {0: _beamTotals(balance), ...totals}),
    ),
    pBeamHomeFormat.overrideWithProvider(
      (_) => Provider((_) => format ?? beamFormat()),
    ),
    coinIconProvider.overrideWithProvider((_) => Provider((_) => icon)),
    coinCardProvider.overrideWithProvider((_) => Provider((_) => null)),
    pCoinColor.overrideWithProvider((_) => StateProvider((_) => color)),
    if (auth != null) pBeamClaimAuthGate.overrideWithValue(auth.gate),
    // The dashboard's asset list and the hidden set, from the same totals
    // and pools (the app reads them from Isar, which this harness does not
    // open).
    pBeamHiddenAssetIds.overrideWithProvider((_) => Provider((_) => <int>{})),
    pBeamAssetMarket.overrideWithProvider(
      (_) => FutureProvider(
        (_) async => source.pools.isEmpty
            ? null
            : BeamAssetMarket(source.pools, readAt: DateTime.now()),
      ),
    ),
    pBeamAssetHoldings.overrideWithProvider(
      (_) => Provider(
        (_) => BeamAssetHoldings.build(
          totals: {0: _beamTotals(balance), ...totals},
          contracts: {
            for (final id in totals.keys)
              if (id != 0) id: BeamAssetRegistry.build(id),
          },
          hidden: const {},
          market: source.pools.isEmpty
              ? null
              : BeamAssetMarket(source.pools, readAt: DateTime.now()),
        ),
      ),
    ),
  ];
}

BeamCachedAssetTotals _beamTotals(Balance b) => BeamCachedAssetTotals(
  assetId: 0,
  available: b.spendable.raw,
  receiving: b.pendingSpendable.raw,
  sending: BigInt.zero,
  maturing: BigInt.zero,
  change: BigInt.zero,
);

// ---------------------------------------------------------------- frames

const mobileSize = Size(375, 812);
const desktopSize = Size(1200, 460);

/// Sets the test window and returns a key for the golden boundary.
ValueKey<String> useWindow(WidgetTester tester, Size size, {double dpr = 2}) {
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
  return const ValueKey('beam-home-golden');
}

/// WalletView's body for a BEAM wallet: Campfire's app bar title, the coin
/// card (`WalletSummary` → BEAM branch), the name payments line and sync
/// banner, the transactions header, and the bottom bar with Receive and
/// Send exactly as WalletView builds them for BEAM.
class MobileHomeFrame extends ConsumerWidget {
  const MobileHomeFrame({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).extension<StackColors>()!;
    return Stack(
      children: [
        Scaffold(
          backgroundColor: c.background,
          appBar: AppBar(
            backgroundColor: c.background,
            elevation: 0,
            automaticallyImplyLeading: false,
            titleSpacing: 16,
            title: Text(
              'My BEAM wallet',
              style: STextStyles.navBarTitle(context),
            ),
          ),
          body: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 10),
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: WalletSummary(
                      walletId: kHomeWalletId,
                      aspectRatio: 1.75,
                      initialSyncStatus: WalletSyncStatus.synced,
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: BeamHomeExtras(walletId: kHomeWalletId),
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Transactions',
                        style: STextStyles.itemSubtitle(context)
                            .copyWith(color: c.textDark3),
                      ),
                      Text('See all', style: STextStyles.link2(context)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
        SafeArea(
          child: WalletNavigationBar(
            items: [
              WalletNavigationBarItemData(
                label: 'Receive',
                icon: const ReceiveNavIcon(),
                onTap: () {},
              ),
              WalletNavigationBarItemData(
                label: 'Send',
                icon: const BeamSendNavIconFor(walletId: kHomeWalletId),
                overrideText: const BeamSendNavLabelFor(
                  walletId: kHomeWalletId,
                ),
                onTap: () {
                  if (!beamSendAllowed(context, ref, kHomeWalletId)) return;
                  sendOpened++;
                },
              ),
            ],
            moreItems: const [],
          ),
        ),
      ],
    );
  }
}

/// Times the frame's Send button got through to the send screen.
int sendOpened = 0;

/// DesktopWalletView's header row and banner for a BEAM wallet
/// (`DesktopWalletHeaderRow` → BeamDesktopWalletSummary, then
/// BeamDesktopSyncBanner), on Campfire's desktop background.
class DesktopHomeFrame extends StatelessWidget {
  const DesktopHomeFrame({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    return Material(
      color: c.background,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RoundedWhiteContainer(
              padding: const EdgeInsets.all(20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SvgPicture.file(File(beamIconPath()), width: 40, height: 40),
                  const SizedBox(width: 10),
                  const BeamDesktopWalletSummary(
                    walletId: kHomeWalletId,
                    initialSyncStatus: WalletSyncStatus.synced,
                  ),
                  const Expanded(child: SizedBox()),
                ],
              ),
            ),
            const BeamDesktopSyncBanner(walletId: kHomeWalletId),
            const SizedBox(height: 24),
            Text(
              'My wallet',
              style: STextStyles.desktopTextExtraSmall(context)
                  .copyWith(color: c.textFieldActiveSearchIconLeft),
            ),
          ],
        ),
      ),
    );
  }
}

/// Named routes the home opened (e.g. network settings).
final List<String?> pushedRoutes = [];

/// Pumps [frame] under Campfire's light theme with [overrides].
Future<void> pumpHome(
  WidgetTester tester, {
  required Widget frame,
  required List<Override> overrides,
  Key boundaryKey = const ValueKey('beam-home-golden'),
}) async {
  final colors = StackColors.fromStackColorTheme(campfireLightTheme());
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      // Around the whole app, so sheets and dialogs are in the golden too.
      child: RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appThemeData(colors),
          home: frame,
          onGenerateRoute: (settings) {
            pushedRoutes.add(settings.name);
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => const Scaffold(body: SizedBox()),
            );
          },
        ),
      ),
    ),
  );
}

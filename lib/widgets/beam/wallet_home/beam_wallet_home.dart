/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The BEAM wallet home wired to the wallet and to Campfire's providers.
// The screens (`WalletView`, `DesktopWalletView`) only place these; the
// spec and exit-intent notes are at the top of beam_home_widgets.dart.

import 'dart:async';
import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:tuple/tuple.dart';

import '../../../models/balance.dart';
import '../../../notifications/show_flush_bar.dart';
import '../../../pages/pinpad_views/lock_screen_view.dart';
import '../../../pages/settings_views/wallet_settings_view/wallet_network_settings_view/wallet_network_settings_view.dart';
import '../../../pages/wallet_view/sub_widgets/wallet_refresh_button.dart';
import '../../../pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_auth_send.dart';
import '../../../providers/global/wallets_provider.dart';
import '../../../route_generator.dart';
import '../../../services/event_bus/events/global/node_connection_status_changed_event.dart';
import '../../../services/event_bus/events/global/wallet_sync_status_changed_event.dart';
import '../../../themes/coin_icon_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/amount/amount_formatter.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/price/beam_fiat_price.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../wallets/beam/wallet/beam_balance_mapper.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../../wallets/wallet/supporting/beam_wallet_info_extension.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import '../../../wallets/beam/assets/beam_asset_providers.dart'
    show pBeamHiddenAssetIds;
import 'beam_claim_sheet.dart';
import 'beam_dashboard_assets.dart';
import 'beam_home_controller.dart';
import 'beam_home_source.dart';
import 'beam_home_text.dart';
import 'beam_home_widgets.dart';

// ------------------------------------------------------------------ inputs

/// The wallet behind the home. Tests replace it with a fake.
final pBeamHomeSource = Provider.family<BeamHomeSource, String>((ref, id) {
  final wallet = ref.watch(pWallets).getWallet(id);
  return BeamWalletHomeSource(wallet as BeamWallet);
});

/// The live state of one BEAM wallet's home, alive while a home widget
/// watches it.
final pBeamHome = ChangeNotifierProvider.autoDispose
    .family<BeamHomeController, String>(
      (ref, id) => BeamHomeController(ref.watch(pBeamHomeSource(id)))..start(),
    );

/// A restore scan still looking for coins, with its whole percent when the
/// core reports one.
typedef BeamCoinScan = ({int? percent});

/// [BeamCoinScan] for one wallet, or null when no restore scan runs: for the
/// lists that would otherwise say "nothing yet" while coins are still being
/// found. It starts from the cached flag, so a wallet that is not scanning
/// never starts the home's live state from here; a scan that is over (the
/// wallet up to date, nothing outstanding) is null too. Tests replace it.
final pBeamCoinScan = Provider.autoDispose.family<BeamCoinScan?, String>((
  ref,
  id,
) {
  final pending = ref.watch(
    pWalletInfo(id).select((i) => i.beamData?.restoreScanPending ?? false),
  );
  if (!pending) return null;
  final running = ref.watch(pBeamHome(id).select((h) => h.isScanningForCoins));
  if (!running) return null;
  return (
    percent: ref.watch(
      pBeamHome(id).select((h) => BeamHomeText.scanPercent(h.scanProgress)),
    ),
  );
});

/// A restored wallet that holds something, whose list therefore starts at
/// the restore (BEAM keeps no history on the chain). Tests replace it.
final pBeamRestoredWithFunds = Provider.autoDispose.family<bool, String>(
  (ref, id) =>
      ref.watch(pWalletInfo(id).select((i) => i.beamRestoredWithFunds)),
);

/// Per-asset totals from Campfire's cache (the last `wallet_status`).
final pBeamAssetTotals =
    Provider.family<Map<int, BeamCachedAssetTotals>, String>(
      (ref, id) => ref.watch(pWalletInfo(id)).beamAssetTotals,
    );

/// How the home formats money: Campfire's amount formatter for BEAM and
/// Campfire's price display (only when the user allows price lookups).
final pBeamHomeFormat = Provider.family<BeamHomeFormat, String>((ref, id) {
  final coin = ref.watch(pWalletCoin(id));
  final formatter = ref.watch(pAmountFormatter(coin));
  // A missing or zero price is null here: never "0.00 USD".
  final fiat = ref.watch(pBeamFiatPrice(id));
  return BeamHomeFormat(
    formatBeam: formatter.format,
    pricesOn: fiat.lookupsOn,
    price: fiat.price,
    currency: fiat.currency,
    locale: fiat.locale,
    fractionDigits: coin.fractionDigits,
  );
});

/// Money formatting for the home.
class BeamHomeFormat {
  const BeamHomeFormat({
    required this.formatBeam,
    this.pricesOn = false,
    this.price,
    this.currency = '',
    this.locale = 'en_US',
    this.fractionDigits = 8,
  });

  final String Function(Amount amount) formatBeam;

  /// The user allows price lookups (Campfire's "external calls").
  final bool pricesOn;

  /// Fiat per BEAM, when known.
  final Decimal? price;
  final String currency;
  final String locale;
  final int fractionDigits;

  /// Campfire's own fiat display: "0.11 USD". Something worth less than a
  /// cent says so ("under 0.01 USD"), never "0.00 USD".
  String? fiat(Amount amount) {
    final p = price;
    if (p == null) return null;
    final exact = p * amount.decimal;
    final cent = Decimal.parse('0.01');
    if (exact > Decimal.zero && exact < cent) {
      final c = cent.toAmount(fractionDigits: 2).fiatString(locale: locale);
      return 'under $c $currency';
    }
    final value = exact.toAmount(fractionDigits: 2);
    return '${value.fiatString(locale: locale)} $currency';
  }

  String? fiatOfGroth(BigInt groth) =>
      fiat(Amount(rawValue: groth, fractionDigits: fractionDigits));
}

/// The balance lines from Campfire's cache and the home's live state.
BeamBalanceLines beamBalanceLines({
  required Balance balance,
  required Map<int, BeamCachedAssetTotals> totals,
  required BeamHomeFormat format,
  required BeamHomeController home,
  Set<int> hidden = const {},
}) {
  final pending = balance.pendingSpendable;
  final holdsAssets = totals.entries.any(
    (e) => e.key != 0 && e.value.total > BigInt.zero,
  );
  final scanning = home.isScanningForCoins;
  // A restore scan that has found nothing yet: the headline says so instead
  // of a bare 0 (and no "0.00 USD" under it). The percent's explanation is
  // the banner's.
  final nothingYet = beamNothingFoundYet(
    scanning: scanning,
    beamTotal: balance.total.raw,
    totals: totals,
  );
  return BeamBalanceLines(
    spendable: nothingYet
        ? BeamHomeText.scanningHeadline(home.scanProgress)
        : format.formatBeam(balance.spendable),
    fiat: nothingYet ? null : format.fiat(balance.spendable),
    reserveFiat: !nothingYet && format.pricesOn,
    foundSoFar: scanning && !nothingYet ? BeamHomeText.foundSoFar : null,
    arriving: BeamHomeText.arriving(format.formatBeam(pending), pending.raw),
    portfolio: BeamHomeText.portfolio(
      totals: totals,
      pricer: home.pricer,
      fiat: format.price == null ? null : format.fiatOfGroth,
      // Assets the user hid are not counted in the total.
      hidden: hidden,
    ),
    reservePortfolio: holdsAssets,
  );
}

// ------------------------------------------------------------------ mobile

/// The BEAM content of Campfire's coin card on the mobile home.
class BeamWalletSummaryInfo extends ConsumerWidget {
  const BeamWalletSummaryInfo({
    super.key,
    required this.walletId,
    required this.initialSyncStatus,
  });

  final String walletId;
  final WalletSyncStatus initialSyncStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coin = ref.watch(pWalletCoin(walletId));
    final home = ref.watch(pBeamHome(walletId));
    final totals = ref.watch(pBeamAssetTotals(walletId));
    home.setHeldAssets(totals.keys.toSet());
    final lines = beamBalanceLines(
      balance: ref.watch(pWalletBalance(walletId)),
      totals: totals,
      format: ref.watch(pBeamHomeFormat(walletId)),
      home: home,
      hidden: ref.watch(pBeamHiddenAssetIds(walletId)),
    );
    return BeamBalanceCardContent(
      lines: lines,
      icon: SvgPicture.file(
        File(ref.watch(coinIconProvider(coin))),
        width: 24,
        height: 24,
      ),
      refreshButton: WalletRefreshButton(
        walletId: walletId,
        initialSyncStatus: initialSyncStatus,
      ),
      nodeChip: BeamNodeChip(
        label: BeamHomeText.nodeChip(home.privateNodeStatus),
        isPrivate: BeamHomeText.onPrivateNode(home.privateNodeStatus),
        onCard: true,
        onTap: () =>
            openBeamNetworkSettings(context, ref, walletId, isDesktop: false),
      ),
    );
  }
}

/// Under the mobile card: the name payments line (directly under the
/// balance) and the sync banner. Takes no space when neither applies.
class BeamHomeExtras extends ConsumerWidget {
  const BeamHomeExtras({
    super.key,
    required this.walletId,
    this.isDesktop = false,
  });

  final String walletId;
  final bool isDesktop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(pBeamHome(walletId));
    final names = BeamHomeText.namePayments(home.namePayments);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child: names == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: BeamNamePaymentsLine(
                    text: names,
                    onClaim: () => showBeamClaimSheet(
                      context,
                      ref,
                      walletId,
                      isDesktop: isDesktop,
                    ),
                  ),
                ),
        ),
        BeamSyncBanner(
          content: home.banner,
          isDesktop: isDesktop,
          padding: const EdgeInsets.only(top: 10),
          onAction: (a) => runBeamHomeAction(
            context,
            ref,
            walletId,
            a,
            isDesktop: isDesktop,
          ),
        ),
        // Everything of value in the wallet, each one tap from Send.
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: BeamDashboardAssets(walletId: walletId, isDesktop: isDesktop),
        ),
      ],
    );
  }
}

/// The Send icon on the mobile bottom bar, dimmed while sending is off.
class BeamSendNavIconFor extends ConsumerWidget {
  const BeamSendNavIconFor({super.key, required this.walletId});

  final String walletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => BeamSendNavIcon(
    enabled: ref.watch(pBeamHome(walletId)).sendPausedReason == null,
  );
}

/// The Send label on the mobile bottom bar, dimmed while sending is off.
class BeamSendNavLabelFor extends ConsumerWidget {
  const BeamSendNavLabelFor({super.key, required this.walletId});

  final String walletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => BeamSendNavLabel(
    enabled: ref.watch(pBeamHome(walletId)).sendPausedReason == null,
  );
}

/// For the Send button's tap: when sending is off, says why (and that it
/// comes back by itself where it does) and returns false.
bool beamSendAllowed(BuildContext context, WidgetRef ref, String walletId) {
  final reason = ref.read(pBeamHome(walletId)).sendPausedReason;
  if (reason == null) return true;
  unawaited(
    showFloatingFlushBar(
      type: FlushBarType.info,
      message: reason,
      context: context,
    ),
  );
  return false;
}

// ----------------------------------------------------------------- actions

/// Runs a banner's button.
void runBeamHomeAction(
  BuildContext context,
  WidgetRef ref,
  String walletId,
  BeamHomeAction action, {
  required bool isDesktop,
}) {
  switch (action) {
    case BeamHomeAction.nodeSettings:
      openBeamNetworkSettings(context, ref, walletId, isDesktop: isDesktop);
    case BeamHomeAction.retry:
      unawaited(ref.read(pBeamHome(walletId)).source.retry());
    case BeamHomeAction.none:
      break;
  }
}

/// Campfire's network settings for this wallet (node list, test, add):
/// the same screen the network icon opens.
void openBeamNetworkSettings(
  BuildContext context,
  WidgetRef ref,
  String walletId, {
  required bool isDesktop,
}) {
  final home = ref.read(pBeamHome(walletId));
  final a = home.assessment;
  final sync =
      home.coreProblem != null ||
          a is BeamSyncStalled ||
          a is BeamSyncNotConnected
      ? WalletSyncStatus.unableToSync
      : a.canSpend
      ? WalletSyncStatus.synced
      : WalletSyncStatus.syncing;
  final node = home.source.isOpen && a is! BeamSyncNotConnected
      ? NodeConnectionStatus.connected
      : NodeConnectionStatus.disconnected;

  if (!isDesktop) {
    unawaited(
      Navigator.of(context).pushNamed(
        WalletNetworkSettingsView.routeName,
        arguments: Tuple3(walletId, sync, node),
      ),
    );
    return;
  }
  // As the desktop network button opens it (network_info_button.dart).
  unawaited(
    showDialog<void>(
      context: context,
      builder: (context) => Navigator(
        initialRoute: WalletNetworkSettingsView.routeName,
        onGenerateRoute: RouteGenerator.generateRoute,
        onGenerateInitialRoutes: (_, _) => [
          FadePageRoute(
            DesktopDialog(
              maxHeight: null,
              maxWidth: 580,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 32),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Network', style: STextStyles.desktopH3(context)),
                        DesktopDialogCloseButton(
                          onPressedOverride: Navigator.of(
                            context,
                            rootNavigator: true,
                          ).pop,
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(32, 16, 32, 32),
                      child: SingleChildScrollView(
                        child: WalletNetworkSettingsView(
                          walletId: walletId,
                          initialSyncStatus: sync,
                          initialNodeStatus: node,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const RouteSettings(name: WalletNetworkSettingsView.routeName),
          ),
        ],
      ),
    ),
  );
}

/// Opens the claim confirmation for what waits for the user's names.
void showBeamClaimSheet(
  BuildContext context,
  WidgetRef ref,
  String walletId, {
  required bool isDesktop,
  BeamAuthGate? authenticate,
}) {
  final home = ref.read(pBeamHome(walletId));
  final summary = home.namePayments;
  if (summary == null || summary.isEmpty) return;
  final coin = ref.read(pWalletCoin(walletId));
  final sheet = BeamClaimSheet(
    controller: home,
    summary: summary,
    beamAvailable: ref.read(pWalletBalance(walletId)).spendable.raw,
    authenticate:
        authenticate ??
        ref.read(pBeamClaimAuthGate)(coin, isDesktop: isDesktop),
    isDesktop: isDesktop,
  );
  if (isDesktop) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => DesktopDialog(
          maxWidth: 580,
          // The window's height less a margin, so a short window scrolls
          // the sheet instead of cutting off its buttons.
          maxHeight: null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [DesktopDialogCloseButton()],
              ),
              Flexible(child: SingleChildScrollView(child: sheet)),
            ],
          ),
        ),
      ),
    );
    return;
  }
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => BeamClaimSheetFrame(child: sheet),
    ),
  );
}

/// Campfire's bottom-sheet look (as `WalletBalanceToggleSheet`).
class BeamClaimSheetFrame extends StatelessWidget {
  const BeamClaimSheetFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    return Container(
      decoration: BoxDecoration(
        color: c.popupBG,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 60,
                height: 4,
                decoration: BoxDecoration(
                  color: c.textFieldDefaultBG,
                  borderRadius: BorderRadius.circular(100),
                ),
              ),
              const SizedBox(height: 10),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Builds the PIN / password step for a claim. Tests replace it.
typedef BeamAuthGateFactory = BeamAuthGate Function(
  CryptoCurrency coin, {
  required bool isDesktop,
});

final pBeamClaimAuthGate = Provider<BeamAuthGateFactory>((ref) => beamAuthGate);

/// Campfire's own confirmation: the PIN screen (mobile) or the wallet
/// password (desktop), as the send flow uses them.
BeamAuthGate beamAuthGate(CryptoCurrency coin, {required bool isDesktop}) =>
    (BuildContext context) async {
      if (isDesktop) {
        final unlocked = await showDialog<bool?>(
          context: context,
          builder: (context) => DesktopDialog(
            maxWidth: 580,
            maxHeight: double.infinity,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [DesktopDialogCloseButton()],
                ),
                Padding(
                  padding: const EdgeInsets.only(
                    left: 32,
                    right: 32,
                    bottom: 32,
                  ),
                  child: DesktopAuthSend(coin: coin),
                ),
              ],
            ),
          ),
        );
        return unlocked == true;
      }
      final unlocked = await Navigator.push<bool>(
        context,
        RouteGenerator.getRoute<bool>(
          shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
          builder: (_) => const LockscreenView(
            showBackButton: true,
            popOnSuccess: true,
            routeOnSuccessArguments: true,
            routeOnSuccess: "",
            biometricsCancelButtonString: "CANCEL",
            biometricsLocalizedReason: "Authenticate to claim name payments",
            biometricsAuthenticationTitle: "Confirm claim",
          ),
          settings: const RouteSettings(name: "/beamclaimlockscreen"),
        ),
      );
      return unlocked == true;
    };

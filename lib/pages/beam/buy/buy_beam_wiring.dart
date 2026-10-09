/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Buy BEAM for the app's real wallets: one controller for the app (one
// file of buys next to Campfire's other data, requests through
// Campfire's connection rule: Tor when Tor is on, nothing while Tor is on
// but not connected), a new address of the chosen BEAM wallet for each
// buy, the Ethereum wallet's address as the refund address for coins on
// Ethereum, and where each choice leads: the Buy BEAM form, or the
// Ethereum wallet's swap to WBEAM, or creating the wallet that is missing.
//
// Which wallet, when Campfire has several of a kind: the one used last on
// the side menu's pages (or open in My Campfire); else the only one; else
// the user is asked, once.
//
// Polling pauses while a phone app is in the background, as the bridge's
// does; desktop keeps polling.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app_config.dart';
import '../../../db/isar/main_db.dart';
import '../../../models/add_wallet_list_entity/sub_classes/coin_entity.dart';
import '../../../models/isar/models/blockchain_data/transaction.dart'
    show TransactionType;
import '../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/prefs.dart';
import '../../../utilities/stack_file_system.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../../wallets/beam/buy/buybeam_client.dart';
import '../../../wallets/beam/buy/buybeam_controller.dart';
import '../../../wallets/beam/buy/buybeam_store.dart';
import '../../../wallets/beam/models/beam_address.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/ethereum/eth_http_client.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../../wallets/wallet/impl/ethereum_wallet.dart';
import '../../../wallets/wallet/wallet.dart';
import '../../../wallets/wallet/wallet_mixin_interfaces/view_only_option_interface.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/sidebar/beam_sidebar.dart';
import '../../../widgets/beam/sidebar/swap_sidebar_wallets.dart';
import '../../../widgets/beam/tx/beam_transaction_card.dart';
import '../../../widgets/beam/wiring/beam_desktop_wallet_tabs.dart';
import '../../add_wallet_views/create_or_restore_wallet_view/create_or_restore_wallet_view.dart';
import '../../eth/uniswap/uniswap_wiring.dart';
import 'buy_beam_deps.dart';
import 'buy_beam_routes.dart';
import 'buy_beam_view.dart';
import 'buy_chooser_view.dart';

/// Builds an app whose buys go to buybeam.my's test mode (nothing payable):
/// `--dart-define=BUYBEAM_SANDBOX=true`. Off in every release.
const kBuyBeamSandbox = bool.fromEnvironment('BUYBEAM_SANDBOX');

abstract final class BuyBeamWiring {
  static BuyBeamController? _controller;
  static AppLifecycleListener? _lifecycle;

  /// Replaces the app's controller (tests).
  @visibleForTesting
  static set debugController(BuyBeamController? c) => _controller = c;

  /// The app's buy controller, created (and its open buys followed) on
  /// first use.
  static BuyBeamController get controller => _controller ??= _create();

  /// Follows the open buys from now on (a BEAM wallet screen, the desktop
  /// menu). Cheap after the first call.
  static void start() => controller;

  static BuyBeamController _create() {
    final c = BuyBeamController(
      client: BuyBeamClient(
        clientFactory: createEthHttpClient,
        sandbox: kBuyBeamSandbox,
      ),
      store: FileBuyBeamStore(() async {
        final dir = await StackFileSystem.applicationRootDirectory();
        return File('${dir.path}${Platform.pathSeparator}buybeam_orders.json');
      }),
    );
    if (!Util.isDesktop) {
      _lifecycle = AppLifecycleListener(
        onStateChange: (s) =>
            s == AppLifecycleState.resumed ? c.resume() : c.pause(),
      );
    }
    unawaited(c.resumeAll());
    return c;
  }

  /// Whether the lifecycle listener exists (tests).
  @visibleForTesting
  static bool get followsLifecycle => _lifecycle != null;
}

// ------------------------------------------------------------------- deps

bool _viewOnly(Wallet w) => w is ViewOnlyOptionInterface && w.isViewOnly;

/// The user's Ethereum wallets that can sign, in My Campfire's order.
List<EthereumWallet> _ethWallets(ProviderContainer c) => [
  for (final w in c.read(pSwapSidebarWallets))
    if (w is EthereumWallet && !_viewOnly(w)) w,
];

/// The Buy BEAM form's dependencies for [wallet]; [context] is the screen
/// it opens from (the wallet, or the side menu's page).
BuyBeamDeps buyBeamDepsFor(
  BuildContext context,
  BeamWallet wallet, {
  bool? isDesktop,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  final desktop = isDesktop ?? Util.isDesktop;
  return BuyBeamDeps(
    controller: BuyBeamWiring.controller,
    walletId: wallet.walletId,
    walletName: wallet.info.name,
    newBeamAddress: () async {
      final api = wallet.coreApi;
      if (api == null) throw const BuyBeamWalletNotReady();
      return api.createAddress(
        type: BeamAddressType.regular,
        expiration: BeamAddressExpiration.never,
        comment: 'Buy BEAM',
      );
    },
    refundAddressFor: (asset) async {
      // Only Ethereum itself: the same 0x address on another chain is
      // the user's too, but this app cannot show coins there.
      if (asset.blockchain != 'eth') return null;
      final eths = _ethWallets(container);
      if (eths.isEmpty) return null;
      final chosen = container.read(pSwapSidebarWalletChoice);
      final w = eths.firstWhere(
        (w) => w.walletId == chosen,
        orElse: () => eths.first,
      );
      try {
        return (await w.getCurrentReceivingAddress())?.value;
      } catch (_) {
        return null;
      }
    },
    receivedInWallet: (txId) async {
      final tx = await _walletTx(wallet, txId);
      // Received and confirmed (a pending one has no height yet).
      return tx != null &&
          tx.type == TransactionType.incoming &&
          tx.height != null;
    },
    onWantWbeam: (context, ref) =>
        unawaited(openWbeamBuy(context, ref, closeFirst: desktop)),
    onOpenTransaction: (context, txId) =>
        _openTransaction(context, wallet, txId, desktop: desktop),
    onOpenSupport: openBuyBeamSupport,
    torOn: () => AppConfig.hasFeature(AppFeature.tor) && Prefs.instance.useTor,
    isDesktop: desktop,
  );
}

/// [wallet]'s own record of the BEAM transaction [txId], if it has one.
Future<TransactionV2?> _walletTx(BeamWallet wallet, String txId) async {
  try {
    return await MainDB.instance.isar.transactionV2s
        .where()
        .txidWalletIdEqualTo(txId, wallet.walletId)
        .findFirst();
  } catch (_) {
    return null;
  }
}

/// buybeam.my's own site, where its support is.
void openBuyBeamSupport() => unawaited(
  launchUrl(Uri.parse(kBuyBeamSite), mode: LaunchMode.externalApplication),
);

Future<void> _openTransaction(
  BuildContext context,
  BeamWallet wallet,
  String? txId, {
  required bool desktop,
}) async {
  final tx = txId == null ? null : await _walletTx(wallet, txId);
  if (!context.mounted) return;
  if (tx != null) {
    await openBeamTxDetails(
      context,
      transaction: tx,
      coin: wallet.cryptoCurrency,
      isDesktop: desktop,
    );
    return;
  }
  // Not in the wallet's list yet: the wallet's history, where it shows.
  ProviderScope.containerOf(
    context,
    listen: false,
  ).read(pBeamShowHistoryRequest(wallet.walletId).state).state++;
  Navigator.of(context).pop();
}

// ------------------------------------------------------------------- open

/// The Buy BEAM form for [wallet], from its wallet screen.
Future<void> openBuyBeam(BuildContext context, BeamWallet wallet) {
  BuyBeamWiring.start();
  return BuyBeamView.show(context, buyBeamDepsFor(context, wallet));
}

/// Buy BEAM where Campfire must find the BEAM wallet first (the chooser,
/// an Ethereum wallet's swap): the one used last, the only one, or the
/// one the user picks; with none, creating one.
Future<void> openBuyBeamFromAnywhere(
  BuildContext context,
  WidgetRef ref,
) async {
  final ctx = ref.read(pBeamSidebarWallet);
  var wallet = ctx.wallet;
  if (!ctx.hasWallets) {
    _addWallet(context, Beam(CryptoCurrencyNetwork.main));
    return;
  }
  if (wallet == null) {
    final id = await _pickWallet(context, 'Which BEAM wallet?', [
      for (final w in ctx.wallets) (id: w.walletId, name: w.info.name),
    ]);
    if (id == null || !context.mounted) return;
    ref.read(pBeamSidebarWalletChoice.notifier).choose(id);
    wallet = ctx.wallets.firstWhere((w) => w.walletId == id);
  }
  await openBuyBeam(context, wallet);
}

/// WBEAM on Ethereum: the Ethereum wallet's swap, with WBEAM to receive.
/// On desktop it is the side menu's Swap page for that wallet ([closeFirst]
/// closes the dialog asking); on a phone the swap opens on top. With no
/// Ethereum wallet, creating one.
Future<void> openWbeamBuy(
  BuildContext context,
  WidgetRef ref, {
  bool closeFirst = false,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final eths = _ethWallets(container);
  final sidebar = BeamSidebar.enabled && Util.isDesktop;
  final nav = Navigator.of(context);
  if (eths.isEmpty) {
    if (closeFirst) nav.pop();
    _addWallet(nav.context, Ethereum(CryptoCurrencyNetwork.main));
    return;
  }
  final chosen = container.read(pSwapSidebarWalletChoice);
  EthereumWallet? wallet = eths.length == 1
      ? eths.single
      : eths.where((w) => w.walletId == chosen).firstOrNull;
  if (wallet == null) {
    final id = await _pickWallet(context, 'Which Ethereum wallet?', [
      for (final w in eths) (id: w.walletId, name: w.info.name),
    ]);
    if (id == null || !context.mounted) return;
    wallet = eths.firstWhere((w) => w.walletId == id);
  }
  if (sidebar) {
    if (closeFirst) nav.pop();
    container.read(pSwapSidebarWalletChoice.notifier).choose(wallet.walletId);
    selectBeamSidebarDestination(container, BeamSidebarDestination.swap);
    return;
  }
  await openUniswapSwap(context, ref, wallet);
}

/// The chooser's dependencies for the app's wallets.
BuyChooserDeps buyChooserDepsFor(WidgetRef ref, {bool? isDesktop}) {
  final wallets = ref.watch(pSwapSidebarWallets);
  return BuyChooserDeps(
    hasBeamWallet: wallets.any((w) => w is BeamWallet),
    hasEthWallet: wallets.any((w) => w is EthereumWallet && !_viewOnly(w)),
    onBeam: (context, ref) => unawaited(openBuyBeamFromAnywhere(context, ref)),
    onWbeam: (context, ref) => unawaited(openWbeamBuy(context, ref)),
    isDesktop: isDesktop ?? Util.isDesktop,
  );
}

void _addWallet(BuildContext context, CryptoCurrency coin) => unawaited(
  Navigator.of(
    context,
    rootNavigator: Util.isDesktop,
  ).pushNamed(CreateOrRestoreWalletView.routeName, arguments: CoinEntity(coin)),
);

/// Asks which of [options] to use; null when the user goes back.
Future<String?> _pickWallet(
  BuildContext context,
  String title,
  List<({String id, String name})> options,
) => showBuyBeamPage<String>(
  context,
  _Layout(Util.isDesktop),
  (context) => DexPage(
    deps: _Layout(Util.isDesktop),
    title: title,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final o in options) ...[
          DexCard(
            key: Key('buy-pick-${o.id}'),
            onTap: () => Navigator.of(context).pop(o.id),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    o.name,
                    style: STextStyles.smallMed14(context).copyWith(
                      color: Theme.of(context)
                          .extension<StackColors>()!
                          .textDark,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, size: 18),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    ),
  ),
);

class _Layout implements DexLayout {
  const _Layout(this.desktop);

  @override
  final bool desktop;
}

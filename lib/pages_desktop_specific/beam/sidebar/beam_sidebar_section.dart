/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// One BEAM item of the desktop side menu, in the content area beside it,
// like Campfire's own menu pages (Address Book, Settings): its own
// navigator, so what it opens (a pool, a name, Claim a code) opens beside
// the menu too, with a back arrow to the page.
//
// Which wallet: the one open in My Campfire or picked here (remembered);
// else the only BEAM wallet; else the only one running. With none the page
// offers "Create a BEAM wallet"; with several and none chosen it asks which,
// at the top of the page.
//
// Specs (USER_PSYCHOLOGY §6): Swap, Names and dApps are the wallet
// screen's own pages (their specs are in desktop_beam_dex_view.dart,
// beam_names_home_view.dart, dapp_store_view.dart), shown under the side
// menu's header; Assets and the Airdrops / Tokens hubs are in this folder;
// Bridge is `bridge_sidebar_page.dart` (a pair of wallets, not one).
//
// R11: nothing here waits for the wallet core. A wallet that is not running
// is started in the background; the pages show what Campfire has cached and
// their honest sync banner meanwhile.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../pages/beam/dapps/dapp_store_view.dart';
import '../../../pages/beam/names/beam_names_home_view.dart';
import '../../../pages/eth/near_intents/near_intents_view.dart';
import '../../../pages/eth/uniswap/uniswap_deps.dart';
import '../../../pages/eth/uniswap/uniswap_wiring.dart';
import '../../../pages/token_view/my_tokens_view.dart';
import '../../../route_generator.dart';
import '../../../utilities/logger.dart';
import '../../../wallets/beam/dapps/host/dapp_host.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../../wallets/wallet/impl/ethereum_wallet.dart';
import '../../../widgets/beam/sidebar/beam_sidebar.dart';
import '../../../widgets/beam/sidebar/swap_sidebar_wallets.dart';
import '../../../widgets/beam/wiring/beam_wallet_listenables.dart';
import '../../bridge/bridge_sidebar_page.dart';
import '../../eth/uniswap/desktop_uniswap_view.dart';
import '../dex/desktop_beam_dex_view.dart';
import 'beam_sidebar_assets_page.dart';
import 'beam_sidebar_hub_page.dart';
import 'beam_sidebar_scaffold.dart';

class BeamSidebarSection extends ConsumerStatefulWidget {
  const BeamSidebarSection({super.key, required this.destination});

  final BeamSidebarDestination destination;

  /// The page shown for [destination] and [wallet] (the root of the
  /// section's navigator).
  static Widget pageFor(
    BuildContext context,
    BeamSidebarDestination destination,
    BeamWallet wallet,
  ) {
    // Sync and funding buttons of the pages open from here.
    final wiring = BeamWalletWiring.of(wallet)..attach(context);
    return switch (destination) {
      BeamSidebarDestination.swap => BeamSidebarScaffold(
        title: destination.label,
        walletChip: const SwapSidebarWalletChip(),
        body: BeamWithoutOwnHeader(child: DesktopBeamDexView(deps: wiring.dex)),
      ),
      BeamSidebarDestination.assets => BeamSidebarAssetsPage(wallet: wallet),
      BeamSidebarDestination.names => BeamSidebarScaffold(
        title: destination.label,
        body: BeamWithoutOwnHeader(
          child: BeamNamesHomeView(deps: wiring.names),
        ),
      ),
      BeamSidebarDestination.dapps => BeamSidebarScaffold(
        title: destination.label,
        body: BeamWithoutOwnHeader(
          child: DappStoreView(host: DappHost.of(wallet)),
        ),
      ),
      BeamSidebarDestination.airdrops || BeamSidebarDestination.tokens =>
        BeamSidebarHubPage(destination: destination, wallet: wallet),
      // Both wallets of a pair, not one: built in [build] instead.
      BeamSidebarDestination.bridge => const BridgeSidebarPage(),
    };
  }

  @override
  ConsumerState<BeamSidebarSection> createState() => _BeamSidebarSectionState();
}

class _BeamSidebarSectionState extends ConsumerState<BeamSidebarSection> {
  /// Wallets this section has asked to start, so it asks once.
  final Set<String> _started = {};

  void _startInBackground(BeamWallet wallet) {
    if (wallet.isOpen || !_started.add(wallet.walletId)) return;
    unawaited(() async {
      try {
        // What Campfire's wallet list does on a click, minus the wait.
        await wallet.init();
        await wallet.open();
      } catch (e, s) {
        Logging.instance.w(
          'BEAM sidebar: could not start wallet ${wallet.walletId}',
          error: e,
          stackTrace: s,
        );
      }
    }());
  }

  Route<dynamic> _route(RouteSettings settings, BeamWallet wallet) {
    if (settings.name == Navigator.defaultRouteName) {
      return RouteGenerator.getRoute<void>(
        builder: (context) =>
            BeamSidebarSection.pageFor(context, widget.destination, wallet),
        settings: settings,
      );
    }
    if (settings.name == MyTokensView.routeName) {
      // The full list (hidden and unpriced assets too), beside the menu.
      return RouteGenerator.getRoute<void>(
        builder: (_) => BeamSidebarAllAssetsPage(walletId: wallet.walletId),
        settings: settings,
      );
    }
    return RouteGenerator.generateRoute(settings);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.destination;
    // A BEAM wallet and an Ethereum wallet, each picked on the page.
    if (d == BeamSidebarDestination.bridge) return const BridgeSidebarPage();
    if (d == BeamSidebarDestination.swap && ref.watch(pSwapHasEthereum)) {
      // Swap also takes Ethereum wallets: Uniswap for those.
      final w = ref.watch(pSwapSidebarWallet).wallet;
      if (w is EthereumWallet) {
        return _UniswapSidebarPage(key: ValueKey(w.walletId), wallet: w);
      }
      if (w is BeamWallet) {
        _startInBackground(w);
        return Navigator(
          key: ValueKey('beamSidebarNav_${d.name}_${w.walletId}'),
          onGenerateRoute: (settings) => _route(settings, w),
        );
      }
    }
    final ctx = ref.watch(pBeamSidebarWallet);
    if (!ctx.hasWallets) {
      return BeamSidebarScaffold(
        title: d.label,
        showWallet: false,
        body: BeamSidebarNoWallet(destination: d),
      );
    }
    final wallet = ctx.wallet;
    if (wallet == null) {
      return BeamSidebarScaffold(
        title: d.label,
        showWallet: false,
        body: BeamSidebarWalletPicker(destination: d),
      );
    }
    _startInBackground(wallet);
    return Navigator(
      key: ValueKey('beamSidebarNav_${d.name}_${wallet.walletId}'),
      onGenerateRoute: (settings) => _route(settings, wallet),
    );
  }
}

/// The Swap page for an Ethereum wallet: Uniswap, beside the side menu.
class _UniswapSidebarPage extends ConsumerStatefulWidget {
  const _UniswapSidebarPage({super.key, required this.wallet});

  final EthereumWallet wallet;

  @override
  ConsumerState<_UniswapSidebarPage> createState() =>
      _UniswapSidebarPageState();
}

class _UniswapSidebarPageState extends ConsumerState<_UniswapSidebarPage> {
  late final Future<UniswapDeps> _deps = uniswapDepsFor(
    widget.wallet,
    ref,
    isDesktop: true,
  );

  @override
  void dispose() {
    unawaited(_deps.then((d) => d.dispose(), onError: (Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BeamSidebarScaffold(
    title: BeamSidebarDestination.swap.label,
    walletChip: const SwapSidebarWalletChip(),
    body: FutureBuilder<UniswapDeps>(
      future: _deps,
      builder: (context, snap) {
        final deps = snap.data;
        if (deps == null) return const SizedBox.shrink();
        return DesktopUniswapView(
          deps: deps,
          showHeader: false,
          onPayWithOtherCoin: () => unawaited(
            NearIntentsView.show(
              context,
              nearIntentsDepsFor(widget.wallet, deps, ref),
            ),
          ),
        );
      },
    ),
  );
}

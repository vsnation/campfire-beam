/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The side menu's Bridge page: the desktop bridge beside the menu, for the
// pair of wallets last used (or the one a wallet's Bridge button asked
// for). Unlike the other BEAM pages it has no wallet chip: its From and To
// cards name both wallets and pick another when there are several.
//
// It is rebuilt when a BEAM or Ethereum wallet is added or removed, so
// "Add an Ethereum wallet" leads back to a working bridge.
//
// Spec: as `desktop_bridge_view.dart`. Clicks from
// app open: Bridge (1), the button (2).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../pages/bridge/bridge_deps.dart';
import '../../pages/bridge/bridge_wiring.dart';
import '../../wallets/bridge/bridge_routes.dart';
import '../../widgets/beam/sidebar/beam_sidebar.dart';
import '../../widgets/beam/sidebar/swap_sidebar_wallets.dart';
import '../beam/sidebar/beam_sidebar_scaffold.dart';
import 'desktop_bridge_view.dart';

class BridgeSidebarPage extends ConsumerStatefulWidget {
  const BridgeSidebarPage({super.key});

  @override
  ConsumerState<BridgeSidebarPage> createState() => _BridgeSidebarPageState();
}

class _BridgeSidebarPageState extends ConsumerState<BridgeSidebarPage> {
  Future<BridgeDeps>? _deps;
  String? _walletsKey;
  BridgeDirection _direction = BridgeDirection.toEthereum;

  @override
  void dispose() {
    unawaited(_deps?.then((d) => d.dispose(), onError: (Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // BEAM and Ethereum wallets, as the Swap page lists them.
    final wallets = ref.watch(pSwapSidebarWallets);
    final key = wallets.map((w) => w.walletId).join(',');
    // A wallet's Bridge button asked for its wallet: also when this page
    // is already up.
    if (key != _walletsKey || BridgeOpenIntent.walletId != null) {
      _walletsKey = key;
      final (walletId, direction) = BridgeOpenIntent.take();
      if (direction != null) _direction = direction;
      final old = _deps;
      _deps = bridgeDepsFor(
        context,
        wallets: wallets,
        walletId: walletId,
        isDesktop: true,
      );
      unawaited(old?.then((d) => d.dispose(), onError: (Object _) {}));
    }
    return BeamSidebarScaffold(
      title: BeamSidebarDestination.bridge.label,
      showWallet: false,
      body: FutureBuilder<BridgeDeps>(
        future: _deps,
        builder: (context, snap) {
          final deps = snap.data;
          if (deps == null) return const SizedBox.shrink();
          return DesktopBridgeView(
            key: ValueKey(deps),
            deps: deps,
            showHeader: false,
            initialDirection: _direction,
          );
        },
      ),
    );
  }
}

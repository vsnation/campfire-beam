/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The desktop bridge, in the layout of the desktop swaps
// (`desktop_uniswap_view.dart`): the Move form on the left, the crossings
// on the right, so the one under way is always in sight. The review, a
// crossing and the wallet pickers open as dialogs.
//
// Spec (USER_PSYCHOLOGY §6): as `bridge_move_view.dart` and
// `bridge_crossings_view.dart`; on desktop the history is beside the form
// instead of one click away. Clicks from app open: the side menu's Bridge
// (1), the button (2).

import 'package:flutter/material.dart';

import '../../pages/bridge/bridge_crossings_view.dart';
import '../../pages/bridge/bridge_deps.dart';
import '../../pages/bridge/bridge_move_view.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/bridge/bridge_controller.dart';
import '../../wallets/bridge/bridge_routes.dart';
import '../../widgets/desktop/desktop_app_bar.dart';
import '../../widgets/desktop/desktop_scaffold.dart';
import '../../widgets/rounded_white_container.dart';

class DesktopBridgeView extends StatefulWidget {
  const DesktopBridgeView({
    super.key,
    required this.deps,
    this.showHeader = true,
    this.initialRoute,
    this.initialDirection = BridgeDirection.toEthereum,
    this.now,
  });

  final BridgeDeps deps;

  /// The time the crossings' "5 min ago" counts from (tests).
  final DateTime Function()? now;

  /// False inside the side menu's page, which has its own title.
  final bool showHeader;

  final BridgeRoute? initialRoute;
  final BridgeDirection initialDirection;

  @override
  State<DesktopBridgeView> createState() => _DesktopBridgeViewState();
}

class _DesktopBridgeViewState extends State<DesktopBridgeView> {
  BridgeDeps get deps => widget.deps;

  @override
  void initState() {
    super.initState();
    deps.changes.addListener(_rebuild);
  }

  @override
  void dispose() {
    deps.changes.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = deps.controller;
    final body = Padding(
      padding: const EdgeInsets.only(left: 24, right: 24, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Move coins between your own BEAM and Ethereum wallets, '
                  "through BEAM's official bridge",
                  style: STextStyles.desktopTextExtraExtraSmall(context),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  controller == null ? '' : 'Your crossings',
                  style: STextStyles.desktopTextExtraExtraSmall(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: RoundedWhiteContainer(
                    padding: const EdgeInsets.all(24),
                    child: BridgeMoveView(
                      deps: deps,
                      embedded: true,
                      initialRoute: widget.initialRoute,
                      initialDirection: widget.initialDirection,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ListView(
                    children: [
                      if (controller == null)
                        const SizedBox.shrink()
                      else
                        FutureBuilder<BridgeController>(
                          future: controller,
                          builder: (context, snap) {
                            final c = snap.data;
                            if (c == null) return const SizedBox.shrink();
                            return BridgeCrossingsView(
                              key: ValueKey(c),
                              deps: deps,
                              controller: c,
                              embedded: true,
                              now: widget.now,
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (!widget.showHeader) return body;
    return DesktopScaffold(
      appBar: DesktopAppBar(
        isCompactHeight: true,
        leading: Padding(
          padding: const EdgeInsets.only(left: 24),
          child: Text('Bridge', style: STextStyles.desktopH3(context)),
        ),
      ),
      body: body,
    );
  }
}

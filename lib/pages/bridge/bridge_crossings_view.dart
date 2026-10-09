/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: find any crossing and see where it is; the ones still on
//    their way first.
// 2. Primary CTA: none (a row opens its crossing); with none yet, "Move
//    coins".
// 3. Taps from app open: Bridge → History (phone: 3); beside the form on
//    desktop (1).
//
// Exit-intent: an empty list with nothing to do (it says what the
// bridge does and offers to move); a row that only says "pending" (each
// says what it waits for: "34 blocks to go", "Collect").

import 'dart:async';

import 'package:flutter/material.dart';

import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/bridge/bridge_controller.dart';
import '../../wallets/bridge/bridge_crossing.dart';
import '../../widgets/beam/dex/dex_widgets.dart';
import '../../widgets/beam/stickers/beam_sticker.dart';
import 'bridge_crossing_view.dart';
import 'bridge_deps.dart';
import 'bridge_format.dart';
import 'bridge_widgets.dart';

class BridgeCrossingsView extends StatefulWidget {
  const BridgeCrossingsView({
    super.key,
    required this.deps,
    required this.controller,
    this.embedded = false,
    this.now,
  });

  final BridgeDeps deps;
  final BridgeController controller;

  /// True beside the desktop form: the list without a page around it.
  final bool embedded;

  /// The time "5 min ago" counts from (tests); the clock when null.
  final DateTime Function()? now;

  static Future<void> show(
    BuildContext context, {
    required BridgeDeps deps,
    required BridgeController controller,
  }) => showDexPage<void>(
    context,
    deps,
    (_) => BridgeCrossingsView(deps: deps, controller: controller),
  );

  @override
  State<BridgeCrossingsView> createState() => _BridgeCrossingsViewState();
}

class _BridgeCrossingsViewState extends State<BridgeCrossingsView> {
  BridgeController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_rebuild);
  }

  @override
  void didUpdateWidget(BridgeCrossingsView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_rebuild);
      widget.controller.addListener(_rebuild);
    }
  }

  @override
  void dispose() {
    controller.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _open(BridgeCrossing c) => unawaited(
    BridgeCrossingView.show(
      context,
      deps: widget.deps,
      controller: controller,
      id: c.id,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final list = controller.crossings;
    final body = list.isEmpty ? _empty(context) : _list(context, list);
    if (widget.embedded) return body;
    return DexPage(
      deps: widget.deps,
      title: 'Bridge history',
      body: body,
      bottom: list.isEmpty
          ? DexPrimaryAction(
              deps: widget.deps,
              buttonKey: const Key('bridge-history-move'),
              label: 'Move coins',
              onPressed: () => Navigator.of(context).pop(),
            )
          : null,
    );
  }

  Widget _empty(BuildContext context) => DexNotice(
    key: const Key('bridge-history-empty'),
    sticker: widget.embedded ? null : BeamMoments.trading,
    title: 'No crossings yet',
    detail:
        'Coins you move between your BEAM and Ethereum wallets show here, '
        'with where each one is.',
  );

  Widget _list(BuildContext context, List<BridgeCrossing> list) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final now = (widget.now ?? DateTime.now)();
    final open = list.where((c) => c.isOpen).toList();
    final done = list.where((c) => !c.isOpen).toList();
    Widget header(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 2),
      child: Text(
        text,
        style: STextStyles.itemSubtitle(context)
            .copyWith(color: colors.textDark3),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (open.isNotEmpty) ...[
          header('On their way'),
          for (final c in open) _row(context, c, now),
          const SizedBox(height: 8),
        ],
        if (done.isNotEmpty) ...[
          header('Finished'),
          for (final c in done) _row(context, c, now),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, BridgeCrossing c, DateTime now) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final words = BridgeWords.of(c, blocksLeft: controller.blocksLeft(c));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DexCard(
        key: Key('bridge-row-${c.id}'),
        onTap: () => _open(c),
        child: Row(
          children: [
            BridgeAssetIcon(route: c.route, onBeam: c.toEthereum, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bridgeHeadline(c),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: STextStyles.smallMed14(context)
                        .copyWith(color: colors.textDark),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        words.short,
                        key: Key('bridge-row-status-${c.id}'),
                        style: STextStyles.smallMed12(context)
                            .copyWith(color: words.color(colors)),
                      ),
                      Text(
                        '  ·  ${BridgeFormat.ago(c.createdAt, now)}',
                        style: STextStyles.label(context)
                            .copyWith(color: colors.textSubtitle1),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: colors.textSubtitle1,
            ),
          ],
        ),
      ),
    );
  }
}

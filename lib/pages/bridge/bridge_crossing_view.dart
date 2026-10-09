/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
// 1. ONE job: know where the money is now, and what happens next.
// 2. Primary CTA: none while it travels ("Done" closes; it carries on);
//    "Collect 0.5 bETH" once it is on BEAM and not collected
//    automatically.
// 3. Taps from app open: it opens by itself after the review; later,
//    Bridge → the crossing at the top, or History → it.
//
// Exit-intent (§1.7):
// * "Is it stuck?" — the step under way is marked, with what it waits for
//   in words ("34 BEAM blocks to go", "waiting for Ethereum gas to come
//   down to the fee you paid"), and slow is said to be normal when it is.
// * "Did it work?" — the end state says where the coins are now.
// * "Can I close this?" — said: it carries on, and Campfire picks it up
//   again when it is opened.
// * "Something went wrong" — what happened, that nothing was lost when
//   that is so, and never a button that sends the same thing twice.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/bridge/bridge_controller.dart';
import '../../wallets/bridge/bridge_crossing.dart';
import '../../wallets/bridge/bridge_sides.dart';
import '../../widgets/beam/dex/dex_widgets.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import 'bridge_deps.dart';
import 'bridge_format.dart';
import 'bridge_widgets.dart';

class BridgeCrossingView extends StatefulWidget {
  const BridgeCrossingView({
    super.key,
    required this.deps,
    required this.controller,
    required this.id,
    this.now,
  });

  final BridgeDeps deps;
  final BridgeController controller;
  final String id;

  /// The time "15 min ago" counts from (tests); the clock when null.
  final DateTime Function()? now;

  static Future<void> show(
    BuildContext context, {
    required BridgeDeps deps,
    required BridgeController controller,
    required String id,
  }) => showDexPage<void>(
    context,
    deps,
    (_) => BridgeCrossingView(deps: deps, controller: controller, id: id),
  );

  @override
  State<BridgeCrossingView> createState() => _BridgeCrossingViewState();
}

class _BridgeCrossingViewState extends State<BridgeCrossingView> {
  bool _busy = false;
  String? _error;

  BridgeDeps get deps => widget.deps;
  BridgeController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_rebuild);
    // Where it is right now, not at the next tick.
    unawaited(controller.poll(widget.id));
  }

  @override
  void dispose() {
    controller.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  bool _canCollect(BridgeCrossing c) =>
      c.state == BridgeCrossingState.delivered &&
      (!c.autoClaim || c.lastError != null);

  Future<void> _collect(BridgeCrossing c) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await controller.prepareClaim(c.id);
      if (!mounted) return;
      final ok = await deps.authenticate(
        context,
        reason: 'Authenticate to collect',
      );
      if (!mounted) return;
      if (ok != true) {
        setState(() {
          _busy = false;
          _error = ok == false
              ? (deps.desktop ? 'Wrong password.' : 'Wrong PIN.')
              : null;
        });
        return;
      }
      await controller.claim(c.id, p);
    } on BridgeException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              "Couldn't collect it: your BEAM wallet did not answer. It is "
              'still waiting for you; try again in a minute.',
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = controller.crossing(widget.id);
    if (c == null) {
      return DexPage(
        deps: deps,
        title: 'Crossing',
        body: const DexNotice(
          title: 'This crossing is not on this device',
          detail: 'It may belong to another pair of wallets.',
        ),
        bottom: DexPrimaryAction(
          deps: deps,
          label: 'Done',
          onPressed: () => Navigator.of(context).pop(),
        ),
      );
    }
    final r = c.route;
    final collect = _canCollect(c);
    return DexPage(
      deps: deps,
      title: c.toEthereum ? 'To Ethereum' : 'To BEAM',
      body: _body(context, c),
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            DexNotice(
              key: const Key('bridge-crossing-error'),
              kind: DexNoticeKind.error,
              title: _error!,
            ),
            const SizedBox(height: 12),
          ],
          DexPrimaryAction(
            deps: deps,
            buttonKey: const Key('bridge-crossing-cta'),
            label: collect
                ? 'Collect '
                      '${BridgeFormat.coin(c.receives, 8, r.beamSymbol)}'
                : 'Done',
            reason: _busy
                ? 'Collecting…'
                : collect
                ? 'Network fee '
                      '${BridgeFormat.coin(c.beamNetworkFee, 8, 'BEAM')}, '
                      'from your BEAM wallet.'
                : c.isOpen
                ? 'It carries on if you close this.'
                : null,
            onPressed: _busy
                ? null
                : collect
                ? () => unawaited(_collect(c))
                : () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, BridgeCrossing c) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final r = c.route;
    final left = controller.blocksLeft(c);
    final now = (widget.now ?? DateTime.now)();
    final words = BridgeWords.of(c, blocksLeft: left, now: now);
    final srcDec = r.sourceDecimals(c.direction);
    final srcSym = r.sourceSymbol(c.direction);
    final links = <Widget>[
      if (c.lockHash != null)
        _link('bridge-crossing-lock', 'See it on Etherscan', () {
          _open(deps.ethExplorerTx(c.lockHash!));
        }),
      if (c.toEthereum && c.state == BridgeCrossingState.paid)
        _link('bridge-crossing-address', 'See your wallet on Etherscan', () {
          _open(deps.ethExplorerAddress(c.ethAddress));
        }),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          bridgeHeadline(c),
          key: const Key('bridge-crossing-headline'),
          style: deps.desktop
              ? STextStyles.desktopTextMedium(context)
              : STextStyles.pageTitleH2(context),
        ),
        const SizedBox(height: 12),
        DexNotice(
          key: const Key('bridge-crossing-status'),
          kind: words.kind,
          title: words.title,
          detail: words.detail,
        ),
        const SizedBox(height: 12),
        BridgeStepList(
          steps: bridgeSteps(c, blocksLeft: left, now: now),
        ),
        const SizedBox(height: 12),
        DexCard(
          child: Column(
            children: [
              DexDetailRow(
                label: 'You moved',
                value: BridgeFormat.coin(c.amount, srcDec, srcSym),
              ),
              DexDetailRow(
                label: c.state.isDone ? 'Arrived' : 'Arrives',
                valueKey: const Key('bridge-crossing-receive'),
                value: BridgeFormat.coin(
                  c.receives,
                  r.destinationDecimals(c.direction),
                  r.destinationSymbol(c.direction),
                ),
              ),
              DexDetailRow(
                label: 'Bridge fee, paid to the bridge operator',
                value: BridgeFormat.coin(c.relayerFee, srcDec, srcSym),
              ),
              DexDetailRow(
                label: 'BEAM network fee',
                value: BridgeFormat.coin(c.beamNetworkFee, 8, 'BEAM'),
              ),
              if (!c.toEthereum)
                DexDetailRow(
                  label: 'Ethereum network fee',
                  value:
                      'up to '
                      '${BridgeFormat.coinShort(c.ethNetworkFee, 18, 'ETH')}',
                ),
              DexDetailRow(
                address: true,
                label: 'Your Ethereum wallet',
                value: bridgeShortAddress(c.ethAddress),
              ),
              if (c.msgId != null)
                DexDetailRow(
                  label: 'Bridge transfer',
                  valueKey: const Key('bridge-crossing-number'),
                  value: '#${c.msgId}',
                ),
              DexDetailRow(
                label: 'Started',
                value: BridgeFormat.ago(c.createdAt, now),
              ),
            ],
          ),
        ),
        if (links.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(alignment: WrapAlignment.center, spacing: 16, children: links),
        ],
        if (c.isOpen && controller.paused) ...[
          const SizedBox(height: 8),
          Text(
            'Campfire looks again when it is back on screen.',
            textAlign: TextAlign.center,
            style: STextStyles.label(context)
                .copyWith(color: colors.textSubtitle1),
          ),
        ],
      ],
    );
  }

  Widget _link(String key, String text, VoidCallback onTap) =>
      CustomTextButton(key: Key(key), text: text, onTap: onTap);

  void _open(Uri uri) =>
      unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
}

/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// 3-line spec (USER_PSYCHOLOGY §6):
// 1. Job: show which node the wallet uses and whether it is up to date, and
//    let the user run their own private node.
// 2. Primary CTA: none while all is well (a status panel); when the private
//    node needs the user, exactly one button naming the fix ("Try again",
//    "Start private node").
// 3. Taps from app open: wallet → network status (1) on phone and desktop;
//    the status chip opens it from any screen that shows one (1).
//
// Exit-intent check (§1.7) — what would make an impatient person leave:
// * A spinner with no words: every state has a sentence; the download shows
//   a percentage and how long it takes.
// * Fear the wallet is broken while the node downloads: "The wallet uses a
//   public node until your private node is ready, then switches by itself."
// * A disk that fills up: the space it needs and the space free, up front;
//   refused below the limit, stopped before the disk is full.
// * A failure with no way out: "Back on a public node — your wallet keeps
//   working", plus the one button that fixes it.
// * Jargon: none on screen (no "owner key", "fast sync", "explorer").

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/global/wallets_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/node/beam_node_panel_model.dart';
import '../../../wallets/beam/node/beam_node_panel_source.dart';
import '../../../wallets/beam/node/beam_private_node_coordinator.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../../widgets/beam/node/beam_node_widgets.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/custom_buttons/draggable_switch_button.dart';
import '../../../widgets/desktop/primary_button.dart';
import '../../../widgets/desktop/secondary_button.dart';
import '../../../widgets/progress_bar.dart';
import '../../../widgets/rounded_white_container.dart';

/// "Node & sync" for one open BEAM wallet: builds the wallet's panel source
/// and disposes it with the widget. Shows nothing for another coin.
class BeamWalletNodeSyncPanel extends ConsumerStatefulWidget {
  const BeamWalletNodeSyncPanel({
    super.key,
    required this.walletId,
    this.header = BeamNodePanelText.title,
  });

  final String walletId;
  final String header;

  @override
  ConsumerState<BeamWalletNodeSyncPanel> createState() =>
      _BeamWalletNodeSyncPanelState();
}

class _BeamWalletNodeSyncPanelState
    extends ConsumerState<BeamWalletNodeSyncPanel> {
  BeamWalletNodePanelSource? _source;

  @override
  void initState() {
    super.initState();
    final wallet = ref.read(pWallets).getWallet(widget.walletId);
    if (wallet is BeamWallet) _source = BeamWalletNodePanelSource(wallet);
  }

  @override
  void dispose() {
    _source?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    if (source == null) return const SizedBox.shrink();
    return BeamNodeSyncPanel(source: source, header: widget.header);
  }
}

/// The node and sync panel, in Campfire's network-settings style: a
/// section header with "Resync", the wallet's honest sync card, and the
/// private node card with its switch.
class BeamNodeSyncPanel extends StatefulWidget {
  const BeamNodeSyncPanel({
    super.key,
    required this.source,
    this.header = BeamNodePanelText.title,
  });

  final BeamNodePanelSource source;
  final String header;

  @override
  State<BeamNodeSyncPanel> createState() => _BeamNodeSyncPanelState();
}

class _BeamNodeSyncPanelState extends State<BeamNodeSyncPanel> {
  late BeamNodePanelSnapshot _snapshot;
  StreamSubscription<BeamNodePanelSnapshot>? _sub;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(BeamNodeSyncPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      unawaited(_sub?.cancel());
      _listen();
    }
  }

  void _listen() {
    _snapshot = widget.source.current;
    _sub = widget.source.changes.listen((s) {
      if (mounted) setState(() => _snapshot = s);
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desktop = BeamNodeLayout.isDesktop(context);
    final view = BeamNodePanelModel.describe(_snapshot);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              widget.header,
              style: desktop
                  ? STextStyles.desktopTextExtraExtraSmall(context)
                  : STextStyles.smallMed12(context),
            ),
            CustomTextButton(
              key: const Key('beamNodeResync'),
              text: 'Resync',
              onTap: () => unawaited(widget.source.refresh()),
            ),
          ],
        ),
        SizedBox(height: desktop ? 12 : 9),
        _SyncCard(
          view: view,
          busy: _snapshot.busy,
          onAction: (a) => unawaited(widget.source.perform(a)),
        ),
        SizedBox(height: desktop ? 12 : 9),
        _PrivateNodeCard(
          view: view,
          snapshot: _snapshot,
          onToggle: (on) =>
              unawaited(widget.source.setPrivateNodeEnabled(on)),
          onAction: (a) => unawaited(widget.source.perform(a)),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final desktop = BeamNodeLayout.isDesktop(context);
    return RoundedWhiteContainer(
      borderColor: desktop
          ? Theme.of(context).extension<StackColors>()!.background
          : null,
      padding: desktop ? const EdgeInsets.all(16) : const EdgeInsets.all(12),
      child: child,
    );
  }
}

TextStyle _titleStyle(BuildContext context, BeamNodeTone tone) {
  final desktop = BeamNodeLayout.isDesktop(context);
  final base = desktop
      ? STextStyles.desktopTextSmall(context)
      : STextStyles.w600_14(context);
  return tone == BeamNodeTone.problem
      ? base.copyWith(color: beamNodeToneColor(context, tone))
      : base;
}

TextStyle _bodyStyle(BuildContext context) => BeamNodeLayout.isDesktop(context)
    ? STextStyles.desktopTextExtraExtraSmall(context)
    : STextStyles.itemSubtitle(context);

TextStyle _strongBodyStyle(BuildContext context) => _bodyStyle(
  context,
).copyWith(color: Theme.of(context).extension<StackColors>()!.textDark);

class _SyncCard extends StatelessWidget {
  const _SyncCard({
    required this.view,
    required this.busy,
    required this.onAction,
  });

  final BeamNodePanelView view;
  final bool busy;
  final void Function(BeamNodePanelAction) onAction;

  @override
  Widget build(BuildContext context) {
    final address = view.nodeAddress;
    final action = view.syncAction;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BeamNodeToneIcon(tone: view.syncTone),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      view.syncTitle,
                      key: const Key('beamNodeSyncTitle'),
                      style: _titleStyle(context, view.syncTone),
                    ),
                    if (view.syncDetail != null) ...[
                      const SizedBox(height: 4),
                      Text(view.syncDetail!, style: _bodyStyle(context)),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      view.nodeTitle,
                      key: const Key('beamNodeCurrentNode'),
                      style: _strongBodyStyle(context),
                    ),
                    if (address != null)
                      Text(
                        address,
                        key: const Key('beamNodeAddress'),
                        style: _bodyStyle(context),
                      ),
                    if (view.heightLine != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        view.heightLine!,
                        key: const Key('beamNodeHeight'),
                        style: _bodyStyle(context),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (action != null) ...[
            const SizedBox(height: 12),
            SecondaryButton(
              key: const Key('beamNodeSyncAction'),
              label: BeamNodePanelText.actionLabel(action),
              enabled: !busy,
              buttonHeight: BeamNodeLayout.isDesktop(context)
                  ? ButtonHeight.m
                  : ButtonHeight.l,
              onPressed: () => onAction(action),
            ),
          ],
        ],
      ),
    );
  }
}

class _PrivateNodeCard extends StatelessWidget {
  const _PrivateNodeCard({
    required this.view,
    required this.snapshot,
    required this.onToggle,
    required this.onAction,
  });

  final BeamNodePanelView view;
  final BeamNodePanelSnapshot snapshot;
  final void Function(bool) onToggle;
  final void Function(BeamNodePanelAction) onAction;

  @override
  Widget build(BuildContext context) {
    final desktop = BeamNodeLayout.isDesktop(context);
    final colors = Theme.of(context).extension<StackColors>()!;
    if (!view.showPrivateNode) {
      return _Card(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BeamNodeToneIcon(tone: view.privateTone),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Your own private node',
                    style: _titleStyle(context, BeamNodeTone.neutral),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    BeamNodePanelText.notOnThisDevice,
                    style: _bodyStyle(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final p = snapshot.privateNode;
    final showStatus =
        view.toggleValue ||
        (p != null && p.phase != BeamPrivateNodePhase.off);
    final moment = view.moment;
    final primary = view.primaryAction;
    final busy = snapshot.busy;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      BeamNodePanelText.toggleLabel,
                      style: _titleStyle(context, BeamNodeTone.neutral),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      BeamNodePanelText.toggleExplainer,
                      style: _bodyStyle(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Semantics(
                label: BeamNodePanelText.toggleLabel,
                toggled: view.toggleValue,
                child: SizedBox(
                  height: 20,
                  width: 40,
                  child: DraggableSwitchButton(
                    // Rebuilt when the state changes from outside.
                    key: ValueKey('beamNodeToggle-${view.toggleValue}-$busy'),
                    isOn: view.toggleValue,
                    enabled: !busy,
                    onValueChanged: onToggle,
                  ),
                ),
              ),
            ],
          ),
          if (showStatus) ...[
            Padding(
              padding: EdgeInsets.symmetric(vertical: desktop ? 16 : 12),
              child: Container(height: 1, color: colors.background),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                BeamNodeToneIcon(tone: view.privateTone),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    view.privateTitle,
                    key: const Key('beamPrivateNodeTitle'),
                    style: _titleStyle(context, view.privateTone),
                  ),
                ),
                if (moment != null) ...[
                  const SizedBox(width: 8),
                  BeamStickerImage(
                    _sticker(moment),
                    key: Key('beamNodeSticker-${moment.name}'),
                    size: desktop ? 120 : 96,
                  ),
                ],
              ],
            ),
            if (view.progress != null) ...[
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, c) => ProgressBar(
                  width: c.maxWidth,
                  height: 5,
                  fillColor: beamNodeToneColor(context, view.privateTone),
                  backgroundColor: colors.textFieldDefaultBG,
                  percent: view.progress!,
                ),
              ),
            ],
            if (view.privateDetail != null) ...[
              const SizedBox(height: 8),
              Text(
                view.privateDetail!,
                key: const Key('beamPrivateNodeDetail'),
                style: _bodyStyle(context),
              ),
            ],
            if (view.diskLine != null) ...[
              const SizedBox(height: 8),
              Text(
                'Disk space: ${view.diskLine!}',
                key: const Key('beamPrivateNodeDisk'),
                style: _strongBodyStyle(context),
              ),
            ],
            if (primary != null) ...[
              SizedBox(height: desktop ? 16 : 12),
              PrimaryButton(
                key: const Key('beamPrivateNodePrimary'),
                label: BeamNodePanelText.actionLabel(primary),
                enabled: !busy,
                buttonHeight: desktop ? ButtonHeight.m : ButtonHeight.l,
                onPressed: () => onAction(primary),
              ),
            ],
            if (view.secondaryActions.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  for (final a in view.secondaryActions) ...[
                    CustomTextButton(
                      key: Key('beamPrivateNode-${a.name}'),
                      text: BeamNodePanelText.actionLabel(a),
                      enabled: !busy,
                      onTap: () => onAction(a),
                    ),
                    const SizedBox(width: 20),
                  ],
                ],
              ),
            ],
            if (view.toggleValue && view.privateTone != BeamNodeTone.problem)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  BeamNodePanelText.fallbackNote,
                  key: const Key('beamPrivateNodeFallback'),
                  style: _bodyStyle(context),
                ),
              ),
          ],
        ],
      ),
    );
  }

  static BeamSticker _sticker(BeamNodeMoment m) => switch (m) {
    BeamNodeMoment.syncing => BeamMoments.syncing,
    BeamNodeMoment.ready => BeamMoments.privateNodeReady,
    BeamNodeMoment.fellBack => BeamMoments.behindOrOffline,
  };
}

/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/util.dart';
import '../../../wallets/beam/node/beam_node_panel_model.dart';

/// Overrides Campfire's platform check ([Util.isDesktop]) for the node
/// widgets below it. The app never needs it; golden tests use it to render
/// the phone layout on a desktop test host.
class BeamNodeLayout extends InheritedWidget {
  const BeamNodeLayout({
    super.key,
    required this.desktop,
    required super.child,
  });

  final bool desktop;

  static bool isDesktop(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BeamNodeLayout>()?.desktop ??
      Util.isDesktop;

  @override
  bool updateShouldNotify(BeamNodeLayout oldWidget) =>
      oldWidget.desktop != desktop;
}

/// The colour of a [BeamNodeTone], from Campfire's theme.
Color beamNodeToneColor(BuildContext context, BeamNodeTone tone) {
  final c = Theme.of(context).extension<StackColors>()!;
  return switch (tone) {
    BeamNodeTone.good => c.accentColorGreen,
    BeamNodeTone.busy => c.accentColorYellow,
    BeamNodeTone.problem => c.accentColorRed,
    BeamNodeTone.neutral => c.textSubtitle1,
  };
}

/// Campfire's sync icon in a tinted circle, as on its "Blockchain status"
/// card: a signal for good, a turning signal while busy, a broken one for a
/// problem, and the node icon when nothing is going on.
class BeamNodeToneIcon extends StatelessWidget {
  const BeamNodeToneIcon({super.key, required this.tone, this.size});

  final BeamNodeTone tone;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final desktop = BeamNodeLayout.isDesktop(context);
    final s = size ?? (desktop ? 40.0 : 28.0);
    final color = beamNodeToneColor(context, tone);
    final asset = switch (tone) {
      BeamNodeTone.good => Assets.svg.radio,
      BeamNodeTone.busy => Assets.svg.radioSyncing,
      BeamNodeTone.problem => Assets.svg.radioProblem,
      BeamNodeTone.neutral => Assets.svg.node,
    };
    return Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(s),
      ),
      child: Center(
        child: SvgPicture.asset(
          asset,
          width: s / 2,
          height: s / 2,
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        ),
      ),
    );
  }
}

/// A small pill other screens can show next to a balance: which node the
/// wallet uses and whether it is up to date ("Public node · private 43%",
/// "Private node", "Catching up"). Tapping it opens the node panel.
class BeamNodeStatusChip extends StatelessWidget {
  const BeamNodeStatusChip({
    super.key,
    required this.label,
    required this.tone,
    this.onTap,
    this.semanticLabel,
  });

  /// From [BeamNodePanelView.chipLabel].
  BeamNodeStatusChip.fromView(
    BeamNodePanelView view, {
    Key? key,
    VoidCallback? onTap,
  }) : this(
         key: key,
         label: view.chipLabel,
         tone: view.chipTone,
         onTap: onTap,
         semanticLabel: '${view.chipLabel}. ${view.syncTitle}',
       );

  final String label;
  final BeamNodeTone tone;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final color = beamNodeToneColor(context, tone);
    final desktop = BeamNodeLayout.isDesktop(context);
    final chip = Container(
      padding: EdgeInsets.symmetric(
        horizontal: desktop ? 12 : 10,
        vertical: desktop ? 6 : 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(1000),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
                fontSize: desktop ? 13 : 12,
                fontWeight: FontWeight.w500,
                color: colors.textDark,
              ),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: onTap != null,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      child: onTap == null
          ? chip
          : MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: chip,
              ),
            ),
    );
  }
}

/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The desktop wallet's "My wallet" tabs (Send | Receive | Transactions) for
// a BEAM wallet: Campfire's CustomTabView, except that the Send tab is dimmed
// while the wallet may not send, exactly as the phone's Send button is, and
// says why (hover, or a click). The Send form inside keeps what was typed;
// its own notice says when sending comes back.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../notifications/show_flush_bar.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../wallet_home/beam_wallet_home.dart';

/// [titles] and [children] as in CustomTabView; the tab titled "Send"
/// follows the wallet's `sendPausedReason`.
class BeamDesktopWalletTabs extends ConsumerStatefulWidget {
  const BeamDesktopWalletTabs({
    super.key,
    required this.walletId,
    required this.titles,
    required this.children,
  }) : assert(titles.length == children.length);

  final String walletId;
  final List<String> titles;
  final List<Widget> children;

  @override
  ConsumerState<BeamDesktopWalletTabs> createState() =>
      _BeamDesktopWalletTabsState();
}

class _BeamDesktopWalletTabsState extends ConsumerState<BeamDesktopWalletTabs> {
  static const _duration = Duration(milliseconds: 250);

  /// How faint a paused Send is: the phone's dimmed Send button.
  static const _dimmed = 0.35;

  int _selected = 0;

  void _tap(int i, String? reason) {
    setState(() => _selected = i);
    if (reason != null) {
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.info,
          message: reason,
          context: context,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final paused = ref.watch(pBeamHome(widget.walletId)).sendPausedReason;
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              for (int i = 0; i < widget.titles.length; i++)
                Expanded(child: _tab(context, colors, i, paused)),
            ],
          ),
          Stack(
            children: [
              Container(height: 2, color: colors.backgroundAppBar),
              AnimatedSlide(
                offset: Offset(_selected.toDouble(), 0),
                duration: _duration,
                child: Container(
                  height: 2,
                  width: constraints.maxWidth / widget.titles.length,
                  color: colors.accentColorBlue,
                ),
              ),
            ],
          ),
          AnimatedSwitcher(
            duration: _duration,
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [...previous, ?current],
            ),
            child: AnimatedAlign(
              key: Key('${widget.titles[_selected]}_customTabKey'),
              alignment: Alignment.topCenter,
              duration: _duration,
              child: widget.children[_selected],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tab(BuildContext context, StackColors colors, int i, String? paused) {
    final title = widget.titles[i];
    final isSend = title == 'Send';
    final reason = isSend ? paused : null;
    final alpha = reason == null ? 1.0 : _dimmed;
    Text text(Color color) => Text(
      title,
      style: STextStyles.desktopTextExtraSmall(context)
          .copyWith(color: color.withValues(alpha: alpha)),
    );
    final tab = MouseRegion(
      key: isSend
          ? Key(
              reason == null
                  ? 'beamDesktopSendTabEnabled'
                  : 'beamDesktopSendTabDisabled',
            )
          : null,
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _tap(i, reason),
        child: Container(
          color: Colors.transparent,
          child: Column(
            children: [
              const SizedBox(height: 16),
              AnimatedCrossFade(
                firstChild: text(colors.accentColorBlue),
                secondChild: text(colors.textSubtitle1),
                crossFadeState: _selected == i
                    ? CrossFadeState.showFirst
                    : CrossFadeState.showSecond,
                duration: _duration,
              ),
              const SizedBox(height: 19),
            ],
          ),
        ),
      ),
    );
    if (reason == null) return tab;
    return Tooltip(
      key: const Key('beamDesktopSendTabReason'),
      message: reason,
      child: tab,
    );
  }
}

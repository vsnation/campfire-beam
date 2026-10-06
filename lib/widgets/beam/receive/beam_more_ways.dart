/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../notifications/show_flush_bar.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/models/beam_address.dart';
import '../../desktop/secondary_button.dart';
import '../../rounded_container.dart';
import 'beam_receive_model.dart';
import 'beam_receive_text.dart';
import 'beam_receive_widgets.dart';

/// "More ways to receive": offline, max-privacy and public addresses.
///
/// Secondary and collapsed: most people only need the regular address
/// above it. The three types are always listed; while the wallet cannot
/// find payments to them (no own node with its key, no body requests) they
/// are shown disabled with the reason and the next step, never hidden and
/// never offered anyway.
class BeamMoreWaysToReceive extends StatefulWidget {
  const BeamMoreWaysToReceive({
    super.key,
    required this.model,
    required this.clipboard,
    required this.desktop,
    this.initiallyOpen = false,
  });

  final BeamReceiveModel model;
  final ClipboardInterface clipboard;
  final bool desktop;
  final bool initiallyOpen;

  static const types = [
    BeamAddressType.offline,
    BeamAddressType.maxPrivacy,
    BeamAddressType.publicOffline,
  ];

  @override
  State<BeamMoreWaysToReceive> createState() => _BeamMoreWaysToReceiveState();
}

class _BeamMoreWaysToReceiveState extends State<BeamMoreWaysToReceive> {
  late bool _open = widget.initiallyOpen;

  BeamReceiveModel get _model => widget.model;

  Future<void> _make(BeamAddressType type) async {
    final String token;
    try {
      token = await _model.privateAddress(type);
    } catch (e) {
      if (!mounted) return;
      await showFloatingFlushBar(
        type: FlushBarType.warning,
        message: BeamReceiveText.error(e),
        context: context,
        duration: const Duration(seconds: 5),
      );
      return;
    }
    if (!mounted) return;
    await showBeamAddressDialog(
      context,
      type: type,
      address: token,
      clipboard: widget.clipboard,
      share: _model.backend.share,
      desktop: widget.desktop,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final gate = _model.privateReceive;
    final why = BeamReceiveText.privateReason(gate);
    final openSettings = _model.backend.openNodeSettings;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BeamCard(
          key: BeamReceiveKeys.moreWays,
          desktop: widget.desktop,
          onPressed: () => setState(() => _open = !_open),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      BeamReceiveText.moreWays,
                      style: STextStyles.w600_14(context),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      BeamReceiveText.moreWaysHint,
                      style: STextStyles.itemSubtitle12(context),
                    ),
                  ],
                ),
              ),
              SvgPicture.asset(
                _open ? Assets.svg.chevronUp : Assets.svg.chevronDown,
                width: 12,
                height: 6,
                colorFilter: ColorFilter.mode(
                  colors.textSubtitle1,
                  BlendMode.srcIn,
                ),
              ),
            ],
          ),
        ),
        if (_open && !gate.available) ...[
          const SizedBox(height: 8),
          RoundedContainer(
            key: BeamReceiveKeys.privateReason,
            color: colors.warningBackground,
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  BeamReceiveText.needsPrivateNode,
                  style: STextStyles.w600_14(
                    context,
                  ).copyWith(color: colors.warningForeground),
                ),
                const SizedBox(height: 4),
                Text(
                  why.reason,
                  style: STextStyles.itemSubtitle12(
                    context,
                  ).copyWith(color: colors.warningForeground),
                ),
                if (why.showNodeSettings && openSettings != null) ...[
                  const SizedBox(height: 10),
                  SecondaryButton(
                    key: BeamReceiveKeys.openNodeSettings,
                    label: BeamReceiveText.openNodeSettings,
                    buttonHeight: ButtonHeight.m,
                    onPressed: () =>
                        openSettings(context, desktop: widget.desktop),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (_open)
          for (final type in BeamMoreWaysToReceive.types) ...[
            const SizedBox(height: 8),
            _TypeTile(
              type: type,
              desktop: widget.desktop,
              enabled: gate.available && _model.makingPrivate == null,
              busy: _model.makingPrivate == type,
              onTap: () => _make(type),
            ),
          ],
      ],
    );
  }
}

class _TypeTile extends StatelessWidget {
  const _TypeTile({
    required this.type,
    required this.desktop,
    required this.enabled,
    required this.busy,
    required this.onTap,
  });

  final BeamAddressType type;
  final bool desktop;
  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final muted = !enabled && !busy;
    final titleColor = muted ? colors.textSubtitle3 : colors.textDark;
    final bodyColor = muted ? colors.textSubtitle3 : colors.textSubtitle1;
    return Semantics(
      button: true,
      enabled: enabled,
      child: BeamCard(
        key: BeamReceiveKeys.typeTile(type),
        desktop: desktop,
        onPressed: enabled ? onTap : null,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    BeamReceiveText.typeTitle(type),
                    style: STextStyles.w500_14(
                      context,
                    ).copyWith(color: titleColor),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    busy
                        ? BeamReceiveText.making
                        : BeamReceiveText.typeExplainer(type),
                    style: STextStyles.itemSubtitle12(
                      context,
                    ).copyWith(color: bodyColor),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (busy)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.accentColorDark,
                ),
              )
            else
              SvgPicture.asset(
                muted ? Assets.svg.lock : Assets.svg.chevronRight,
                width: 14,
                height: 14,
                colorFilter: ColorFilter.mode(
                  muted ? colors.textSubtitle3 : colors.textSubtitle1,
                  BlendMode.srcIn,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

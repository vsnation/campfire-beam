/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// 3-line spec:
// 1. Job: the node and sync panel on its own page, for the node status chip
//    (the network settings page embeds the same panel).
// 2. Primary CTA: the panel's own (only when the private node needs the
//    user).
// 3. Taps from app open: 1 (tap the status chip).
//
// Exit-intent check: see beam_node_sync_panel.dart; this page adds
// only Campfire's app bar and back arrow, so nothing new to leave over.

import 'package:flutter/material.dart';

import '../../../pages_desktop_specific/beam/node/desktop_beam_node_sync_dialog.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../../wallets/beam/node/beam_node_panel_model.dart';
import '../../../wallets/beam/node/beam_node_panel_source.dart';
import '../../../widgets/background.dart';
import '../../../widgets/custom_buttons/app_bar_icon_button.dart';
import 'beam_node_sync_panel.dart';

/// Opens the node panel for [walletId]: a page on phones, a dialog on
/// desktop (Campfire's split).
Future<void> showBeamNodeSync(
  BuildContext context, {
  required String walletId,
}) {
  if (Util.isDesktop) {
    return showDialog<void>(
      context: context,
      builder: (_) => DesktopBeamNodeSyncDialog(walletId: walletId),
    );
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => BeamNodeSyncView(walletId: walletId),
    ),
  );
}

/// The phone page around [BeamNodeSyncPanel].
class BeamNodeSyncView extends StatelessWidget {
  const BeamNodeSyncView({super.key, this.walletId, this.source})
    : assert(walletId != null || source != null);

  /// The wallet whose panel to show.
  final String? walletId;

  /// A ready source instead (tests).
  final BeamNodePanelSource? source;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final s = source;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.background,
          leading: AppBarBackButton(
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Text(
            BeamNodePanelText.title,
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: s != null
                ? BeamNodeSyncPanel(source: s, header: 'Status')
                : BeamWalletNodeSyncPanel(
                    walletId: walletId!,
                    header: 'Status',
                  ),
          ),
        ),
      ),
    );
  }
}

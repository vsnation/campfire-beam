/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// 3-line spec (USER_PSYCHOLOGY §6):
// 1. Job: the node and sync panel as a desktop dialog, sized like Campfire's
//    "Network" dialog (580 wide).
// 2. Primary CTA: the panel's own (only when the private node needs the
//    user); closing is the dialog's X.
// 3. Clicks from app open: 1 (the status chip).
//
// Exit-intent check (§1.7): see beam_node_sync_panel.dart.

import 'package:flutter/material.dart';

import '../../../pages/beam/node/beam_node_sync_panel.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/node/beam_node_panel_model.dart';
import '../../../wallets/beam/node/beam_node_panel_source.dart';
import '../../../widgets/desktop/desktop_dialog.dart';
import '../../../widgets/desktop/desktop_dialog_close_button.dart';

class DesktopBeamNodeSyncDialog extends StatelessWidget {
  const DesktopBeamNodeSyncDialog({super.key, this.walletId, this.source})
    : assert(walletId != null || source != null);

  final String? walletId;

  /// A ready source instead (tests).
  final BeamNodePanelSource? source;

  @override
  Widget build(BuildContext context) {
    final s = source;
    return DesktopDialog(
      maxWidth: 580,
      maxHeight: null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 32),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  BeamNodePanelText.title,
                  style: STextStyles.desktopH3(context),
                ),
                const DesktopDialogCloseButton(),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(32, 8, 32, 32),
              child: s != null
                  ? BeamNodeSyncPanel(source: s, header: 'Status')
                  : BeamWalletNodeSyncPanel(
                      walletId: walletId!,
                      header: 'Status',
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

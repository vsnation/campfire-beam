/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6, §1.4) — empty BEAM history:
//   Job:  say the history is empty because nothing has happened yet, and
//         get the first BEAM in.
//   CTA:  "Receive BEAM".
//   Taps: open wallet → Receive BEAM (1).
// Exit-intent: "Is my wallet broken / where is my money?" → the text says
// there is simply nothing yet and the button goes straight to receiving.
// The Beam girl ("send me beams") sits above it, secondary to the button.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../pages/receive_view/receive_view.dart';
import '../../../pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_receive.dart';
import '../../../utilities/text_styles.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import '../../desktop/primary_button.dart';
import '../../rounded_white_container.dart';
import '../stickers/beam_sticker.dart';
import 'beam_tx_backend.dart';

/// Campfire's "no transactions" card for a BEAM wallet, with a one-tap way
/// to receive.
class BeamNoTransactions extends ConsumerWidget {
  const BeamNoTransactions({super.key, required this.walletId, this.onReceive});

  final String walletId;

  /// Replaces the default (Campfire's receive screen) — for tests.
  final VoidCallback? onReceive;

  Future<void> _receive(BuildContext context, bool isDesktop) async {
    if (onReceive != null) return onReceive!();
    if (isDesktop) {
      await showDialog<void>(
        context: context,
        builder: (context) => DesktopDialog(
          maxHeight: null,
          maxWidth: 580,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 32),
                    child: Text(
                      'Receive BEAM',
                      style: STextStyles.desktopH3(context),
                    ),
                  ),
                  const DesktopDialogCloseButton(),
                ],
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                    child: DesktopReceive(walletId: walletId),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      await Navigator.of(context)
          .pushNamed(ReceiveView.routeName, arguments: walletId);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDesktop = ref.watch(pBeamTxIsDesktop);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RoundedWhiteContainer(
          padding: EdgeInsets.all(isDesktop ? 20 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(
                child: BeamStickerImage(BeamMoments.emptyHistory, size: 160),
              ),
              const SizedBox(height: 12),
              Text(
                'No transactions yet',
                textAlign: TextAlign.center,
                style: isDesktop
                    ? STextStyles.desktopTextSmall(context)
                    : STextStyles.titleBold12(context),
              ),
              const SizedBox(height: 6),
              Text(
                'Payments you send and receive will show up here.',
                textAlign: TextAlign.center,
                style: STextStyles.itemSubtitle(context),
              ),
              const SizedBox(height: 16),
              Center(
                child: PrimaryButton(
                  key: const Key('beamNoTxReceive'),
                  width: isDesktop ? 220 : null,
                  label: 'Receive BEAM',
                  onPressed: () => _receive(context, isDesktop),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

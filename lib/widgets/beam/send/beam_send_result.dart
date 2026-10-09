/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What the user sees after pressing Send: the payment went out (with its
// transaction id and the way to it in history), or it did not and why.
//
// Spec:
//   1. Job: confirm the outcome at once (silence feels like failure)
//      and say what happens next; on failure, say nothing was sent (when
//      that is true) and the one thing to do.
//   2. Primary CTA: "View in history" (sent) / "Back to the payment" or
//      "Check my history" (not sent / not sure).
//   3. Taps: shown right after the PIN, no extra tap.
//
// The Beam girl (BeamMoments.sendDone / somethingWentWrong) is secondary
// decoration here and never on the confirmation screen itself.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/bans/bans_exceptions.dart';
import '../../../wallets/beam/wallet/beam_wallet_errors.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/primary_button.dart';
import '../../rounded_white_container.dart';
import '../../stack_dialog.dart';
import '../stickers/beam_sticker.dart';
import '../wiring/beam_desktop_wallet_tabs.dart';
import 'beam_send_format.dart';
import 'beam_send_model.dart';
import 'beam_send_review.dart';

/// The "payment sent" sheet. Returns when the user leaves it.
Future<void> showBeamSendSuccess(
  BuildContext context, {
  required BeamSendReview review,
  required String txId,
  required bool desktop,
  String? walletId,
  ClipboardInterface clipboard = const ClipboardWrapper(),
}) => showDialog<void>(
  context: context,
  useRootNavigator: true,
  barrierDismissible: false,
  builder: (context) => BeamSendSuccess(
    review: review,
    txId: txId,
    desktop: desktop,
    walletId: walletId,
    clipboard: clipboard,
  ),
);

/// The "not sent" sheet. Returns when the user leaves it.
Future<void> showBeamSendFailure(
  BuildContext context, {
  required Object error,
  required bool outcomeUnknown,
  required bool desktop,
}) => showDialog<void>(
  context: context,
  useRootNavigator: true,
  builder: (context) => BeamSendFailure(
    error: error,
    outcomeUnknown: outcomeUnknown,
    desktop: desktop,
  ),
);

class BeamSendSuccess extends StatelessWidget {
  const BeamSendSuccess({
    super.key,
    required this.review,
    required this.txId,
    required this.desktop,
    this.walletId,
    this.clipboard = const ClipboardWrapper(),
  });

  final BeamSendReview review;
  final String txId;
  final bool desktop;

  /// The paying wallet: "View in history" brings its desktop tabs to
  /// Transactions (on a phone the history is already on the home).
  final String? walletId;
  final ClipboardInterface clipboard;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final what = BeamSendFormat.amount(review.amount, review.asset);
    final to = review.isName
        ? review.destination
        : BeamSendFormat.shortAddress(review.destination);
    final next = review.isName
        ? 'The owner of ${review.destination} can claim it from their wallet '
              'whenever they like.'
        : "It completes when the receiver's wallet comes online. You can "
              'follow it in your history.';
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: BeamAnimatedStickerView(BeamMoments.sendDone, size: 160),
        ),
        const SizedBox(height: 12),
        Text(
          'Payment sent',
          textAlign: TextAlign.center,
          style: desktop
              ? STextStyles.desktopH3(context)
              : STextStyles.pageTitleH2(context),
        ),
        const SizedBox(height: 8),
        Text(
          '$what to $to.',
          key: const Key('beamSendSuccessSummary'),
          textAlign: TextAlign.center,
          style: STextStyles.itemSubtitle12(context),
        ),
        const SizedBox(height: 4),
        Text(
          next,
          textAlign: TextAlign.center,
          style: STextStyles.label(context),
        ),
        const SizedBox(height: 16),
        RoundedWhiteContainer(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          borderColor: c.textFieldDefaultBG,
          child: Row(
            children: [
              Text('Transaction ID', style: STextStyles.label(context)),
              const Spacer(),
              SelectableText(
                BeamSendFormat.shortTxId(txId),
                key: const Key('beamSendSuccessTxId'),
                style: STextStyles.itemSubtitle12(context),
              ),
              IconButton(
                tooltip: 'Copy the transaction ID',
                onPressed: () => clipboard.setData(ClipboardData(text: txId)),
                icon: SvgPicture.asset(
                  Assets.svg.copy,
                  width: 14,
                  height: 14,
                  colorFilter: ColorFilter.mode(
                    c.infoItemIcons,
                    BlendMode.srcIn,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        PrimaryButton(
          key: const Key('beamSendSuccessDone'),
          label: 'View in history',
          buttonHeight: desktop ? ButtonHeight.l : null,
          onPressed: () {
            final id = walletId;
            if (id != null) {
              ProviderScope.containerOf(context, listen: false)
                  .read(pBeamShowHistoryRequest(id).state)
                  .state++;
            }
            Navigator.of(context, rootNavigator: true).pop();
          },
        ),
      ],
    );
    if (desktop) {
      return DesktopDialog(
        maxWidth: 480,
        maxHeight: double.infinity,
        child: Padding(padding: const EdgeInsets.all(32), child: body),
      );
    }
    return PopScope(canPop: false, child: StackDialogBase(child: body));
  }
}

class BeamSendFailure extends StatelessWidget {
  const BeamSendFailure({
    super.key,
    required this.error,
    required this.outcomeUnknown,
    required this.desktop,
  });

  final Object error;

  /// The connection dropped while sending: it may have gone out.
  final bool outcomeUnknown;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final title = outcomeUnknown
        ? 'Check your history before sending again'
        : error is BansOwnerChanged
        ? 'Nothing was sent'
        : 'Payment not sent';
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: BeamStickerImage(BeamMoments.somethingWentWrong, size: 140),
        ),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: desktop
              ? STextStyles.desktopH3(context)
              : STextStyles.pageTitleH2(context),
        ),
        const SizedBox(height: 8),
        Text(
          outcomeUnknown && error is! BeamWalletException
              ? 'The connection to the wallet dropped while sending, so it '
                    "isn't certain whether the payment went out. Check your "
                    'history before sending again.'
              : BeamSendModel.describeError(error),
          key: const Key('beamSendFailureMessage'),
          textAlign: TextAlign.center,
          style: STextStyles.itemSubtitle12(context),
        ),
        const SizedBox(height: 20),
        PrimaryButton(
          key: const Key('beamSendFailureDone'),
          label: outcomeUnknown
              ? 'Check my history'
              : error is BansOwnerChanged
              ? 'Check the name again'
              : 'Back to the payment',
          buttonHeight: desktop ? ButtonHeight.l : null,
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
    if (desktop) {
      return DesktopDialog(
        maxWidth: 480,
        maxHeight: double.infinity,
        child: Padding(padding: const EdgeInsets.all(32), child: body),
      );
    }
    return StackDialogBase(child: body);
  }
}

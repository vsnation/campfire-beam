/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (no dead ends) — empty BEAM history:
//   Job:  say the history is empty because nothing has happened yet, and
//         get the first BEAM in.
//   CTA:  "Receive BEAM".
//   Taps: open wallet → Receive BEAM (1).
// Exit-intent: "Is my wallet broken / where is my money?" → the text says
// there is simply nothing yet and the button goes straight to receiving.
// A restored wallet is different: a restore finds coins, not past payments
// (BEAM keeps no history on the chain). While the scan runs the card says
// the coins are still being found, with how far it is; once it is over and
// the wallet holds something, it says why the list is empty and that the
// balance is complete. Never "nothing yet" next to a balance.
// The Beam girl sits above it, secondary to the button: where the height is
// fixed she gets only what the words and the button leave (measured, not
// guessed: on desktop a fixed guess cut the button off under the scanning
// banner), and whatever still does not fit scrolls.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../pages/receive_view/receive_view.dart';
import '../../../pages/wallet_view/wallet_view.dart';
import '../../../pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_receive.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import '../../desktop/primary_button.dart';
import '../../rounded_white_container.dart';
import '../stickers/beam_sticker.dart';
import '../wallet_home/beam_wallet_home.dart';
import 'beam_tx_backend.dart';

/// Campfire's "no transactions" card for a BEAM wallet, with a one-tap way
/// to receive.
class BeamNoTransactions extends ConsumerWidget {
  const BeamNoTransactions({super.key, required this.walletId, this.onReceive});

  final String walletId;

  /// Replaces the default (Campfire's receive screen) — for tests.
  final VoidCallback? onReceive;

  static const double _stickerSize = 160;

  /// Smaller than this, the sticker is left out.
  static const double _minSticker = 64;

  /// The button's height: [ButtonHeight.xl], which PrimaryButton sizes by
  /// the platform itself.
  static double get _buttonHeight => Util.isDesktop ? 70 : 46;

  /// How tall [text] lays out in [width].
  static double _textHeight(
    BuildContext context,
    String text,
    TextStyle style,
    double width,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: TextAlign.center,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: width);
    final height = painter.height;
    painter.dispose();
    return height.ceilToDouble();
  }

  /// What a restore leaves out of the list.
  static const _noPastPayments =
      "Payments from before the restore aren't listed: BEAM keeps no history "
      'on the chain.';

  /// The title: a restore scan still running ([scan]), a restored wallet
  /// that holds something ([restoredWithFunds]), or simply nothing yet.
  static String title(BeamCoinScan? scan, {bool restoredWithFunds = false}) {
    if (scan != null) return 'Still looking for your coins';
    if (restoredWithFunds) return 'No payments since the restore';
    return 'No transactions yet';
  }

  /// The line under the title.
  static String detail(BeamCoinScan? scan, {bool restoredWithFunds = false}) {
    if (scan != null) {
      final p = scan.percent;
      return 'They show in your balance as they are found'
          '${p == null ? '' : ' ($p%)'}. $_noPastPayments';
    }
    if (restoredWithFunds) {
      return '$_noPastPayments Your balance is complete, and new payments '
          'appear here.';
    }
    return 'Payments you send and receive will show up here.';
  }

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
    final scan = ref.watch(pBeamCoinScan(walletId));
    final restored =
        scan == null && ref.watch(pBeamRestoredWithFunds(walletId));
    // On a phone the bar floats over the bottom of the list, as under
    // Campfire's own last transaction.
    final bottom = isDesktop ? 0.0 : WalletView.navBarHeight + 14;
    final pad = isDesktop ? 20.0 : 16.0;
    final heading = title(scan, restoredWithFunds: restored);
    final headingStyle = isDesktop
        ? STextStyles.desktopTextSmall(context)
        : STextStyles.titleBold12(context);
    final words = detail(scan, restoredWithFunds: restored);
    final wordsStyle = STextStyles.itemSubtitle(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxHeight;
        // A short window or phone leaves little room under the balance: the
        // sticker shrinks, then goes, before the words or the button do.
        var sticker = _stickerSize;
        if (room.isFinite) {
          final width = constraints.maxWidth - 2 * pad;
          final rest =
              2 * pad +
              _textHeight(context, heading, headingStyle, width) +
              6 +
              _textHeight(context, words, wordsStyle, width) +
              16 +
              _buttonHeight;
          sticker = (room - bottom - rest - 12).clamp(0.0, _stickerSize);
        }
        final card = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RoundedWhiteContainer(
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (sticker >= _minSticker) ...[
                    Center(
                      child: BeamStickerImage(
                        scan == null
                            ? BeamMoments.emptyHistory
                            : BeamMoments.coinsOnTheirWay,
                        key: const Key('beamNoTxSticker'),
                        size: sticker,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Text(
                    heading,
                    textAlign: TextAlign.center,
                    style: headingStyle,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    words,
                    key: const Key('beamNoTxDetail'),
                    textAlign: TextAlign.center,
                    style: wordsStyle,
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: PrimaryButton(
                      key: const Key('beamNoTxReceive'),
                      width: isDesktop ? 220 : null,
                      buttonHeight: ButtonHeight.xl,
                      label: 'Receive BEAM',
                      onPressed: () => _receive(context, isDesktop),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: bottom),
          ],
        );
        // Scrolls rather than overflows where the height is fixed; sized by
        // its content where it is not (a scroll view cannot be).
        return room.isFinite ? SingleChildScrollView(child: card) : card;
      },
    );
  }
}

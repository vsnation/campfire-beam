/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../notifications/show_flush_bar.dart';
import '../../../pages/pinpad_views/lock_screen_view.dart';
import '../../../pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_auth_send.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import 'beam_layout.dart';

/// Asks the user to prove it is them before money moves: true only when
/// they did. [reason] is shown by the system biometrics prompt.
typedef BeamSpendAuthorizer = Future<bool> Function(
  BuildContext context, {
  required String reason,
});

/// Campfire's own gate, exactly as `ConfirmTransactionView` uses it: the
/// wallet password in a desktop dialog ([DesktopAuthSend]), the PIN screen
/// ([LockscreenView], with biometrics when enabled) on a phone. A wrong
/// password or PIN shows Campfire's "Invalid …" bar.
Future<bool> campfireAuthorizeSpend(
  BuildContext context, {
  required String reason,
}) async {
  final desktop = BeamLayoutScope.isDesktop(context);
  final bool? unlocked;
  if (desktop) {
    unlocked = await showDialog<bool?>(
      context: context,
      builder: (context) => DesktopDialog(
        maxWidth: 580,
        maxHeight: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [DesktopDialogCloseButton()],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 32, right: 32, bottom: 32),
              child: DesktopAuthSend(coin: Beam(CryptoCurrencyNetwork.main)),
            ),
          ],
        ),
      ),
    );
  } else {
    unlocked = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(
        settings: const RouteSettings(name: '/beamContractLockscreen'),
        builder: (_) => LockscreenView(
          showBackButton: true,
          popOnSuccess: true,
          routeOnSuccessArguments: true,
          routeOnSuccess: '',
          biometricsCancelButtonString: 'CANCEL',
          biometricsLocalizedReason: reason,
          biometricsAuthenticationTitle: 'Confirm transaction',
        ),
      ),
    );
  }
  if (unlocked == false && context.mounted) {
    unawaited(
      showFloatingFlushBar(
        type: FlushBarType.warning,
        message: desktop ? 'Invalid passphrase' : 'Invalid PIN',
        context: context,
      ),
    );
  }
  return unlocked == true;
}

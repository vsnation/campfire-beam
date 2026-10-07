/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';

import '../../../pages/pinpad_views/lock_screen_view.dart';
import '../../../pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_auth_send.dart';
import '../../../utilities/util.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';

/// Campfire's own confirmation gate, exactly as the send flow uses it
/// (`ConfirmTransactionView`): the PIN lock screen on mobile, the wallet
/// password dialog on desktop.
///
/// True: the user passed. False: wrong PIN / password. Null: backed out.
Future<bool?> campfireDexAuthGate(
  BuildContext context, {
  required String reason,
}) async {
  if (Util.isDesktop) {
    final unlocked = await showDialog<bool?>(
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
              child: DesktopAuthSend(
                coin: Beam(CryptoCurrencyNetwork.main),
                // "Enter your wallet password to swap", not "to send BEAM".
                action: dexAuthAction(reason),
              ),
            ),
          ],
        ),
      ),
    );
    return unlocked;
  }
  return Navigator.push<bool>(
    context,
    MaterialPageRoute<bool>(
      builder: (_) => LockscreenView(
        showBackButton: true,
        popOnSuccess: true,
        routeOnSuccessArguments: true,
        routeOnSuccess: "",
        biometricsCancelButtonString: "CANCEL",
        biometricsLocalizedReason: reason,
        biometricsAuthenticationTitle: "Confirm transaction",
      ),
      settings: const RouteSettings(name: "/beamDexConfirmLockscreen"),
    ),
  );
}

/// What a DEX [reason] ("Authenticate to swap") asks the password for:
/// "swap". Null for any other wording, which keeps Campfire's own prompt.
String? dexAuthAction(String reason) {
  const lead = 'Authenticate to ';
  return reason.startsWith(lead) ? reason.substring(lead.length) : null;
}

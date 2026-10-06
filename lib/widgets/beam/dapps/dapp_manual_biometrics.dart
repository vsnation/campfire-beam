/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../utilities/biometrics.dart';

/// Signature of [Biometrics.authenticate].
typedef DappBiometricPrompt =
    Future<bool> Function({
      required String cancelButtonText,
      required String localizedReason,
      required String title,
    });

/// Biometrics for the dApp approval PIN screen that never start by
/// themselves.
///
/// Campfire's `LockscreenView` starts a biometric prompt from `initState`
/// (`lock_screen_view.dart:261`). On the dApp path that turns "tap Approve,
/// glance at the phone" into an approval, which a page can engineer by
/// placing its own button where Approve will appear. This declines that
/// first, automatic call without prompting — the PIN pad shows as usual —
/// and prompts for real only when the user taps "Use biometrics" on the
/// lock screen, which calls again.
class DappManualBiometrics extends Biometrics {
  DappManualBiometrics({this.prompt});

  /// The real prompt; Campfire's [Biometrics] when null (tests pass a
  /// fake).
  final DappBiometricPrompt? prompt;
  bool _declinedAutomatic = false;

  /// Prompts actually shown.
  int prompts = 0;

  @override
  Future<bool> authenticate({
    required String cancelButtonText,
    required String localizedReason,
    required String title,
  }) {
    if (!_declinedAutomatic) {
      _declinedAutomatic = true;
      return Future.value(false);
    }
    prompts++;
    final prompt = this.prompt;
    if (prompt != null) {
      return prompt(
        cancelButtonText: cancelButtonText,
        localizedReason: localizedReason,
        title: title,
      );
    }
    return super.authenticate(
      cancelButtonText: cancelButtonText,
      localizedReason: localizedReason,
      title: title,
    );
  }
}

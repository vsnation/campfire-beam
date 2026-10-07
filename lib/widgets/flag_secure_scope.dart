/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:mobile_app_privacy/mobile_app_privacy.dart';

import '../utilities/prefs.dart';

/// Keeps Android's `FLAG_SECURE` on while [child] is on screen, so recovery
/// words never appear in a screenshot, a screen recording or the recents
/// thumbnail. Used by the widgets that show the words (`MnemonicTable`,
/// `WordTable`), so every screen that shows them is covered.
///
/// Several scopes can be mounted at once (the phrase screen stays under the
/// verify screen): the flag goes on with the first and, when the last one
/// goes, back to the user's own "Disable screenshots" setting, never simply
/// off. Does nothing off Android (iOS has no such flag; desktop has no
/// screenshot API to block).
class FlagSecureScope extends StatefulWidget {
  const FlagSecureScope({super.key, required this.child});

  final Widget child;

  /// Replaces the platform call, for tests. When set it is used on every
  /// platform.
  @visibleForTesting
  static Future<void> Function(bool enable)? debugSetFlagSecure;

  /// Replaces the user's "Disable screenshots" setting
  /// (`Prefs.disableScreenShots`, the one `main.dart` applies), for tests.
  @visibleForTesting
  static bool Function()? debugUserWantsSecure;

  /// How many scopes are mounted right now.
  @visibleForTesting
  static int get activeCount => _FlagSecureScopeState._active;

  @override
  State<FlagSecureScope> createState() => _FlagSecureScopeState();
}

class _FlagSecureScopeState extends State<FlagSecureScope> {
  static int _active = 0;
  static MobileAppPrivacy? _privacy;

  static bool _userWantsSecure() =>
      (FlagSecureScope.debugUserWantsSecure ??
      () => Prefs.instance.disableScreenShots)();

  static Future<void> Function(bool)? get _set {
    final debug = FlagSecureScope.debugSetFlagSecure;
    if (debug != null) return debug;
    if (!Platform.isAndroid) return null;
    return (_privacy ??= MobileAppPrivacy()).setFlagSecure;
  }

  @override
  void initState() {
    super.initState();
    if (_active++ == 0) unawaited(_set?.call(true));
  }

  @override
  void dispose() {
    if (--_active == 0) unawaited(_set?.call(_userWantsSecure()));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

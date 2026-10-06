/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';

import '../../../utilities/util.dart';
import '../../desktop/primary_button.dart';
import '../../desktop/secondary_button.dart';
import 'airdrop_text.dart';
import 'beam_layout.dart';
import 'beam_spend_auth.dart';

/// "Authorize, then send" for a confirmation screen, with the in-flight
/// flag set before the first `await` so a second tap cannot start a
/// second send.
mixin BeamSendFlow<T extends StatefulWidget> on State<T> {
  bool sending = false;
  BeamProblem? problem;

  /// Runs [send] after [authorize] succeeds. Returns its result, or null
  /// when the user backed out or it failed ([problem] then says why).
  Future<R?> runSend<R>({
    required BeamSpendAuthorizer authorize,
    required String reason,
    required Future<R> Function() send,
    required BeamProblem Function(Object error) explain,
  }) async {
    if (sending) return null;
    setState(() {
      sending = true;
      problem = null;
    });
    try {
      if (!await authorize(context, reason: reason)) return null;
      return await send();
    } catch (e) {
      if (mounted) setState(() => problem = explain(e));
      return null;
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }
}

/// The bottom action area: one primary button, optionally one secondary
/// button above it. While [busy] the primary shows [busyLabel] and ignores
/// taps.
class BeamCtaBar extends StatelessWidget {
  const BeamCtaBar({
    super.key,
    required this.label,
    required this.onPressed,
    this.enabled = true,
    this.busy = false,
    this.busyLabel = 'Working…',
    this.secondaryLabel,
    this.onSecondary,
    this.primaryKey,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool enabled;
  final bool busy;
  final String busyLabel;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final Key? primaryKey;

  @override
  Widget build(BuildContext context) {
    final desktop = BeamLayoutScope.isDesktop(context);
    final height = desktop ? ButtonHeight.l : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (secondaryLabel != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SecondaryButton(
              label: secondaryLabel,
              buttonHeight: height,
              onPressed: busy ? null : onSecondary,
              enabled: !busy && onSecondary != null,
            ),
          ),
        Builder(
          builder: (context) {
            final on = enabled && !busy && onPressed != null;
            // Campfire's own button and text style, but a label with an
            // amount in it can be long: it shrinks to fit rather than
            // overflowing a narrow phone.
            final style = PrimaryButton(
              enabled: on,
              buttonHeight: height,
            ).getStyle(Util.isDesktop, context);
            return PrimaryButton(
              key: primaryKey,
              buttonHeight: height,
              enabled: on,
              onPressed: busy ? null : onPressed,
              icon: Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(busy ? busyLabel : label, style: style),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

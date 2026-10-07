/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Makes the decimal key of the phone's keyboard type the separator an
/// amount field expects.
///
/// A phone's decimal pad offers only its region's separator: on an iPhone
/// set to a region that writes 0,5 there is no "." key at all. Campfire's
/// amount fields expect one separator (the app locale's, or "." on the DEX),
/// so without this an amount like 0.5 could not be typed (seen on the iOS
/// simulator of a Mac set to Russia).
///
/// Only a single typed "," or "." is changed, never pasted text: "1,000"
/// pasted from elsewhere may be a thousand and is left for the field to
/// refuse rather than turned into 1.0.
class BeamDecimalKeyFormatter extends TextInputFormatter {
  BeamDecimalKeyFormatter(this.separator)
    : assert(separator == '.' || separator == ',');

  /// The separator the field accepts.
  final String separator;

  String get _other => separator == '.' ? ',' : '.';

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final typed = newValue.text.length == oldValue.text.length + 1;
    final at = newValue.selection.baseOffset - 1;
    if (!typed || !newValue.selection.isCollapsed || at < 0) return newValue;
    if (at >= newValue.text.length || newValue.text[at] != _other) {
      return newValue;
    }
    // The rest of the text must be what was there before: one key press.
    final before = newValue.text.substring(0, at);
    final after = newValue.text.substring(at + 1);
    if (before + after != oldValue.text) return newValue;
    return newValue.copyWith(text: '$before$separator$after');
  }
}

/// Puts a phone keyboard away when the user taps elsewhere, for the fields
/// in [child].
///
/// iOS's decimal pad has no Done key, and on phones Flutter does not
/// unfocus a field on a touch outside it, so after typing an amount the
/// keyboard could not be put away (iOS simulator, Send). This unfocuses the
/// field that was tapped away from, and only that one (a tap into another
/// field keeps its focus), on pointer up, so the tap still reaches what it
/// hit.
class BeamCloseKeyboardOnTapOutside extends StatelessWidget {
  const BeamCloseKeyboardOnTapOutside({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Actions(
    actions: <Type, Action<Intent>>{
      EditableTextTapUpOutsideIntent:
          CallbackAction<EditableTextTapUpOutsideIntent>(
            onInvoke: (intent) {
              intent.focusNode.unfocus();
              return null;
            },
          ),
    },
    child: child,
  );
}

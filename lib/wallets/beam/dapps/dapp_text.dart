/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Makes text a dApp wrote safe to show inside Campfire's own screens.
///
/// `confirm_comment`, kernel comments from the dApp's app shader, payment
/// comments and messages to sign all come from the dApp. Bidi and format
/// controls (U+202E and friends) can make them read as something else —
/// reverse an amount, hide a word — and control characters can break the
/// layout. The same ranges are refused in manifest names
/// (`DappManifest`), but here the text cannot be refused (it is part of
/// what the dApp asks), so it is cleaned for display only: what executes
/// is untouched.
///
/// * Bidi, zero-width and other format controls are removed.
/// * Other control characters become a space; line breaks are kept, at
///   most two in a row.
/// * The result is trimmed and cut to [maxLength] UTF-16 units (never
///   inside a surrogate pair), with "…" when cut.
String dappDisplayText(String text, {int maxLength = 1024}) {
  var t = text.replaceAll(_invisible, '');
  t = t.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  t = t.replaceAll(_control, ' ');
  t = t.replaceAll(_manyBreaks, '\n\n').trim();
  if (t.length <= maxLength) return t;
  var cut = maxLength;
  final last = t.codeUnitAt(cut - 1);
  if (last >= 0xd800 && last <= 0xdbff) cut--; // a lone high surrogate
  return '${t.substring(0, cut).trimRight()}…';
}

/// True when [text] holds characters [dappDisplayText] would remove or
/// replace (bidi and format controls, control characters other than tab and
/// line feed). Text that must be shown exactly as it is used — a message
/// to sign — is refused when this is true.
bool dappTextHasHidden(String text) =>
    _invisible.hasMatch(text) || _control.hasMatch(text);

/// Bidi controls (ALM, LRM/RLM, embeddings and overrides, isolates),
/// zero-width characters, word joiner and invisible operators, and the
/// byte-order mark.
final _invisible = RegExp(
  _charClass(const [
    (0x061c, 0x061c),
    (0x200b, 0x200f),
    (0x202a, 0x202e),
    (0x2060, 0x206f),
    (0xfeff, 0xfeff),
  ]),
);

/// C0 (except tab and line feed), DEL, C1, and the line and paragraph
/// separators.
final _control = RegExp(
  _charClass(const [
    (0x0000, 0x0008),
    (0x000b, 0x001f),
    (0x007f, 0x009f),
    (0x2028, 0x2029),
  ]),
);

final _manyBreaks = RegExp(r'\n[ \t]*(?:\n[ \t]*){2,}');

/// A RegExp character class of code point ranges, written with escapes so
/// no invisible character appears in this source file.
String _charClass(List<(int, int)> ranges) {
  String esc(int c) => '${r'\'}u${c.toRadixString(16).padLeft(4, '0')}';
  return '[${ranges.map((r) => '${esc(r.$1)}-${esc(r.$2)}').join()}]';
}

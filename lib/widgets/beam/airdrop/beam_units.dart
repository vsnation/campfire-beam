/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Amounts on the BEAM screens. Every BEAM asset, BEAM itself included, is
/// shown on the groth scale (8 decimals), as the core does
/// (`BeamAssetInfo.decimalsFor`).
abstract final class BeamUnits {
  static const decimals = 8;
  static final BigInt one = BigInt.from(100000000);

  /// `123456789012` → `1,234.56789012`: thousands grouped, trailing zeros
  /// dropped, never rounded (an amount that moves money is shown exactly).
  static String format(BigInt units) {
    final negative = units.isNegative;
    final abs = units.abs();
    final whole = (abs ~/ one).toString();
    final frac = abs
        .remainder(one)
        .toString()
        .padLeft(decimals, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    final grouped = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      if (i > 0 && (whole.length - i) % 3 == 0) grouped.write(',');
      grouped.write(whole[i]);
    }
    return '${negative ? '-' : ''}$grouped${frac.isEmpty ? '' : '.$frac'}';
  }

  /// [format] followed by [symbol].
  static String withSymbol(BigInt units, String symbol) =>
      '${format(units)} $symbol';

  /// Text the user typed → smallest units, or null when it is not a
  /// positive amount with at most 8 decimals. See [problem] for why.
  static BigInt? parse(String text) {
    final t = _normalise(text);
    if (t == null) return null;
    final parts = t.split('.');
    final whole = parts[0].isEmpty ? '0' : parts[0];
    final frac = parts.length > 1 ? parts[1] : '';
    if (frac.length > decimals) return null;
    final units =
        BigInt.parse(whole) * one + BigInt.parse(frac.padRight(decimals, '0'));
    return units > BigInt.zero ? units : null;
  }

  /// Why [parse] refused [text], in plain words; null when it did not, or
  /// when the field is empty (an empty field is not an error yet).
  static String? problem(String text) {
    if (text.trim().isEmpty) return null;
    if (_ambiguousComma(text)) {
      return 'Write 1000 or 1.5 — a comma here could mean either';
    }
    if (_mixedSeparators(text)) {
      return 'Write 1234.5 — mixing . and , here could mean a thousand '
          'times more or less';
    }
    final t = _normalise(text);
    if (t == null) return 'Enter a number, like 1.5';
    final parts = t.split('.');
    if (parts.length > 1 && parts[1].length > decimals) {
      return 'Use at most $decimals digits after the point';
    }
    if (parse(text) == null) return 'Enter an amount above zero';
    return null;
  }

  /// `1,000`: a thousands separator or a decimal comma? Refused rather than
  /// guessed, since the two readings differ a thousandfold.
  static bool _ambiguousComma(String text) {
    final t = text.trim().replaceAll(RegExp(r'[\s_]'), '');
    return !t.contains('.') && RegExp(r'^\d+,\d{3}$').hasMatch(t);
  }

  /// `1,234,567` or `1,234.5`: commas only as thousands groups (one to
  /// three digits, then groups of exactly three), before an optional single
  /// `.` decimal point.
  static final _grouped = RegExp(r'^\d{1,3}(,\d{3})+(\.\d*)?$');

  /// Both `.` and `,` (or several commas) in a shape that is not
  /// [_grouped]: `1.234,5` is 1234.5 in much of Europe and 1.2345 to a
  /// naive reader. Refused rather than guessed.
  static bool _mixedSeparators(String text) {
    final t = text.trim().replaceAll(RegExp(r'[\s_]'), '');
    final commas = ','.allMatches(t).length;
    final mixed = (t.contains('.') && commas > 0) || commas > 1;
    return mixed && !_grouped.hasMatch(t);
  }

  /// Accepts `1234.5`, `1,234.5`, `1,234,567`, `1 234,5` and `.5`. A lone
  /// comma is read as the decimal point (many keyboards only offer a
  /// comma), except in the ambiguous `1,000` shape. Commas next to a point
  /// must be thousands groups before it (`1.234,5` is refused).
  static String? _normalise(String text) {
    if (_ambiguousComma(text) || _mixedSeparators(text)) return null;
    var t = text.trim().replaceAll(RegExp(r'[\s_]'), '');
    if (t.isEmpty) return null;
    final commas = ','.allMatches(t).length;
    if ((t.contains('.') && commas > 0) || commas > 1) {
      // Only [_grouped] text gets here: the commas are thousands groups.
      t = t.replaceAll(',', '');
    } else if (commas == 1) {
      t = t.replaceAll(',', '.');
    }
    if (!RegExp(r'^\d*(\.\d*)?$').hasMatch(t) || t == '.') return null;
    return t;
  }
}

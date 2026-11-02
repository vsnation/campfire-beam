/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../l10n/amount_text.dart';
import '../../../l10n/l10n.dart';

/// Amounts on the BEAM screens. BEAM has 8 decimals; an asset the places its
/// metadata's `NTH_RATIO` gives ([BeamAssetDisplay.decimals]), passed as
/// [places] (8 when not given; null, not known yet: shown as 8, never read).
abstract final class BeamUnits {
  static const decimals = 8;
  static final BigInt one = BigInt.from(100000000);

  /// `123456789012` → `1,234.56789012` (`1 234.56789012` in Russian):
  /// thousands grouped, trailing zeros dropped, "." decimals in every
  /// language, never rounded (an amount that moves money is shown exactly).
  static String format(BigInt units, {int? places}) =>
      formatAmountUnits(units, decimals: places ?? decimals);

  /// [format] without grouping, for putting back into a text field:
  /// `123456789012` → `1234.56789012`.
  /// Nothing while [places] is not known.
  static String plain(BigInt units, {int? places = decimals}) {
    if (places == null) return '';
    final unit = BigInt.from(10).pow(places);
    final whole = (units.abs() ~/ unit).toString();
    final frac = places == 0
        ? ''
        : units
              .abs()
              .remainder(unit)
              .toString()
              .padLeft(places, '0')
              .replaceFirst(RegExp(r'0+$'), '');
    return '${units.isNegative ? '-' : ''}$whole'
        '${frac.isEmpty ? '' : '.$frac'}';
  }

  /// [format] followed by [symbol].
  static String withSymbol(BigInt units, String symbol, {int? places}) =>
      '${format(units, places: places)} $symbol';

  /// Text the user typed → smallest units, or null when it is not a
  /// positive amount with at most 8 decimals. See [problem] for why.
  static BigInt? parse(String text, {int? places = decimals}) {
    final t = _normalise(text);
    if (t == null || places == null) return null;
    final parts = t.split('.');
    final whole = parts[0].isEmpty ? '0' : parts[0];
    final frac = parts.length > 1 ? parts[1] : '';
    if (frac.length > places) return null;
    final units =
        BigInt.parse(whole) * BigInt.from(10).pow(places) +
        BigInt.parse(
          frac.padRight(places, '0').isEmpty ? '0' : frac.padRight(places, '0'),
        );
    return units > BigInt.zero ? units : null;
  }

  /// Why [parse] refused [text], in plain words; null when it did not, or
  /// when the field is empty (an empty field is not an error yet).
  static String? problem(
    String text, {
    int? places = decimals,
    String? symbol,
  }) {
    if (text.trim().isEmpty) return null;
    final l = appL10n;
    if (places == null) return l.sendAssetDecimalsUnknown(symbol ?? '');
    if (_ambiguousComma(text)) return l.unitsAmbiguousComma;
    if (_mixedSeparators(text)) return l.unitsMixedSeparators;
    final t = _normalise(text);
    if (t == null) return l.unitsEnterNumber;
    final parts = t.split('.');
    if (parts.length > 1 && parts[1].length > places) {
      return l.unitsTooManyDecimals(places);
    }
    if (parse(text, places: places) == null) return l.unitsAboveZero;
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

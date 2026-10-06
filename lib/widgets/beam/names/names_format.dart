/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:intl/intl.dart';

import '../../../wallets/beam/contracts/bans/bans_constants.dart';

/// Number and date wording for the Names screens. Every BEAM asset uses the
/// groth scale (10^8), so one formatter serves BEAM and tokens alike.
abstract final class NamesFormat {
  static final BigInt _groth = BigInt.from(100000000);

  /// The exact amount, all significant decimals, with thousands
  /// separators: `1,162.13166091`. For confirmation screens, where the
  /// user must see precisely what will be signed.
  static String exact(BigInt units) {
    final neg = units.isNegative;
    final a = units.abs();
    final whole = _thousands(a ~/ _groth);
    final frac = a
        .remainder(_groth)
        .toString()
        .padLeft(8, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    return '${neg ? '-' : ''}$whole${frac.isEmpty ? '' : '.$frac'}';
  }

  /// Rounded for reading: two decimals from 100 up (`1,162.13`), every
  /// significant decimal below that, so a fee still reads `0.011`.
  static String readable(BigInt units) {
    if (units.abs() < BigInt.from(100) * _groth) return exact(units);
    final cents = (units.abs() + BigInt.from(500000)) ~/ BigInt.from(1000000);
    final whole = _thousands(cents ~/ BigInt.from(100));
    final frac = cents
        .remainder(BigInt.from(100))
        .toString()
        .padLeft(2, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    return '${units.isNegative ? '-' : ''}$whole'
        '${frac.isEmpty ? '' : '.$frac'}';
  }

  /// Whole units only, rounded: `1,162`. For estimates ("about").
  static String whole(BigInt units) =>
      _thousands((units + _groth ~/ BigInt.two) ~/ _groth);

  static String _thousands(BigInt v) {
    final s = v.toString();
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
      out.write(s[i]);
    }
    return out.toString();
  }

  /// Parses what a person typed as an amount ("1,000.5", "0.25") into
  /// groth-scale units. Null when it is not a positive amount with at most
  /// eight decimals.
  static BigInt? parse(String text) {
    final t = text.trim().replaceAll(',', '');
    final m = RegExp(r'^(\d*)(?:\.(\d{0,8}))?$').firstMatch(t);
    if (m == null || t.isEmpty || t == '.') return null;
    final w = m.group(1)!.isEmpty ? '0' : m.group(1)!;
    final f = (m.group(2) ?? '').padRight(8, '0');
    final v = BigInt.parse(w) * _groth + BigInt.parse(f);
    return v > BigInt.zero ? v : null;
  }

  /// `$10`, `$1,200`.
  static String usd(int dollars) => '\$${_thousands(BigInt.from(dollars))}';

  /// `18 May 2028`.
  static String date(DateTime d) => DateFormat('d MMM y').format(d.toLocal());

  /// `1 year`, `5 years`.
  static String years(int n) => n == 1 ? '1 year' : '$n years';

  /// Whole days from [tipHeight] to [height] at one block a minute.
  static int daysBetween(int tipHeight, int height) =>
      ((height - tipHeight) * kBeamTargetBlockTime.inSeconds) ~/ 86400;

  /// `in 12 days`, `tomorrow`, `today`.
  static String inDays(int days) => switch (days) {
    <= 0 => 'today',
    1 => 'tomorrow',
    _ => 'in $days days',
  };

  /// `block 4,918,184`, shown only on tap (heights are jargon).
  static String block(int height) => 'block ${_thousands(BigInt.from(height))}';
}

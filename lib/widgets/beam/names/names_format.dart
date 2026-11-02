/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:intl/intl.dart';

import '../../../l10n/amount_text.dart';
import '../../../l10n/l10n.dart';
import '../../../wallets/beam/contracts/bans/bans_constants.dart';
import '../airdrop/beam_units.dart';

/// Number and date wording for the Names screens. Every BEAM asset uses the
/// groth scale (10^8), so one formatter serves BEAM and tokens alike.
abstract final class NamesFormat {
  static final BigInt _groth = BigInt.from(100000000);

  /// The exact amount, all significant decimals, with thousands
  /// separators: `1,162.13166091`. For confirmation screens, where the
  /// user must see precisely what will be signed.
  ///
  /// [places]: the asset's decimals (BEAM's 8; an asset's from its
  /// `NTH_RATIO`, [BeamAssetDisplay.decimals]; null, not read yet, as 8).
  static String exact(BigInt units, {int? places}) {
    final p = places ?? 8;
    final one = BigInt.from(10).pow(p);
    final neg = units.isNegative;
    final a = units.abs();
    final whole = _thousands(a ~/ one);
    final frac = p == 0
        ? ''
        : a
              .remainder(one)
              .toString()
              .padLeft(p, '0')
              .replaceFirst(RegExp(r'0+$'), '');
    return '${neg ? '-' : ''}$whole${frac.isEmpty ? '' : '.$frac'}';
  }

  /// Rounded for reading: two decimals from 100 up (`1,162.13`), every
  /// significant decimal below that, so a fee still reads `0.011`.
  static String readable(BigInt units, {int? places}) {
    final p = places ?? 8;
    if (p <= 2 || units.abs() < BigInt.from(100) * BigInt.from(10).pow(p)) {
      return exact(units, places: p);
    }
    final step = BigInt.from(10).pow(p - 2);
    final cents = (units.abs() + step ~/ BigInt.two) ~/ step;
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

  /// `1,162` (`1 162` in Russian: lib/l10n/amount_text.dart).
  static String _thousands(BigInt v) => groupThousands(v.toString());

  /// Parses what a person typed as an amount ("1,000.5", "0.25") into
  /// groth-scale units. Null when it is not a positive amount with at most
  /// eight decimals. The Airdrop and Minter fields' rules ([BeamUnits.parse]):
  /// commas only as thousands groups before a "." ("1,000.5"), a lone one
  /// as the decimal point ("0,5" is 0.5, never 5), and "1,000" refused (a
  /// thousand or one?). Stripping every comma read a Russian "0,5" as 5.
  static BigInt? parse(String text, {int? places = BeamUnits.decimals}) =>
      BeamUnits.parse(text, places: places);

  /// `$10`, `$1,200`.
  static String usd(int dollars) => '\$${_thousands(BigInt.from(dollars))}';

  /// `18 May 2028`.
  static String date(DateTime d) => DateFormat('d MMM y').format(d.toLocal());

  /// `1 year`, `5 years`.
  static String years(int n) => appL10n.namesYears(n);

  /// Whole days from [tipHeight] to [height] at one block a minute.
  static int daysBetween(int tipHeight, int height) =>
      ((height - tipHeight) * kBeamTargetBlockTime.inSeconds) ~/ 86400;

  /// `block 4,918,184`, shown only on tap (heights are jargon).
  static String block(int height) =>
      appL10n.namesBlockHeight(_thousands(BigInt.from(height)));
}

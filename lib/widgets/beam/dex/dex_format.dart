/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:decimal/decimal.dart';

import '../../../utilities/amount/amount.dart';
import '../../../wallets/beam/contracts/dex/beam_ratio.dart';
import '../../../wallets/beam/contracts/dex/dex_constants.dart';
import '../../../wallets/beam/models/beam_asset_info.dart';

/// What the user typed into an amount field.
class DexAmountInput {
  const DexAmountInput._(this.value, this.error);

  /// Nothing typed yet.
  static const empty = DexAmountInput._(null, null);

  /// The amount in the asset's smallest unit, when the text is a valid
  /// amount. Zero is a valid value (and not a swappable one).
  final BigInt? value;

  /// Why the text is not an amount, in plain words. Never blames the user.
  final String? error;

  bool get isEmpty => value == null && error == null;
  bool get isPositive => value != null && value! > BigInt.zero;
}

/// Amounts, rates and percentages for the DEX screens.
///
/// Money never goes through `double`: every BEAM asset uses the groth scale
/// (10^8 smallest units per unit, `BeamAssetInfo.decimalsFor`), so amounts
/// are formatted from the exact integer.
abstract final class DexFormat {
  static const decimals = BeamAssetInfo.beamDecimals;
  static final _unit = BigInt.from(10).pow(decimals);
  static final _amountText = RegExp(r'^[0-9]*\.?[0-9]*$');

  /// Parses a plain decimal ("0.5", "12", ".25", "3."). Thousands
  /// separators and commas are refused by name, never guessed: "1,000"
  /// could mean one thousand or one.
  static DexAmountInput parse(String text) {
    final t = text.trim();
    if (t.isEmpty) return DexAmountInput.empty;
    if (t.contains(',')) {
      return const DexAmountInput._(null, 'Use a dot for decimals, like 0.5');
    }
    if (!_amountText.hasMatch(t) || t == '.') {
      return const DexAmountInput._(null, 'Enter a number, like 0.5');
    }
    final dot = t.indexOf('.');
    final whole = dot < 0 ? t : t.substring(0, dot);
    final frac = dot < 0 ? '' : t.substring(dot + 1);
    if (frac.length > decimals) {
      return const DexAmountInput._(
        null,
        'BEAM amounts have at most 8 decimals',
      );
    }
    final w = whole.isEmpty ? BigInt.zero : BigInt.parse(whole);
    final f = frac.isEmpty
        ? BigInt.zero
        : BigInt.parse(frac.padRight(decimals, '0'));
    final value = w * _unit + f;
    if (value >= (BigInt.one << 63)) {
      return const DexAmountInput._(null, 'That amount is too large');
    }
    return DexAmountInput._(value, null);
  }

  /// The exact amount, trailing zeros trimmed, thousands grouped:
  /// 637304113367 → "6,373.04113367". This is what confirmation screens
  /// show: nothing rounded away.
  static String exact(BigInt groth) {
    final negative = groth.isNegative;
    final v = groth.abs();
    final whole = v ~/ _unit;
    final frac = (v % _unit).toString().padLeft(decimals, '0');
    final trimmed = frac.replaceFirst(RegExp(r'0+$'), '');
    final w = _group(whole.toString());
    return '${negative ? '-' : ''}$w${trimmed.isEmpty ? '' : '.$trimmed'}';
  }

  /// The exact amount without grouping, for putting back into a text
  /// field: 10000000 → "0.1".
  static String plain(BigInt groth) => exact(groth).replaceAll(',', '');

  /// A short amount for lists: rounded down to what people read.
  /// ≥ 1000 → 2 decimals, ≥ 1 → 4, below 1 → 4 significant digits (at most
  /// 8 decimals). The full value is on the confirmation screen.
  static String compact(BigInt groth) {
    if (groth == BigInt.zero) return '0';
    final r = BeamRatio(groth, _unit);
    return number(r);
  }

  /// A human number from an exact ratio, rounded down (see [compact]).
  static String number(BeamRatio r) {
    if (r.isZero) return '0';
    final negative = r.isNegative;
    final a = negative ? -r : r;
    final int places;
    if (a >= BeamRatio.fromInt(1000)) {
      places = 2;
    } else if (a >= BeamRatio.one) {
      places = 4;
    } else {
      // Leading zeros after the point, then 4 significant digits.
      var p = 0;
      var scaled = a;
      final ten = BeamRatio.fromInt(10);
      while (scaled < BeamRatio.one && p < 12) {
        scaled = scaled * ten;
        p++;
      }
      places = (p + 3).clamp(1, 12);
    }
    var s = a.toDecimalString(places);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    if (s == '0') return negative ? '> -0.000000000001' : '< 0.000000000001';
    final dot = s.indexOf('.');
    final w = dot < 0 ? s : s.substring(0, dot);
    final rest = dot < 0 ? '' : s.substring(dot);
    return '${negative ? '-' : ''}${_group(w)}$rest';
  }

  /// [fraction] as a percentage: 0.0013 → "0.13%"; tiny values say
  /// "< 0.01%" instead of a misleading "0%".
  static String percent(BeamRatio fraction) {
    final p = fraction * BeamRatio.fromInt(100);
    if (p.isZero) return '0%';
    if (p.isNegative) return '-${percent(-fraction)}';
    if (p < BeamRatio(BigInt.one, BigInt.from(100))) return '< 0.01%';
    final places = p >= BeamRatio.fromInt(10) ? 1 : 2;
    var s = p.toDecimalString(places);
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return '$s%';
  }

  /// "1% fee", from the pool's fee tier.
  static String feeTier(BeamPoolKind kind) => '${kind.feePercent} fee';

  /// The first and last six characters of a contract id.
  static String shortId(String hex) => hex.length <= 14
      ? hex
      : '${hex.substring(0, 6)}…${hex.substring(hex.length - 6)}';

  /// "1,234,567" from "1234567".
  static String _group(String digits) {
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  /// [groth] of BEAM in the fiat currency, written the way the rest of
  /// Campfire writes money ("1.19 USD", "1.234,56 EUR" in a German locale,
  /// [locale]'s digits), rounded down. Anything below one cent says
  /// "under 0.01 USD", never "0.00 USD": callers only value amounts that
  /// are something (a value that rounds to no groth at all included).
  static String fiat(
    BigInt groth,
    BeamRatio perBeam,
    String currency, {
    String locale = 'en_US',
  }) {
    final v = BeamRatio(groth, _unit) * perBeam;
    final code = currency.toUpperCase();
    final cent = BeamRatio(BigInt.one, BigInt.from(100));
    String money(BeamRatio r) =>
        Decimal.parse(r.toDecimalString(2))
            .toAmount(fractionDigits: 2)
            .fiatString(locale: locale);
    if (v < cent) return 'under ${money(cent)} $code';
    return '${money(v)} $code';
  }

  /// [fiat] as an estimate: "≈ 1.19 USD"; "under 0.01 USD" already says
  /// it is not exact.
  static String fiatApprox(
    BigInt groth,
    BeamRatio perBeam,
    String currency, {
    String locale = 'en_US',
  }) {
    final text = fiat(groth, perBeam, currency, locale: locale);
    final v = BeamRatio(groth, _unit) * perBeam;
    return v < BeamRatio(BigInt.one, BigInt.from(100)) ? text : '≈ $text';
  }
}

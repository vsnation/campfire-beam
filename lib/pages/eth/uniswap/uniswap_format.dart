/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Amounts, rates and percentages for the Uniswap screens. Like the BEAM
// DEX (`dex_format.dart`), money never goes through `double`: each token
// has its own number of decimals (ETH 18, USDC 6, WBEAM 8) and amounts are
// formatted from the exact integer.

import '../../../wallets/beam/contracts/dex/beam_ratio.dart';
import '../../../wallets/ethereum/uniswap/uniswap_models.dart';
import '../../../widgets/beam/dex/dex_format.dart';

/// What the user typed into an amount field.
class UniAmountInput {
  const UniAmountInput._(this.value, this.error);

  static const empty = UniAmountInput._(null, null);

  /// In the token's smallest unit.
  final BigInt? value;

  /// Why the text is not an amount, in plain words.
  final String? error;

  bool get isPositive => value != null && value! > BigInt.zero;
}

abstract final class UniFormat {
  static final _amountText = RegExp(r'^[0-9]*\.?[0-9]*$');

  static BigInt unit(int decimals) => BigInt.from(10).pow(decimals);

  /// Parses "0.5", "12", ".25" for a token with [decimals] decimals.
  static UniAmountInput parse(String text, UniToken token) {
    final t = text.trim();
    if (t.isEmpty) return UniAmountInput.empty;
    if (t.contains(',')) {
      return const UniAmountInput._(null, 'Use a dot for decimals, like 0.5');
    }
    if (!_amountText.hasMatch(t) || t == '.') {
      return const UniAmountInput._(null, 'Enter a number, like 0.5');
    }
    final dot = t.indexOf('.');
    final whole = dot < 0 ? t : t.substring(0, dot);
    final frac = dot < 0 ? '' : t.substring(dot + 1);
    if (frac.length > token.decimals) {
      return UniAmountInput._(
        null,
        '${token.symbol} has at most ${token.decimals} decimals',
      );
    }
    final w = whole.isEmpty ? BigInt.zero : BigInt.parse(whole);
    final f = frac.isEmpty
        ? BigInt.zero
        : BigInt.parse(frac.padRight(token.decimals, '0'));
    final value = w * unit(token.decimals) + f;
    if (value >= (BigInt.one << 127)) {
      return const UniAmountInput._(null, 'That amount is too large');
    }
    return UniAmountInput._(value, null);
  }

  /// Every digit, trailing zeros trimmed, thousands grouped.
  static String exact(BigInt v, int decimals) {
    final negative = v.isNegative;
    final a = v.abs();
    final u = unit(decimals);
    final whole = a ~/ u;
    final frac = decimals == 0
        ? ''
        : (a % u)
              .toString()
              .padLeft(decimals, '0')
              .replaceFirst(RegExp(r'0+$'), '');
    final w = _group(whole.toString());
    return '${negative ? '-' : ''}$w${frac.isEmpty ? '' : '.$frac'}';
  }

  /// [exact] without grouping, for a text field.
  static String plain(BigInt v, int decimals) =>
      exact(v, decimals).replaceAll(',', '');

  /// Rounded down to what people read (as the BEAM DEX does).
  static String compact(BigInt v, int decimals) {
    if (v == BigInt.zero) return '0';
    return DexFormat.number(BeamRatio(v, unit(decimals)));
  }

  /// "1 ETH ≈ 322,127.46 WBEAM".
  static String rate(UniQuote q) {
    final r = BeamRatio(
      q.amountOut * unit(q.tokenIn.decimals),
      q.amountIn * unit(q.tokenOut.decimals),
    );
    return '1 ${q.tokenIn.symbol} ≈ ${DexFormat.number(r)} ${q.tokenOut.symbol}';
  }

  /// 0.0313 → "3.13%", tiny → "< 0.01%".
  static String percent(double fraction) {
    final p = fraction * 100;
    if (p <= 0) return '0%';
    if (p < 0.01) return '< 0.01%';
    return '${p >= 10 ? p.toStringAsFixed(1) : p.toStringAsFixed(2)}%';
  }

  /// A share of a swap, in whole percent: 0.7 → "70%".
  static String share(double fraction) {
    final p = (fraction * 100).round();
    return p < 1 ? '< 1%' : '$p%';
  }

  /// A pool's fee: 3000 → "0.3%", 100 → "0.01%", null → "set by its hook".
  static String fee(int? hundredthsOfBip) {
    if (hundredthsOfBip == null) return 'set by its hook';
    final p = hundredthsOfBip / 10000;
    var s = p.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    return '$s%';
  }

  /// "0x66a9…a8af" (draw it with `kAddressFontFeatures`).
  static String short(String address) =>
      '${address.substring(0, 6)}…${address.substring(address.length - 4)}';

  /// Any chain's address shortened the same way ("bc1qar…5mdq").
  static String shortAny(String address) => address.length <= 14
      ? address
      : '${address.substring(0, 6)}…${address.substring(address.length - 4)}';

  static String _group(String digits) {
    final b = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) b.write(',');
      b.write(digits[i]);
    }
    return b.toString();
  }
}

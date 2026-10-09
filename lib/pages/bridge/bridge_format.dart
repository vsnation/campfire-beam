/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Amounts, money and time for the bridge screens. A crossing has two
// sides with their own decimals (BEAM always 8, Ethereum 6 to 18), so
// every amount is formatted from its exact integer with its own decimals,
// never through `double` (the money value next to it may be).

import '../../wallets/bridge/bridge_controller.dart';
import '../../wallets/bridge/bridge_fees.dart';
import '../../wallets/bridge/bridge_routes.dart';
import '../eth/uniswap/uniswap_format.dart';

/// What the user typed into the amount field.
class BridgeAmountInput {
  const BridgeAmountInput._(this.value, this.error);

  static const empty = BridgeAmountInput._(null, null);

  /// In the source chain's smallest unit.
  final BigInt? value;

  /// Why the text is not an amount, in plain words.
  final String? error;

  bool get isPositive => value != null && value! > BigInt.zero;
}

abstract final class BridgeFormat {
  static final _amountText = RegExp(r'^[0-9]*\.?[0-9]*$');

  /// Parses "0.5" for [route] going [direction]: at most the decimals a
  /// crossing carries ([BridgeRouteUnits.movableDecimals]), so nothing
  /// typed is floored away later.
  static BridgeAmountInput parse(
    String text,
    BridgeRoute route,
    BridgeDirection direction,
  ) {
    final t = text.trim();
    if (t.isEmpty) return BridgeAmountInput.empty;
    if (t.contains(',')) {
      return const BridgeAmountInput._(
        null,
        'Use a dot for decimals, like 0.5',
      );
    }
    if (!_amountText.hasMatch(t) || t == '.') {
      return const BridgeAmountInput._(null, 'Enter a number, like 0.5');
    }
    final dot = t.indexOf('.');
    final whole = dot < 0 ? t : t.substring(0, dot);
    final frac = dot < 0 ? '' : t.substring(dot + 1);
    final places = route.movableDecimals;
    if (frac.length > places) {
      return BridgeAmountInput._(
        null,
        '${route.sourceSymbol(direction)} moves with at most $places '
        'decimals',
      );
    }
    final dec = route.sourceDecimals(direction);
    final w = whole.isEmpty ? BigInt.zero : BigInt.parse(whole);
    final f = frac.isEmpty
        ? BigInt.zero
        : BigInt.parse(frac.padRight(dec, '0'));
    final value = w * BigInt.from(10).pow(dec) + f;
    final groth = direction == BridgeDirection.toEthereum
        ? value
        : route.ethToGroth(value);
    if (groth >= (BigInt.one << 63)) {
      return const BridgeAmountInput._(null, 'That amount is too large');
    }
    return BridgeAmountInput._(value, null);
  }

  /// Every digit: "1,072.56834523".
  static String exact(BigInt v, int decimals) => UniFormat.exact(v, decimals);

  /// For a text field: "1072.56834523".
  static String plain(BigInt v, int decimals) => UniFormat.plain(v, decimals);

  /// Rounded down to what people read: "72.5683", "0.0002473".
  static String compact(BigInt v, int decimals) =>
      UniFormat.compact(v, decimals);

  /// "1,000 BEAM", every digit.
  static String coin(BigInt v, int decimals, String symbol) =>
      '${exact(v, decimals)} $symbol';

  /// "72.5683 BEAM", rounded down.
  static String coinShort(BigInt v, int decimals, String symbol) =>
      '${compact(v, decimals)} $symbol';

  /// What [units] of the coin priced as [coingeckoId] are worth in US
  /// dollars, from the prices the fee was computed with: "≈ 0.57 USD",
  /// "under 0.01 USD"; null without a price.
  static String? usd(
    BridgePrices? prices,
    String coingeckoId,
    BigInt units,
    int decimals,
  ) {
    final per = prices?.of(coingeckoId);
    if (per == null) return null;
    final v = units.toDouble() / BigInt.from(10).pow(decimals).toDouble() * per;
    if (v < 0.01) return 'under 0.01 USD';
    final digits = v >= 1000
        ? _group(v.toStringAsFixed(0))
        : v.toStringAsFixed(2);
    return '≈ $digits USD';
  }

  /// "About 1 hour", "About 2 minutes".
  static String about(Duration d) {
    if (d.inMinutes >= 90) return 'About ${(d.inMinutes / 60).round()} hours';
    if (d.inMinutes >= 55) return 'About 1 hour';
    if (d.inMinutes <= 1) return 'About a minute';
    return 'About ${d.inMinutes} minutes';
  }

  /// "up to 11 hours".
  static String upTo(Duration d) => d.inHours >= 2
      ? 'up to ${d.inHours} hours'
      : 'up to ${d.inMinutes} minutes';

  /// "5 min ago", "2 h ago", "Oct 9".
  static String ago(DateTime t, DateTime now) {
    final d = now.difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final l = t.toLocal();
    return '${months[l.month - 1]} ${l.day}';
  }

  static String _group(String digits) {
    final b = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) b.write(',');
      b.write(digits[i]);
    }
    return b.toString();
  }
}

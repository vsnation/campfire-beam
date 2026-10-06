/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../utilities/amount/amount.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';

/// Amounts and names on the BEAM send screens.
///
/// Every BEAM asset, BEAM included, counts in units of 10^-8 (the core has
/// no other scale; see PROGRESS "every BEAM asset has 8 decimals"), so one
/// formatter serves them all. Amounts that move money are never rounded.
abstract final class BeamSendFormat {
  static const int decimals = 8;
  static final BigInt _one = BigInt.from(100000000);

  /// `123456789012` → `1,234.56789012`; trailing zeros dropped.
  static String units(BigInt value) {
    final negative = value.isNegative;
    final abs = value.abs();
    final whole = (abs ~/ _one).toString();
    final frac = abs
        .remainder(_one)
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

  /// `1.5 BEAM`, `10 FOMO`, `3 XYZ #321` (unverified assets always carry
  /// their id, because anyone can mint an asset and call it anything).
  static String amount(BigInt value, BeamAssetDisplay asset) =>
      '${units(value)} ${symbol(asset)}';

  /// `1.5 BEAM` for asset 0.
  static String beam(BigInt groth) => '${units(groth)} BEAM';

  /// The ticker as the send screens show it.
  static String symbol(BeamAssetDisplay asset) {
    if (asset.verified) return asset.symbol;
    return asset.symbol == asset.idLabel
        ? asset.idLabel
        : '${asset.symbol} ${asset.idLabel}';
  }

  /// What the user typed, in units; null when it is not a positive amount
  /// with at most 8 decimals in [locale]'s notation.
  static BigInt? parse(String text, String locale) {
    final t = text.trim();
    if (t.isEmpty) return null;
    final a = Amount.tryParseEditableAmount(
      t,
      locale: locale,
      fractionDigits: decimals,
    );
    if (a == null || a.raw <= BigInt.zero) return null;
    return a.raw;
  }

  /// [value] as text the amount field accepts again (no grouping).
  static String editable(BigInt value, String locale) =>
      Amount.formatEditableDecimal(
        Amount(rawValue: value, fractionDigits: decimals).decimal,
        locale: locale,
      );

  /// `2d37ef…c1a09f`: enough of both ends to compare by eye. The full
  /// address is one tap away (copy).
  static String shortAddress(String address, {int keep = 6}) {
    final a = address.trim();
    if (a.length <= keep * 2 + 3) return a;
    return '${a.substring(0, keep)}…${a.substring(a.length - keep)}';
  }

  /// `ab12…ef90` for a transaction id.
  static String shortTxId(String txId) => shortAddress(txId, keep: 6);
}

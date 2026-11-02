/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../l10n/amount_text.dart';
import '../../../utilities/amount/amount.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';

/// Amounts and names on the BEAM send screens.
///
/// BEAM counts in units of 10^-8; a Confidential Asset in the places its
/// metadata's `NTH_RATIO` gives ([BeamAssetDisplay.decimals], 8 when it sets
/// none: CANDY #31 has 1). Amounts that move money are never rounded.
abstract final class BeamSendFormat {
  /// BEAM's, and every asset's that sets none of its own.
  static const int decimals = 8;
  static final BigInt _one = BigInt.from(100000000);

  /// `123456789012` → `1,234.56789012` (`1 234.56789012` in Russian);
  /// trailing zeros dropped, "." decimals in every language. [places]: the
  /// asset's decimals (null, not known yet: shown as 8).
  static String units(BigInt value, {int? places}) =>
      formatAmountUnits(value, decimals: places ?? decimals);

  /// `1.5 BEAM`, `10 FOMO`, `3 XYZ #321` (unverified assets always carry
  /// their id, because anyone can mint an asset and call it anything), in the
  /// asset's own decimals.
  static String amount(BigInt value, BeamAssetDisplay asset) =>
      '${units(value, places: asset.decimals)} ${symbol(asset)}';

  /// For an asset with its own decimals: the same amount as BEAM's desktop
  /// wallet and explorer read it (every asset with 8), so a figure from
  /// someone using them is not misread 10^n apart. Null for 8 decimals,
  /// decimals not known yet, and pool shares.
  static String? atEight(BigInt value, BeamAssetDisplay asset) {
    final d = asset.decimals;
    if (d == null || d == decimals || asset.isPoolShare) return null;
    return '${units(value)} ${symbol(asset)}';
  }

  /// `1.5 BEAM` for asset 0.
  static String beam(BigInt groth) => '${units(groth)} BEAM';

  /// The ticker as the send screens show it.
  static String symbol(BeamAssetDisplay asset) {
    if (asset.verified) return asset.symbol;
    return asset.symbol == asset.idLabel
        ? asset.idLabel
        : '${asset.symbol} ${asset.idLabel}';
  }

  /// What the user typed, in units of an asset with [places] decimals (BEAM's
  /// 8 by default); null when it is not a positive amount with at most that
  /// many decimals, written with a "." decimal point, or when [places] is null
  /// (the asset's metadata is not read yet: "1" read as 8 would be 10^8 of a
  /// whole-number asset).
  ///
  /// The same in every language and on every device (the owner's rule;
  /// lib/l10n/amount_text.dart): a comma is never a decimal point here, so
  /// "0,5" is refused, never 5, and "1,000" is refused, never 1. (On iOS
  /// and macOS the device locale is Russian's own once the app declares
  /// Russian, and its decimal comma would otherwise make "1,000" one BEAM.)
  static BigInt? parse(String text, {int? places = decimals}) {
    final t = text.trim();
    if (places == null || t.isEmpty || t.contains(',')) return null;
    final a = Amount.tryParseEditableAmount(
      t,
      locale: kAppAmountLocale,
      fractionDigits: places,
    );
    if (a == null || a.raw <= BigInt.zero) return null;
    return a.raw;
  }

  /// [value] as text the amount field accepts again: no grouping, "."
  /// decimals, in [places] (the asset's decimals; null: nothing, as a text
  /// written as 8 would be read again with the real ones).
  static String editable(BigInt value, {int? places = decimals}) =>
      places == null
      ? ''
      : Amount.formatEditableDecimal(
          Amount(rawValue: value, fractionDigits: places).decimal,
          locale: kAppAmountLocale,
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

  /// What [amount] of [assetId] is worth, for the asset picker: "≈ 0.02 USD"
  /// for BEAM; "≈ 24.73 BEAM · 0.21 USD" for an asset priced by its DEX
  /// pool ([inBeam]); without a fiat price ([fiat] null) the BEAM part only.
  /// Null when nothing is known, so nothing is shown rather than a 0.
  static String? assetWorth(
    int assetId,
    BigInt amount, {
    BigInt? Function(int assetId, BigInt amount)? inBeam,
    String? Function(BigInt groth)? fiat,
  }) {
    if (amount <= BigInt.zero) return null;
    if (assetId == 0) return fiat?.call(amount);
    final groth = inBeam?.call(assetId, amount);
    if (groth == null || groth <= BigInt.zero) return null;
    final beam = '≈ ${_estimate(groth)} BEAM';
    final f = fiat?.call(groth);
    return f == null ? beam : '$beam · ${f.replaceFirst('≈ ', '')}';
  }

  /// An estimate, never more digits than it deserves: 2 decimals from one
  /// BEAM up, 4 below; rounded down.
  static String _estimate(BigInt groth) {
    final keep = groth >= _one ? 2 : 4;
    final step = BigInt.from(10).pow(decimals - keep);
    return units(groth - groth.remainder(step));
  }
}

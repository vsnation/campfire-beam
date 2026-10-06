/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:decimal/decimal.dart';

import '../../../models/isar/models/beam/beam_asset_contract.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/amount/amount_unit.dart';
import '../../../utilities/util.dart';
import '../../crypto_currency/crypto_currency.dart';
import '../contracts/dex/dex_constants.dart';
import 'beam_asset_catalog.dart';

/// Every user-facing sentence and number format of the asset screens, in
/// one place so the list, the asset page, send and confirm say the same
/// thing the same way.
abstract final class BeamAssetText {
  static final Beam _beam = Beam(CryptoCurrencyNetwork.main);

  /// "1,234.50000000 FOMO". Assets use whole units with BEAM's decimals
  /// setting ([maxDecimals]); the user's BEAM unit (mBEAM…) never applies
  /// to another asset.
  static String amount(
    Amount value,
    BeamAssetContract asset, {
    required String locale,
    int maxDecimals = 8,
    bool withUnit = true,
  }) => AmountUnit.normal.displayAmount(
    amount: value,
    locale: locale,
    coin: _beam,
    maxDecimalPlaces: maxDecimals,
    withUnitName: withUnit,
    overrideUnit: asset.symbol,
    tokenContract: asset,
  );

  /// "12.5 FOMO": the exact amount, trailing zeros dropped (confirm
  /// screens, where every digit matters and padding is noise).
  static String exact(
    Amount value,
    BeamAssetContract asset, {
    required String locale,
  }) {
    final text = amount(value, asset, locale: locale, withUnit: false);
    final sep = Util.getSymbolsFor(locale: locale)?.DECIMAL_SEP ?? '.';
    var trimmed = text;
    if (trimmed.contains(sep)) {
      trimmed = trimmed.replaceFirst(RegExp(r'0+$'), '');
      if (trimmed.endsWith(sep)) {
        trimmed = trimmed.substring(0, trimmed.length - sep.length);
      }
    }
    return '$trimmed ${asset.symbol}';
  }

  /// "0.001 BEAM", trailing zeros dropped.
  static String beam(BigInt groth, {required String locale}) =>
      _units(groth, 'BEAM', locale);

  /// [raw] smallest units (8 decimals) as "1,234.5 [unit]", trailing zeros
  /// dropped, grouped for [locale].
  static String _units(BigInt raw, String unit, String locale) {
    final symbols = Util.getSymbolsFor(locale: locale);
    final sep = symbols?.DECIMAL_SEP ?? '.';
    final group = symbols?.GROUP_SEP ?? ',';
    final one = BigInt.from(100000000);
    final whole = (raw.abs() ~/ one).toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (m) => '${m[0]}$group',
    );
    var frac = (raw.abs() % one).toString().padLeft(8, '0');
    frac = frac.replaceFirst(RegExp(r'0+$'), '');
    final sign = raw.isNegative ? '-' : '';
    return frac.isEmpty ? '$sign$whole $unit' : '$sign$whole$sep$frac $unit';
  }

  /// A list row's amount, rounded down to what a person reads: 2 decimals
  /// from 1,000, 4 from 1, all 8 below ("6,477,953.06 GIGA",
  /// "568.1297 FOMO", "0.46659234 LP"). The asset page shows every digit.
  static String rounded(
    Amount value,
    BeamAssetContract asset, {
    required String locale,
  }) {
    final raw = value.raw;
    final abs = raw.abs();
    final one = BigInt.from(100000000);
    final places = abs >= one * BigInt.from(1000)
        ? 2
        : abs >= one
        ? 4
        : 8;
    final step = BigInt.from(10).pow(8 - places);
    return _units(raw ~/ step * step, asset.symbol, locale);
  }

  /// "≈ 3.214 BEAM": a DEX spot estimate, rounded down to what a person
  /// reads (2 decimals from 100 BEAM, 3 from 1, 4 below).
  static String beamEstimate(BigInt groth, {required String locale}) {
    if (groth <= BigInt.zero) return '0 BEAM';
    final value = Decimal.parse('$groth').shift(-8);
    final places = value >= Decimal.fromInt(100)
        ? 2
        : value >= Decimal.one
        ? 3
        : 4;
    final step = BigInt.from(10).pow(8 - places);
    final rounded = groth ~/ step * step;
    if (rounded == BigInt.zero) {
      final symbols = Util.getSymbolsFor(locale: locale);
      return '< 0${symbols?.DECIMAL_SEP ?? '.'}0001 BEAM';
    }
    return '≈ ${beam(rounded, locale: locale)}';
  }

  /// Fiat for [groth] at [beamPrice] per BEAM: "≈ $12.34"-style text with
  /// Campfire's currency code after it.
  static String fiatEstimate(
    BigInt groth,
    Decimal beamPrice, {
    required String locale,
    required String currency,
  }) {
    final value =
        Amount(rawValue: groth, fractionDigits: 8).decimal * beamPrice;
    return '≈ ${value.toAmount(fractionDigits: 2).fiatString(locale: locale)}'
        ' $currency';
  }

  static const String noPrice = 'No price';
  static const String priceLoading = 'Price not loaded yet';
  static const String estimateNote =
      'Estimated from DEX prices. Assets without a DEX price are not counted.';

  /// The warning under an asset that copies a verified one.
  static String? impersonation(BeamAssetContract asset) {
    final copied = asset.impersonates;
    if (copied == null) return null;
    final real = BeamAssetCatalog.verified[copied];
    final what = real?.symbol ?? '#$copied';
    return 'Not the verified $what (#$copied). Anyone can create an asset '
        'with any name.';
  }

  /// Short label next to an unverified asset's name.
  static String badge(BeamAssetContract asset) {
    if (asset.isPoolShare) return 'Pool share';
    if (asset.verified) return '';
    return 'Unverified ${asset.idLabel}';
  }

  /// "BEAM / FOMO · 1% fee pool" for a liquidity token.
  static String? poolLine(BeamAssetContract asset) {
    final kind = asset.poolKind;
    if (!asset.isPoolShare || kind == null) return null;
    final pair = asset.name.replaceFirst(RegExp(r' pool share$'), '');
    String fee;
    try {
      fee = BeamPoolKind.fromWire(kind).feePercent;
    } on FormatException {
      fee = '?';
    }
    return 'Your share of the $pair pool ($fee fee)';
  }

  /// The fee sentence on the send form.
  static String feeLine(BigInt fee, {required String locale}) =>
      'Network fee: ${beam(fee, locale: locale)}, paid in BEAM';

  /// Shown when the wallet cannot pay the fee in BEAM.
  static String needBeamForFee(
    String symbol,
    BigInt fee,
    BigInt beamAvailable, {
    required String locale,
  }) =>
      'Sending $symbol costs a ${beam(fee, locale: locale)} network fee, paid '
      'in BEAM. This wallet has ${beam(beamAvailable, locale: locale)} '
      'available. Add at least ${beam(fee - beamAvailable, locale: locale)} '
      'first.';

  /// Receive explanation.
  static String receiveLine(String symbol) =>
      '$symbol arrives at your BEAM address, the same one you use for BEAM.';
}

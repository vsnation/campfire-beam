/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:decimal/decimal.dart';

import '../../../l10n/amount_text.dart';
import '../../../l10n/l10n.dart';
import '../../../models/isar/models/beam/beam_asset_contract.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/amount/amount_unit.dart';
import '../../crypto_currency/crypto_currency.dart';
import '../contracts/dex/dex_constants.dart';
import '../models/beam_asset_info.dart';
import 'beam_asset_catalog.dart';
import 'beam_asset_registry.dart';

/// Every user-facing sentence and number format of the asset screens, in
/// one place so the list, the asset page, send and confirm say the same
/// thing the same way.
abstract final class BeamAssetText {
  static final Beam _beam = Beam(CryptoCurrencyNetwork.main);

  /// "1,234.50000000 FOMO". Assets use whole units with BEAM's decimals
  /// setting ([maxDecimals]); the user's BEAM unit (mBEAM…) never applies
  /// to another asset.
  ///
  /// Every amount here is written the app's way, whatever [locale] says:
  /// "." decimals in every language, thousands grouped for the app's
  /// language (lib/l10n/amount_text.dart). [locale] only shapes fiat.
  static String amount(
    Amount value,
    BeamAssetContract asset, {
    required String locale,
    int maxDecimals = 8,
    bool withUnit = true,
  }) => AmountUnit.normal.displayAmount(
    amount: value,
    locale: kAppAmountLocale,
    coin: _beam,
    // An asset with more decimals than the BEAM setting (doggy's 12) shows
    // them all: what is shown is what it holds. Fewer are capped at its own.
    maxDecimalPlaces: maxDecimals > asset.decimals
        ? maxDecimals
        : asset.decimals,
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
    const sep = '.';
    var trimmed = text;
    if (trimmed.contains(sep)) {
      trimmed = trimmed.replaceFirst(RegExp(r'0+$'), '');
      if (trimmed.endsWith(sep)) {
        trimmed = trimmed.substring(0, trimmed.length - sep.length);
      }
    }
    return '$trimmed ${asset.symbol}';
  }

  /// The ticker as money-moving screens name it: "FOMO" for a verified
  /// asset, "FOMO #999" for anything else, so a copy never reads like the
  /// asset it copies.
  static String symbolLabel(BeamAssetContract asset) =>
      asset.verified || asset.symbol == asset.idLabel
      ? asset.symbol
      : '${asset.symbol} ${asset.idLabel}';

  /// [exact] with [symbolLabel]: "12.5 FOMO", "250 FOMO #999" (confirm
  /// headlines and buttons).
  static String exactLabelled(
    Amount value,
    BeamAssetContract asset, {
    required String locale,
  }) {
    final plain = exact(value, asset, locale: locale);
    final unit = ' ${asset.symbol}';
    final number = plain.endsWith(unit)
        ? plain.substring(0, plain.length - unit.length)
        : plain;
    return '$number ${symbolLabel(asset)}';
  }

  /// For an asset whose metadata sets its own decimals (NTH_RATIO, CANDY's 1):
  /// how many, and, when [available] is above zero, that BEAM's official
  /// wallet and explorer (every asset with 8) show this balance differently.
  /// Null for 8 decimals, a pool share, or decimals not read this run.
  static String? decimalsNote(BeamAssetContract asset, BigInt available) {
    final d = asset.decimals;
    if (d == BeamAssetInfo.beamDecimals ||
        asset.poolAssetA != null ||
        !BeamAssetRegistry.decimalsRead(asset.assetId)) {
      return null;
    }
    final label = symbolLabel(asset);
    final own = d == 0
        ? appL10n.assetDecimalsNone(label)
        : appL10n.assetDecimalsOwn(label, d);
    if (available <= BigInt.zero) return own;
    return '$own ${appL10n.assetDecimalsElsewhere('${formatAmountUnits(available)} $label')}';
  }

  /// After a send whose outcome is unknown (the connection dropped and the
  /// wallet could not be asked afterwards).
  static String get sendUnknownTitle => appL10n.assetsSendUnknownTitle;
  static String get sendUnknown => appL10n.assetsSendUnknown;

  /// "0.001 BEAM", trailing zeros dropped.
  static String beam(BigInt groth, {required String locale}) =>
      _units(groth, 'BEAM', locale);

  /// [raw] smallest units of an asset with [decimals] places (BEAM's 8) as
  /// "1,234.5 [unit]", trailing zeros dropped, written the app's way
  /// ([formatAmountUnits]).
  static String _units(
    BigInt raw,
    String unit,
    String locale, [
    int decimals = 8,
  ]) => '${formatAmountUnits(raw, decimals: decimals)} $unit';

  /// A list row's amount, rounded down to what a person reads: 2 decimals
  /// from 1,000, 4 from 1, all of the asset's below ("6,477,953.06 GIGA",
  /// "568.1297 FOMO", "0.46659234 LP"). The asset page shows every digit.
  static String rounded(
    Amount value,
    BeamAssetContract asset, {
    required String locale,
  }) {
    final raw = value.raw;
    final abs = raw.abs();
    final d = asset.decimals;
    final one = BigInt.from(10).pow(d);
    final places = abs >= one * BigInt.from(1000)
        ? 2
        : abs >= one
        ? 4
        : d;
    final step = BigInt.from(10).pow(d > places ? d - places : 0);
    return _units(raw ~/ step * step, asset.symbol, locale, d);
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
    if (rounded == BigInt.zero) return '< 0.0001 BEAM';
    return '≈ ${beam(rounded, locale: locale)}';
  }

  /// "≈ 12.5 BEAM if sold now": an unverified asset's value, which is what
  /// its pool would pay for the whole holding, not a price anyone vouches
  /// for (`BeamAssetPricer.isSaleValue`).
  static String saleEstimate(BigInt groth, {required String locale}) =>
      appL10n.assetsIfSoldNow(beamEstimate(groth, locale: locale));

  /// [beamEstimate], or [saleEstimate] when [sale].
  static String valueEstimate(
    BigInt groth, {
    required bool sale,
    required String locale,
  }) => sale
      ? saleEstimate(groth, locale: locale)
      : beamEstimate(groth, locale: locale);

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

  static String get noPrice => appL10n.assetsNoPrice;
  static String get priceLoading => appL10n.assetsPriceLoading;
  static String get estimateNote => appL10n.assetsEstimateNote;

  /// The warning under an asset that copies a verified one.
  static String? impersonation(BeamAssetContract asset) {
    final copied = asset.impersonates;
    if (copied == null) return null;
    final real = BeamAssetCatalog.verified[copied];
    final what = real?.symbol ?? '#$copied';
    return appL10n.assetsImpersonation(what, '$copied');
  }

  /// Short label next to an unverified asset's name.
  static String badge(BeamAssetContract asset) {
    if (asset.isPoolShare) return appL10n.assetsPoolShare;
    if (asset.verified) return '';
    return appL10n.assetsUnverifiedBadge(asset.idLabel);
  }

  /// "BEAM/FOMO" for the liquidity token "BEAM/FOMO LP": the pool it is a
  /// share of. Null for any other asset.
  static String? poolPair(BeamAssetContract asset) {
    if (!asset.isPoolShare) return null;
    return asset.name.replaceFirst(RegExp(r' LP$'), '');
  }

  /// "1% fee": a liquidity token's pool fee tier; null for any other asset.
  static String? poolFee(BeamAssetContract asset) {
    final kind = asset.poolKind;
    if (!asset.isPoolShare || kind == null) return null;
    try {
      return appL10n.assetsPoolFee(BeamPoolKind.fromWire(kind).feePercent);
    } on FormatException {
      return null;
    }
  }

  /// "Your share of the BEAM/FOMO pool (1% fee)" for a liquidity token.
  static String? poolLine(BeamAssetContract asset) {
    final pair = poolPair(asset);
    if (pair == null) return null;
    final fee = poolFee(asset);
    return fee == null
        ? appL10n.assetsPoolLine(pair)
        : appL10n.assetsPoolLineWithFee(pair, fee);
  }

  /// "Pool share · 1% fee": what a liquidity token is, under its name in a
  /// list, where the fee tier tells the pools of one pair apart.
  static String? poolSubtitle(BeamAssetContract asset) {
    if (!asset.isPoolShare) return null;
    final fee = poolFee(asset);
    return fee == null
        ? appL10n.assetsPoolShare
        : appL10n.assetsPoolSubtitleWithFee(fee);
  }

  /// "2,728.25 LP": a liquidity token's amount where its name ("BEAM/FOMO
  /// LP") is already written next to it; [rounded] for anything else.
  static String roundedShort(
    Amount value,
    BeamAssetContract asset, {
    required String locale,
  }) {
    final text = rounded(value, asset, locale: locale);
    if (!asset.isPoolShare || !text.endsWith(' ${asset.symbol}')) return text;
    return '${text.substring(0, text.length - asset.symbol.length)}LP';
  }

  /// The fee sentence on the send form.
  static String feeLine(BigInt fee, {required String locale}) =>
      appL10n.assetsFeeLine(beam(fee, locale: locale));

  /// Shown when the wallet cannot pay the fee in BEAM.
  static String needBeamForFee(
    String symbol,
    BigInt fee,
    BigInt beamAvailable, {
    required String locale,
  }) => appL10n.assetsNeedBeamForFee(
    symbol,
    beam(fee, locale: locale),
    beam(beamAvailable, locale: locale),
    beam(fee - beamAvailable, locale: locale),
  );

  /// Receive explanation, for [symbol] or (null) for every asset.
  static String receiveLine(String? symbol) => symbol == null
      ? appL10n.assetsReceiveLineAll
      : appL10n.assetsReceiveLine(symbol);
}

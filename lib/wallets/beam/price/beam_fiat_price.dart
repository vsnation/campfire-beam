/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/global/locale_provider.dart';
import '../../../providers/global/prefs_provider.dart';
import '../../../providers/global/price_provider.dart';
import '../../isar/providers/wallet_info_provider.dart';

/// BEAM's price in the user's currency, as every BEAM screen reads it.
///
/// It comes from Campfire's own price service (CoinGecko id `beam`, BEAM
/// Privacy at beam.mw; not `beam-2`, an unrelated Ethereum token with the
/// same ticker), in the currency chosen in Settings, and only when the user
/// allows price lookups. Asset prices in BEAM come from the DEX pools
/// (`BeamAssetPricer`); this is the one step from BEAM to fiat.
@immutable
class BeamFiatPrice {
  const BeamFiatPrice({
    required this.lookupsOn,
    required this.currency,
    this.price,
    this.locale = 'en_US',
  });

  /// The user allows price lookups (Campfire's "external calls"). Off means
  /// values are shown in BEAM, never as a missing price.
  final bool lookupsOn;

  /// Fiat per whole BEAM; null when there is no price right now. Never
  /// zero: the price cache writes 0 for a coin the last answer left out,
  /// and that is "unknown", not "worthless".
  final Decimal? price;

  /// ISO code from Settings, e.g. "USD".
  final String currency;

  /// For digit grouping and the decimal mark ("1,234.56" / "1.234,56").
  final String locale;

  /// A price is known and may be shown.
  bool get known => lookupsOn && price != null;

  /// [raw] as a usable price: null for a missing, zero or negative one.
  static Decimal? usable(Decimal? raw) =>
      raw == null || raw <= Decimal.zero ? null : raw;
}

/// [BeamFiatPrice] for the BEAM wallet [walletId].
final pBeamFiatPrice = Provider.family<BeamFiatPrice, String>((ref, walletId) {
  final lookupsOn = ref.watch(
    prefsChangeNotifierProvider.select((p) => p.externalCalls),
  );
  final currency = ref.watch(
    prefsChangeNotifierProvider.select((p) => p.currency),
  );
  final locale = ref.watch(
    localeServiceChangeNotifierProvider.select((l) => l.locale),
  );
  final coin = ref.watch(pWalletCoin(walletId));
  final price = lookupsOn
      ? ref.watch(
          priceAnd24hChangeNotifierProvider.select(
            (p) => p.getPrice(coin)?.value,
          ),
        )
      : null;
  return BeamFiatPrice(
    lookupsOn: lookupsOn,
    price: BeamFiatPrice.usable(price),
    currency: currency,
    locale: locale,
  );
});

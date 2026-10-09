/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// WBEAM is BEAM moved to Ethereum by the Beam Bridge, one for one. So
// Campfire treats it as BEAM: worth what BEAM is worth (the BEAM price
// Campfire already fetched; no extra request), and drawn with BEAM's icon
// (`WbeamIcon`).

import 'package:decimal/decimal.dart';

import '../../utilities/default_eth_tokens.dart';
import '../crypto_currency/crypto_currency.dart';

/// Whether [contractAddress] is WBEAM's (any letter case).
bool isWbeam(String? contractAddress) =>
    contractAddress != null &&
    contractAddress.toLowerCase() == DefaultTokens.wbeam.address;

/// The coin WBEAM stands for.
final CryptoCurrency wbeamCoin = Beam(CryptoCurrencyNetwork.main);

/// The token prices that follow from coin prices: WBEAM's is BEAM's, when
/// WBEAM is among [contractAddresses] and BEAM's price is known. Keyed by
/// lower-case contract address, as `PriceService` keeps token prices.
Map<String, ({Decimal value, double change24h})> pricesFromCoins(
  Map<CryptoCurrency, ({Decimal value, double change24h})> coinPrices,
  Iterable<String> contractAddresses,
) {
  final beam = coinPrices[wbeamCoin];
  if (beam == null || !contractAddresses.any(isWbeam)) return const {};
  return {DefaultTokens.wbeam.address: beam};
}

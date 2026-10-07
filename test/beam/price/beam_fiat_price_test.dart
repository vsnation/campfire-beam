/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// BEAM's fiat price as every BEAM screen reads it (pBeamFiatPrice): from
// Campfire's price service, in the currency chosen in Settings, never a
// zero price; and the price service keeps refreshing after the currency is
// changed (it stopped before: the owner's "update coingecko").

import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/providers/global/locale_provider.dart';
import 'package:stackwallet/providers/global/prefs_provider.dart';
import 'package:stackwallet/providers/global/price_provider.dart';
import 'package:stackwallet/services/locale_service.dart';
import 'package:stackwallet/services/price.dart';
import 'package:stackwallet/services/price_service.dart';
import 'package:stackwallet/utilities/prefs.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_ratio.dart';
import 'package:stackwallet/wallets/beam/price/beam_fiat_price.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/providers/wallet_info_provider.dart';
import 'package:stackwallet/widgets/beam/tx/beam_tx_backend.dart';
import 'package:stackwallet/widgets/beam/wiring/beam_wallet_listenables.dart';

/// Only what the price providers read of Campfire's settings.
class _Prefs extends ChangeNotifier implements Prefs {
  _Prefs({this.lookups = true, this.code = 'USD'});

  bool lookups;
  String code;

  void setCurrency(String value) {
    code = value;
    notifyListeners();
  }

  @override
  bool get externalCalls => lookups;

  @override
  String get currency => code;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Campfire's price service holding [price] for BEAM.
class _Prices extends PriceService {
  _Prices(this.price) : super('USD');

  Decimal? price;

  void refreshed(Decimal value) {
    price = value;
    notifyListeners();
  }

  @override
  ({Decimal value, double change24h})? getPrice(CryptoCurrency coin) =>
      coin is Beam && price != null ? (value: price!, change24h: 0) : null;
}

void main() {
  const walletId = 'w1';

  ProviderContainer container({
    required _Prefs prefs,
    Decimal? price,
    String locale = 'en_US',
  }) {
    final c = ProviderContainer(
      overrides: [
        prefsChangeNotifierProvider.overrideWithValue(prefs),
        priceAnd24hChangeNotifierProvider.overrideWithValue(_Prices(price)),
        localeServiceChangeNotifierProvider.overrideWithValue(LocaleService()),
        pWalletCoin.overrideWithProvider(
          (id) => Provider((_) => Beam(CryptoCurrencyNetwork.main)),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('the CoinGecko id is BEAM Privacy\'s ("beam"), not "beam-2"', () {
    // Checked live on 2026-10-07: id "beam" is BEAM, homepage beam.mw,
    // 0.00856 USD; "beam-2" is an unrelated Ethereum gaming token.
    expect(PriceAPI.coinGeckoIdOf(Beam(CryptoCurrencyNetwork.main)), 'beam');
  });

  test('a known price, in the chosen currency', () {
    final c = container(
      prefs: _Prefs(code: 'EUR'),
      price: Decimal.parse('0.00856196'),
    );
    final f = c.read(pBeamFiatPrice(walletId));
    expect(f.lookupsOn, isTrue);
    expect(f.price, Decimal.parse('0.00856196'));
    expect(f.currency, 'EUR');
    expect(f.locale, 'en_US');
    expect(f.known, isTrue);

    final dex = beamDexFiatOf(f)!;
    expect(dex.perBeam, BeamRatio.parseDecimal('0.00856196'));
    expect(dex.currency, 'EUR');
    expect(dex.approx(BigInt.from(2000000)), 'under 0.01 EUR');

    final tx = c.read(pBeamTxFiat(walletId))!;
    expect(tx.price, Decimal.parse('0.00856196'));
    expect(tx.currency, 'EUR');
  });

  test('a zero price is no price: never "0.00 USD"', () {
    // The price cache writes "0" for a coin the last answer left out.
    final c = container(prefs: _Prefs(), price: Decimal.zero);
    final f = c.read(pBeamFiatPrice(walletId));
    expect(f.price, isNull);
    expect(f.known, isFalse);
    expect(beamDexFiatOf(f)!.perBeam, isNull);
    expect(beamDexFiatOf(f)!.approx(BigInt.one), isNull);
    expect(c.read(pBeamTxFiat(walletId)), isNull);
    expect(BeamFiatPrice.usable(Decimal.parse('-1')), isNull);
  });

  test('lookups off: no price at all, values stay in BEAM', () {
    final c = container(
      prefs: _Prefs(lookups: false),
      price: Decimal.parse('0.5'),
    );
    final f = c.read(pBeamFiatPrice(walletId));
    expect(f.lookupsOn, isFalse);
    expect(f.price, isNull);
    expect(beamDexFiatOf(f), isNull);
    expect(c.read(pBeamTxFiat(walletId)), isNull);
  });

  test('the price follows the service as it refreshes', () {
    final prices = _Prices(null);
    final c = ProviderContainer(
      overrides: [
        prefsChangeNotifierProvider.overrideWithValue(_Prefs()),
        priceAnd24hChangeNotifierProvider.overrideWithValue(prices),
        localeServiceChangeNotifierProvider.overrideWithValue(LocaleService()),
        pWalletCoin.overrideWithProvider(
          (id) => Provider((_) => Beam(CryptoCurrencyNetwork.main)),
        ),
      ],
    );
    addTearDown(c.dispose);
    final seen = <Decimal?>[];
    c.listen<BeamFiatPrice>(
      pBeamFiatPrice(walletId),
      (_, next) => seen.add(next.price),
      fireImmediately: true,
    );
    prices.refreshed(Decimal.parse('0.009'));
    expect(c.read(pBeamFiatPrice(walletId)).price, Decimal.parse('0.009'));
    expect(seen, [null, Decimal.parse('0.009')]);
  });

  test('changing the currency keeps prices refreshing', () {
    final prefs = _Prefs();
    final c = ProviderContainer(
      overrides: [prefsChangeNotifierProvider.overrideWithValue(prefs)],
    );
    addTearDown(c.dispose);
    final first = c.read(priceAnd24hChangeNotifierProvider);
    // main.dart starts the first service.
    first.start(false);
    expect(first.isRunning, isTrue);

    prefs.setCurrency('EUR');
    final second = c.read(priceAnd24hChangeNotifierProvider);
    expect(identical(first, second), isFalse);
    expect(second.baseTicker, 'EUR');
    // The old service was disposed with its timer; the new one refreshes
    // on its own instead of only once.
    expect(first.isRunning, isFalse);
    expect(second.isRunning, isTrue);
  });
}

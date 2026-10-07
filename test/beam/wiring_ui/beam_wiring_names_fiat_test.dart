/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// BeamWalletWiring over a REAL BeamWallet: the DEX and Names deps name
// assets the wallet does not hold (one read of the explorer's table, saved
// in the wallet's info), and the DEX follows Campfire's fiat price from the
// app's providers once a screen attaches.
//
//   scripts/beam/host_test.sh --no-analyze test/beam/wiring_ui

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:stackwallet/providers/global/prefs_provider.dart';
import 'package:stackwallet/providers/global/price_provider.dart';
import 'package:stackwallet/services/price_service.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_directory.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_ratio.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/isar/providers/wallet_info_provider.dart';
import 'package:stackwallet/widgets/beam/wiring/beam_wallet_listenables.dart';

import 'wiring_harness.dart';

/// Settings with price lookups on, in [code].
class _PricesOn extends TestPrefs {
  _PricesOn(this.code);

  final String code;

  @override
  bool get externalCalls => true;

  @override
  String get currency => code;
}

/// Campfire's price service holding [price] for BEAM.
class _Prices extends PriceService {
  _Prices(this.price) : super('EUR');

  Decimal? price;

  void refreshed(Decimal? value) {
    price = value;
    notifyListeners();
  }

  @override
  ({Decimal value, double change24h})? getPrice(CryptoCurrency coin) =>
      coin is Beam && price != null ? (value: price!, change24h: 0) : null;
}

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  testWidgets('assets the wallet does not hold are named from one read', (
    tester,
  ) async {
    var reads = 0;
    final wallet = await openBeamWallet(
      tester,
      db,
      readAssetTable: () async {
        reads++;
        return {
          2: 'STD:SCH_VER=1;N=RAYS;SN=RAYS;UN=RAYS;NTHUN=Flicker',
          3: 'STD:SCH_VER=1;N=BeamBots Token;SN=BB;UN=BB',
          999: 'STD:SCH_VER=1;N=FOMO;SN=FOMO;UN=FOMO',
        };
      },
    );
    final w = BeamWalletWiring.of(wallet);
    // The read, then the save into Isar: real I/O, finished between pumps.
    String? saved;
    for (var i = 0; i < 100 && saved == null; i++) {
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final info = wallet.mainDB.isar.walletInfo
            .where()
            .walletIdEqualTo(wallet.walletId)
            .findFirstSync();
        saved =
            info?.otherData[WalletInfoAssetDirectoryCache.otherDataKey]
                as String?;
      });
    }

    // The wallet holds BEAM and FOMO only; #2 and #3 are named anyway.
    expect(w.dex.display(2).symbol, 'RAYS');
    expect(w.dex.display(2).verified, isFalse);
    expect(w.dex.assetLabel(3), 'BB #3');
    expect(w.names.display(2).name, 'RAYS');
    // A copy of FOMO stays a copy.
    expect(w.dex.display(999).impersonates, 174);
    expect(w.dex.assetLabel(999), 'FOMO #999');
    expect(reads, 1);

    // Saved with the wallet: on screen at the next unlock.
    expect(saved, isNotNull);
    final back = WalletInfoAssetDirectoryCache.decode(saved!)!;
    expect(back.assets[3]!.name, 'BeamBots Token');
    expect(back.readAt, isNotNull);
    await finish(tester);
  });

  testWidgets('the DEX follows Campfire\'s price once a screen attaches', (
    tester,
  ) async {
    final wallet = await openBeamWallet(tester, db);
    final w = BeamWalletWiring.of(wallet);
    expect(w.fiat.value, isNull, reason: 'nothing attached yet');

    final prices = _Prices(null);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsChangeNotifierProvider.overrideWithValue(_PricesOn('EUR')),
          priceAnd24hChangeNotifierProvider.overrideWithValue(prices),
          // The coin without Campfire's Isar watcher, which this short-lived
          // scope would dispose under the wallet's own writes.
          pWalletCoin.overrideWithProvider(
            (id) => Provider((_) => Beam(CryptoCurrencyNetwork.main)),
          ),
        ],
        child: Builder(
          builder: (context) {
            w.attach(context);
            return const SizedBox();
          },
        ),
      ),
    );
    // Lookups on, no price yet: "No EUR price", never "0.00".
    expect(w.fiat.value!.perBeam, isNull);
    expect(w.fiat.value!.currency, 'EUR');
    expect(identical(w.dex.fiat, w.fiat), isTrue);
    expect(w.dex.worthOfBeam(BigInt.from(100000000)), 'No EUR price');

    prices.refreshed(Decimal.parse('0.5'));
    await tester.pump();
    expect(w.fiat.value!.perBeam, BeamRatio.parseDecimal('0.5'));
    expect(w.dex.worthOfBeam(BigInt.from(300000000)), '≈ 1.50 EUR');

    // A zero price is no price.
    prices.refreshed(Decimal.zero);
    await tester.pump();
    expect(w.fiat.value!.perBeam, isNull);

    await tester.pumpWidget(const SizedBox());
    await finish(tester);
  });
}

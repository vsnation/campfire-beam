/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// How the asset list orders and labels what a wallet holds when someone
// prices their own asset (M-4).

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_holdings.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_text.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_pool.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_balance_mapper.dart';

final _beam = BigInt.from(100000000);

BeamCachedAssetTotals _held(int id, BigInt units) => BeamCachedAssetTotals(
  assetId: id,
  available: units,
  receiving: BigInt.zero,
  sending: BigInt.zero,
  maturing: BigInt.zero,
  change: BigInt.zero,
);

BeamPool _pool(int aid, BigInt beam, BigInt units, int lp) => BeamPool(
  aid1: 0,
  aid2: aid,
  kind: BeamPoolKind.high,
  tok1: beam,
  tok2: units,
  ctl: BigInt.from(1000),
  lpToken: lp,
);

void main() {
  test('an asset anyone can mint and price never tops the list, and its '
      'value says it is what its pool would pay', () {
    final market = BeamAssetMarket([
      // FOMO: 10,000 BEAM against 1,000,000 FOMO (0.01 BEAM each).
      _pool(174, _beam * BigInt.from(10000), _beam * BigInt.from(1000000), 175),
      // #999: 5,000 BEAM against 1 groth, set up to look precious.
      _pool(999, _beam * BigInt.from(5000), BigInt.one, 1000),
    ]);
    final list = BeamAssetHoldings.build(
      totals: {
        174: _held(174, _beam * BigInt.from(10)),
        999: _held(999, _beam),
        777: _held(777, _beam * BigInt.from(5)),
      },
      contracts: const {},
      hidden: const {},
      market: market,
    );
    expect([for (final h in list) h.assetId], [174, 999, 777]);
    final spam = list[1];
    expect(
      spam.valueGroth! > list[0].valueGroth!,
      isTrue,
      reason: 'worth more on paper, still listed after FOMO',
    );
    expect(spam.valueGroth! < _beam * BigInt.from(5000), isTrue);
    expect(spam.saleValue, isTrue);
    expect(list[0].saleValue, isFalse);
    expect(list[2].priced, isFalse);
    expect(
      BeamAssetText.valueEstimate(
        spam.valueGroth!,
        sale: true,
        locale: 'en_US',
      ),
      endsWith('BEAM if sold now'),
    );
    expect(
      BeamAssetText.valueEstimate(_beam, sale: false, locale: 'en_US'),
      '≈ 1 BEAM',
    );
  });
}

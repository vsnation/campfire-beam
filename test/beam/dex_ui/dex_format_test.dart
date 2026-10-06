/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_ratio.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/widgets/beam/dex/dex_format.dart';

void main() {
  const g = BigInt.from;
  BeamRatio r(int n, int d) => BeamRatio(g(n), g(d));

  group('parse: exact, never guessed', () {
    test('plain decimals', () {
      expect(DexFormat.parse('0.1').value, g(10000000));
      expect(DexFormat.parse('12').value, g(1200000000));
      expect(DexFormat.parse('.25').value, g(25000000));
      expect(DexFormat.parse('3.').value, g(300000000));
      expect(DexFormat.parse(' 0.00000001 ').value, g(1));
      expect(DexFormat.parse('0').value, BigInt.zero);
      expect(DexFormat.parse('0').isPositive, isFalse);
      expect(DexFormat.parse('').isEmpty, isTrue);
    });

    test('commas and separators are refused by name', () {
      expect(
        DexFormat.parse('1,000').error,
        'Use a dot for decimals, like 0.5',
      );
      expect(DexFormat.parse('0,5').error, isNotNull);
      expect(DexFormat.parse('1.2.3').error, isNotNull);
      expect(DexFormat.parse('.').error, isNotNull);
      expect(DexFormat.parse('-1').error, isNotNull);
      expect(DexFormat.parse('1e5').error, isNotNull);
    });

    test('more than 8 decimals is refused, not rounded', () {
      expect(
        DexFormat.parse('0.000000001').error,
        'BEAM amounts have at most 8 decimals',
      );
    });

    test('above a 64-bit amount is refused', () {
      expect(DexFormat.parse('99999999999').error, isNotNull);
      expect(DexFormat.parse('92233720368').value, isNotNull);
    });
  });

  group('formatting', () {
    test('exact keeps every groth, groups thousands', () {
      expect(DexFormat.exact(g(637304113367)), '6,373.04113367');
      expect(DexFormat.exact(g(10000000)), '0.1');
      expect(DexFormat.exact(g(1100000)), '0.011');
      expect(DexFormat.exact(BigInt.zero), '0');
      expect(DexFormat.plain(g(123456789012345)), '1234567.89012345');
    });

    test('compact rounds down to what people read', () {
      expect(DexFormat.compact(g(637304113367)), '6,373.04');
      expect(DexFormat.compact(g(803687640)), '8.0368');
      expect(DexFormat.compact(g(80368764)), '0.8036');
      expect(DexFormat.compact(g(99010)), '0.0009901');
      expect(DexFormat.compact(g(1)), '0.00000001');
    });

    test('percent never says 0% for something real', () {
      expect(DexFormat.percent(r(13, 10000)), '0.13%');
      expect(DexFormat.percent(r(1, 100)), '1%');
      expect(DexFormat.percent(r(1, 200)), '0.5%');
      expect(DexFormat.percent(r(1, 1000000)), '< 0.01%');
      expect(DexFormat.percent(BeamRatio.zero), '0%');
      expect(DexFormat.percent(r(523, 1000)), '52.3%');
    });

    test('fee tier labels follow the measured kinds', () {
      expect(DexFormat.feeTier(BeamPoolKind.low), '0.05% fee');
      expect(DexFormat.feeTier(BeamPoolKind.mid), '0.3% fee');
      expect(DexFormat.feeTier(BeamPoolKind.high), '1% fee');
    });

    test('fiat', () {
      expect(DexFormat.fiat(g(59974286), r(2, 1), 'USD'), r'$1.19');
      expect(DexFormat.fiat(g(100000000), r(89, 10000), 'USD'), r'< $0.01');
      expect(DexFormat.fiat(g(250000000000), r(1, 1), 'CHF'), '2,500.00 CHF');
    });

    test('short contract id', () {
      expect(DexFormat.shortId(kDexContractId), '729fe0…ef9cbf');
    });
  });
}

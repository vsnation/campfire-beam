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

void main() {
  const g = BigInt.from;
  BeamRatio r(int n, int d) => BeamRatio(g(n), g(d));

  test('reduced, positive denominator, value equality', () {
    expect(r(6, -4), r(-3, 2));
    expect(r(6, -4).numerator, g(-3));
    expect(r(6, -4).denominator, g(2));
    expect(r(0, 5), BeamRatio.zero);
    expect(() => r(1, 0), throwsArgumentError);
  });

  test('arithmetic and comparison are exact', () {
    expect(r(1, 3) + r(1, 6), r(1, 2));
    expect(r(1, 3) - r(1, 2), r(-1, 6));
    expect(r(2, 3) * r(3, 4), r(1, 2));
    expect(r(2, 3) / r(4, 9), r(3, 2));
    expect(() => r(1, 2) / BeamRatio.zero, throwsArgumentError);
    expect(r(1, 3) < r(1, 2), isTrue);
    expect(-r(1, 3), r(-1, 3));
  });

  test('floor rounds toward minus infinity', () {
    expect(r(7, 2).floor(), g(3));
    expect(r(-7, 2).floor(), g(-4));
    expect(r(-6, 2).floor(), g(-3));
    expect(r(1, 3).floorTimes(g(10)), g(3));
  });

  test('toDecimalString truncates toward zero', () {
    expect(r(1, 3).toDecimalString(4), '0.3333');
    expect(r(2, 3).toDecimalString(4), '0.6666');
    expect(r(-2, 3).toDecimalString(2), '-0.66');
    expect(r(-1, 1000).toDecimalString(2), '0.00');
    expect(r(12345, 100).toDecimalString(0), '123');
    expect(r(5, 1).toDecimalString(3), '5.000');
  });

  test('parseDecimal reads the shader rate formats exactly', () {
    expect(
      BeamRatio.parseDecimal('0.12319260112024993667'),
      BeamRatio(BigInt.parse('12319260112024993667'), BigInt.from(10).pow(20)),
    );
    expect(BeamRatio.parseDecimal('8.117370612411103308').toDecimalString(5),
        '8.11737');
    expect(BeamRatio.parseDecimal('1.25e-7'), r(125, 1000000000));
    expect(BeamRatio.parseDecimal('3E+5'), r(300000, 1));
    expect(BeamRatio.parseDecimal('-0.5'), r(-1, 2));
    expect(BeamRatio.parseDecimal('.5'), r(1, 2));
    expect(BeamRatio.parseDecimal('5.'), r(5, 1));
    for (final bad in ['', '.', 'abc', '1.2.3', '1e', '0x10', 'NaN']) {
      expect(() => BeamRatio.parseDecimal(bad), throwsFormatException,
          reason: bad);
    }
  });
}

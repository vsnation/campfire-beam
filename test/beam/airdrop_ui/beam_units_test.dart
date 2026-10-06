/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// BeamUnits.parse: the amount typed on the airdrop, mint and burn screens.
// A guess between two readings that differ a thousandfold is refused.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/widgets/beam/airdrop/beam_units.dart';

BigInt _u(String whole, [String frac = '']) =>
    BigInt.parse(whole) * BeamUnits.one + BigInt.parse(frac.padRight(8, '0'));

void main() {
  test('plain amounts, a decimal comma, and thousands groups', () {
    expect(BeamUnits.parse('1234.5'), _u('1234', '5'));
    expect(BeamUnits.parse('1,5'), _u('1', '5'));
    expect(BeamUnits.parse('.5'), _u('0', '5'));
    expect(BeamUnits.parse('1 234,5'), _u('1234', '5'));
    expect(BeamUnits.parse('1,234.5'), _u('1234', '5'));
    expect(BeamUnits.parse('1,234,567'), _u('1234567'));
    expect(BeamUnits.parse('12,345,678.12345678'), _u('12345678', '12345678'));
  });

  test('"1.234,5" is refused, never read as 1.2345 (L-9)', () {
    // European grouping: 1234.5 to its writer. Read naively it is 1000
    // times smaller; neither reading is guessed.
    expect(BeamUnits.parse('1.234,5'), isNull);
    expect(BeamUnits.problem('1.234,5'), contains('mixing . and ,'));
    expect(BeamUnits.parse('1.234.567,89'), isNull);
    expect(BeamUnits.parse('12,34.5'), isNull);
    expect(BeamUnits.parse('1,23,4'), isNull);
    expect(BeamUnits.parse('1,2345.6'), isNull);
  });

  test('the ambiguous "1,000" is still refused', () {
    expect(BeamUnits.parse('1,000'), isNull);
    expect(BeamUnits.problem('1,000'), contains('could mean either'));
  });
}

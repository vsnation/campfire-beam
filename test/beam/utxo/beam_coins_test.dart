/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/models/beam_utxo.dart';
import 'package:stackwallet/wallets/beam/utxo/beam_coins.dart';

const _g = BigInt.from;

BeamUtxo _coin(int aid, int amount, String status, {String type = 'norm'}) =>
    BeamUtxo(
      id: '$aid-$amount-$status',
      assetId: aid,
      amount: _g(amount),
      type: type,
      statusCode: 0,
      statusString: status,
    );

void main() {
  group('fees', () {
    test('a small split pays the 100,000 groth minimum', () {
      expect(BeamFees.forSplit(3), _g(100000)); // 4 outputs + kernel
    });

    test('a large split pays per output, as the core computes it', () {
      // 20 coins + 1 change = 21 outputs: 10,000 + 21 * 18,000.
      expect(BeamFees.forSplit(20), _g(388000));
      // An asset split also needs BEAM change.
      expect(BeamFees.forSplit(20, asset: true), _g(406000));
    });
  });

  group('summary', () {
    test('groups per asset; spent coins are left out', () {
      final s = BeamCoinSummary.of([
        _coin(0, 10, 'available'),
        _coin(0, 30, 'available'),
        _coin(0, 5, 'maturing'),
        _coin(0, 7, 'outgoing'),
        _coin(0, 99, 'spent'),
        _coin(174, 3, 'available', type: 'shld'),
      ]);
      expect(s.keys.toSet(), {0, 174});
      final beam = s[0]!;
      expect(beam.available.map((u) => u.amount), [_g(30), _g(10)]);
      expect(beam.availableTotal, _g(40));
      expect(beam.lockedTotal, _g(12));
      expect(beam.parallelSends, 2);
      expect(s[174]!.shieldedCount, 1);
    });

    test('reads the recorded get_utxo shape', () {
      final json =
          jsonDecode(File('test/beam/fixtures/get_utxo.json').readAsStringSync())
              as Map;
      final utxos = [
        for (final u in json['result'] as List)
          BeamUtxo.fromJson((u as Map).cast<String, Object?>()),
      ];
      final s = BeamCoinSummary.of(utxos);
      final counted = s.values.fold<int>(
        0,
        (n, c) => n + c.available.length + c.locked.length,
      );
      final notSpent = utxos
          .where(
            (u) => !const {
              BeamUtxoStatus.spent,
              BeamUtxoStatus.consumed,
              BeamUtxoStatus.unknown,
            }.contains(u.status),
          )
          .length;
      expect(counted, notSpent);
    });
  });

  group('split plan', () {
    test('1 BEAM into 9 coins keeps the fee back', () {
      final p = BeamSplitPlan.equal(available: _g(100000000), count: 9)!;
      expect(p.fee, BeamFees.forSplit(9));
      expect(p.coins, hasLength(9));
      expect(p.total + p.fee, lessThanOrEqualTo(_g(100000000)));
      expect(p.size, greaterThan(BeamFees.minimum));
    });

    test('coins worth less than a send fee are not proposed', () {
      expect(BeamSplitPlan.equal(available: _g(1000000), count: 20), isNull);
    });

    test('nonsense counts are refused', () {
      expect(BeamSplitPlan.equal(available: _g(100000000), count: 1), isNull);
      expect(
        BeamSplitPlan.equal(
          available: _g(100000000),
          count: BeamSplitPlan.maxCoins + 1,
        ),
        isNull,
      );
    });

    test('an asset split spends the asset, the fee comes from BEAM', () {
      final p = BeamSplitPlan.equal(
        available: _g(1000),
        count: 4,
        assetId: 174,
      )!;
      expect(p.size, _g(225)); // 90 % of 1000, in 4
      expect(p.fee, BeamFees.forSplit(4, asset: true));
    });
  });
}

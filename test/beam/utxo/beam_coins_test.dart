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
import 'package:stackwallet/wallets/beam/utxo/beam_coin_split.dart';
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
      // 90 % of 1000 in 4 is 225, rounded down to two digits.
      expect(p.size, _g(220));
      expect(p.fee, BeamFees.forSplit(4, asset: true));
      expect(p.change, _g(120), reason: 'the fee is not taken from FOMO');
    });

    test('coins read the way people count: two significant digits, the '
        'rest stays as change', () {
      // 1 BEAM into 5: 6 outputs cost 0.00118; (1 - 0.00118) * 0.9 / 5 =
      // 0.17978760 → 0.17.
      final p = BeamSplitPlan.equal(available: _g(100000000), count: 5)!;
      expect(p.fee, _g(118000));
      expect(p.size, _g(17000000));
      expect(p.total + p.fee + p.change, _g(100000000));
      expect(p.change, _g(100000000 - 85000000 - 118000));
      expect(BeamSplitPlan.roundDown(_g(17978760)), _g(17000000));
      expect(BeamSplitPlan.roundDown(_g(123456789012)), _g(120000000000));
      expect(BeamSplitPlan.roundDown(_g(99)), _g(99));
    });

    test('rounding never makes a BEAM coin too small to spend', () {
      // (0.0035 - 0.001) * 0.9 / 2 = 0.001125: rounded, 0.0011 > 0.001.
      final p = BeamSplitPlan.equal(available: _g(350000), count: 2)!;
      expect(p.size, _g(110000));
      // (0.00325 - 0.001) * 0.9 / 2 = 0.0010125: rounded to 0.001, which
      // is a send's fee, so the unrounded size is kept.
      final q = BeamSplitPlan.equal(available: _g(325000), count: 2)!;
      expect(q.size, _g(101250));
      expect(q.size, greaterThan(BeamFees.minimum));
    });

    test('an exact split (0.05 in 3, as the live test splits) is checked '
        'like any other', () {
      final p = BeamSplitPlan.sized(
        available: _g(10000000),
        count: 3,
        size: _g(1666666),
      )!;
      expect(p.coins, List.filled(3, _g(1666666)));
      expect(p.fee, _g(100000));
      expect(p.change, _g(10000000 - 4999998 - 100000));
      expect(
        BeamSplitPlan.sized(available: _g(4999998), count: 3, size: _g(1666666)),
        isNull,
        reason: 'no room for the fee',
      );
      expect(
        BeamSplitPlan.sized(available: _g(10000000), count: 3, size: _g(100000)),
        isNull,
        reason: 'a coin worth only a send fee',
      );
    });

    test('the screen offers the presets, plus the advised count', () {
      expect(BeamSplitPlan.choices(0), [2, 3, 5, 8, 10]);
      expect(BeamSplitPlan.choices(5), [2, 3, 5, 8, 10]);
      expect(BeamSplitPlan.choices(4), [2, 3, 4, 5, 8, 10]);
      expect(BeamSplitPlan.choices(7), [2, 3, 5, 7, 8, 10]);
    });
  });

  group('advice (BEAM Light Wallet thresholds)', () {
    BeamCoinSummary coins(List<int> amounts, {int aid = 0}) =>
        BeamCoinSummary.of([
          for (final (i, a) in amounts.indexed)
            BeamUtxo(
              id: 'c$i',
              assetId: aid,
              amount: _g(a),
              type: 'norm',
              statusCode: 1,
              statusString: 'available',
            ),
        ])[aid]!;

    test('everything in one coin: needed, one coin per 10 BEAM, 3 to 10', () {
      final one = coins([100000000]).advice; // 1 BEAM
      expect(one.urgency, BeamSplitUrgency.needed);
      expect(one.suggestedCount, 3);
      expect(coins([4500000000]).advice.suggestedCount, 5); // 45 BEAM
      expect(coins([50000000000]).advice.suggestedCount, 10); // 500 BEAM
    });

    test('dust that cannot pay a fee does not count as a coin', () {
      // One real coin and two of 0.0005 BEAM: still "all in one coin".
      final s = coins([100000000, 50000, 50000]);
      expect(s.available, hasLength(3));
      expect(s.usable, hasLength(1));
      expect(s.advice.urgency, BeamSplitUrgency.needed);
      expect(s.largestShare, 1.0);
    });

    test('two coins with over 80 % in one: worth it, 4 coins', () {
      final a = coins([85000000, 15000000]).advice;
      expect(a.urgency, BeamSplitUrgency.worthIt);
      expect(a.suggestedCount, 4);
      expect(coins([70000000, 30000000]).advice.urgency, BeamSplitUrgency.none);
    });

    test('over 90 % in the largest of several: worth it, 3 coins', () {
      final a = coins([95000000, 2000000, 2000000, 1000000]).advice;
      expect(a.urgency, BeamSplitUrgency.worthIt);
      expect(a.suggestedCount, 3);
      expect(
        coins([50000000, 30000000, 20000000]).advice.urgency,
        BeamSplitUrgency.none,
      );
    });

    test('too little to make coins worth spending: no advice', () {
      // 0.003 BEAM in one coin: no split leaves each coin above 0.001.
      expect(coins([300000]).advice.urgency, BeamSplitUrgency.none);
      // 0.004 BEAM: 3 coins would be too small, 2 fit.
      final a = coins([400000]).advice;
      expect(a.urgency, BeamSplitUrgency.needed);
      expect(a.suggestedCount, 2);
    });

    test('an asset is advised in its own units; its fee is BEAM\'s', () {
      final a = coins([2500000000], aid: 174).advice; // 25 FOMO
      expect(a.urgency, BeamSplitUrgency.needed);
      expect(a.suggestedCount, 3);
    });

    test('nothing spendable: nothing to advise', () {
      expect(BeamCoinSummary.empty(0).advice.urgency, BeamSplitUrgency.none);
      expect(BeamCoinSummary.empty(0).largestShare, 0);
    });
  });

  group('reading every page of coins', () {
    test('pages until a short one, and never counts a coin twice', () async {
      final all = [
        for (var i = 0; i < 7; i++)
          BeamUtxo(
            id: 'c$i',
            assetId: 0,
            amount: _g(1000000),
            type: 'norm',
            statusCode: 1,
            statusString: 'available',
          ),
      ];
      final asked = <(int, int)>[];
      final read = await beamReadAllCoins((skip, count) async {
        asked.add((skip, count));
        // The list moved under the read: each later page starts one coin
        // early, repeating the last coin of the page before.
        final from = skip == 0 ? 0 : skip - 1;
        return all.skip(from).take(count).toList();
      }, pageSize: 3);
      expect(asked, [(0, 3), (3, 3), (6, 3)]);
      expect(read.map((u) => u.id).toSet(), {for (final u in all) u.id});
      expect(read, hasLength(7));
    });
  });
}

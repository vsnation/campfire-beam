/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/common/shader_output.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_pool.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_ratio.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/price/beam_asset_pricer.dart';

import '../contracts/dex/dex_fixtures.dart';

const _g = BigInt.from;
final _beam = _g(100000000);

/// A pool that only these tests construct; reserves in smallest units.
BeamPool _pool(
  int aid1,
  int aid2,
  int tok1,
  int tok2, {
  int ctl = 1000,
  int lp = 900,
  BeamPoolKind kind = BeamPoolKind.high,
}) => BeamPool(
  aid1: aid1,
  aid2: aid2,
  kind: kind,
  tok1: _g(tok1),
  tok2: _g(tok2),
  ctl: _g(ctl),
  lpToken: lp,
);

void main() {
  final recorded = [
    for (final row in ShaderOutput.list(
      ShaderOutput.decode(dexOutput('pools_view'))['res'],
      'res',
    ))
      BeamPool.fromJson(ShaderOutput.map(row, 'res[]')),
  ];

  group('recorded mainnet pools', () {
    // These check which pool prices an asset; the 1,000 BEAM floor for
    // unverified assets is lowered to 1 BEAM so mainnet's smaller pools
    // still take part (the floor is checked in its own group below).
    final pricer = BeamAssetPricer(recorded, minUnverifiedBeamReserve: _beam);

    BeamPool deepestBeamPool(int aid) => recorded
        .where((p) => p.aid1 == 0 && p.aid2 == aid && !p.isEmpty)
        .reduce((a, b) => a.tok1 >= b.tok1 ? a : b);

    test('each asset is priced from its deepest BEAM pool, whatever its '
        'kind', () {
      // Assets that trade in more than one BEAM pool on mainnet. Asset 37
      // has a pool holding 5 groth next to one holding ~228,000 BEAM; the
      // first-pool rule LightWallet used could have priced it from 5 groth.
      for (final aid in [7, 9, 37, 116, 141]) {
        final deepest = deepestBeamPool(aid);
        expect(pricer.pricingPool(aid), same(deepest), reason: 'asset $aid');
      }
      final tiny = recorded.firstWhere(
        (p) => p.aid2 == 37 && p.tok1 == BigInt.from(5),
      );
      expect(pricer.pricingPool(37), isNot(same(tiny)));
    });

    test('a 0.065 BEAM pool loses to the 2.25 BEAM one beside it', () {
      // Asset 141 on mainnet: kind 0 holds 2.25 BEAM, kind 2 holds 0.065.
      expect(pricer.pricingPool(141)!.tok1, BigInt.from(225496566));
    });

    test('a holding is valued without knowing the asset decimals', () {
      final p = pricer.pricingPool(174)!;
      final amount = _g(80368764); // what 0.1 BEAM bought in the DEX test
      expect(pricer.valueInGroth(174, amount), amount * p.tok1 ~/ p.tok2);
    });

    test('BEAM is worth itself', () {
      expect(pricer.valueInGroth(0, _beam), _beam);
      expect(pricer.beamPerWholeUnit(0, 8), BeamRatio.one);
    });

    test('an asset with no BEAM pool is reported unpriced, not zero', () {
      const nowhere = 999999;
      final v = pricer.portfolio({0: _beam, nowhere: _g(5)});
      expect(v.totalGroth, _beam);
      expect(v.unpriced, [nowhere]);
      expect(v.valuesGroth.containsKey(nowhere), isFalse);
    });
  });

  group('rules', () {
    test('pools below the minimum BEAM reserve never set a price', () {
      final pricer = BeamAssetPricer([
        _pool(0, 7, 1000, 1), // 1000 groth of BEAM: anyone can seed this
      ]);
      expect(pricer.grothPerUnit(7), isNull);
      expect(pricer.valueInGroth(7, _g(10)), isNull);
    });

    test('the deepest pool wins over a shallower, pricier one', () {
      final pricer = BeamAssetPricer([
        _pool(0, 7, 2 * 100000000, 1000, kind: BeamPoolKind.low),
        _pool(0, 7, 50 * 100000000, 100000, lp: 901),
      ]);
      expect(pricer.grothPerUnit(7), BeamRatio(_g(50 * 100000000), _g(100000)));
    });

    test('price per whole unit follows the declared decimals', () {
      // 10 BEAM against 1000 whole units of a 2-decimal asset:
      // 0.01 BEAM per whole unit.
      final pricer = BeamAssetPricer([_pool(0, 7, 10 * 100000000, 100000)]);
      expect(pricer.beamPerWholeUnit(7, 2), BeamRatio(BigInt.one, _g(100)));
    });

    test('values round down, never up', () {
      final pricer = BeamAssetPricer([_pool(0, 7, 3 * 100000000, 7)]);
      // 1 unit = 300000000/7 = 42857142.857… groth
      expect(pricer.valueInGroth(7, BigInt.one), _g(42857142));
    });

    test('an LP token is its share of both reserves', () {
      final pricer = BeamAssetPricer([
        _pool(0, 7, 10 * 100000000, 1000, ctl: 400, lp: 900),
      ]);
      // Asset 7: 1 unit = 1,000,000 groth, so the pool holds 10 BEAM + 10
      // BEAM of asset 7 = 20 BEAM; a quarter of the LP supply is 5 BEAM.
      expect(pricer.valueInGroth(900, _g(100)), _g(5 * 100000000));
    });

    test('an LP token in a pool with an unpriced side is unpriced', () {
      final pricer = BeamAssetPricer([
        _pool(7, 8, 1000, 1000, ctl: 10, lp: 905),
      ]);
      expect(pricer.valueInGroth(905, _g(5)), isNull);
    });

    test('empty and zero holdings are worth zero', () {
      final pricer = BeamAssetPricer(const []);
      expect(pricer.valueInGroth(7, BigInt.zero), BigInt.zero);
    });
  });

  group('assets anyone can mint and price (M-4)', () {
    const spam = 999;

    test('1 BEAM against 1 groth no longer makes an airdrop worth '
        '100,000,000 BEAM', () {
      final pricer = BeamAssetPricer([_pool(0, spam, 100000000, 1)]);
      // One whole unit, as an airdrop would send.
      expect(pricer.valueInGroth(spam, _beam), isNull);
      final p = pricer.portfolio({0: _beam, spam: _beam});
      expect(p.totalGroth, _beam);
      expect(p.unpriced, [spam]);
    });

    test('an unverified asset needs a pool of 1,000 BEAM; a verified one '
        'does not', () {
      final pricer = BeamAssetPricer([
        _pool(0, spam, 999 * 100000000, 1000),
        _pool(0, 7, 2 * 100000000, 1000, lp: 901),
      ]);
      expect(
        BeamAssetPricer.defaultMinUnverifiedBeamReserve,
        _g(1000 * 100000000),
      );
      expect(pricer.pricingPool(spam), isNull);
      expect(pricer.valueInGroth(spam, _g(10)), isNull);
      expect(pricer.valueInGroth(7, _g(10)), _g(2 * 100000000 * 10 ~/ 1000));
    });

    test('valued at what its pool would pay: never more than the BEAM in '
        'it, and marked as such', () {
      // 1,000 BEAM against 1 groth: at spot one whole unit would be
      // "worth" 100,000,000,000 BEAM.
      final pool = _pool(0, spam, 1000 * 100000000, 1);
      final pricer = BeamAssetPricer([pool]);
      final v = pricer.valueInGroth(spam, _beam)!;
      expect(v, pool.tok1 * _beam ~/ (pool.tok2 + _beam));
      expect(v < pool.tok1, isTrue);
      expect(pricer.isSaleValue(spam), isTrue);
      // A verified asset keeps its spot price.
      expect(
        BeamAssetPricer([_pool(0, 7, 5 * 100000000, 10)]).isSaleValue(7),
        isFalse,
      );
      expect(pricer.isSaleValue(0), isFalse);
    });

    test('a deep, honest pool still values a small holding close to its '
        'price', () {
      // 10,000 BEAM against 1,000,000 units: 0.01 BEAM a unit.
      final pricer = BeamAssetPricer([
        _pool(0, spam, 10000 * 100000000, 1000000 * 100000000),
      ]);
      // 100 units: 1 BEAM at spot; what the pool pays is 0.9999 BEAM.
      expect(pricer.valueInGroth(spam, _g(100 * 100000000)), _g(99990000));
    });

    test('a pool share of a spam pool is worth at most the pool\'s BEAM', () {
      final pricer = BeamAssetPricer([
        _pool(0, spam, 1000 * 100000000, 1, ctl: 100, lp: 950),
      ]);
      // The whole pool: its BEAM plus the spam side sold back into it.
      final whole = pricer.valueInGroth(950, _g(100))!;
      expect(whole <= _g(2 * 1000 * 100000000), isTrue);
      expect(whole >= _g(1000 * 100000000), isTrue);
    });
  });
}

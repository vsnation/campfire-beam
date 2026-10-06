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
import 'package:stackwallet/wallets/beam/contracts/dex/beam_dex_quotes.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_pool.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_ratio.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';

import 'dex_fixtures.dart';

Map<String, Object?> res(String fixture) =>
    ShaderOutput.map(ShaderOutput.decode(dexOutput(fixture))['res'], 'res');

List<BeamPool> recordedPools() => [
  for (final row in ShaderOutput.list(
    ShaderOutput.decode(dexOutput('pools_view'))['res'],
    'res',
  ))
    BeamPool.fromJson(ShaderOutput.map(row, 'row')),
];

/// The contract's constant-product price for buying [buy] from a pool with
/// [rBuy] / [rPay] reserves (`Totals::Trade`, exact integers instead of the
/// contract's float).
BigInt rawPayFor(BigInt buy, BigInt rBuy, BigInt rPay) =>
    rBuy * rPay ~/ (rBuy - buy) - rPay;

void main() {
  const g = BigInt.from;
  final pools = recordedPools();
  final beamFomo = pools.singleWhere(
    (p) => p.aid1 == 0 && p.aid2 == 174 && p.kind == BeamPoolKind.high,
  );

  group('BeamPool from pools_view', () {
    test('every recorded row parses; 75 hold liquidity', () {
      expect(pools, hasLength(97));
      expect(pools.where((p) => !p.isEmpty), hasLength(75));
      expect(pools.every((p) => p.aid1 < p.aid2), isTrue);
      expect(pools.any((p) => p.createdByThisWallet), isFalse);
      expect(
        pools.map((p) => p.kind).toSet(),
        BeamPoolKind.values.toSet(),
      );
    });

    test('the BEAM/FOMO pool', () {
      expect(beamFomo.tok1, g(637304113367));
      expect(beamFomo.tok2, g(5173233681014));
      expect(beamFomo.ctl, g(2125257813880));
      expect(beamFomo.lpToken, 175);
      expect(beamFomo.reserveOf(0), beamFomo.tok1);
      expect(beamFomo.reserveOf(174), beamFomo.tok2);
      expect(beamFomo.otherAsset(0), 174);
      expect(beamFomo.pairs(174, 0), isTrue);
      expect(beamFomo.pairs(0, 0), isFalse);
      expect(() => beamFomo.reserveOf(7), throwsArgumentError);
    });

    test('exact spot prices agree with the shader rate strings', () {
      for (final p in pools.where((p) => !p.isEmpty)) {
        // k1_2 = tok1 / tok2: the price of aid2 in aid1 units.
        final k12 = BeamRatio.parseDecimal(p.shaderRate12!);
        final exact = p.spotPriceOf(p.aid2);
        final diff = (k12 - exact) / exact;
        expect(
          diff.numerator.abs() * BigInt.from(10).pow(15) <= diff.denominator,
          isTrue,
          reason: '$p k1_2 ${p.shaderRate12} vs $exact',
        );
      }
      expect(
        beamFomo.spotPriceOf(174).toDecimalString(8),
        '0.12319260',
      );
      expect(beamFomo.spotPriceOf(0).toDecimalString(8), '8.11737061');
    });

    test('an empty pool has no price', () {
      final empty = pools.firstWhere((p) => p.isEmpty);
      expect(() => empty.spotPriceOf(empty.aid1), throwsStateError);
      expect(empty.shaderRate12, isNull);
    });

    test('pool_view totals are in pool order whatever order was asked', () {
      final p = BeamPool.fromPoolView(
        res('pool_view_174_0_k2'),
        aidA: 174,
        aidB: 0,
        kind: BeamPoolKind.high,
      );
      expect(p.aid1, 0);
      expect(p.aid2, 174);
      expect(p.tok1, beamFomo.tok1);
      expect(p.tok2, beamFomo.tok2);
      expect(p.lpToken, 175);
    });

    test('creator: 1 marks a pool this wallet created', () {
      final p = BeamPool.fromJson(
        ShaderOutput.decode(
          '{"aid1": 0,"aid2": 9,"kind": 2,"ctl": 1,"tok1": 1,"tok2": 1,'
          '"lp-token": 10,"creator": 1}',
        ),
      );
      expect(p.createdByThisWallet, isTrue);
    });

    test('malformed rows are FormatExceptions', () {
      Map<String, Object?> row(String s) => ShaderOutput.decode(s);
      expect(
        () => BeamPool.fromJson(row(
          '{"aid1": 9,"aid2": 0,"kind": 2,"ctl": 0,"tok1": 0,"tok2": 0,'
          '"lp-token": 1}',
        )),
        throwsFormatException,
      );
      expect(
        () => BeamPool.fromJson(row(
          '{"aid1": 0,"aid2": 9,"kind": 5,"ctl": 0,"tok1": 0,"tok2": 0,'
          '"lp-token": 1}',
        )),
        throwsFormatException,
      );
      expect(
        () => BeamPool.fromJson(row(
          '{"aid1": 0,"aid2": 9,"kind": 2,"ctl": 0,"tok1": 0,"tok2": 0}',
        )),
        throwsFormatException,
      );
    });
  });

  group('BeamSwapQuote from recorded predictions', () {
    test('pay 0.1 BEAM, receive FOMO', () {
      final q = BeamSwapQuote.fromPrediction(
        res('trade_pay_beam_get_fomo'),
        pool: beamFomo,
        payAsset: 0,
        receiveAsset: 174,
      );
      expect(q.pay, g(10000000));
      expect(q.receive, g(80368764));
      expect(q.fee, g(99010));
      expect(q.networkFee, g(1100000));
      // The curve, recomputed exactly, agrees within rounding.
      final raw = rawPayFor(q.receive, beamFomo.tok2, beamFomo.tok1);
      expect((raw - q.payRaw).abs() <= g(2), isTrue, reason: '$raw');
      // 0.1 BEAM against a 6373 BEAM reserve: about 0.0016% impact.
      expect(q.priceImpact.isNegative, isFalse);
      expect(q.priceImpact.toDecimalString(6), '0.000015');
      expect(q.effectiveRate.toDecimalString(6), '8.036876');
      expect(q.spotRate.toDecimalString(6), '8.117370');
    });

    test('pay FOMO, receive BEAM (the other ordering)', () {
      final q = BeamSwapQuote.fromPrediction(
        res('trade_pay_fomo_get_beam'),
        pool: beamFomo,
        payAsset: 174,
        receiveAsset: 0,
      );
      expect(q.pay, g(9999996));
      expect(q.receive, g(1219726));
      final raw = rawPayFor(q.receive, beamFomo.tok1, beamFomo.tok2);
      expect((raw - q.payRaw).abs() <= g(2), isTrue, reason: '$raw');
    });

    test('exact receive', () {
      final q = BeamSwapQuote.fromPrediction(
        res('trade_buy_exact_fomo'),
        pool: beamFomo,
        payAsset: 0,
        receiveAsset: 174,
      );
      expect(q.receive, g(80000000));
      expect(q.pay, g(9954116));
    });

    test('fees that do not match the pool kind are refused', () {
      final low = BeamPool(
        aid1: 0,
        aid2: 174,
        kind: BeamPoolKind.low,
        tok1: beamFomo.tok1,
        tok2: beamFomo.tok2,
        ctl: beamFomo.ctl,
        lpToken: 175,
      );
      expect(
        () => BeamSwapQuote.fromPrediction(
          res('trade_pay_beam_get_fomo'),
          pool: low,
          payAsset: 0,
          receiveAsset: 174,
        ),
        throwsFormatException,
      );
      expect(
        () => BeamSwapQuote.fromPrediction(
          {...res('trade_pay_beam_get_fomo'), 'pay': g(10000001)},
          pool: beamFomo,
          payAsset: 0,
          receiveAsset: 174,
        ),
        throwsFormatException,
      );
    });

    test('kind 0 and kind 1 predictions satisfy their fee rules', () {
      final p4 = pools.singleWhere(
        (p) => p.aid1 == 0 && p.aid2 == 4 && p.kind == BeamPoolKind.low,
      );
      final p116 = pools.singleWhere(
        (p) => p.aid1 == 0 && p.aid2 == 116 && p.kind == BeamPoolKind.mid,
      );
      final q0 = BeamSwapQuote.fromPrediction(
        res('trade_kind0_pay_beam_get_4'),
        pool: p4,
        payAsset: 0,
        receiveAsset: 4,
      );
      final q1 = BeamSwapQuote.fromPrediction(
        res('trade_kind1_pay_beam_get_116'),
        pool: p116,
        payAsset: 0,
        receiveAsset: 116,
      );
      // fee / raw: 0.05% and 0.3%, each plus one groth.
      expect(q0.fee, q0.payRaw ~/ g(2000) + BigInt.one);
      expect(q1.fee, q1.payRaw ~/ g(1000) * g(3) + BigInt.one);
    });
  });

  group('liquidity', () {
    test('add: caller order, other side computed from the reserves', () {
      final q = BeamLiquidityQuote.fromPrediction(
        res('add_beam_side'),
        pool: beamFomo,
      );
      expect(q.amount1, g(10000000));
      expect(q.amount2, g(81173706));
      expect(q.lpMinted, g(33347624));
      // amount2 / amount1 matches the pool ratio to the groth.
      expect(
        (beamFomo.spotPriceOf(0).floorTimes(q.amount1) - q.amount2).abs() <=
            BigInt.one,
        isTrue,
      );
      expect(q.shareOfPoolAfter < BeamRatio(g(1), g(10000)), isTrue);
    });

    test('withdraw: estimate matches the shader prediction', () {
      final q = BeamWithdrawQuote.fromPrediction(
        res('withdraw_ctl'),
        pool: beamFomo,
      );
      expect(q.lpBurned, g(100000000));
      expect(q.amount1, g(29987143));
      expect(q.amount2, g(243416758));
      final pos = beamFomo.position(q.lpBurned);
      expect((pos.estimatedTok1 - q.amount1).abs() <= BigInt.one, isTrue);
      expect((pos.estimatedTok2 - q.amount2).abs() <= BigInt.one, isTrue);
      expect(pos.share, BeamRatio(q.lpBurned, beamFomo.ctl));
    });

    test('LP position edges', () {
      final all = beamFomo.position(beamFomo.ctl);
      expect(all.estimatedTok1, beamFomo.tok1);
      expect(all.share, BeamRatio.one);
      final over = beamFomo.position(beamFomo.ctl + BigInt.one);
      expect(over.exceedsSupply, isTrue);
      expect(over.estimatedTok2, BigInt.zero);
      expect(() => beamFomo.position(g(-1)), throwsArgumentError);
    });
  });
}

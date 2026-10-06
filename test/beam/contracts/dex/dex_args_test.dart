/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_args.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';

import 'dex_fixtures.dart';

void main() {
  const g = BigInt.from;

  group('DexArgs builders', () {
    test('pools_view', () {
      expect(DexArgs.poolsView(), 'action=pools_view,cid=$dexCid');
    });

    test('pool_view', () {
      expect(
        DexArgs.poolView(aidA: 174, aidB: 0, kind: BeamPoolKind.high),
        'action=pool_view,cid=$dexCid,aid1=174,aid2=0,kind=2',
      );
    });

    test('pool_trade pay BEAM, receive FOMO: aid1 = received, aid2 = paid',
        () {
      // The ordering verified on mainnet: aid1=174,aid2=0 pays BEAM.
      expect(
        DexArgs.trade(
          payAsset: 0,
          receiveAsset: 174,
          kind: BeamPoolKind.high,
          payAmount: g(10000000),
          predictOnly: true,
        ),
        'action=pool_trade,cid=$dexCid,aid1=174,aid2=0,kind=2,'
        'val1_buy=0,val2_pay=10000000,bPredictOnly=1',
      );
    });

    test('pool_trade pay FOMO, receive BEAM, execute', () {
      expect(
        DexArgs.trade(
          payAsset: 174,
          receiveAsset: 0,
          kind: BeamPoolKind.high,
          payAmount: g(5),
          predictOnly: false,
        ),
        'action=pool_trade,cid=$dexCid,aid1=0,aid2=174,kind=2,'
        'val1_buy=0,val2_pay=5,bPredictOnly=0',
      );
    });

    test('pool_trade exact receive', () {
      expect(
        DexArgs.trade(
          payAsset: 0,
          receiveAsset: 174,
          kind: BeamPoolKind.low,
          receiveAmount: g(80000000),
          predictOnly: true,
        ),
        'action=pool_trade,cid=$dexCid,aid1=174,aid2=0,kind=0,'
        'val1_buy=80000000,val2_pay=0,bPredictOnly=1',
      );
    });

    test('pool_add_liquidity, one side computed by the shader', () {
      expect(
        DexArgs.addLiquidity(
          aid1: 0,
          aid2: 174,
          kind: BeamPoolKind.high,
          amount1: g(10000000),
          predictOnly: false,
        ),
        'action=pool_add_liquidity,cid=$dexCid,aid1=0,aid2=174,kind=2,'
        'val1=10000000,val2=0,bPredictOnly=0',
      );
      expect(
        DexArgs.addLiquidity(
          aid1: 0,
          aid2: 174,
          kind: BeamPoolKind.mid,
          amount1: g(1),
          amount2: g(2),
          predictOnly: true,
        ),
        'action=pool_add_liquidity,cid=$dexCid,aid1=0,aid2=174,kind=1,'
        'val1=1,val2=2,bPredictOnly=1',
      );
      expect(
        DexArgs.addLiquidity(
          aid1: 0,
          aid2: 174,
          kind: BeamPoolKind.high,
          amount1: g(1),
          predictOnly: true,
        ),
        isNot(contains('bCoversAll')),
      );
    });

    test('pool_withdraw', () {
      expect(
        DexArgs.withdraw(
          aid1: 0,
          aid2: 174,
          kind: BeamPoolKind.high,
          ctl: g(100000000),
          predictOnly: true,
        ),
        'action=pool_withdraw,cid=$dexCid,aid1=0,aid2=174,kind=2,'
        'ctl=100000000,bPredictOnly=1',
      );
    });

    test('pool_create writes the pair in pool order', () {
      expect(
        DexArgs.createPool(aidA: 174, aidB: 9, kind: BeamPoolKind.mid),
        'action=pool_create,cid=$dexCid,aid1=9,aid2=174,kind=1',
      );
    });

    test('a different contract id is passed through', () {
      final cid = 'ab' * 32;
      expect(DexArgs.poolsView(cid: cid), 'action=pools_view,cid=$cid');
    });
  });

  group('DexArgs validation', () {
    final max = (BigInt.one << 63) - BigInt.one;

    test('amounts must be > 0 and <= 2^63-1', () {
      String trade(BigInt v) => DexArgs.trade(
        payAsset: 0,
        receiveAsset: 174,
        kind: BeamPoolKind.high,
        payAmount: v,
        predictOnly: true,
      );
      expect(trade(max), contains('val2_pay=$max'));
      expect(() => trade(BigInt.zero), throwsArgumentError);
      expect(() => trade(g(-1)), throwsArgumentError);
      expect(() => trade(max + BigInt.one), throwsArgumentError);
      expect(
        () => DexArgs.withdraw(
          aid1: 0,
          aid2: 174,
          kind: BeamPoolKind.high,
          ctl: BigInt.zero,
          predictOnly: true,
        ),
        throwsArgumentError,
      );
    });

    test('exactly one of pay / receive amount', () {
      expect(
        () => DexArgs.trade(
          payAsset: 0,
          receiveAsset: 174,
          kind: BeamPoolKind.high,
          predictOnly: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => DexArgs.trade(
          payAsset: 0,
          receiveAsset: 174,
          kind: BeamPoolKind.high,
          payAmount: g(1),
          receiveAmount: g(1),
          predictOnly: true,
        ),
        throwsArgumentError,
      );
    });

    test('add liquidity needs at least one amount', () {
      expect(
        () => DexArgs.addLiquidity(
          aid1: 0,
          aid2: 174,
          kind: BeamPoolKind.high,
          predictOnly: true,
        ),
        throwsArgumentError,
      );
    });

    test('asset ids are 0..2^32-1 and must differ', () {
      expect(
        () => DexArgs.poolView(aidA: -1, aidB: 1, kind: BeamPoolKind.high),
        throwsArgumentError,
      );
      expect(
        () => DexArgs.poolView(
          aidA: 0,
          aidB: 0x100000000,
          kind: BeamPoolKind.high,
        ),
        throwsArgumentError,
      );
      expect(
        DexArgs.poolView(aidA: 0, aidB: 0xffffffff, kind: BeamPoolKind.high),
        contains('aid2=4294967295'),
      );
      expect(
        () => DexArgs.createPool(aidA: 7, aidB: 7, kind: BeamPoolKind.high),
        throwsArgumentError,
      );
    });

    test('the contract id must be 64 lowercase hex chars', () {
      expect(() => DexArgs.poolsView(cid: 'AB' * 32), throwsArgumentError);
      expect(() => DexArgs.poolsView(cid: 'ab' * 31), throwsArgumentError);
      expect(
        () => DexArgs.poolsView(cid: '${'ab' * 31}a,'),
        throwsArgumentError,
      );
    });
  });

  group('BeamPoolKind', () {
    test('wire values and fee labels follow the shader', () {
      expect(BeamPoolKind.fromWire(0), BeamPoolKind.low);
      expect(BeamPoolKind.low.feePercent, '0.05%');
      expect(BeamPoolKind.fromWire(1), BeamPoolKind.mid);
      expect(BeamPoolKind.mid.feePercent, '0.3%');
      expect(BeamPoolKind.fromWire(2), BeamPoolKind.high);
      expect(BeamPoolKind.high.feePercent, '1%');
      expect(() => BeamPoolKind.fromWire(3), throwsFormatException);
    });

    test('tradeFee reproduces the fees recorded on mainnet', () {
      // From the recorded predictions (fee_pool, fee_dao on pay_raw).
      expect(BeamPoolKind.high.tradeFee(g(9900990)), (
        pool: g(69307),
        dao: g(29703),
      ));
      expect(BeamPoolKind.low.tradeFee(g(99950015)), (
        pool: g(34984),
        dao: g(14992),
      ));
      expect(BeamPoolKind.mid.tradeFee(g(99700899)), (
        pool: g(209371),
        dao: g(89730),
      ));
      // The +1 groth even on a zero price.
      expect(BeamPoolKind.high.tradeFee(BigInt.zero), (
        pool: BigInt.one,
        dao: BigInt.zero,
      ));
    });
  });

  group('fee constants', () {
    test('a DEX call costs 0.011 BEAM; pool_create derives 0.01471', () {
      expect(kDexCallFee, g(1100000));
      expect(kDexPoolCreateFee, g(1471000));
      expect(kDexPoolCreateDeposit, g(1000000000));
    });
  });
}

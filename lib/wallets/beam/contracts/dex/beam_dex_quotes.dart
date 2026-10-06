/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import '../common/shader_output.dart';
import 'beam_pool.dart';
import 'beam_ratio.dart';
import 'dex_constants.dart';

/// A swap the AMM predicted (`pool_trade` with `bPredictOnly=1`).
///
/// Amounts are in each asset's smallest unit. [fee] is the pool's trading
/// fee and is in the **paid** asset (LightWallet labels it with the
/// received asset). The network fee is separate: [networkFee], in BEAM.
///
/// A quote is not a promise. The swap is rebuilt from the chain when it is
/// prepared, and the prepared call's decoded amounts are what the
/// confirmation shows.
@immutable
class BeamSwapQuote {
  const BeamSwapQuote({
    required this.pool,
    required this.payAsset,
    required this.receiveAsset,
    required this.pay,
    required this.payRaw,
    required this.receive,
    required this.feePool,
    required this.feeDao,
  });

  /// Parses the prediction's `res` and checks it against the pool's fee
  /// rule, so a shader or pool mismatch fails here rather than on screen.
  factory BeamSwapQuote.fromPrediction(
    Map<String, Object?> res, {
    required BeamPool pool,
    required int payAsset,
    required int receiveAsset,
  }) {
    if (!pool.pairs(payAsset, receiveAsset)) {
      throw ArgumentError('pool $pool does not trade $payAsset/$receiveAsset');
    }
    final q = BeamSwapQuote(
      pool: pool,
      payAsset: payAsset,
      receiveAsset: receiveAsset,
      pay: ShaderOutput.amount(res, 'pay'),
      payRaw: ShaderOutput.amount(res, 'pay_raw'),
      receive: ShaderOutput.amount(res, 'buy'),
      feePool: ShaderOutput.amount(res, 'fee_pool'),
      feeDao: ShaderOutput.amount(res, 'fee_dao'),
    );
    if (q.pay != q.payRaw + q.feePool + q.feeDao) {
      throw const FormatException('pool_trade: pay != pay_raw + fees');
    }
    final expected = pool.kind.tradeFee(q.payRaw);
    if (expected.pool != q.feePool || expected.dao != q.feeDao) {
      throw FormatException(
        'pool_trade: fees ${q.feePool}+${q.feeDao} do not match a '
        '${pool.kind.feePercent} pool',
      );
    }
    return q;
  }

  final BeamPool pool;
  final int payAsset;
  final int receiveAsset;

  /// Total the wallet pays: [payRaw] plus [fee].
  final BigInt pay;

  /// The price on the curve, before fees.
  final BigInt payRaw;

  /// What the wallet receives.
  final BigInt receive;

  /// Fee share that stays in the pool (LP income), in [payAsset].
  final BigInt feePool;

  /// Fee share sent to the DAO vault (30%), in [payAsset].
  final BigInt feeDao;

  /// The pool's trading fee, in [payAsset].
  BigInt get fee => feePool + feeDao;

  /// The BEAM network fee for the swap transaction (0.011 BEAM).
  BigInt get networkFee => kDexCallFee;

  BeamPoolKind get kind => pool.kind;

  /// The amount is too small to receive anything: do not offer the swap.
  bool get receivesNothing => receive == BigInt.zero;

  /// Received units per paid unit, fees included.
  BeamRatio get effectiveRate => pay == BigInt.zero
      ? BeamRatio.zero
      : BeamRatio(receive, pay);

  /// Received units per paid unit at the pool's current spot price.
  BeamRatio get spotRate =>
      BeamRatio(pool.reserveOf(receiveAsset), pool.reserveOf(payAsset));

  /// How much worse than spot the curve prices this size, fees excluded:
  /// 1 − receive / (payRaw × spot). Zero for an infinitely deep pool; a UI
  /// shows it as a percentage and warns above a threshold.
  BeamRatio get priceImpact {
    if (payRaw == BigInt.zero) return BeamRatio.zero;
    final atSpot = BeamRatio(
      payRaw * pool.reserveOf(receiveAsset),
      pool.reserveOf(payAsset),
    );
    return BeamRatio.one - BeamRatio(receive, BigInt.one) / atSpot;
  }
}

/// An add-liquidity the AMM predicted (`pool_add_liquidity`,
/// `bPredictOnly=1`). Amounts are in pool order.
@immutable
class BeamLiquidityQuote {
  const BeamLiquidityQuote({
    required this.pool,
    required this.amount1,
    required this.amount2,
    required this.lpMinted,
  });

  /// Parses `res` of a prediction requested in pool order (`aid1` =
  /// [BeamPool.aid1]).
  factory BeamLiquidityQuote.fromPrediction(
    Map<String, Object?> res, {
    required BeamPool pool,
  }) => BeamLiquidityQuote(
    pool: pool,
    amount1: ShaderOutput.amount(res, 'tok1'),
    amount2: ShaderOutput.amount(res, 'tok2'),
    lpMinted: ShaderOutput.amount(res, 'ctl'),
  );

  final BeamPool pool;

  /// Deposit of [BeamPool.aid1].
  final BigInt amount1;

  /// Deposit of [BeamPool.aid2].
  final BigInt amount2;

  /// LP tokens the deposit mints.
  final BigInt lpMinted;

  /// The fraction of the pool the new LP tokens will own.
  BeamRatio get shareOfPoolAfter =>
      BeamRatio(lpMinted, pool.ctl + lpMinted);

  BigInt get networkFee => kDexCallFee;
}

/// A withdrawal the AMM predicted (`pool_withdraw`, `bPredictOnly=1`).
/// Amounts are in pool order.
@immutable
class BeamWithdrawQuote {
  const BeamWithdrawQuote({
    required this.pool,
    required this.lpBurned,
    required this.amount1,
    required this.amount2,
  });

  factory BeamWithdrawQuote.fromPrediction(
    Map<String, Object?> res, {
    required BeamPool pool,
  }) => BeamWithdrawQuote(
    pool: pool,
    lpBurned: ShaderOutput.amount(res, 'ctl'),
    amount1: ShaderOutput.amount(res, 'tok1'),
    amount2: ShaderOutput.amount(res, 'tok2'),
  );

  final BeamPool pool;
  final BigInt lpBurned;

  /// Returned [BeamPool.aid1].
  final BigInt amount1;

  /// Returned [BeamPool.aid2].
  final BigInt amount2;

  BigInt get networkFee => kDexCallFee;
}

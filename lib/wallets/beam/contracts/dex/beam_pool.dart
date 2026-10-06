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
import 'beam_ratio.dart';
import 'dex_constants.dart';

/// One AMM liquidity pool, as `pools_view` / `pool_view` print it.
///
/// [aid1] < [aid2] always (the contract keys pools in that order), and
/// [tok1] / [tok2] are their reserves in each asset's smallest unit.
/// Prices are exact ratios of those reserves; the shader's own decimal
/// strings (`k1_2`, `k2_1`) are kept only as [shaderRate12] /
/// [shaderRate21] for cross-checking.
@immutable
class BeamPool {
  const BeamPool({
    required this.aid1,
    required this.aid2,
    required this.kind,
    required this.tok1,
    required this.tok2,
    required this.ctl,
    required this.lpToken,
    this.shaderRate12,
    this.shaderRate21,
    this.createdByThisWallet = false,
  });

  /// A `pools_view` row.
  factory BeamPool.fromJson(Map<String, Object?> json) {
    final aid1 = ShaderOutput.uint32(json, 'aid1');
    final aid2 = ShaderOutput.uint32(json, 'aid2');
    if (aid1 >= aid2) {
      throw FormatException('pool $aid1/$aid2: expected aid1 < aid2');
    }
    return BeamPool._totals(
      json,
      aid1: aid1,
      aid2: aid2,
      kind: BeamPoolKind.fromWire(ShaderOutput.uint32(json, 'kind')),
    );
  }

  /// A `pool_view` result (`res`), which carries no key: the pair and kind
  /// are what was asked for. Either order of [aidA]/[aidB] is accepted.
  factory BeamPool.fromPoolView(
    Map<String, Object?> res, {
    required int aidA,
    required int aidB,
    required BeamPoolKind kind,
  }) {
    if (aidA == aidB) throw ArgumentError('the two assets must differ');
    return BeamPool._totals(
      res,
      aid1: aidA < aidB ? aidA : aidB,
      aid2: aidA < aidB ? aidB : aidA,
      kind: kind,
    );
  }

  factory BeamPool._totals(
    Map<String, Object?> json, {
    required int aid1,
    required int aid2,
    required BeamPoolKind kind,
  }) {
    final creator = json['creator'];
    return BeamPool(
      aid1: aid1,
      aid2: aid2,
      kind: kind,
      tok1: ShaderOutput.amount(json, 'tok1'),
      tok2: ShaderOutput.amount(json, 'tok2'),
      ctl: ShaderOutput.amount(json, 'ctl'),
      lpToken: ShaderOutput.uint32(json, 'lp-token'),
      shaderRate12: ShaderOutput.optString(json, 'k1_2'),
      shaderRate21: ShaderOutput.optString(json, 'k2_1'),
      createdByThisWallet: creator is BigInt && creator == BigInt.one,
    );
  }

  final int aid1;
  final int aid2;
  final BeamPoolKind kind;

  /// Reserve of [aid1].
  final BigInt tok1;

  /// Reserve of [aid2].
  final BigInt tok2;

  /// LP tokens in circulation.
  final BigInt ctl;

  /// Asset id of this pool's LP token (`"lp-token"` in the JSON).
  final int lpToken;

  /// The shader's `k1_2` (tok1 / tok2) and `k2_1` (tok2 / tok1) as printed.
  final String? shaderRate12;
  final String? shaderRate21;

  /// The shader printed `creator: 1`: this wallet's key created the pool and
  /// may destroy it once empty. Wallet-specific; never put it in fixtures.
  final bool createdByThisWallet;

  /// No liquidity: nothing can be traded and the first deposit sets the
  /// price.
  bool get isEmpty =>
      ctl == BigInt.zero || tok1 == BigInt.zero || tok2 == BigInt.zero;

  bool hasAsset(int aid) => aid == aid1 || aid == aid2;

  /// Whether this pool trades [a] against [b], in either order.
  bool pairs(int a, int b) =>
      a != b && hasAsset(a) && hasAsset(b);

  int otherAsset(int aid) {
    if (aid == aid1) return aid2;
    if (aid == aid2) return aid1;
    throw ArgumentError.value(aid, 'aid', 'not in pool $aid1/$aid2');
  }

  BigInt reserveOf(int aid) {
    if (aid == aid1) return tok1;
    if (aid == aid2) return tok2;
    throw ArgumentError.value(aid, 'aid', 'not in pool $aid1/$aid2');
  }

  /// The spot price of one smallest unit of [aid] in smallest units of the
  /// other asset: reserve(other) / reserve(aid). Asset decimals are not
  /// applied; for a human price multiply by 10^(decimals(aid) -
  /// decimals(other)).
  BeamRatio spotPriceOf(int aid) {
    if (isEmpty) throw StateError('pool $aid1/$aid2 is empty');
    return BeamRatio(reserveOf(otherAsset(aid)), reserveOf(aid));
  }

  /// A position of [lpAmount] LP tokens in this pool.
  BeamLpPosition position(BigInt lpAmount) => BeamLpPosition(this, lpAmount);

  @override
  String toString() =>
      'BeamPool($aid1/$aid2 ${kind.feePercent}, lp $lpToken)';
}

/// A holding of a pool's LP token and what it is worth.
///
/// The estimates mirror `Totals::Remove`: the share rounded down per asset,
/// or the whole reserves for the last provider. The contract uses its own
/// floating-point type, so the result can differ from a `pool_withdraw`
/// prediction by a groth or so; the prediction is what the confirmation
/// shows.
@immutable
class BeamLpPosition {
  BeamLpPosition(this.pool, this.lpAmount) {
    if (lpAmount.isNegative) {
      throw ArgumentError.value(lpAmount, 'lpAmount', 'negative');
    }
  }

  final BeamPool pool;
  final BigInt lpAmount;

  /// Fraction of the pool this position owns, lpAmount / ctl.
  BeamRatio get share => pool.ctl == BigInt.zero
      ? BeamRatio.zero
      : BeamRatio(lpAmount, pool.ctl);

  /// More LP tokens than exist: a withdraw of this amount will fail.
  bool get exceedsSupply => lpAmount > pool.ctl;

  BigInt get estimatedTok1 => _estimate(pool.tok1);
  BigInt get estimatedTok2 => _estimate(pool.tok2);

  BigInt _estimate(BigInt reserve) {
    if (pool.ctl == BigInt.zero || exceedsSupply) return BigInt.zero;
    if (lpAmount == pool.ctl) return reserve;
    return reserve * lpAmount ~/ pool.ctl;
  }
}

/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dex_constants.dart';

/// `args` strings for the AMM app shader (`bvm/Shaders/amm/app.cpp`,
/// tag `beam-7.5.14493`). Pure functions; every input is validated here so
/// nothing the shader would misread is ever sent.
///
/// Every parameter the action declares is written explicitly. The shader
/// reads a missing number as 0 (`bvm2.cpp` `DocGetNum64`), and parses with
/// `strtoull(.., 0)`, so a leading zero would mean octal: only canonical
/// decimals (`BigInt.toString`) are emitted.
abstract final class DexArgs {
  static final _maxAmount = (BigInt.one << 63) - BigInt.one;
  static const _maxAssetId = 0xffffffff;
  static final _cid = RegExp(r'^[0-9a-f]{64}$');

  /// `pools_view`: every pool, `{"res": [ {aid1, aid2, kind, ctl, tok1,
  /// tok2, "lp-token", k1_2?, k2_1?, k1_ctl?, k2_ctl?, creator?} ]}`.
  static String poolsView({String cid = kDexContractId}) =>
      _join('pools_view', cid, const {});

  /// `pool_view`: one pool. The shader orders the pair itself; its totals
  /// (`tok1`, `tok2`) are always in pool order (smaller asset id first),
  /// whatever order is passed.
  static String poolView({
    required int aidA,
    required int aidB,
    required BeamPoolKind kind,
    String cid = kDexContractId,
  }) {
    _pair(aidA, aidB);
    return _join('pool_view', cid, {
      'aid1': '$aidA',
      'aid2': '$aidB',
      'kind': '${kind.wire}',
    });
  }

  /// `pool_trade`.
  ///
  /// **Direction, verified on mainnet** (2026-10-06, height 4068104,
  /// `bPredictOnly=1`, BEAM/FOMO kind 2, `val2_pay=10000000`):
  ///
  /// * `aid1=174,aid2=0` → `buy 80368764, pay 10000000`: pays 0.1 BEAM,
  ///   receives 0.80368764 FOMO.
  /// * `aid1=0,aid2=174` → `buy 1219726, pay 9999996`: pays 0.09999996
  ///   FOMO, receives 0.01219726 BEAM.
  ///
  /// So **`aid1` is always the asset received and `aid2` the asset paid**,
  /// in either id order (the contract un-normalizes the pair itself,
  /// `amm/contract.cpp` `Method_7`). This matches LightWallet's main DEX;
  /// its Quick Trade, which puts the bought asset in `aid2`, swaps the
  /// wrong way (defect D1).
  ///
  /// Give exactly one of:
  /// * [payAmount] (`val2_pay`): spend at most this much; the shader
  ///   searches for the largest receive whose price plus fee fits, so the
  ///   actual pay can be a few groth lower;
  /// * [receiveAmount] (`val1_buy`): receive exactly this much. The shader
  ///   silently truncates it to the pool's reserve minus one; check the
  ///   prediction.
  ///
  /// The prediction (`bPredictOnly=1`) prints `{"res": {buy, pay, pay_raw,
  /// fee_pool, fee_dao}}`: `pay` = `pay_raw` + both fees, all fees in the
  /// paid asset.
  static String trade({
    required int payAsset,
    required int receiveAsset,
    required BeamPoolKind kind,
    required bool predictOnly,
    BigInt? payAmount,
    BigInt? receiveAmount,
    String cid = kDexContractId,
  }) {
    _pair(payAsset, receiveAsset);
    if ((payAmount == null) == (receiveAmount == null)) {
      throw ArgumentError('give exactly one of payAmount and receiveAmount');
    }
    return _join('pool_trade', cid, {
      'aid1': '$receiveAsset',
      'aid2': '$payAsset',
      'kind': '${kind.wire}',
      'val1_buy': receiveAmount == null
          ? '0'
          : _amount(receiveAmount, 'receiveAmount'),
      'val2_pay': payAmount == null ? '0' : _amount(payAmount, 'payAmount'),
      'bPredictOnly': predictOnly ? '1' : '0',
    });
  }

  /// `pool_add_liquidity`. [amount1] goes with [aid1], [amount2] with
  /// [aid2], in the order given (the shader keeps the caller's order for
  /// `val1`/`val2` and for the predicted `tok1`/`tok2`).
  ///
  /// Leave one amount null to let the shader compute it from the reserves,
  /// which avoids "val1 too large" / "val2 too large" from a ratio that is
  /// slightly off. An empty pool (first provider) needs both.
  ///
  /// There is no `bCoversAll` parameter in this shader. LightWallet sends
  /// `bCoversAll=1`; the shader never reads it, so it has no effect.
  ///
  /// The prediction prints `{"res": {tok1, tok2, ctl}}`: both deposits and
  /// the LP tokens minted.
  static String addLiquidity({
    required int aid1,
    required int aid2,
    required BeamPoolKind kind,
    required bool predictOnly,
    BigInt? amount1,
    BigInt? amount2,
    String cid = kDexContractId,
  }) {
    _pair(aid1, aid2);
    if (amount1 == null && amount2 == null) {
      throw ArgumentError('give at least one of amount1 and amount2');
    }
    return _join('pool_add_liquidity', cid, {
      'aid1': '$aid1',
      'aid2': '$aid2',
      'kind': '${kind.wire}',
      'val1': amount1 == null ? '0' : _amount(amount1, 'amount1'),
      'val2': amount2 == null ? '0' : _amount(amount2, 'amount2'),
      'bPredictOnly': predictOnly ? '1' : '0',
    });
  }

  /// `pool_withdraw`: burn [ctl] LP tokens for a share of both reserves.
  /// The prediction prints `{"res": {ctl, tok1, tok2}}` with `tok1`/`tok2`
  /// in pool order (smaller asset id first), whatever order is passed.
  static String withdraw({
    required int aid1,
    required int aid2,
    required BeamPoolKind kind,
    required BigInt ctl,
    required bool predictOnly,
    String cid = kDexContractId,
  }) {
    _pair(aid1, aid2);
    return _join('pool_withdraw', cid, {
      'aid1': '$aid1',
      'aid2': '$aid2',
      'kind': '${kind.wire}',
      'ctl': _amount(ctl, 'ctl'),
      'bPredictOnly': predictOnly ? '1' : '0',
    });
  }

  /// `pool_create`: a new, empty pool. Locks [kDexPoolCreateDeposit]
  /// (10 BEAM) and costs [kDexPoolCreateFee]; there is no prediction mode.
  /// The pair is written in pool order. Liquidity is a separate
  /// [addLiquidity] once the pool exists on chain.
  static String createPool({
    required int aidA,
    required int aidB,
    required BeamPoolKind kind,
    String cid = kDexContractId,
  }) {
    _pair(aidA, aidB);
    final lo = aidA < aidB ? aidA : aidB;
    final hi = aidA < aidB ? aidB : aidA;
    return _join('pool_create', cid, {
      'aid1': '$lo',
      'aid2': '$hi',
      'kind': '${kind.wire}',
    });
  }

  // ---------------------------------------------------------------- helpers

  static String _join(String action, String cid, Map<String, String> p) {
    if (!_cid.hasMatch(cid)) {
      throw ArgumentError.value(cid, 'cid', '64 lowercase hex chars');
    }
    return [
      'action=$action',
      'cid=$cid',
      for (final e in p.entries) '${e.key}=${e.value}',
    ].join(',');
  }

  static void _pair(int a, int b) {
    _assetId(a, 'aid');
    _assetId(b, 'aid');
    if (a == b) throw ArgumentError('the two assets must differ ($a)');
  }

  static void _assetId(int id, String name) {
    if (id < 0 || id > _maxAssetId) {
      throw ArgumentError.value(id, name, 'asset ids are 0..2^32-1');
    }
  }

  static String _amount(BigInt v, String name) {
    if (v <= BigInt.zero) {
      throw ArgumentError.value(v, name, 'must be positive');
    }
    if (v > _maxAmount) {
      throw ArgumentError.value(v, name, 'above 2^63-1');
    }
    return v.toString();
  }
}

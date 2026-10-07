/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../assets/beam_asset_catalog.dart';
import '../contracts/dex/beam_pool.dart';
import '../contracts/dex/beam_ratio.dart';

/// Values Confidential Assets in BEAM from the DEX, for balances and the
/// portfolio total.
///
/// Each asset is priced from its deepest BEAM pool: the pool, of any kind,
/// holding the most BEAM. LightWallet took the first pool it found, so a
/// shallow pool could set the price of an asset that also trades deeply.
///
/// Anyone can create an asset and a pool for it, and set its price with
/// the first deposit (1 BEAM against 1 groth of the asset prices a unit at
/// 1 BEAM). So the two kinds of asset are valued differently:
///
/// * A verified asset ([BeamAssetCatalog.verified]) is valued at the spot
///   (mid) price of its deepest pool holding at least [minBeamReserve].
/// * Any other asset needs a pool holding at least
///   [minUnverifiedBeamReserve] (1,000 BEAM), and is valued at what that
///   pool would actually pay for the holding: the constant-product output
///   `beamReserve × amount / (assetReserve + amount)`, before the pool fee.
///   That is always less than the pool's BEAM, so no airdrop of a spam
///   asset can show as worth more than the BEAM someone locked in its pool.
///   The UI marks such values ([isSaleValue]).
///
/// A DEX liquidity (LP) token is valued from its pool, never from a pool
/// trading the LP token itself: it is worth what a withdraw of it pays out
/// (lpAmount / ctl of each reserve), each side valued as above. For a pool
/// of verified assets that is (lpAmount / ctl) × (tok1·price1 +
/// tok2·price2) at spot. An unverified side whose price comes from this
/// very pool is valued as sold back into what the withdraw leaves in it, so
/// a spam pool's LP tokens are never worth more than the BEAM in the pool.
///
/// Values are estimates either way and are labelled so in the UI. A holding
/// is valued in groth directly from the reserves, so an asset's decimals
/// are never needed to value it. Most assets on chain declare none we can
/// trust. LP tokens have 8 decimals like every Confidential Asset, and
/// their supply is the pool's `ctl` in the same smallest units (asset 175's
/// explorer supply equals pool 0/174's `ctl`).
class BeamAssetPricer {
  BeamAssetPricer(
    Iterable<BeamPool> pools, {
    BigInt? minBeamReserve,
    BigInt? minUnverifiedBeamReserve,
    bool Function(int assetId)? isVerified,
  }) : minBeamReserve = minBeamReserve ?? _oneBeam,
       minUnverifiedBeamReserve =
           minUnverifiedBeamReserve ?? defaultMinUnverifiedBeamReserve,
       _isVerified = isVerified ?? BeamAssetCatalog.verified.containsKey {
    final deepest = <int, BeamPool>{};
    for (final pool in pools) {
      if (pool.aid1 != 0 || pool.isEmpty) continue;
      if (pool.tok1 < _minReserveFor(pool.aid2) || pool.tok2 <= BigInt.zero) {
        continue;
      }
      final current = deepest[pool.aid2];
      if (current == null || pool.tok1 > current.tok1) {
        deepest[pool.aid2] = pool;
      }
    }
    _beamPools = Map.unmodifiable(deepest);
    _byLpToken = Map.unmodifiable({
      for (final pool in pools)
        if (!pool.isEmpty && pool.ctl > BigInt.zero) pool.lpToken: pool,
    });
  }

  static final _oneBeam = BigInt.from(100000000);

  /// 1,000 BEAM: the least a pool must hold before it may value an asset
  /// Campfire does not vouch for.
  static final BigInt defaultMinUnverifiedBeamReserve =
      BigInt.from(1000) * _oneBeam;

  /// Pools below this BEAM reserve never set a verified asset's price.
  final BigInt minBeamReserve;

  /// Pools below this BEAM reserve never value an unverified asset.
  final BigInt minUnverifiedBeamReserve;

  final bool Function(int assetId) _isVerified;

  late final Map<int, BeamPool> _beamPools;
  late final Map<int, BeamPool> _byLpToken;

  BigInt _minReserveFor(int assetId) =>
      _isVerified(assetId) ? minBeamReserve : minUnverifiedBeamReserve;

  /// The pool that prices [assetId], or null when no BEAM pool qualifies.
  BeamPool? pricingPool(int assetId) => _beamPools[assetId];

  /// True when [valueInGroth] values [assetId] as a sale into its pool (an
  /// unverified asset, or an LP token with an unverified side), not at a
  /// verified asset's spot price.
  bool isSaleValue(int assetId) => _isSale(assetId, 0);

  bool _isSale(int assetId, int depth) {
    if (assetId == 0) return false;
    final lp = _byLpToken[assetId];
    if (lp != null && depth < _maxLpDepth) {
      return _isSale(lp.aid1, depth + 1) || _isSale(lp.aid2, depth + 1);
    }
    return !_isVerified(assetId) && _beamPools[assetId] != null;
  }

  /// Groth per smallest unit of [assetId] at its pool's spot price. BEAM is
  /// exactly one. For an unverified asset this is the pool's quote, not
  /// what a holding is worth: see [valueInGroth].
  BeamRatio? grothPerUnit(int assetId) {
    if (assetId == 0) return BeamRatio.one;
    final pool = _beamPools[assetId];
    if (pool == null) return null;
    return BeamRatio(pool.tok1, pool.tok2);
  }

  /// BEAM per whole unit of [assetId], given its [decimals]. Null when the
  /// asset has no qualifying pool.
  BeamRatio? beamPerWholeUnit(int assetId, int decimals) {
    final perUnit = grothPerUnit(assetId);
    if (perUnit == null) return null;
    return perUnit *
        BeamRatio(BigInt.from(10).pow(decimals), BigInt.from(100000000));
  }

  /// What [amount] smallest units of [assetId] are worth in groth, rounded
  /// down: spot for a verified asset, what its pool would pay for an
  /// unverified one ([isSaleValue]), and for an LP token what a withdraw
  /// of it pays out, valued the same way (see the class comment). Null
  /// when the asset cannot be priced.
  BigInt? valueInGroth(int assetId, BigInt amount) =>
      _value(assetId, amount, 0);

  /// LP tokens of pools of LP tokens of… are valued this many levels deep
  /// at most.
  static const _maxLpDepth = 3;

  BigInt? _value(int assetId, BigInt amount, int depth) {
    if (amount <= BigInt.zero) return BigInt.zero;
    if (assetId == 0) return amount;
    final lp = _byLpToken[assetId];
    if (lp != null && depth < _maxLpDepth) return _lpValue(lp, amount, depth);
    return _directValue(assetId, amount);
  }

  BigInt? _directValue(int assetId, BigInt amount) {
    final pool = _beamPools[assetId];
    if (pool == null) return null;
    if (_isVerified(assetId)) {
      return _floor(
        BeamRatio(pool.tok1, pool.tok2) * BeamRatio(amount, BigInt.one),
      );
    }
    // Sold into the pool: x·y = k, so the BEAM out is tok1·a / (tok2 + a),
    // always below the pool's BEAM reserve.
    return pool.tok1 * amount ~/ (pool.tok2 + amount);
  }

  /// [lpAmount] LP tokens of [pool]: the share lpAmount / ctl of each
  /// reserve, each valued, added exactly and rounded down once.
  BigInt? _lpValue(BeamPool pool, BigInt lpAmount, int depth) {
    final share = BeamRatio(
      lpAmount > pool.ctl ? pool.ctl : lpAmount,
      pool.ctl,
    );
    final v1 = _sideValue(pool, pool.aid1, pool.tok1, share, depth);
    final v2 = _sideValue(pool, pool.aid2, pool.tok2, share, depth);
    if (v1 == null || v2 == null) return null;
    return (v1 + v2).floor();
  }

  /// [share] of [pool]'s [reserve] of [assetId], in groth.
  BeamRatio? _sideValue(
    BeamPool pool,
    int assetId,
    BigInt reserve,
    BeamRatio share,
    int depth,
  ) {
    final part = share * BeamRatio(reserve, BigInt.one);
    if (assetId == 0) return part;
    final pricing = _beamPools[assetId];
    if (pricing != null &&
        _isVerified(assetId) &&
        _byLpToken[assetId] == null) {
      // At spot: share × reserve × tok1 / tok2 of its BEAM pool.
      return part * BeamRatio(pricing.tok1, pricing.tok2);
    }
    // Sold, so in whole smallest units: what a withdraw would pay out
    // (rounded down, `Totals::Remove`).
    final amount = part.floor();
    if (pricing != null &&
        pricing.lpToken == pool.lpToken &&
        _byLpToken[assetId] == null) {
      // This very pool prices the asset: sold back into what the withdraw
      // leaves in it ([pool] is then BEAM/asset, BEAM its first side).
      final beamLeft = pool.tok1 - share.floorTimes(pool.tok1);
      if (beamLeft <= BigInt.zero || amount == BigInt.zero) {
        return BeamRatio.zero;
      }
      return BeamRatio(beamLeft * amount ~/ pool.tok2, BigInt.one);
    }
    final v = _value(assetId, amount, depth + 1);
    return v == null ? null : BeamRatio(v, BigInt.one);
  }

  /// Values every holding in [balances] (asset id → smallest units).
  BeamPortfolioValue portfolio(Map<int, BigInt> balances) {
    var total = BigInt.zero;
    final values = <int, BigInt>{};
    final unpriced = <int>[];
    for (final e in balances.entries) {
      final v = valueInGroth(e.key, e.value);
      if (v == null) {
        unpriced.add(e.key);
      } else {
        values[e.key] = v;
        total += v;
      }
    }
    unpriced.sort();
    return BeamPortfolioValue(
      totalGroth: total,
      valuesGroth: Map.unmodifiable(values),
      unpriced: List.unmodifiable(unpriced),
    );
  }

  static BigInt _floor(BeamRatio r) => r.numerator ~/ r.denominator;
}

/// A wallet's holdings valued in BEAM.
class BeamPortfolioValue {
  const BeamPortfolioValue({
    required this.totalGroth,
    required this.valuesGroth,
    required this.unpriced,
  });

  /// Sum of every holding that could be priced, in groth.
  final BigInt totalGroth;

  /// Value of each priced holding, in groth.
  final Map<int, BigInt> valuesGroth;

  /// Assets held that no qualifying pool prices. The total leaves them out,
  /// and the UI says so instead of treating them as worthless.
  final List<int> unpriced;
}

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
/// Values are estimates either way and are labelled so in the UI. A holding
/// is valued in groth directly from the reserves, so an asset's decimals
/// are never needed to value it. Most assets on chain declare none we can
/// trust.
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
  /// unverified asset), not at a verified asset's spot price.
  bool isSaleValue(int assetId) =>
      assetId != 0 && !_isVerified(assetId) && _beamPools[assetId] != null;

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
  /// unverified one ([isSaleValue]). LP tokens are valued as their share of
  /// both pool reserves, each side valued the same way. Null when the asset
  /// cannot be priced.
  BigInt? valueInGroth(int assetId, BigInt amount) {
    if (amount <= BigInt.zero) return BigInt.zero;
    if (assetId == 0) return amount;
    final direct = _directValue(assetId, amount);
    if (direct != null) return direct;
    final pool = _byLpToken[assetId];
    if (pool != null) return _lpValue(pool, amount);
    return null;
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

  BigInt? _lpValue(BeamPool pool, BigInt lpAmount) {
    final share = BeamRatio(
      lpAmount > pool.ctl ? pool.ctl : lpAmount,
      pool.ctl,
    );
    final side1 = _sideValue(pool.aid1, pool.tok1);
    final side2 = _sideValue(pool.aid2, pool.tok2);
    if (side1 == null || side2 == null) return null;
    return _floor(share * BeamRatio(side1 + side2, BigInt.one));
  }

  BigInt? _sideValue(int assetId, BigInt reserve) {
    if (assetId == 0) return reserve;
    return _directValue(assetId, reserve);
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

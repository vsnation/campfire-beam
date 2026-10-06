/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../contracts/dex/beam_pool.dart';
import '../contracts/dex/beam_ratio.dart';

/// Values Confidential Assets in BEAM from the DEX, for balances and the
/// portfolio total.
///
/// Each asset is priced from its deepest BEAM pool: the pool, of any kind,
/// holding the most BEAM. LightWallet took the first pool it found, so a
/// shallow pool could set the price of an asset that also trades deeply.
/// Pools holding less than [minBeamReserve] are ignored entirely: a pool
/// anyone can seed with a few groth would otherwise let them set the value
/// shown for a user's holdings.
///
/// Values are spot (mid) prices from the reserves, before fees and price
/// impact, and are labelled as estimates in the UI. A holding is valued in
/// groth directly as `amount * beamReserve / assetReserve`, so an asset's
/// decimals are never needed to value it. Most assets on chain declare
/// none we can trust.
class BeamAssetPricer {
  BeamAssetPricer(
    Iterable<BeamPool> pools, {
    BigInt? minBeamReserve,
  }) : minBeamReserve = minBeamReserve ?? _oneBeam {
    final deepest = <int, BeamPool>{};
    for (final pool in pools) {
      if (pool.aid1 != 0 || pool.isEmpty) continue;
      if (pool.tok1 < this.minBeamReserve || pool.tok2 <= BigInt.zero) {
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

  /// Pools below this BEAM reserve never set a price.
  final BigInt minBeamReserve;

  late final Map<int, BeamPool> _beamPools;
  late final Map<int, BeamPool> _byLpToken;

  /// The pool that prices [assetId], or null when no BEAM pool qualifies.
  BeamPool? pricingPool(int assetId) => _beamPools[assetId];

  /// Groth per smallest unit of [assetId]. BEAM is exactly one.
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
  /// down. LP tokens are valued as their share of both pool reserves. Null
  /// when the asset cannot be priced.
  BigInt? valueInGroth(int assetId, BigInt amount) {
    if (amount <= BigInt.zero) return BigInt.zero;
    if (assetId == 0) return amount;
    final direct = grothPerUnit(assetId);
    if (direct != null) return _floor(direct * BeamRatio(amount, BigInt.one));
    final pool = _byLpToken[assetId];
    if (pool != null) return _lpValue(pool, amount);
    return null;
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
    final perUnit = grothPerUnit(assetId);
    if (perUnit == null) return null;
    return _floor(perUnit * BeamRatio(reserve, BigInt.one));
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

/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import 'beam_pool.dart';

/// The pool a DEX liquidity (LP) token is a share of: its two assets, in the
/// contract's order (`aid1 < aid2`), and its fee kind (wire value).
@immutable
class BeamLpPool {
  const BeamLpPool({
    required this.lpToken,
    required this.aid1,
    required this.aid2,
    required this.kind,
  });

  final int lpToken;
  final int aid1;
  final int aid2;

  /// `BeamPoolKind.wire`.
  final int kind;

  @override
  bool operator ==(Object other) =>
      other is BeamLpPool &&
      other.lpToken == lpToken &&
      other.aid1 == aid1 &&
      other.aid2 == aid2 &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(lpToken, aid1, aid2, kind);

  @override
  String toString() => 'BeamLpPool(lp $lpToken: $aid1/$aid2 kind $kind)';
}

/// Which Confidential Assets are the DEX's liquidity (LP) tokens, and of
/// which pool, for every screen that names or draws an asset.
///
/// An LP token's on-chain metadata is the contract's own text,
/// `STD:SCH_VER=1;N=Amm Liquidity Token <aid1>-<aid2>-<kind>;SN=AmmL;UN=AMML;
/// NTHUN=GROTH` (`bvm/Shaders/amm/contract.cpp`, `Method_3`), but anyone can
/// mint an asset with that text from their own key. So an asset is an LP
/// token here only when the DEX contract says so: a `pools_view` /
/// `pool_view` row naming it as `lp-token` ([learnPools]), or a cached asset
/// row that was built from one ([learn]). Never from a name.
///
/// The mapping is a fact of the chain, the same for every wallet: an LP
/// token belongs to one pool for its whole life (a destroyed and re-created
/// pool mints a new one). So it is kept once per process.
abstract final class BeamLpTokens {
  static final Map<int, BeamLpPool> _byLp = {};

  /// The pool [assetId] is the LP token of, or null when it is not one (or
  /// the DEX has not been read yet).
  static BeamLpPool? of(int assetId) => _byLp[assetId];

  /// Every pool learnt so far, by LP token.
  static Map<int, BeamLpPool> get all => Map.unmodifiable(_byLp);

  /// Records the LP token of every pool in [pools] (DEX `pools_view` rows).
  static void learnPools(Iterable<BeamPool> pools) {
    for (final p in pools) {
      learn(
        BeamLpPool(
          lpToken: p.lpToken,
          aid1: p.aid1,
          aid2: p.aid2,
          kind: p.kind.wire,
        ),
      );
    }
  }

  /// Records [pool]. Ignores anything malformed: the LP token must be a
  /// Confidential Asset distinct from the pool's two assets, which must be
  /// in the contract's order.
  static void learn(BeamLpPool pool) {
    if (pool.lpToken <= 0 ||
        pool.aid1 < 0 ||
        pool.aid1 >= pool.aid2 ||
        pool.lpToken == pool.aid1 ||
        pool.lpToken == pool.aid2) {
      return;
    }
    _byLp[pool.lpToken] = pool;
  }

  /// Forgets everything (tests).
  @visibleForTesting
  static void clear() => _byLp.clear();
}

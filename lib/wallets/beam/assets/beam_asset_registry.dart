/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:isar_community/isar.dart';

import '../../../models/isar/models/beam/beam_asset_contract.dart';
import '../api/beam_api.dart';
import '../contracts/dex/beam_pool.dart';
import '../models/beam_asset_info.dart';
import 'beam_asset_catalog.dart';

/// Builds and caches [BeamAssetContract]s: how each asset a wallet holds is
/// shown.
///
/// * Verified assets come from [BeamAssetCatalog] and never need the core.
/// * Unverified assets take their cleaned on-chain name from `assets_list`
///   (one call for everything the wallet knows), with `get_asset_info` for
///   the few it does not. Until then they show as "Asset #id".
/// * DEX liquidity tokens are recognised only from the DEX contract's own
///   pool list (`lp-token`), never from a name: anyone can mint an asset
///   called "Amm Liquidity Token".
abstract final class BeamAssetRegistry {
  /// At most this many `get_asset_info` calls per sync: a wallet sent
  /// hundreds of spam assets must not hold the core up.
  static const int maxSingleLookups = 20;

  /// The row for [assetId] from what is known now. [metadata] is the
  /// on-chain metadata, [pool] the DEX pool whose LP token this is, and
  /// [pairLabel] how that pool's assets read ("BEAM / FOMO").
  static BeamAssetContract build(
    int assetId, {
    BeamAssetMetadata? metadata,
    BeamPool? pool,
    String? pairLabel,
  }) {
    final address = BeamAssetContract.addressFor(assetId);
    final decimals = BeamAssetInfo.decimalsFor(assetId);
    if (pool != null) {
      return BeamAssetContract(
        address: address,
        assetId: assetId,
        name: '${pairLabel ?? '#${pool.aid1} / #${pool.aid2}'} pool share',
        symbol: 'LP',
        decimals: decimals,
        verified: false,
        metadataKnown: true,
        // The desktop wallet's generic icon for the LP token's id (never
        // one a verified asset wears).
        iconAsset: BeamAssetCatalog.unverifiedIcon(assetId),
        color: BeamAssetCatalog.genericColor(assetId),
        poolAssetA: pool.aid1,
        poolAssetB: pool.aid2,
        poolKind: pool.kind.wire,
      );
    }
    final d = BeamAssetCatalog.display(assetId, metadata);
    return BeamAssetContract(
      address: address,
      assetId: assetId,
      name: d.name,
      symbol: d.symbol,
      decimals: decimals,
      verified: d.verified,
      metadataKnown: d.verified || metadata != null,
      iconAsset: d.icon,
      color: d.color,
      impersonates: d.impersonates,
    );
  }

  /// [row] with today's catalogue look (icon, colour, verified), which a
  /// cached row may predate. What was learnt from the chain is kept, but an
  /// unverified asset's name and ticker are cleaned and checked for a
  /// copied verified asset again ([BeamAssetCatalog.relook]): a stricter
  /// check, or a newly verified asset, applies to rows cached before it.
  static BeamAssetContract refreshLook(BeamAssetContract row) {
    final verified = BeamAssetCatalog.verified.containsKey(row.assetId);
    final look = BeamAssetCatalog.display(row.assetId, null);
    final pool = row.isPoolShare;
    final text = verified || pool
        ? null
        : BeamAssetCatalog.relook(row.assetId, row.name, row.symbol);
    return BeamAssetContract(
      address: row.address,
      assetId: row.assetId,
      name: verified ? look.name : (text?.name ?? row.name),
      symbol: verified ? look.symbol : (text?.symbol ?? row.symbol),
      decimals: BeamAssetInfo.decimalsFor(row.assetId),
      verified: verified,
      metadataKnown: row.metadataKnown,
      iconAsset: pool
          ? BeamAssetCatalog.unverifiedIcon(row.assetId)
          : look.icon,
      color: look.color,
      impersonates: text?.impersonates,
      poolAssetA: row.poolAssetA,
      poolAssetB: row.poolAssetB,
      poolKind: row.poolKind,
    )..id = row.id;
  }

  /// "FOMO" for a verified asset, "SCAM #999" for anything else, so a pool
  /// of a copycat never reads like the real pair.
  static String sideLabel(int assetId, BeamAssetMetadata? metadata) {
    final d = BeamAssetCatalog.display(assetId, metadata);
    if (d.verified || d.symbol == d.idLabel) return d.symbol;
    return '${d.symbol} ${d.idLabel}';
  }

  /// Refreshes the cached rows of [heldIds] in [isar].
  ///
  /// [api] (the open core, or null) supplies metadata for unverified assets
  /// whose name is not known yet; [pools] (the DEX's pools, or null when not
  /// loaded) marks liquidity tokens. Failures leave the cache as it was:
  /// the list keeps showing what it showed. Returns the rows now cached for
  /// [heldIds].
  static Future<Map<int, BeamAssetContract>> sync({
    required Isar isar,
    required Iterable<int> heldIds,
    BeamApi? api,
    List<BeamPool>? pools,
  }) async {
    final ids = {
      for (final id in heldIds)
        if (id > 0) id,
    };
    final existing = {
      for (final c in isar.beamAssetContracts.where().findAllSync())
        c.assetId: c,
    };
    final byLp = pools == null ? null : {for (final p in pools) p.lpToken: p};

    // Metadata for unverified assets (and pool sides) not named yet.
    final wanted = <int>{
      for (final id in ids)
        if (!BeamAssetCatalog.verified.containsKey(id) &&
            !(existing[id]?.metadataKnown ?? false) &&
            !(byLp?.containsKey(id) ?? false))
          id,
      if (byLp != null)
        for (final id in ids)
          if (byLp[id] case final pool?) ...[
            if (!BeamAssetCatalog.verified.containsKey(pool.aid1)) pool.aid1,
            if (!BeamAssetCatalog.verified.containsKey(pool.aid2)) pool.aid2,
          ],
    }..remove(0);
    final metadata = <int, BeamAssetMetadata>{};
    if (api != null && wanted.isNotEmpty) {
      try {
        for (final a in await api.assetsList()) {
          if (wanted.contains(a.assetId)) metadata[a.assetId] = a.metadata;
        }
      } catch (_) {
        // Not open, or slow: try one by one below, then next time.
      }
      var lookups = 0;
      for (final id in wanted) {
        if (metadata.containsKey(id)) continue;
        if (lookups++ >= maxSingleLookups) break;
        try {
          metadata[id] = (await api.getAssetInfo(id)).metadata;
        } catch (_) {
          // Unknown to the core: stays "Asset #id".
        }
      }
    }

    BeamAssetMetadata? metaOf(int id) => metadata[id];

    final out = <int, BeamAssetContract>{};
    final changed = <BeamAssetContract>[];
    for (final id in ids) {
      final old = existing[id];
      final pool = byLp?[id];
      BeamAssetContract next;
      if (pool != null) {
        next = build(
          id,
          pool: pool,
          pairLabel:
              '${sideLabel(pool.aid1, metaOf(pool.aid1))} / '
              '${sideLabel(pool.aid2, metaOf(pool.aid2))}',
        );
      } else if (byLp == null && old != null && old.isPoolShare) {
        // Pools not loaded this time: keep what the DEX said before.
        next = refreshLook(old);
      } else if (metadata[id] == null && old != null && old.metadataKnown) {
        next = old.isPoolShare ? build(id) : refreshLook(old);
      } else {
        next = build(id, metadata: metadata[id]);
      }
      if (old != null) next.id = old.id;
      out[id] = next;
      if (old == null || !old.sameAs(next)) changed.add(next);
    }
    if (changed.isNotEmpty) {
      // A handful of small rows: synchronous, like Campfire's token info
      // providers, so no half-finished write outlives the screen.
      isar.writeTxnSync(() => isar.beamAssetContracts.putAllSync(changed));
    }
    return out;
  }
}

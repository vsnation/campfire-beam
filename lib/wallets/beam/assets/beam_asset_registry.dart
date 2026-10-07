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
import '../contracts/dex/beam_lp_tokens.dart';
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
///   pool list (`lp-token`, [BeamLpTokens]), never from a name: anyone can
///   mint an asset called "Amm Liquidity Token 0-174-2". They are named
///   after their pool, "BEAM/FOMO LP", as the DEX names it.
abstract final class BeamAssetRegistry {
  /// At most this many `get_asset_info` calls per sync: a wallet sent
  /// hundreds of spam assets must not hold the core up.
  static const int maxSingleLookups = 20;

  /// The row for [assetId] from what is known now. [metadata] is the
  /// on-chain metadata; [pool] the DEX pool whose LP token this is (by
  /// default whatever [BeamLpTokens] knows), and [metadataOf] the metadata
  /// of that pool's assets, so an unverified side reads "PEPE #777".
  static BeamAssetContract build(
    int assetId, {
    BeamAssetMetadata? metadata,
    BeamLpPool? pool,
    BeamAssetMetadata? Function(int assetId)? metadataOf,
  }) {
    final address = BeamAssetContract.addressFor(assetId);
    final decimals = BeamAssetInfo.decimalsFor(assetId);
    final lp = BeamAssetCatalog.verified.containsKey(assetId)
        ? null
        : pool ?? BeamLpTokens.of(assetId);
    if (lp != null && lp.lpToken == assetId) {
      final d = BeamAssetCatalog.lpDisplay(lp, metadataOf: metadataOf);
      return BeamAssetContract(
        address: address,
        assetId: assetId,
        name: d.name,
        symbol: d.symbol,
        decimals: decimals,
        verified: d.verified,
        metadataKnown: true,
        // The desktop wallet's generic icon for the LP token's id (never
        // one a verified asset wears), for screens that cannot draw the
        // pair; `BeamAssetLogo` draws the pair from the pool.
        iconAsset: d.icon,
        color: d.color,
        poolAssetA: lp.aid1,
        poolAssetB: lp.aid2,
        poolKind: lp.kind,
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

  /// The pool [row] is the LP token of, or null for any other asset.
  static BeamLpPool? poolOf(BeamAssetContract row) {
    final a = row.poolAssetA, b = row.poolAssetB, kind = row.poolKind;
    if (a == null || b == null || kind == null) return null;
    return BeamLpPool(lpToken: row.assetId, aid1: a, aid2: b, kind: kind);
  }

  /// Teaches [BeamLpTokens] the pools of the LP tokens among [rows] (rows
  /// cached from an earlier DEX read), so they are named before the DEX is
  /// read again.
  static void learnPools(Iterable<BeamAssetContract> rows) {
    for (final r in rows) {
      if (poolOf(r) case final pool?) BeamLpTokens.learn(pool);
    }
  }

  /// [row] with today's catalogue look (icon, colour, verified), which a
  /// cached row may predate. What was learnt from the chain is kept, but an
  /// unverified asset's name and ticker are cleaned and checked for a
  /// copied verified asset again ([BeamAssetCatalog.relook]): a stricter
  /// check, or a newly verified asset, applies to rows cached before it.
  /// An LP token's row is named again from its pool ("BEAM / FOMO pool
  /// share" from an older version becomes "BEAM/FOMO LP"), keeping the
  /// names it had for unverified sides.
  static BeamAssetContract refreshLook(BeamAssetContract row) {
    final pool = poolOf(row);
    if (pool != null) {
      final fresh = build(row.assetId, pool: pool);
      // Both sides verified: the catalogue names them. Otherwise keep the
      // names the row was built with (from the sides' metadata, which a
      // build without it would turn into "#777").
      final name = fresh.verified
          ? fresh.name
          : _legacyName(row.name) ?? row.name;
      return BeamAssetContract(
        address: row.address,
        assetId: row.assetId,
        name: name,
        symbol: name,
        decimals: BeamAssetInfo.decimalsFor(row.assetId),
        verified: fresh.verified,
        metadataKnown: true,
        iconAsset: fresh.iconAsset,
        color: fresh.color,
        poolAssetA: row.poolAssetA,
        poolAssetB: row.poolAssetB,
        poolKind: row.poolKind,
      )..id = row.id;
    }
    final verified = BeamAssetCatalog.verified.containsKey(row.assetId);
    final look = BeamAssetCatalog.display(row.assetId, null);
    final text = verified
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
      iconAsset: look.icon,
      color: look.color,
      impersonates: text?.impersonates,
    )..id = row.id;
  }

  /// "BEAM / PEPE #777 pool share", as versions before 2026-10-07 named an
  /// LP token, as "BEAM/PEPE #777 LP"; null for any other name.
  static String? _legacyName(String name) {
    const suffix = ' pool share';
    if (!name.endsWith(suffix)) return null;
    final sides = name.substring(0, name.length - suffix.length).split(' / ');
    if (sides.length != 2) return null;
    return '${sides[0]}/${sides[1]} LP';
  }

  /// "FOMO" for a verified asset, "SCAM #999" for anything else, so a pool
  /// of a copycat never reads like the real pair; "(BEAM/NPH LP)" for an LP
  /// token ([BeamAssetCatalog.pairName]).
  static String sideLabel(int assetId, BeamAssetMetadata? metadata) {
    final d = BeamAssetCatalog.display(assetId, metadata);
    return d.isPoolShare ? '(${d.label})' : d.label;
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
    // LP tokens the DEX named before (cached rows), and the ones it names
    // now ([pools]): from here on [BeamLpTokens] knows every one of them.
    learnPools(existing.values);
    if (pools != null) BeamLpTokens.learnPools(pools);

    // An LP token whose cached row already names its pool is kept as it is
    // when this sync could not name it better: the DEX was not read, or the
    // core cannot name the pool's unverified assets.
    bool keepPoolRow(int id) {
      final old = existing[id];
      if (old == null || (pools != null && api != null)) return false;
      final pool = poolOf(old);
      return pool != null && pool == BeamLpTokens.of(id);
    }

    // Metadata for unverified assets (and pool sides) not named yet.
    final wanted = <int>{
      for (final id in ids)
        if (!BeamAssetCatalog.verified.containsKey(id) &&
            !(existing[id]?.metadataKnown ?? false) &&
            BeamLpTokens.of(id) == null)
          id,
      for (final id in ids)
        if (BeamLpTokens.of(id) case final pool? when !keepPoolRow(id)) ...[
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
      final pool = BeamLpTokens.of(id);
      BeamAssetContract next;
      if (pool != null && keepPoolRow(id)) {
        next = refreshLook(old!);
      } else if (pool != null) {
        next = build(id, pool: pool, metadataOf: metaOf);
      } else if (metadata[id] == null && old != null && old.metadataKnown) {
        next = refreshLook(old);
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

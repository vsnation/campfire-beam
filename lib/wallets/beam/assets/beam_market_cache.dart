/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

import 'package:isar_community/isar.dart';

import '../../isar/models/wallet_info.dart';
import '../contracts/dex/beam_pool.dart';
import '../contracts/dex/dex_constants.dart';
import 'beam_asset_holdings.dart';

/// Where the last DEX snapshot is kept between launches, so asset prices
/// are on screen the moment a wallet opens instead of after the first
/// `pools_view` (seconds on a public node).
abstract class BeamMarketCache {
  /// The saved snapshot, or null when there is none or it cannot be read.
  /// Never throws.
  BeamAssetMarket? load();

  /// Saves [market]. Failures are swallowed: a cache must never break the
  /// prices it speeds up.
  Future<void> save(BeamAssetMarket market);
}

/// The snapshot in the wallet's own `WalletInfo.otherData`: one wallet's
/// cache, deleted with the wallet, and only public chain data (pool
/// reserves), so nothing about the user is stored.
class WalletInfoMarketCache implements BeamMarketCache {
  WalletInfoMarketCache({required this.info, required this.isar});

  /// The wallet's current info (it is replaced on every update).
  final WalletInfo Function() info;
  final Isar Function() isar;

  static const String otherDataKey = 'beamMarketCacheV1';

  /// Snapshots older than this are not shown at all: pool prices that old
  /// would mislead more than they help.
  static const Duration maxAge = Duration(days: 7);

  @override
  BeamAssetMarket? load() {
    try {
      final raw = info().otherData[otherDataKey];
      if (raw is! String) return null;
      return decode(raw, now: DateTime.now());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(BeamAssetMarket market) async {
    try {
      await info().updateOtherData(
        newEntries: {otherDataKey: encode(market)},
        isar: isar(),
      );
    } catch (_) {}
  }

  static String encode(BeamAssetMarket market) => jsonEncode({
    'readAt': market.readAt.toUtc().millisecondsSinceEpoch,
    'pools': [
      for (final p in market.pools)
        [
          p.aid1,
          p.aid2,
          p.kind.wire,
          '${p.tok1}',
          '${p.tok2}',
          '${p.ctl}',
          p.lpToken,
        ],
    ],
  });

  /// The snapshot in [raw], or null when it is malformed or older than
  /// [maxAge] at [now].
  static BeamAssetMarket? decode(String raw, {required DateTime now}) {
    final json = jsonDecode(raw);
    if (json is! Map) return null;
    final at = json['readAt'];
    final rows = json['pools'];
    if (at is! int || rows is! List) return null;
    final readAt = DateTime.fromMillisecondsSinceEpoch(at, isUtc: true);
    if (now.toUtc().difference(readAt) > maxAge) return null;
    final pools = <BeamPool>[];
    for (final r in rows) {
      if (r is! List || r.length != 7) return null;
      final tok1 = BigInt.tryParse('${r[3]}');
      final tok2 = BigInt.tryParse('${r[4]}');
      final ctl = BigInt.tryParse('${r[5]}');
      if (r[0] is! int || r[1] is! int || r[2] is! int || r[6] is! int) {
        return null;
      }
      if (tok1 == null || tok2 == null || ctl == null) return null;
      if (tok1.isNegative || tok2.isNegative || ctl.isNegative) return null;
      pools.add(
        BeamPool(
          aid1: r[0] as int,
          aid2: r[1] as int,
          kind: BeamPoolKind.fromWire(r[2] as int),
          tok1: tok1,
          tok2: tok2,
          ctl: ctl,
          lpToken: r[6] as int,
        ),
      );
    }
    return BeamAssetMarket(pools, readAt: readAt.toLocal());
  }
}

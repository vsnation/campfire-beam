/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import '../../../models/balance.dart';
import '../../../utilities/amount/amount.dart';
import '../models/beam_wallet_status.dart';

/// One asset's totals as Campfire caches them in `WalletInfo.otherData`
/// under `WalletInfoKeys.beamAssetTotals`.
///
/// All amounts are in the asset's smallest unit. Decimals are not known here
/// (they come from the asset's metadata, B-ASSET-1).
@immutable
class BeamCachedAssetTotals {
  const BeamCachedAssetTotals({
    required this.assetId,
    required this.available,
    required this.receiving,
    required this.sending,
    required this.maturing,
    required this.change,
  });

  factory BeamCachedAssetTotals.fromTotals(BeamAssetTotals t) =>
      BeamCachedAssetTotals(
        assetId: t.assetId,
        available: t.available,
        receiving: t.receiving,
        sending: t.sending,
        maturing: t.maturing,
        change: t.change,
      );

  /// Reads one entry written by [toJson]. Throws [FormatException] on
  /// anything else.
  factory BeamCachedAssetTotals.fromJson(int assetId, Object? json) {
    if (json is! Map) throw const FormatException('asset totals: not a map');
    BigInt read(String key) {
      final v = json[key];
      final parsed = v is String ? BigInt.tryParse(v) : null;
      if (parsed == null) throw FormatException('asset totals: bad $key');
      return parsed;
    }

    return BeamCachedAssetTotals(
      assetId: assetId,
      available: read('available'),
      receiving: read('receiving'),
      sending: read('sending'),
      maturing: read('maturing'),
      change: read('change'),
    );
  }

  final int assetId;

  /// Spendable now (regular and shielded summed).
  final BigInt available;

  /// Incoming, change included (BEAM counts change as incoming).
  final BigInt receiving;

  /// Leaving in unfinished outgoing transactions.
  final BigInt sending;

  /// Received but not yet spendable (e.g. coinbase, shielded maturity).
  final BigInt maturing;

  /// The part of [receiving] that is change from this wallet's own sends.
  final BigInt change;

  /// What the wallet owns once pending transactions settle.
  BigInt get total => available + receiving + maturing;

  Map<String, String> toJson() => {
    'available': '$available',
    'receiving': '$receiving',
    'sending': '$sending',
    'maturing': '$maturing',
    'change': '$change',
  };

  @override
  bool operator ==(Object other) =>
      other is BeamCachedAssetTotals &&
      other.assetId == assetId &&
      other.available == available &&
      other.receiving == receiving &&
      other.sending == sending &&
      other.maturing == maturing &&
      other.change == change;

  @override
  int get hashCode =>
      Object.hash(assetId, available, receiving, sending, maturing, change);
}

/// Maps `wallet_status` onto Campfire's [Balance] and the per-asset cache.
///
/// BEAM (asset 0) into [Balance]:
///
/// | Campfire            | BEAM                         |
/// |---------------------|------------------------------|
/// | `spendable`         | `available`                  |
/// | `pendingSpendable`  | `receiving + maturing`       |
/// | `blockedTotal`      | 0                            |
/// | `total`             | `available + receiving + maturing` |
///
/// Why not `+ change` and `blocked = locked`: in the core, `change` is a
/// subset of `receiving` (`wallet_db.cpp:6319-6327` adds every incoming coin
/// to `Incoming` and change coins also to `ReceivingChange`), and `locked`
/// is not a separate pot but `maturing + maturing_mp + change`
/// (`v6_1_api_parse.cpp:245-247`). Adding either would count the same coins
/// twice. BEAM has no frozen coins in Campfire's sense, so nothing is
/// blocked. `sending` is not part of the total: those coins are leaving.
abstract final class BeamBalanceMapper {
  static Balance balance(BeamWalletStatus status, {int fractionDigits = 8}) {
    final beam = totalsFor(status, 0);
    Amount a(BigInt v) => Amount(rawValue: v, fractionDigits: fractionDigits);
    return Balance(
      total: a(beam.total),
      spendable: a(beam.available),
      blockedTotal: a(BigInt.zero),
      pendingSpendable: a(beam.receiving + beam.maturing),
    );
  }

  /// [assetId]'s totals. Asset 0 falls back to the top-level BEAM fields when
  /// the core sent no `totals` (assets disabled). Missing assets are zero.
  static BeamCachedAssetTotals totalsFor(BeamWalletStatus status, int assetId) {
    final t = status.totalsFor(assetId);
    if (t != null) return BeamCachedAssetTotals.fromTotals(t);
    if (assetId == 0 && status.totals.isEmpty) {
      return BeamCachedAssetTotals(
        assetId: 0,
        available: status.available ?? BigInt.zero,
        receiving: status.receiving ?? BigInt.zero,
        sending: status.sending ?? BigInt.zero,
        maturing: status.maturing ?? BigInt.zero,
        change: BigInt.zero,
      );
    }
    return BeamCachedAssetTotals(
      assetId: assetId,
      available: BigInt.zero,
      receiving: BigInt.zero,
      sending: BigInt.zero,
      maturing: BigInt.zero,
      change: BigInt.zero,
    );
  }

  /// Every asset's totals, for `WalletInfoKeys.beamAssetTotals`.
  static Map<String, Map<String, String>> assetTotalsJson(
    BeamWalletStatus status,
  ) {
    final out = <String, Map<String, String>>{
      '0': totalsFor(status, 0).toJson(),
    };
    for (final t in status.totals) {
      out['${t.assetId}'] = BeamCachedAssetTotals.fromTotals(t).toJson();
    }
    return out;
  }

  /// Parses [assetTotalsJson] output back; unreadable entries are skipped.
  static Map<int, BeamCachedAssetTotals> parseAssetTotals(Object? json) {
    final out = <int, BeamCachedAssetTotals>{};
    if (json is! Map) return out;
    for (final entry in json.entries) {
      final id = int.tryParse('${entry.key}');
      if (id == null) continue;
      try {
        out[id] = BeamCachedAssetTotals.fromJson(id, entry.value);
      } on FormatException {
        continue;
      }
    }
    return out;
  }
}

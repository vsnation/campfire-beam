/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import 'beam_json.dart';

/// `wallet_status` (API 6.1+).
///
/// [isInSync] is the core's own opinion: the last processed block is less
/// than 10 minutes old. It knows nothing about forks, so it is one input to
/// the sync decision, never the decision itself.
@immutable
class BeamWalletStatus {
  const BeamWalletStatus({
    required this.currentHeight,
    required this.currentStateHash,
    required this.currentStateTimestamp,
    required this.prevStateHash,
    required this.isInSync,
    required this.available,
    required this.receiving,
    required this.sending,
    required this.maturing,
    required this.difficulty,
    required this.totals,
  });

  factory BeamWalletStatus.fromJson(Map<String, Object?> json) =>
      BeamWalletStatus(
        currentHeight: BeamJson.integer(json, 'current_height'),
        currentStateHash: BeamJson.string(json, 'current_state_hash'),
        currentStateTimestamp: BeamJson.integer(
          json,
          'current_state_timestamp',
        ),
        prevStateHash: BeamJson.string(json, 'prev_state_hash'),
        isInSync: BeamJson.boolean(json, 'is_in_sync'),
        available: BeamJson.optAmount(json, 'available'),
        receiving: BeamJson.optAmount(json, 'receiving'),
        sending: BeamJson.optAmount(json, 'sending'),
        maturing: BeamJson.optAmount(json, 'maturing'),
        difficulty: BeamJson.optDouble(json, 'difficulty'),
        totals: List.unmodifiable(
          json['totals'] == null
              ? const <BeamAssetTotals>[]
              : BeamJson.mapList(
                  json['totals'],
                  'totals',
                ).map(BeamAssetTotals.fromJson),
        ),
      );

  /// The last fully processed block, not the header tip (the tip arrives in
  /// `ev_system_state` / `ev_sync_progress`).
  final int currentHeight;
  final String currentStateHash;

  /// Unix seconds of [currentHeight]'s block.
  final int currentStateTimestamp;
  final String prevStateHash;
  final bool isInSync;

  /// BEAM only, regular and shielded summed. Null when the core leaves the
  /// field out (it does for app-scoped API instances).
  final BigInt? available;
  final BigInt? receiving;
  final BigInt? sending;
  final BigInt? maturing;
  final double? difficulty;

  /// One entry per asset the wallet has seen. Empty when Confidential Assets
  /// are disabled.
  final List<BeamAssetTotals> totals;

  DateTime get currentStateTime => BeamJson.unixSeconds(currentStateTimestamp);

  BeamAssetTotals? totalsFor(int assetId) {
    for (final t in totals) {
      if (t.assetId == assetId) return t;
    }
    return null;
  }
}

/// One asset's balance, split into regular (MW) and shielded (`_mp`, max
/// privacy) coins. All amounts are in the asset's smallest unit.
@immutable
class BeamAssetTotals {
  const BeamAssetTotals({
    required this.assetId,
    required this.available,
    required this.availableRegular,
    required this.availableMp,
    required this.receiving,
    required this.receivingRegular,
    required this.receivingMp,
    required this.sending,
    required this.sendingRegular,
    required this.sendingMp,
    required this.maturing,
    required this.maturingRegular,
    required this.maturingMp,
    required this.change,
    required this.locked,
  });

  factory BeamAssetTotals.fromJson(Map<String, Object?> json) {
    // The core always writes all fifteen `_str` fields; a missing one is a
    // shape change, not a zero balance.
    BigInt a(String key) => BeamJson.amount(json, key);
    return BeamAssetTotals(
      assetId: BeamJson.integer(json, 'asset_id'),
      available: a('available'),
      availableRegular: a('available_regular'),
      availableMp: a('available_mp'),
      receiving: a('receiving'),
      receivingRegular: a('receiving_regular'),
      receivingMp: a('receiving_mp'),
      sending: a('sending'),
      sendingRegular: a('sending_regular'),
      sendingMp: a('sending_mp'),
      maturing: a('maturing'),
      maturingRegular: a('maturing_regular'),
      maturingMp: a('maturing_mp'),
      change: a('change'),
      locked: a('locked'),
    );
  }

  final int assetId;
  final BigInt available;
  final BigInt availableRegular;
  final BigInt availableMp;
  final BigInt receiving;
  final BigInt receivingRegular;
  final BigInt receivingMp;
  final BigInt sending;
  final BigInt sendingRegular;
  final BigInt sendingMp;
  final BigInt maturing;
  final BigInt maturingRegular;
  final BigInt maturingMp;

  /// Change returning to the wallet from outgoing transactions.
  final BigInt change;
  final BigInt locked;
}

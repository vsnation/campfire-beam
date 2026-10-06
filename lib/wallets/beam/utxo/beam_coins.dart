/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../models/beam_utxo.dart';

/// Fee rules after HF3 (`core/block_crypt.cpp:1707-1709`): 18,000 groth per
/// output, 10,000 per kernel, and at least 100,000 ("exactly covers 5
/// outputs + 1 kernel").
abstract final class BeamFees {
  static final BigInt perOutput = BigInt.from(18000);
  static final BigInt perKernel = BigInt.from(10000);
  static final BigInt minimum = BigInt.from(100000);

  /// The fee the core asks for a `tx_split` of [coins] outputs
  /// (`v6_api_parse.cpp:656-662`): one more output for BEAM change, and one
  /// more for asset change when splitting a Confidential Asset.
  static BigInt forSplit(int coins, {bool asset = false}) {
    final outputs = coins + 1 + (asset ? 1 : 0);
    final fee = perKernel + perOutput * BigInt.from(outputs);
    return fee > minimum ? fee : minimum;
  }
}

/// One asset's coins, as the coin view and the send screen need them.
class BeamCoinSummary {
  BeamCoinSummary._(this.assetId, this.available, this.locked);

  /// Groups [utxos] per asset. Spent and consumed coins are left out.
  static Map<int, BeamCoinSummary> of(Iterable<BeamUtxo> utxos) {
    final available = <int, List<BeamUtxo>>{};
    final locked = <int, List<BeamUtxo>>{};
    for (final u in utxos) {
      switch (u.status) {
        case BeamUtxoStatus.available:
          (available[u.assetId] ??= []).add(u);
        case BeamUtxoStatus.maturing ||
            BeamUtxoStatus.incoming ||
            BeamUtxoStatus.outgoing ||
            BeamUtxoStatus.unavailable:
          (locked[u.assetId] ??= []).add(u);
        case BeamUtxoStatus.spent ||
            BeamUtxoStatus.consumed ||
            BeamUtxoStatus.unknown:
          break;
      }
    }
    return {
      for (final aid in {...available.keys, ...locked.keys})
        aid: BeamCoinSummary._(
          aid,
          List.unmodifiable(
            (available[aid] ?? <BeamUtxo>[])
              ..sort((a, b) => b.amount.compareTo(a.amount)),
          ),
          List.unmodifiable(locked[aid] ?? const <BeamUtxo>[]),
        ),
    };
  }

  final int assetId;

  /// Spendable now, largest first.
  final List<BeamUtxo> available;

  /// Waiting to mature, or tied up in a transaction that has not finished.
  final List<BeamUtxo> locked;

  BigInt get availableTotal =>
      available.fold(BigInt.zero, (sum, u) => sum + u.amount);

  BigInt get lockedTotal =>
      locked.fold(BigInt.zero, (sum, u) => sum + u.amount);

  /// How many sends can be in flight at once: each one locks at least one
  /// coin until its change comes back. A wallet with one big coin can only
  /// run one payment at a time, which is what "Split" fixes.
  int get parallelSends => available.length;

  int get shieldedCount => available.where((u) => u.isShielded).length;
}

/// A `tx_split` the coin view proposes: [count] coins of [size] each.
class BeamSplitPlan {
  BeamSplitPlan._(this.assetId, this.size, this.count, this.fee);

  /// Splits most of [available] into [count] equal coins, keeping enough
  /// back for the fee (BEAM) and leaving the rest as change. Returns null
  /// when the coins would be too small to be worth it: each must be worth
  /// more than a plain send's fee, or spending it costs more than it holds.
  static BeamSplitPlan? equal({
    required BigInt available,
    required int count,
    int assetId = 0,
  }) {
    if (count < 2 || count > maxCoins) return null;
    final asset = assetId != 0;
    final fee = BeamFees.forSplit(count, asset: asset);
    final budget = asset ? available : available - fee;
    if (budget <= BigInt.zero) return null;
    final size =
        budget * BigInt.from(9) ~/ BigInt.from(10) ~/ BigInt.from(count);
    if (!asset && size <= BeamFees.minimum) return null;
    if (size <= BigInt.zero) return null;
    return BeamSplitPlan._(assetId, size, count, fee);
  }

  /// More outputs make one transaction slow to build and verify; split in
  /// rounds beyond this.
  static const int maxCoins = 50;

  final int assetId;
  final BigInt size;
  final int count;

  /// Network fee in groth, always paid in BEAM.
  final BigInt fee;

  List<BigInt> get coins => List.filled(count, size);

  BigInt get total => size * BigInt.from(count);
}

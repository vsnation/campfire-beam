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
///
/// Checked against tag beam-7.5.14493: `tx_split` refuses a fee below
/// `max(kernel + output * (coins + 1 [+ 1 for an asset]), default)`
/// (`v6_api_parse.cpp:656-662`), and the builder's own check
/// (`BaseTxBuilder::CheckMinimumFee`, `base_tx_builder.cpp:916`) counts the
/// same outputs: the new coins plus one change coin per asset that has
/// change. Shielded inputs add nothing after HF3 (`m_ShieldedInputTotal`
/// is 0), so the figure holds whichever coins the core picks.
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

  /// An asset the wallet holds no coin of.
  factory BeamCoinSummary.empty(int assetId) =>
      BeamCoinSummary._(assetId, const [], const []);

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

  /// Spendable coins worth more than a send's fee, largest first. Smaller
  /// ones ("dust") cost more to spend than they hold, so they never count
  /// as a coin a payment could use.
  List<BeamUtxo> get usable =>
      available.where((u) => u.amount > BeamFees.minimum).toList();

  BigInt get usableTotal =>
      usable.fold(BigInt.zero, (sum, u) => sum + u.amount);

  /// The largest usable coin's share of [usableTotal], 0 to 1 (0 when
  /// there is none).
  double get largestShare {
    final coins = usable;
    if (coins.isEmpty) return 0;
    final total = usableTotal;
    return coins.first.amount / total;
  }

  /// Whether splitting would help, and into how many coins.
  BeamSplitAdvice get advice => BeamSplitAdvice.of(this);
}

/// How much splitting would help.
enum BeamSplitUrgency {
  /// The coins are spread well enough, or there is too little to split.
  none,

  /// Most of the balance sits in one coin: worth splitting.
  worthIt,

  /// Everything usable is one coin: a payment locks the whole balance until
  /// it is confirmed, so nothing else can be sent meanwhile.
  needed,
}

/// Whether one asset's coins are worth splitting, and into how many: BEAM
/// Light Wallet's thresholds (`analyzeUtxos`, app.js), with coins that
/// cannot pay a fee left out.
///
/// * one usable coin: [BeamSplitUrgency.needed], 3 to 10 coins, one per
///   10 whole units (LW also called it critical when the largest coin held
///   over 90 % and the rest could not pay one fee; with dust left out that
///   is the same case);
/// * two coins, the larger holding over 80 %: [BeamSplitUrgency.worthIt],
///   4 coins;
/// * the largest coin holding over 90 %: [BeamSplitUrgency.worthIt], 3.
///
/// The count is lowered until [BeamSplitPlan.equal] accepts it (each new
/// coin must be worth more than a send's fee); when no count works there is
/// nothing to advise.
class BeamSplitAdvice {
  const BeamSplitAdvice._(this.urgency, this.suggestedCount);

  static const none = BeamSplitAdvice._(BeamSplitUrgency.none, 0);

  static BeamSplitAdvice of(BeamCoinSummary coins) {
    final usable = coins.usable;
    if (usable.isEmpty) return none;
    final total = coins.usableTotal;
    final share = coins.largestShare;
    final BeamSplitUrgency urgency;
    final int count;
    if (usable.length == 1) {
      urgency = BeamSplitUrgency.needed;
      count = bySize(total);
    } else if (usable.length == 2 && share > 0.8) {
      urgency = BeamSplitUrgency.worthIt;
      count = 4;
    } else if (share > 0.9) {
      urgency = BeamSplitUrgency.worthIt;
      count = 3;
    } else {
      return none;
    }
    for (var n = count; n >= 2; n--) {
      final plan = BeamSplitPlan.equal(
        available: coins.availableTotal,
        count: n,
        assetId: coins.assetId,
      );
      if (plan != null) return BeamSplitAdvice._(urgency, n);
    }
    return none;
  }

  /// One new coin per 10 whole units (BEAM or an asset: every one has 8
  /// decimals), at least 3 and at most 10.
  static int bySize(BigInt total) {
    final ten = BigInt.from(10) * BigInt.from(10).pow(8);
    final n = ((total + ten - BigInt.one) ~/ ten).toInt();
    return n.clamp(3, 10);
  }

  final BeamSplitUrgency urgency;

  /// 0 when [urgency] is [BeamSplitUrgency.none].
  final int suggestedCount;

  bool get isNeeded => urgency == BeamSplitUrgency.needed;
}

/// A `tx_split` the coin view proposes: [count] coins of [size] each.
class BeamSplitPlan {
  BeamSplitPlan._(
    this.assetId,
    this.size,
    this.count,
    this.fee,
    this.available,
  );

  /// Splits most of [available] into [count] equal coins, keeping enough
  /// back for the fee (BEAM) and leaving the rest as change. Returns null
  /// when the coins would be too small to be worth it: each must be worth
  /// more than a plain send's fee, or spending it costs more than it holds.
  ///
  /// 90 % of what is left after the fee is split, each coin rounded down to
  /// two significant digits ("5 coins of 0.17 BEAM", not 0.1799991), so the
  /// new coins read the way people count; the rest stays as one change
  /// coin, which can pay too.
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
    final raw =
        budget * BigInt.from(9) ~/ BigInt.from(10) ~/ BigInt.from(count);
    final round = roundDown(raw);
    return sized(
          available: available,
          count: count,
          size: round,
          assetId: assetId,
        ) ??
        sized(available: available, count: count, size: raw, assetId: assetId);
  }

  /// [count] coins of exactly [size] from [available]; null when that is not
  /// a split the core would accept and a person would want: fewer than 2 or
  /// more than [maxCoins] coins, BEAM coins not worth more than a send's
  /// fee, or more than [available] (with the fee, for BEAM).
  static BeamSplitPlan? sized({
    required BigInt available,
    required int count,
    required BigInt size,
    int assetId = 0,
  }) {
    if (count < 2 || count > maxCoins) return null;
    if (size <= BigInt.zero) return null;
    final asset = assetId != 0;
    if (!asset && size <= BeamFees.minimum) return null;
    final fee = BeamFees.forSplit(count, asset: asset);
    final total = size * BigInt.from(count);
    if (total + (asset ? BigInt.zero : fee) > available) return null;
    return BeamSplitPlan._(assetId, size, count, fee, available);
  }

  /// [units] rounded down to two significant digits (17,999,910 →
  /// 17,000,000).
  static BigInt roundDown(BigInt units) {
    if (units < BigInt.from(100)) return units;
    final digits = units.toString().length;
    final step = BigInt.from(10).pow(digits - 2);
    return units ~/ step * step;
  }

  /// More outputs make one transaction slow to build and verify; split in
  /// rounds beyond this.
  static const int maxCoins = 50;

  /// The counts the split screen offers (BEAM Light Wallet's presets).
  static const List<int> presets = [2, 3, 5, 8, 10];

  /// [presets] plus [suggested] when it is not one of them, in order.
  static List<int> choices(int suggested) => [
    ...{...presets, if (suggested >= 2 && suggested <= maxCoins) suggested},
  ]..sort();

  final int assetId;
  final BigInt size;
  final int count;

  /// Network fee in groth, always paid in BEAM.
  final BigInt fee;

  /// What was spendable when the plan was made.
  final BigInt available;

  List<BigInt> get coins => List.filled(count, size);

  BigInt get total => size * BigInt.from(count);

  /// What stays as one change coin: the rest of [available], less the fee
  /// when it is paid from the same asset (BEAM).
  BigInt get change => available - total - (assetId == 0 ? fee : BigInt.zero);

  @override
  bool operator ==(Object other) =>
      other is BeamSplitPlan &&
      other.assetId == assetId &&
      other.size == size &&
      other.count == count &&
      other.fee == fee &&
      other.available == available;

  @override
  int get hashCode => Object.hash(assetId, size, count, fee, available);
}

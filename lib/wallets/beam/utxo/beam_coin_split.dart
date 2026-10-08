/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../models/beam_utxo.dart';
import 'beam_coins.dart';

/// A split on its review screen: checked against the wallet's coins a
/// moment ago, holding the wallet's node switch (`BeamWallet.prepareSplit`)
/// until it is sent or [discard]ed.
///
/// A prepared split reaches the core at most once: once handed over, its tx
/// id is kept ([handedOff]) and any later confirm only looks it up.
class BeamPreparedSplit {
  BeamPreparedSplit({
    required this.plan,
    required this.before,
    required this.beamAvailable,
    this._onDiscard,
  });

  final BeamSplitPlan plan;

  /// The asset's coins when the split was prepared.
  final BeamCoinSummary before;

  /// Spendable BEAM, which pays the fee.
  final BigInt beamAvailable;

  final void Function()? _onDiscard;

  /// The tx id the core was given, once it was; null again when the core
  /// plainly refused it (nothing started, so it may be tried again).
  String? handedOff;

  bool _discarded = false;

  bool get isDiscarded => _discarded;

  /// Lets the node switch go. Harmless twice.
  void discard() {
    if (_discarded) return;
    _discarded = true;
    _onDiscard?.call();
  }
}

/// Why a split cannot start now and what happens next, in plain words.
abstract final class BeamSplitMessages {
  /// What the wallet's open money flows are, from their gate reasons.
  static String busy(Iterable<String> reasons) {
    final r = reasons.toSet();
    final String what;
    if (r.any((x) => x.contains('swap'))) {
      what = 'A swap is still being confirmed';
    } else if (r.any((x) => x.contains('claim'))) {
      what = 'Name payments are being claimed';
    } else if (r.any((x) => x.contains('dApp'))) {
      what = 'A dApp is waiting for your approval';
    } else if (r.any((x) => x.contains('split'))) {
      what = 'Another split is on its way';
    } else {
      what = 'A payment is being prepared or sent';
    }
    return '$what. Splitting turns back on by itself once it is done, '
        'usually within a few minutes.';
  }

  static const scanning =
      'Campfire is still looking for this wallet\'s coins after the restore. '
      'Splitting turns on by itself once the scan is done; the wallet home '
      'shows how far it is.';

  static const poolShare =
      'Pool shares are not split: they go back to their pool as a whole.';

  static const notPrepared =
      'This split was not prepared. Go back and review it again.';

  static const tooLittle =
      'There is not enough here to split: each new coin has to be worth more '
      'than the 0.001 BEAM a payment costs.';

  static String changed() =>
      'Your coins changed since this split was prepared. Go back and review '
      'it again.';

  static String needBeamForFee(BigInt fee, BigInt beam) =>
      'Splitting costs a ${_beam(fee)} network fee, paid in BEAM, and this '
      'wallet has ${_beam(beam)} available. Add at least '
      '${_beam(fee - beam)} first.';

  static const outcomeUnknown =
      "The connection dropped while splitting, so it's not certain whether "
      'the split started. Check your transaction history before trying '
      'again.';

  static const alreadyHandedOff =
      'This split was already handed to the wallet. Check your transaction '
      'history before trying again.';

  /// "0.005 BEAM": trailing zeros dropped, at least one decimal place.
  static String _beam(BigInt groth) {
    final unit = BigInt.from(10).pow(8);
    final whole = groth ~/ unit;
    var frac = (groth % unit).toString().padLeft(8, '0');
    frac = frac.replaceFirst(RegExp(r'0+$'), '');
    if (frac.isEmpty) frac = '0';
    return '$whole.$frac BEAM';
  }
}

/// Reads every `get_utxo` page (the core returns spent coins too, so a
/// long-lived wallet can have thousands) through [page], [pageSize] coins at
/// a time, without counting a coin twice if the list moves under the read.
Future<List<BeamUtxo>> beamReadAllCoins(
  Future<List<BeamUtxo>> Function(int skip, int count) page, {
  int pageSize = 500,
  int maxPages = 200,
}) async {
  final seen = <String>{};
  final out = <BeamUtxo>[];
  for (var i = 0; i < maxPages; i++) {
    final batch = await page(i * pageSize, pageSize);
    for (final u in batch) {
      if (seen.add('${u.type}:${u.id}')) out.add(u);
    }
    if (batch.length < pageSize) break;
  }
  return out;
}

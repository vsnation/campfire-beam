/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../wallets/beam/utxo/beam_coins.dart';
import '../airdrop/beam_units.dart';

/// Everything the Split coins screens say, in plain words: no widget code,
/// so each sentence can be tested on its own. "Coins" is BEAM's own word
/// for what a balance is made of; the technical name stays out.
abstract final class BeamSplitText {
  static const title = 'Split coins';
  static const reviewTitle = 'Review split';

  static const headline = 'Send several payments at once';

  /// The why, in one breath, with the reassurance that matters most.
  static const intro =
      'Each payment ties up a coin for about a minute. With more coins, '
      'several can go at once. Nothing leaves your wallet.';

  /// "1.2345 BEAM in 1 coin: one payment at a time".
  static String now(BeamCoinSummary coins, String symbol) {
    final n = coins.available.length;
    final total = BeamUnits.withSymbol(coins.availableTotal, symbol);
    if (n == 0) return 'Nothing to split yet';
    if (n == 1) return '$total in 1 coin: one payment at a time';
    final share = (coins.largestShare * 100).round();
    return '$total in $n coins; the largest holds $share%';
  }

  /// When the coins are already spread out.
  static String spreadWell(int coins) =>
      'Your coins are already spread out: up to $coins payments can go at '
      'once. You can still split for more.';

  static const countLabel = 'Split into';

  /// "5 coins of 0.17 BEAM".
  static String newCoins(BeamSplitPlan plan, String symbol) =>
      '${plan.count} coins of ${BeamUnits.withSymbol(plan.size, symbol)}';

  /// The primary button, the outcome: "Split into 5 coins".
  static String cta(int count) => 'Split into $count coins';

  static String fee(BeamSplitPlan plan) =>
      BeamUnits.withSymbol(plan.fee, 'BEAM');

  /// What the review's last line says left the wallet: the fee alone.
  static String leaves(BeamSplitPlan plan) => fee(plan);

  /// "Nothing leaves your wallet" in full, for the review.
  static String reviewNote(String symbol, {required bool asset}) =>
      'Your $symbol is split into new coins in this same wallet. You pay '
      'only the network fee${asset ? ', in BEAM' : ''}.';

  static String noCoins(String symbol) =>
      'This wallet has no $symbol it can spend right now. Coins that arrive '
      'or come back from a payment show up here.';

  static const tooLittle =
      'There is too little here to split: each new coin has to be worth more '
      'than the 0.001 BEAM a payment costs.';

  /// An asset split when the BEAM balance cannot pay its fee.
  static String needBeam(BigInt fee, BigInt beam) =>
      'Splitting costs a ${BeamUnits.withSymbol(fee, 'BEAM')} network fee, '
      'paid in BEAM, and this wallet has '
      '${BeamUnits.withSymbol(beam, 'BEAM')} available. Add BEAM first.';

  /// The biometric prompt's reason.
  static String authReason(BeamSplitPlan plan, String symbol) =>
      'Split ${BeamUnits.withSymbol(plan.total, symbol)} into '
      '${plan.count} coins';

  static String doneTitle(int count) => 'Splitting into $count coins';

  static const doneMessage =
      'The new coins are ready in about a minute, once the network confirms '
      'the split. Until then the coins being split are busy. Your history '
      'shows it as "Splitting coins".';
}

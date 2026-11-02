/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../l10n/l10n.dart';
import '../../../wallets/beam/utxo/beam_coins.dart';
import '../airdrop/beam_units.dart';

/// Everything the Split coins screens say, in plain words: no widget code,
/// so each sentence can be tested on its own. "Coins" is BEAM's own word
/// for what a balance is made of; the technical name stays out. The text is
/// in lib/l10n/app_en.arb (split* keys), in the language the app speaks.
abstract final class BeamSplitText {
  static String get title => appL10n.splitTitle;
  static String get reviewTitle => appL10n.splitReviewTitle;

  static String get headline => appL10n.splitHeadline;

  /// The why, in one breath, with the reassurance that matters most.
  static String get intro => appL10n.splitIntro;

  /// "1.2345 BEAM in 1 coin: one payment at a time".
  static String now(BeamCoinSummary coins, String symbol, {int? places}) {
    final n = coins.available.length;
    final total = BeamUnits.withSymbol(
      coins.availableTotal,
      symbol,
      places: places,
    );
    if (n == 0) return appL10n.splitNowNothing;
    if (n == 1) return appL10n.splitNowOneCoin(total);
    final share = (coins.largestShare * 100).round();
    return appL10n.splitNowCoins(n, total, share);
  }

  /// When the coins are already spread out.
  static String spreadWell(int coins) => appL10n.splitSpreadWell(coins);

  static String get countLabel => appL10n.splitCountLabel;

  /// "5 coins of 0.17 BEAM".
  static String newCoins(BeamSplitPlan plan, String symbol, {int? places}) =>
      appL10n.splitNewCoins(
        plan.count,
        BeamUnits.withSymbol(plan.size, symbol, places: places),
      );

  /// The primary button, the outcome: "Split into 5 coins".
  static String cta(int count) => appL10n.splitCta(count);

  static String fee(BeamSplitPlan plan) =>
      BeamUnits.withSymbol(plan.fee, 'BEAM');

  /// What the review's last line says left the wallet: the fee alone.
  static String leaves(BeamSplitPlan plan) => fee(plan);

  /// "Nothing leaves your wallet" in full, for the review.
  static String reviewNote(String symbol, {required bool asset}) => asset
      ? appL10n.splitReviewNoteAsset(symbol)
      : appL10n.splitReviewNote(symbol);

  static String noCoins(String symbol) => appL10n.splitNoCoins(symbol);

  static String get tooLittle => appL10n.splitTooLittle;

  /// An asset split when the BEAM balance cannot pay its fee.
  static String needBeam(BigInt fee, BigInt beam) => appL10n.splitNeedBeam(
    BeamUnits.withSymbol(fee, 'BEAM'),
    BeamUnits.withSymbol(beam, 'BEAM'),
  );

  /// The biometric prompt's reason.
  static String authReason(BeamSplitPlan plan, String symbol, {int? places}) =>
      appL10n.splitAuthReason(
        plan.count,
        BeamUnits.withSymbol(plan.total, symbol, places: places),
      );

  static String doneTitle(int count) => appL10n.splitDoneTitle(count);

  static String get doneMessage => appL10n.splitDoneMessage;
}

/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What the Buy BEAM screens say: dollars and BEAM the way people read
// them, how long a buy usually takes, the smallest buy in the coin being
// paid with, and every way buybeam.my can say no, in plain words, never
// the user's fault, each with the one thing that fixes it.

import 'dart:math' as math;

import '../../../wallets/beam/buy/buybeam_client.dart';
import '../../../wallets/beam/buy/buybeam_order.dart';
import '../../eth/uniswap/uniswap_format.dart';

/// The one thing that fixes a problem.
enum BuyFix {
  /// Put the smallest buy in the amount field.
  useMinimum,

  /// Change the amount.
  editAmount,

  /// Pick another coin.
  pickCoin,

  /// Change the refund address.
  editRefund,

  /// Ask again.
  tryAgain,

  /// Open buybeam.my's support.
  contactSupport,
}

class BuyProblem {
  const BuyProblem({
    required this.title,
    this.detail,
    this.fix,
    this.fixLabel,
    this.serious = false,
  });

  final String title;
  final String? detail;
  final BuyFix? fix;
  final String? fixLabel;

  /// An error colour rather than a warning one.
  final bool serious;
}

abstract final class BuyBeamWords {
  /// "$1,000", "$1,497.27", "$5".
  static String usd(double v) {
    final whole = v >= 1000 || v == v.roundToDouble();
    final cents = (v * 100).round();
    final dollars = whole ? (v.round()) : cents ~/ 100;
    final g = UniFormat.exact(BigInt.from(dollars), 0);
    if (whole) return '\$$g';
    return '\$$g.${(cents % 100).toString().padLeft(2, '0')}';
  }

  /// "166,888.69 BEAM" from groth.
  static String beam(BigInt groth) => '${UniFormat.compact(groth, 8)} BEAM';

  /// "111,326 BEAM": whole BEAM from a thousand up, for a list.
  static String beamShort(double beam) => beam >= 1000
      ? '${UniFormat.exact(BigInt.from(beam.floor()), 0)} BEAM'
      : BuyBeamWords.beam(groth(beam));

  /// The estimate buybeam.my gave, in groth.
  static BigInt groth(double beam) => BigInt.from((beam * 1e8).round());

  /// "0.0123 BTC" exactly as it must be sent.
  static String coin(String amount, String symbol) => '$amount $symbol';

  /// "Usually done in about 14 minutes" (rounded up; "a few minutes"
  /// under three).
  static String eta(int seconds) {
    final minutes = (seconds / 60).ceil();
    if (minutes < 3) return 'Usually done in a few minutes';
    if (minutes < 90) return 'Usually done in about $minutes minutes';
    final hours = (minutes / 60).ceil();
    return 'Usually done in about $hours hours';
  }

  /// The amount of [asset] worth at least [minimumUsd] (a little over, so
  /// a moving price does not put it back under), rounded up to three
  /// significant digits; null without a price.
  static String? minimumAmount(
    double minimumUsd,
    BuyBeamAsset asset, {
    double? priceUsd,
  }) {
    final price = priceUsd ?? asset.priceUsd;
    if (price == null || price <= 0 || minimumUsd <= 0) return null;
    final value = minimumUsd * 1.005 / price;
    final exponent = (math.log(value) / math.ln10).floor();
    final maxPlaces = BuyBeamAmount.maxFractionDigits(asset.decimals);
    var places = math.max(0, 2 - exponent);
    if (places > maxPlaces) places = maxPlaces;
    final step = math.pow(10, -places).toDouble();
    var units = (value / step).ceil();
    for (var i = 0; i < 20; i++, units++) {
      final text = (units * step).toStringAsFixed(places);
      final a = BuyBeamAmount.parse(text, decimals: asset.decimals).amount;
      if (a != null && a.isPositive && a.exact) return a.text;
    }
    return null;
  }

  /// [e] as the form shows it. [minimum]: the smallest buy in the coin
  /// ("0.0122"), when it could be worked out.
  static BuyProblem problem(
    BuyBeamError e, {
    required BuyBeamAsset coin,
    String? minimum,
    bool tor = false,
  }) {
    final sym = coin.symbol;
    switch (e.code) {
      case BuyBeamErrorCode.amountBelowUpstreamMinimum:
      case BuyBeamErrorCode.amountBelowOurMinimum:
        final usdText = e.minimumUsd == null ? null : usd(e.minimumUsd!);
        if (minimum != null) {
          return BuyProblem(
            title:
                'Buy at least $minimum $sym'
                '${usdText == null ? '' : ' ($usdText)'}',
            detail:
                "That's the smallest buy buybeam.my can do right now. "
                'Nothing was sent.',
            fix: BuyFix.useMinimum,
            fixLabel: 'Use $minimum $sym',
          );
        }
        return BuyProblem(
          title: usdText == null
              ? 'This is under the smallest buy'
              : 'Buy at least $usdText of $sym',
          detail:
              "That's the smallest buy buybeam.my can do right now. "
              'Nothing was sent.',
          fix: BuyFix.editAmount,
          fixLabel: 'Change the amount',
        );
      case BuyBeamErrorCode.badAmount:
      case BuyBeamErrorCode.amountTooSmall:
        return BuyProblem(
          title: "buybeam.my can't use this amount of $sym",
          detail: 'It is too small to send. Nothing was sent.',
          fix: BuyFix.editAmount,
          fixLabel: 'Change the amount',
        );
      case BuyBeamErrorCode.unknownAsset:
        return BuyProblem(
          title: 'buybeam.my no longer takes $sym on ${coin.chainName}',
          detail: 'Pick another coin. Nothing was sent.',
          fix: BuyFix.pickCoin,
          fixLabel: 'Pick another coin',
        );
      case BuyBeamErrorCode.assetUnavailable:
        return BuyProblem(
          title: "$sym on ${coin.chainName} can't be used right now",
          detail:
              'buybeam.my has paused it for a while. Pick another coin, or '
              'try again later. Nothing was sent.',
          fix: BuyFix.pickCoin,
          fixLabel: 'Pick another coin',
        );
      case BuyBeamErrorCode.noLiquidity:
        return BuyProblem(
          title: "buybeam.my can't take this much $sym right now",
          detail: 'Try a smaller amount or another coin. Nothing was sent.',
          fix: BuyFix.editAmount,
          fixLabel: 'Change the amount',
        );
      case BuyBeamErrorCode.refundAddressRequired:
        return BuyProblem(
          title: 'Add your ${coin.chainName} address',
          detail:
              'Your $sym goes back there if the buy can\'t go through. '
              'Nothing was sent.',
          fix: BuyFix.editRefund,
          fixLabel: 'Add the address',
        );
      case BuyBeamErrorCode.beamWalletRequired:
      case BuyBeamErrorCode.beamWalletTooShort:
      case BuyBeamErrorCode.beamWalletTooLong:
      case BuyBeamErrorCode.beamWalletInvalid:
        return const BuyProblem(
          title: "buybeam.my didn't take your wallet's new BEAM address",
          detail:
              'This is not something you did. Nothing was sent. Try again: '
              'Campfire makes another one.',
          fix: BuyFix.tryAgain,
          fixLabel: 'Try again',
        );
      case BuyBeamErrorCode.assetIdRequired:
      case BuyBeamErrorCode.badBody:
        return const BuyProblem(
          title: "buybeam.my couldn't read Campfire's request",
          detail: 'This is not something you did. Nothing was sent.',
          fix: BuyFix.tryAgain,
          fixLabel: 'Try again',
        );
      case BuyBeamErrorCode.orderNotFound:
        return const BuyProblem(
          title: "buybeam.my can't find this buy",
          detail:
              'If you already paid, contact buybeam.my support with the '
              'deposit address.',
          fix: BuyFix.contactSupport,
          fixLabel: 'Contact buybeam.my support',
          serious: true,
        );
      case BuyBeamErrorCode.priceUnavailable:
      case BuyBeamErrorCode.upstreamAbsent:
      case BuyBeamErrorCode.upstreamUnavailable:
      case BuyBeamErrorCode.quoteFailed:
        return BuyProblem(
          title: "buybeam.my can't price this right now",
          detail:
              'This is not something you did, and nothing was sent. '
              '${_later(e.retryAfter)}',
          fix: BuyFix.tryAgain,
          fixLabel: 'Try again',
        );
      case BuyBeamErrorCode.noDepositAddress:
        return const BuyProblem(
          title: "buybeam.my didn't give a deposit address",
          detail: 'Nothing to pay, and nothing was sent. Try again.',
          fix: BuyFix.tryAgain,
          fixLabel: 'Try again',
        );
      case BuyBeamErrorCode.blocked:
      case BuyBeamErrorCode.network:
        final server = (e.httpStatus ?? 0) >= 500;
        return BuyProblem(
          title: "Couldn't reach buybeam.my",
          detail: [
            'Nothing was sent.',
            if (server && !coin.isEvm)
              'If it keeps happening, check that your ${coin.chainName} '
                  'address is right.',
            if (tor) 'If Tor is on, a new connection usually helps.',
          ].join(' '),
          fix: BuyFix.tryAgain,
          fixLabel: 'Try again',
        );
      case BuyBeamErrorCode.unexpectedAnswer:
        return const BuyProblem(
          title:
              "buybeam.my sent an answer Campfire didn't expect. Nothing to "
              'pay.',
          detail: 'This is not something you did. Try again in a moment.',
          fix: BuyFix.tryAgain,
          fixLabel: 'Try again',
          serious: true,
        );
      case BuyBeamErrorCode.unknown:
        return const BuyProblem(
          title: "buybeam.my couldn't do this buy",
          detail: 'Nothing was sent. Try again, or pick another coin.',
          fix: BuyFix.tryAgain,
          fixLabel: 'Try again',
        );
    }
  }

  static String _later(Duration? after) {
    if (after == null || after.inSeconds < 5) return 'Try again in a moment.';
    if (after.inSeconds < 90) {
      return 'Try again in ${after.inSeconds} seconds.';
    }
    return 'Try again in ${(after.inSeconds / 60).ceil()} minutes.';
  }

  /// One line for a buy in a list: where it is, in plain words.
  static String stateLine(BuyBeamOrder o) => switch (o.lastState) {
    null || BuyBeamState.awaitingDeposit => 'Waiting for your payment',
    BuyBeamState.depositDetected => 'Payment received',
    BuyBeamState.sending => 'Sending BEAM to your wallet',
    BuyBeamState.delivered => 'BEAM sent to your wallet',
    BuyBeamState.refunded => 'Sent back to you',
    BuyBeamState.expired => 'No payment arrived in time',
    BuyBeamState.failed => "The payment couldn't be processed",
    BuyBeamState.attention => 'buybeam.my is checking it',
    BuyBeamState.swapping ||
    BuyBeamState.buying ||
    BuyBeamState.processing ||
    BuyBeamState.inProgress => 'Buying your BEAM',
  };
}

/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// The Beam girl: Campfire for BEAM's character, in place of Firo's Sparky.
/// Static stickers are bundled WebP (512 px); see [BeamMoments] for which one
/// goes where, so every screen uses her the same way.
enum BeamSticker {
  hi,
  welcome,
  thumbsUp,
  yes,
  success,
  greatNews,
  dontTalk,
  thankYou,
  love,
  lowBattery,
  really,
  wow,
  fullPower,
  sad,
  ok,
  sendMeBeams,
  sendingBeams,
  receivingBeams,
  receivedBeams,
  tradingBeam,
  beamMeUp,
  recharging,
  hurryUp,
  bravo,
  goodMorning,
  goodNight,
  toTheMoon,
  upgrade;

  String get asset => 'assets/beam/stickers/static/${_snake(name)}.webp';
}

/// Animated stickers (Telegram `.tgs`: gzipped Lottie, 512 px, 3 s).
enum BeamAnimatedSticker {
  diamonds,
  love,
  greatNews,
  thumbsUp,
  hiFive;

  String get asset => 'assets/beam/stickers/animated/${_snake(name)}.tgs';

  /// The static sticker shown instead when the system asks for less motion.
  BeamSticker get still => switch (this) {
    diamonds => BeamSticker.success,
    love => BeamSticker.love,
    greatNews => BeamSticker.greatNews,
    thumbsUp => BeamSticker.thumbsUp,
    hiFive => BeamSticker.bravo,
  };
}

String _snake(String camel) =>
    camel.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');

/// Which sticker belongs to which moment. Screens ask for a moment, not a
/// file, so the character stays consistent across the app.
abstract final class BeamMoments {
  static const emptyWallets = BeamSticker.welcome;
  static const emptyHistory = BeamSticker.sendMeBeams;
  static const receive = BeamSticker.receivingBeams;
  static const sending = BeamSticker.sendingBeams;
  static const paymentArrived = BeamSticker.receivedBeams;
  static const trading = BeamSticker.tradingBeam;
  static const syncing = BeamSticker.recharging;
  static const privateNodeReady = BeamSticker.fullPower;
  static const behindOrOffline = BeamSticker.lowBattery;
  static const somethingWentWrong = BeamSticker.sad;
  static const updateAvailable = BeamSticker.upgrade;

  static const walletCreated = BeamAnimatedSticker.greatNews;
  static const sendDone = BeamAnimatedSticker.hiFive;
  static const swapDone = BeamAnimatedSticker.thumbsUp;
  static const claimDone = BeamAnimatedSticker.diamonds;
  static const thanks = BeamAnimatedSticker.love;
}

/// A static Beam girl sticker. Decorative: hidden from screen readers unless
/// [semanticLabel] is given.
class BeamStickerImage extends StatelessWidget {
  const BeamStickerImage(
    this.sticker, {
    super.key,
    this.size = 160,
    this.semanticLabel,
  });

  final BeamSticker sticker;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Image.asset(
    sticker.asset,
    width: size,
    height: size,
    fit: BoxFit.contain,
    semanticLabel: semanticLabel,
    excludeFromSemantics: semanticLabel == null,
    filterQuality: FilterQuality.medium,
  );
}

/// An animated Beam girl sticker. Plays once by default (a celebration, not
/// a loop competing with the content); shows the matching still when the
/// system's reduce-motion setting is on.
class BeamAnimatedStickerView extends StatelessWidget {
  const BeamAnimatedStickerView(
    this.sticker, {
    super.key,
    this.size = 180,
    this.repeat = false,
  });

  final BeamAnimatedSticker sticker;
  final double size;
  final bool repeat;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return BeamStickerImage(sticker.still, size: size);
    }
    return ExcludeSemantics(
      child: Lottie.asset(
        sticker.asset,
        width: size,
        height: size,
        repeat: repeat,
        decoder: decodeTgs,
        errorBuilder: (context, error, stack) =>
            BeamStickerImage(sticker.still, size: size),
      ),
    );
  }

  /// `.tgs` files are gzip-compressed Lottie JSON.
  static Future<LottieComposition?> decodeTgs(List<int> bytes) =>
      LottieComposition.fromBytes(gzip.decode(bytes));
}

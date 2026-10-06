/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'bans_constants.dart';

/// Where a name is in its life, as the next transaction would see it.
enum BansNameStatus {
  /// Never registered. Anyone can register it.
  available,

  /// Registered and not expired.
  active,

  /// Registered, not expired, and listed for sale by its owner.
  forSale,

  /// Expired, but inside the 90-day hold: only the owner can renew,
  /// transfer or list it, and payments still reach the owner.
  onHold,

  /// Expired and past the hold. Anyone can register it again (the old
  /// record stays on-chain until someone does). Payments are refused.
  availableAgain;

  /// Whether `role=user,action=domain_register` would accept it.
  bool get canRegister => this == available || this == availableAgain;

  /// Whether `role=manager,action=pay` would accept it.
  bool get canReceivePayments =>
      this == active || this == forSale || this == onHold;
}

/// Block-height arithmetic for BANS names, mirroring the shader and the
/// contract.
///
/// Status is evaluated at `tipHeight + 1`, the first block a new
/// transaction can land in. That is the height the app shader checks
/// (`Env::get_Height() + 1` in `app.cpp:443,535,566`), so a name shown as
/// payable here is one `pay` will accept.
abstract final class BansTimeline {
  /// `Domain::IsExpired` (`contract.h:68-71`) at [height].
  static bool isPastHold(int expireHeight, int height) =>
      expireHeight + kBansHoldBlocks <= height;

  /// The status of a registered name at the next block after [tipHeight].
  /// [listed]: the record carries a sale price.
  static BansNameStatus statusOf({
    required int expireHeight,
    required int tipHeight,
    bool listed = false,
  }) {
    final h = tipHeight + 1;
    if (isPastHold(expireHeight, h)) return BansNameStatus.availableAgain;
    if (expireHeight <= h) return BansNameStatus.onHold;
    return listed ? BansNameStatus.forSale : BansNameStatus.active;
  }

  /// The first height at which someone else can register the name, if the
  /// owner does not renew: `expireHeight + hold`. Before it the owner can
  /// still renew ("renew by").
  static int holdEndHeight(int expireHeight) => expireHeight + kBansHoldBlocks;

  /// The expiry a registration of [periods] would get if mined at the next
  /// block (`MyDomain::Extend`, `contract.cpp:71-85`). An estimate: the
  /// contract uses the height it is actually mined at.
  static int expiryAfterRegister({
    required int tipHeight,
    required int periods,
  }) => tipHeight + 1 + kBansBlocksPerPeriod * periods;

  /// The expiry a renewal of [periods] would give: periods are added to the
  /// later of the current expiry and the mining height.
  static int expiryAfterExtend({
    required int expireHeight,
    required int tipHeight,
    required int periods,
  }) =>
      math.max(expireHeight, tipHeight + 1) + kBansBlocksPerPeriod * periods;

  /// Most periods a renewal can add now (`app.cpp:565-574`): the new expiry
  /// must stay within 50 periods of the mining height. 0 when none fit.
  static int maxExtendPeriods({
    required int expireHeight,
    required int tipHeight,
  }) {
    final h = tipHeight + 1;
    final from = math.max(h, expireHeight);
    final limit = h + kBansBlocksPerPeriod * kBansMaxPeriods;
    return from < limit ? (limit - from) ~/ kBansBlocksPerPeriod : 0;
  }

  /// Most periods a new registration can buy (`app.cpp:539-541`).
  static const int maxRegisterPeriods = kBansMaxPeriods;
}

/// Converts heights to estimated dates from one observed block.
///
/// BEAM targets one block per minute; the estimate drifts by however much
/// real block times differ, so show these as "about" dates.
@immutable
class BansClock {
  /// [tipTime] is the timestamp of block [tipHeight] (`wallet_status
  /// .current_state_timestamp`, or an explorer status).
  const BansClock({required this.tipHeight, required this.tipTime});

  final int tipHeight;
  final DateTime tipTime;

  /// Estimated time block [height] is (or was) mined.
  DateTime dateOf(int height) =>
      tipTime.add(kBeamTargetBlockTime * (height - tipHeight));

  /// The first height expected at or after [date].
  int heightAt(DateTime date) {
    final secs = date.difference(tipTime).inSeconds;
    final per = kBeamTargetBlockTime.inSeconds;
    return tipHeight + (secs / per).ceil();
  }
}

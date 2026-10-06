/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/gestures.dart';

/// Remembers when the user last tapped the dApp page: a pointer that went
/// down and up close together, in place. Scrolls, drags and long presses
/// do not count — a page can make the user scroll at will, and the dApp
/// browser uses a recent tap as the sign that the user asked for what the
/// page is now requesting.
class DappTapTracker {
  DappTapTracker({
    this.slop = kTouchSlop,
    this.maxTapDuration = const Duration(milliseconds: 600),
  });

  /// How far a pointer may move between down and up and still be a tap.
  final double slop;

  /// How long a pointer may stay down and still be a tap.
  final Duration maxTapDuration;

  final _down = <int, (Offset, DateTime)>{};
  DateTime? _lastTap;

  /// When the last tap ended, or null.
  DateTime? get lastTap => _lastTap;

  void down(int pointer, Offset position, DateTime at) =>
      _down[pointer] = (position, at);

  void up(int pointer, Offset position, DateTime at) {
    final d = _down.remove(pointer);
    if (d == null) return;
    final (from, since) = d;
    if ((position - from).distance <= slop &&
        at.difference(since) <= maxTapDuration) {
      _lastTap = at;
    }
  }

  void cancel(int pointer) => _down.remove(pointer);

  /// The user tapped the page less than [window] before [now].
  bool tappedWithin(Duration window, DateTime now) {
    final t = _lastTap;
    return t != null && now.difference(t) < window;
  }
}

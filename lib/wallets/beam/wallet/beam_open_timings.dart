/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// How long one open of a BEAM wallet took to reach each R11 milestone
/// (cached view <= 300 ms, live data <= 3 s, able to send
/// <= 10 s on a recently opened wallet). Measured from the moment `open()`
/// was called; null until the milestone is reached.
class BeamOpenTimings {
  BeamOpenTimings(this.requestedAt);

  /// When `open()` started this open.
  final DateTime requestedAt;

  /// `open()` returned (the cached view can render from here).
  Duration? openReturned;

  /// wallet-api answered on its loopback port.
  Duration? sessionUp;

  /// The first `wallet_status` from the core was applied to the cache.
  Duration? liveData;

  /// The honest sync verdict first allowed spending.
  Duration? canSend;

  /// The owner key had to be read before this open (old wallet without a
  /// stored key); how long that took.
  Duration? ownerKeyCapture;

  Duration since(DateTime now) => now.difference(requestedAt);

  @override
  String toString() =>
      'BeamOpenTimings(open returned ${_ms(openReturned)}, '
      'session ${_ms(sessionUp)}, live ${_ms(liveData)}, '
      'can send ${_ms(canSend)}'
      '${ownerKeyCapture == null ? '' : ', owner key '}'
      '${ownerKeyCapture == null ? '' : _ms(ownerKeyCapture)})';

  static String _ms(Duration? d) => d == null ? '-' : '${d.inMilliseconds} ms';
}

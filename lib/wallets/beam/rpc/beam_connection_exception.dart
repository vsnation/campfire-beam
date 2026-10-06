/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// A request could not complete because there is no live connection to the
/// wallet core: it was never opened, it was closed, or it dropped while the
/// request was in flight.
///
/// Distinct from `BeamRpcException` (the core answered with an error) and
/// `TimeoutException` (the core did not answer in time): after this one the
/// outcome of a write call such as `tx_send` is unknown, and the caller must
/// look it up (`tx_list`) before retrying.
class BeamConnectionException implements Exception {
  const BeamConnectionException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'BeamConnectionException: $message'
      : 'BeamConnectionException: $message ($cause)';
}

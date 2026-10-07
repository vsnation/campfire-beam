/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Why a host operation failed.
enum BeamHostError {
  /// A password, phrase, wallet id or node address that cannot be handed to
  /// the BEAM binaries safely or unchanged.
  invalidInput,

  /// The wallet password does not open `wallet.db`.
  wrongPassword,

  /// `wallet.db` already exists where a new one was to be created.
  walletExists,

  /// There is no `wallet.db` in the given directory.
  walletNotFound,

  /// Another session or process holds this `wallet.db` (rule R8).
  walletInUse,

  /// A directory or file that must be private is readable or writable by
  /// other users.
  insecurePath,

  /// A BEAM binary is not where it should be.
  binaryMissing,

  /// A BEAM binary's SHA-256 differs from the pinned value, or the binary is
  /// writable by other users.
  binaryUntrusted,

  /// No binaries are pinned for this OS and architecture.
  unsupportedPlatform,

  /// A BEAM binary does not follow the current mainnet consensus (HF6).
  consensusMismatch,

  /// The node address was rejected or could not be resolved.
  badNode,

  /// The operation needs the user's own node holding the owner key.
  notOwnedNode,

  /// A child process did not reach the expected state in time.
  timeout,

  /// A child process failed for another reason.
  processFailed,

  /// Tor is switched on but not connected (or cannot resolve the node), so
  /// nothing connects: never a direct connection while Tor is on.
  torNotReady,

  /// Tor is switched on and this build's BEAM core cannot route through a
  /// SOCKS5 proxy, so it does not connect at all.
  torUnsupported,
}

/// A failed host operation. [message] never contains a password, a seed
/// phrase, an owner key or an ACL key.
class BeamHostException implements Exception {
  const BeamHostException(this.kind, this.message);

  final BeamHostError kind;
  final String message;

  @override
  String toString() => 'BeamHostException(${kind.name}): $message';
}

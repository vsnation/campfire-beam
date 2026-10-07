/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../rpc/beam_transport.dart';

/// Wallet lifecycle operations that wallet-api does not offer as JSON-RPC:
/// creating and restoring `wallet.db`, opening it against a node, exporting
/// the owner key, and rescanning.
///
/// [ProcessHost] implements this with the `beam-wallet`, `wallet-api` and
/// `beam-node` binaries (desktop). An FFI host (phase 2) implements it
/// in-process. Secrets passed here must never reach a process argv, a log, or
/// a file that outlives the call.
abstract class BeamHost {
  /// Creates `wallet.db` in [walletDir] from [words]. Create and restore are
  /// the same core call. [words] must already be validated against the BIP39
  /// dictionary and checksum: the BEAM core checks neither.
  Future<void> initWallet({
    required String walletDir,
    required String password,
    required List<String> words,
  });

  /// Opens the wallet in [walletDir] against [node] and returns a live
  /// session. [requestBodies] lets a wallet without an owned node detect
  /// shielded and offline coins by requesting block bodies.
  Future<BeamSession> openWallet({
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
    bool requestBodies = false,
  });

  /// Returns the owner key. The wallet must not be open. The key is kept in
  /// memory by the caller only, and never logged.
  Future<String> exportOwnerKey({
    required String walletDir,
    required String password,
  });

  /// Rescans the wallet against an owned node. The wallet must not be open.
  Future<void> rescan({
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
  });
}

/// Brings an existing BEAM `wallet.db` (from BEAM's own wallets, BEAM Light
/// Wallet, or another computer) into Campfire with its password: the owner
/// has such files and no recovery phrase. [ProcessHost] and [InProcessHost]
/// implement it.
abstract class BeamWalletFileImporter {
  /// Copies [sourcePath] to `wallet.db` in [walletDir] (0600) and checks
  /// that [password] opens the copy with BEAM's own code. The source is only
  /// read. Throws [BeamHostException]: walletExists (the directory already
  /// holds a wallet), wrongPassword (the password does not open it, or it is
  /// not a BEAM wallet), walletInUse (another program is in the middle of
  /// writing it), invalidInput. Nothing is left behind on failure.
  Future<void> importWalletFile({
    required String walletDir,
    required String sourcePath,
    required String password,
  });
}

/// An open wallet.
abstract class BeamSession {
  BeamTransport get transport;

  BeamNodeEndpoint get node;

  /// Moves the wallet to [node]. The process host restarts wallet-api, since
  /// it has no runtime switch; the returned session replaces this one.
  Future<BeamSession> switchNode(BeamNodeEndpoint node);

  /// Closes the wallet and stops anything this session started.
  Future<void> close();
}

/// A BEAM node address, `host:port`. BEAM nodes are not URLs.
class BeamNodeEndpoint {
  const BeamNodeEndpoint(this.host, this.port, {this.isOwned = false});

  /// Parses `host:port`. Throws [FormatException] for anything else.
  factory BeamNodeEndpoint.parse(String value, {bool isOwned = false}) {
    final i = value.lastIndexOf(':');
    final port = i > 0 ? int.tryParse(value.substring(i + 1)) : null;
    if (port == null || port <= 0 || port > 65535) {
      throw FormatException('Expected host:port', value);
    }
    return BeamNodeEndpoint(value.substring(0, i), port, isOwned: isOwned);
  }

  final String host;
  final int port;

  /// True for the user's private node holding the owner key. Only an owned
  /// node lets the wallet see offline and max-privacy payments.
  final bool isOwned;

  @override
  String toString() => '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is BeamNodeEndpoint &&
      other.host == host &&
      other.port == port &&
      other.isOwned == isOwned;

  @override
  int get hashCode => Object.hash(host, port, isOwned);
}

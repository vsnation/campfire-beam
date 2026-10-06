/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:io';

import '../../../utilities/flutter_secure_storage_interface.dart';
import '../host/process_host.dart';
import '../node/beam_node_process.dart';
import 'beam_secret_store.dart';
import 'beam_wallet_environment.dart';

/// Stops every BEAM child this app started (wallet-api, beam-wallet,
/// beam-node) and deletes leftover secret files. Campfire's desktop quit
/// path ends in `exit(0)`, which would otherwise orphan them
/// (ARCHITECTURE.md §5, Shutdown). Never throws; gives up after [timeout]
/// so quitting is never held hostage.
Future<void> shutdownBeamChildren({
  Duration timeout = const Duration(seconds: 8),
}) async {
  try {
    await Future.wait([ProcessHost.shutdownAll(), BeamNodeProcess.stopAll()])
        .timeout(timeout);
  } catch (_) {
    // Quitting anyway; a child that survives is found and stopped through
    // its lock file on the next start.
  }
}

/// Removes a BEAM wallet's files and secrets. The wallet must be closed
/// (`BeamWallet.exit`) first. Safe to call for a wallet that never got a
/// file.
Future<void> deleteBeamWalletData({
  required String walletId,
  required SecureStorageInterface secureStore,
  BeamWalletEnvironment? environment,
}) async {
  await BeamSecretStore(secureStore, walletId).deleteAll();
  final env = environment ?? BeamWalletEnvironment.instance;
  final String dir;
  try {
    dir = await env.walletDir(walletId);
  } on ArgumentError {
    return; // not an id this app could have created a directory for
  }
  final d = Directory(dir);
  if (await d.exists()) await d.delete(recursive: true);
}

/// The "forgot password" wipe: stops every BEAM child, then deletes the
/// whole BEAM directory (wallet files, logs and the private node's data,
/// which holds owner-key-derived history). Never throws.
Future<void> deleteBeamDataDirectory(Directory appRoot) async {
  await shutdownBeamChildren();
  try {
    final dir = Directory('${appRoot.path}/beam');
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (_) {
    // The rest of the wipe goes on; a later delete retries.
  }
}

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

import '../host/beam_host_exception.dart';
import '../rpc/beam_connection_exception.dart';
import '../rpc/beam_transport.dart';

/// Why a BEAM wallet operation could not be done.
enum BeamWalletProblem {
  /// This build has no usable BEAM core for this computer: the binaries are
  /// missing, not pinned for this platform, or the BEAM flag is off.
  coreNotInstalled,

  /// A BEAM core binary is present but failed its pinned-hash or consensus
  /// check, so it is not run.
  coreUntrusted,

  /// Campfire's secure storage has no password for this wallet's file.
  passwordMissing,

  /// The stored password does not open the wallet file.
  wrongPassword,

  /// The wallet's data file is missing.
  walletFileMissing,

  /// Another process has the wallet file open.
  walletInUse,

  /// The configured BEAM node could not be used.
  nodeUnreachable,

  /// Tor is switched on and not connected yet, or cannot reach the node:
  /// the wallet waits rather than connect outside Tor.
  waitingForTor,

  /// Tor is switched on and this build's core cannot go through it, so the
  /// wallet does not connect.
  torUnsupported,

  /// The core is not open yet (or was closed).
  notOpen,

  /// The wallet is not honestly synced, so spending is off.
  notSynced,

  /// The recipient is not a BEAM address.
  invalidAddress,

  /// A real BEAM address of a type this version cannot send to yet.
  unsupportedAddressType,

  /// Amount plus fee is more than the available balance.
  insufficientFunds,

  /// The amount is zero, negative or not representable.
  invalidAmount,

  /// The recovery phrase is not a valid 12-word BIP39 phrase.
  invalidPhrase,

  /// The connection dropped while sending: the payment may or may not have
  /// gone out.
  sendOutcomeUnknown,

  /// The core refused the payment.
  sendRejected,

  /// Another money flow (a payment, swap, claim or dApp approval) is open or
  /// still being confirmed; this one waits until it is done.
  walletBusy,

  /// A restored wallet is still looking for its coins.
  scanningForCoins,

  /// Anything else.
  other,
}

/// A BEAM wallet error with a message a user can act on.
///
/// [toString] is the message alone, because Campfire's dialogs show
/// `e.toString()`. Messages never contain a password, a phrase, an owner
/// key, a full address or an amount together with an address.
class BeamWalletException implements Exception {
  const BeamWalletException(this.problem, this.message);

  final BeamWalletProblem problem;
  final String message;

  @override
  String toString() => message;
}

/// Plain-language messages, kept in one place.
abstract final class BeamWalletMessages {
  static const coreNotInstalled =
      'BEAM core not installed. This copy of Campfire is missing the BEAM '
      "wallet engine for this computer, so it can't create or open BEAM "
      'wallets yet. Nothing was lost. Install a Campfire build that includes '
      'the BEAM core.';

  static const coreUntrusted =
      "The BEAM wallet engine on this computer failed Campfire's safety "
      "check, so it won't be run. Reinstall Campfire.";

  /// [coreNotInstalled] and [coreUntrusted] as a phone says them.
  static const coreNotInstalledOnPhone =
      'BEAM core not installed. This copy of Campfire is missing the BEAM '
      "wallet engine for this device, so it can't create or open BEAM "
      'wallets yet. Nothing was lost. Install a Campfire build that includes '
      'the BEAM core.';

  static const coreUntrustedOnPhone =
      "The BEAM wallet engine on this device failed Campfire's safety "
      "check, so it won't be run. Reinstall Campfire.";

  static bool get _onPhone => Platform.isAndroid || Platform.isIOS;

  /// The "core not installed" text for the device the app runs on.
  static String get coreNotInstalledHere =>
      _onPhone ? coreNotInstalledOnPhone : coreNotInstalled;

  /// The "core failed the safety check" text for the device the app runs on.
  static String get coreUntrustedHere =>
      _onPhone ? coreUntrustedOnPhone : coreUntrusted;

  static const passwordMissing =
      "This wallet's file can't be unlocked because its key is missing from "
      "Campfire's secure storage. Restore the wallet from its recovery "
      'phrase.';

  static const wrongPassword =
      "This wallet's file can't be unlocked with the key Campfire stored for "
      'it. Restore the wallet from its recovery phrase.';

  static const walletFileMissing =
      "This wallet's data file is missing. Restore the wallet from its "
      'recovery phrase.';

  static const walletInUse =
      'This wallet is already open in another Campfire window or app. Close '
      'it there, then try again.';

  static const notOpen =
      'The wallet is still connecting to the BEAM network. Try again in a '
      'few seconds.';

  static const rescanWhileBusy =
      'A payment, swap or dApp approval is open in this wallet. Finish or '
      'close it, then rescan.';

  static const rescanWithTxInFlight =
      'Some transactions of this wallet are still being sent, received or '
      'confirmed. Rescanning now would lose them; rescan once they have '
      'completed or been canceled.';

  static const rescanCoreStillOpen =
      "The wallet engine hasn't finished closing this wallet, so it can't "
      'be rebuilt yet. Nothing was changed. Try again in a minute.';

  static const importedNoRescan =
      'This wallet was imported from its wallet.db file and has no recovery '
      'phrase here, so it cannot be rebuilt. Import the original file again '
      'if you need a fresh copy.';

  static const waitingForTor =
      'Waiting for Tor. BEAM Campfire connects only through Tor while it is '
      'on, so nothing reveals your IP address.';

  static const torUnsupported =
      "This version can't reach BEAM through Tor yet, so with Tor on it stays "
      'offline. Turn Tor off in Settings to connect without it.';

  static String nodeUnreachable(String node) =>
      "Couldn't reach the BEAM node $node. Check the node in Settings, or "
      'pick another one.';

  static const coreDidNotStart =
      "The BEAM wallet engine didn't start. Try again. If it keeps "
      'happening, restart Campfire.';

  static const invalidPhrase =
      "That recovery phrase isn't valid. Check each of the 12 words and their "
      'order.';
}

/// Maps a failure from the host, transport or core to a
/// [BeamWalletException]. A [BeamWalletException] passes through unchanged.
BeamWalletException beamWalletExceptionFrom(Object error, {String? node}) {
  if (error is BeamWalletException) return error;
  if (error is BeamHostException) {
    return switch (error.kind) {
      BeamHostError.binaryMissing ||
      BeamHostError.unsupportedPlatform => BeamWalletException(
        BeamWalletProblem.coreNotInstalled,
        BeamWalletMessages.coreNotInstalledHere,
      ),
      BeamHostError.binaryUntrusted ||
      BeamHostError.consensusMismatch => BeamWalletException(
        BeamWalletProblem.coreUntrusted,
        BeamWalletMessages.coreUntrustedHere,
      ),
      BeamHostError.wrongPassword => const BeamWalletException(
        BeamWalletProblem.wrongPassword,
        BeamWalletMessages.wrongPassword,
      ),
      BeamHostError.walletNotFound => const BeamWalletException(
        BeamWalletProblem.walletFileMissing,
        BeamWalletMessages.walletFileMissing,
      ),
      BeamHostError.walletInUse => const BeamWalletException(
        BeamWalletProblem.walletInUse,
        BeamWalletMessages.walletInUse,
      ),
      BeamHostError.badNode => BeamWalletException(
        BeamWalletProblem.nodeUnreachable,
        BeamWalletMessages.nodeUnreachable(node ?? 'you picked'),
      ),
      BeamHostError.torNotReady => const BeamWalletException(
        BeamWalletProblem.waitingForTor,
        BeamWalletMessages.waitingForTor,
      ),
      BeamHostError.torUnsupported => const BeamWalletException(
        BeamWalletProblem.torUnsupported,
        BeamWalletMessages.torUnsupported,
      ),
      BeamHostError.invalidInput => BeamWalletException(
        BeamWalletProblem.other,
        // Host messages never carry a secret (BeamHostException contract).
        error.message,
      ),
      BeamHostError.walletExists ||
      BeamHostError.insecurePath ||
      BeamHostError.notOwnedNode ||
      BeamHostError.timeout ||
      BeamHostError.processFailed => const BeamWalletException(
        BeamWalletProblem.other,
        BeamWalletMessages.coreDidNotStart,
      ),
    };
  }
  if (error is BeamConnectionException || error is TimeoutException) {
    return const BeamWalletException(
      BeamWalletProblem.notOpen,
      BeamWalletMessages.notOpen,
    );
  }
  if (error is BeamRpcException) {
    return BeamWalletException(
      BeamWalletProblem.other,
      'The BEAM wallet refused the request: ${error.message}',
    );
  }
  // `libBeam.createHost` throws a plain Exception when the BEAM flag is off.
  if ('$error'.contains('BEAM not enabled')) {
    return BeamWalletException(
      BeamWalletProblem.coreNotInstalled,
      BeamWalletMessages.coreNotInstalledHere,
    );
  }
  return BeamWalletException(BeamWalletProblem.other, '$error');
}

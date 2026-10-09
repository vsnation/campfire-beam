/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import '../../../wallets/beam/contracts/airdrop/airdrop.dart';
import '../../../wallets/beam/rpc/beam_connection_exception.dart';
import '../../../wallets/beam/rpc/beam_transport.dart';

/// What went wrong, whose fault it is (never the user's) and the one thing
/// that fixes it (no dead ends).
class BeamProblem {
  const BeamProblem(this.title, this.message);

  final String title;
  final String message;
}

/// Problems every contract screen shares: the core or the network.
BeamProblem? beamTransportProblem(Object error) => switch (error) {
  BeamConnectionException() || TimeoutException() => const BeamProblem(
    "Couldn't reach the wallet",
    'The wallet did not answer in time. Check your connection, then try '
        'again.',
  ),
  BeamRpcException(:final message) => BeamProblem(
    'The wallet refused this',
    message.isEmpty
        ? 'Nothing was sent. Try again in a moment.'
        : 'Nothing was sent. The wallet said: "$message". Try again in a '
              'moment.',
  ),
  _ => null,
};

/// What a voucher code is, said where codes are made and claimed.
///
/// The live Airdrop contract redeems with the code itself (the preimage of
/// the hash it stores), so a claim carries the code in a transaction that
/// the network sees before it is in a block. Anyone watching could take the
/// code and claim the voucher first. Campfire cannot change that contract;
/// it says so, so codes are used for amounts where that risk is acceptable.
abstract final class AirdropBearerText {
  static const createTitle = 'Codes work like cash';

  static const createMessage =
      'Anyone who has a code can claim it. Claiming also shows the code to '
      'the network before it is confirmed, so someone watching could claim '
      'it first. Use codes for small amounts, and give each one to one '
      'person.';

  static const claimMessage =
      'Claiming shows this code to the network before it is confirmed, so '
      'someone watching could claim it first. That is how this airdrop '
      'contract works; codes are meant for small amounts.';
}

/// The airdrop's refusals in plain words.
BeamProblem airdropProblem(Object error) {
  final t = beamTransportProblem(error);
  if (t != null) return t;
  if (error is! BeamAirdropException) {
    return const BeamProblem(
      'Something went wrong on our side',
      'Nothing was sent. Try again; if it keeps happening, restart the '
          'wallet.',
    );
  }
  return switch (error.code) {
    AirdropErrorCode.invalidCode => const BeamProblem(
      "That isn't a voucher code",
      'Codes are 16 letters and digits, like ABCD-EFGH-JKLM-NPQR. Paste '
          'the whole code you were given.',
    ),
    AirdropErrorCode.voucherNotFound => const BeamProblem(
      'No voucher has this code',
      'Check it letter by letter: codes never use I, O, 0 or 1. If it '
          'still fails, ask the sender: the code may have been cancelled.',
    ),
    AirdropErrorCode.alreadyRedeemed => const BeamProblem(
      'This voucher was already claimed',
      'Each code works once. Ask the sender for a new one.',
    ),
    AirdropErrorCode.busy => const BeamProblem(
      'Another airdrop action is still open',
      'Finish or close it, then try again.',
    ),
    AirdropErrorCode.codesNotSaved => const BeamProblem(
      "The codes couldn't be saved on this device",
      'So nothing was sent and nothing was locked. Free up some space or '
          'restart the wallet, then try again.',
    ),
    AirdropErrorCode.unexpectedTransaction => const BeamProblem(
      'Stopped for your safety',
      'The wallet built a different transaction than the one you asked '
          'for, so nothing was sent. Try again; if it repeats, update the '
          'app.',
    ),
    AirdropErrorCode.expired ||
    AirdropErrorCode.alreadyExecuted => const BeamProblem(
      'This confirmation is out of date',
      'Nothing new was sent. Go back and start again.',
    ),
    AirdropErrorCode.walletNotSynced => const BeamProblem(
      'The wallet is still catching up',
      'Try again once it is up to date.',
    ),
    AirdropErrorCode.batchNotFound ||
    AirdropErrorCode.nothingToCancel => const BeamProblem(
      'Nothing left to take back',
      'Every code of this batch was already claimed or cancelled.',
    ),
    AirdropErrorCode.stillHoldsFunds => const BeamProblem(
      'These codes can still unlock funds',
      'So they stay saved. Cancel the unclaimed codes first, or wait until '
          'the batch has settled on the network.',
    ),
    AirdropErrorCode.contractNotFound => const BeamProblem(
      "The airdrop contract didn't answer",
      'The wallet may be on the wrong network. Check the node in Settings.',
    ),
    _ => BeamProblem('The airdrop refused this', error.message),
  };
}

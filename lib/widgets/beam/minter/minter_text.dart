/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../wallets/beam/contracts/burn/burn.dart';
import '../../../wallets/beam/contracts/minter/minter.dart';
import '../airdrop/airdrop_text.dart';

/// The Minter's and the BlackHole's refusals in plain words: what happened,
/// never the user's fault, and the next step.
BeamProblem minterProblem(Object error) {
  final t = beamTransportProblem(error);
  if (t != null) return t;
  if (error is BeamBurnException) return _burn(error);
  if (error is! BeamMinterException) {
    return const BeamProblem(
      'Something went wrong on our side',
      'Nothing was sent. Try again; if it keeps happening, restart the '
          'wallet.',
    );
  }
  return switch (error.code) {
    MinterErrorCode.busy => const BeamProblem(
      'Another token action is still open',
      'Finish or close it, then try again.',
    ),
    MinterErrorCode.noSuchToken => const BeamProblem(
      "The Minter doesn't know this token",
      'It may still be waiting for the network. Try again in a few '
          'minutes.',
    ),
    MinterErrorCode.notOwner => const BeamProblem(
      'Only the wallet that created this token can mint it',
      'Open the wallet that created it to mint more.',
    ),
    MinterErrorCode.aboveLimit => BeamProblem(
      'More than this token can ever have',
      '${error.message} Lower the amount.',
    ),
    MinterErrorCode.unexpectedTransaction => const BeamProblem(
      'Stopped for your safety',
      'The wallet built a different transaction than the one you asked '
          'for, so nothing was sent. Try again; if it repeats, update the '
          'app.',
    ),
    MinterErrorCode.expired ||
    MinterErrorCode.alreadyExecuted => const BeamProblem(
      'This confirmation is out of date',
      'Nothing new was sent. Go back and start again.',
    ),
    MinterErrorCode.noSuchContract => const BeamProblem(
      "The Minter contract didn't answer",
      'The wallet may be on the wrong network. Check the node in Settings.',
    ),
    MinterErrorCode.shaderError => BeamProblem(
      'The Minter refused this',
      'Nothing was sent. It said: "${error.message}".',
    ),
  };
}

BeamProblem _burn(BeamBurnException error) => switch (error.code) {
  BurnErrorCode.busy => const BeamProblem(
    'Another burn is still open',
    'Finish or close it, then try again.',
  ),
  BurnErrorCode.notAcknowledged => const BeamProblem(
    'Confirm that the tokens are destroyed for good',
    'Type the ticker to confirm, then try again.',
  ),
  BurnErrorCode.unexpectedTransaction => const BeamProblem(
    'Stopped for your safety',
    'The wallet built a different transaction than the one you asked for, '
        'so nothing was burned. Try again; if it repeats, update the app.',
  ),
  BurnErrorCode.expired || BurnErrorCode.alreadyExecuted => const BeamProblem(
    'This confirmation is out of date',
    'Nothing new was burned. Go back and start again.',
  ),
  BurnErrorCode.shaderError => BeamProblem(
    'The burn was refused',
    'Nothing was burned. It said: "${error.message}".',
  ),
};

/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_errors.dart';

void main() {
  group('core messages name the device the app runs on', () {
    test('phones say "device", desktops say "computer"', () {
      for (final m in [
        BeamWalletMessages.coreNotInstalledOnPhone,
        BeamWalletMessages.coreUntrustedOnPhone,
      ]) {
        expect(m, contains('this device'));
        expect(m, isNot(contains('computer')));
      }
      expect(BeamWalletMessages.coreNotInstalled, contains('this computer'));
      expect(BeamWalletMessages.coreUntrusted, contains('this computer'));
    });

    test('the phone texts differ from the desktop ones only in that word', () {
      expect(
        BeamWalletMessages.coreNotInstalledOnPhone,
        BeamWalletMessages.coreNotInstalled.replaceAll('computer', 'device'),
      );
      expect(
        BeamWalletMessages.coreUntrustedOnPhone,
        BeamWalletMessages.coreUntrusted.replaceAll('computer', 'device'),
      );
    });

    test('a missing or untrusted core maps to the text for this host '
        '(a desktop under flutter test)', () {
      final missing = beamWalletExceptionFrom(
        const BeamHostException(BeamHostError.binaryMissing, 'x'),
      );
      expect(missing.problem, BeamWalletProblem.coreNotInstalled);
      expect(missing.message, BeamWalletMessages.coreNotInstalledHere);
      expect(missing.message, BeamWalletMessages.coreNotInstalled);

      final untrusted = beamWalletExceptionFrom(
        const BeamHostException(BeamHostError.binaryUntrusted, 'x'),
      );
      expect(untrusted.problem, BeamWalletProblem.coreUntrusted);
      expect(untrusted.message, BeamWalletMessages.coreUntrustedHere);
    });
  });
}

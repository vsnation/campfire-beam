/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_sync_tracker.dart';

void main() {
  test('progress is measured against the largest total of the scan', () {
    const p = BeamScanProgress.new;
    // First session: as reported.
    expect(beamScanAcrossRestarts(p(60, 100), null), p(60, 100));
    expect(beamScanAcrossRestarts(p(60, 100), 100), p(60, 100));
    // After a restart the core recounts what is left from 0.
    expect(beamScanAcrossRestarts(p(0, 40), 100), p(60, 100));
    expect(beamScanAcrossRestarts(p(30, 40), 100), p(90, 100));
    // More work than ever seen (the chain grew): the new total counts.
    expect(beamScanAcrossRestarts(p(10, 120), 100), p(10, 120));
    // Done stays done.
    expect(beamScanAcrossRestarts(p(40, 40), 100).fraction, 1.0);
  });
}

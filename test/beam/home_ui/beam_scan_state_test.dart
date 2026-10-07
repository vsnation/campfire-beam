/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// When the screens say a restored wallet is still being scanned: only while
// the scan runs, never for ever on the strength of the "pending" flag (which
// stays set until a private node takes over, and on many devices never
// does). And what a restored wallet that holds something is.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_sync_tracker.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/wallet/supporting/beam_wallet_info_extension.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_scan_state.dart';

/// A BEAM wallet's info as the restore leaves it, with [assets] found so
/// far (asset id → whole units).
WalletInfo _info({
  bool pending = true,
  int? startedAt = 1791300000,
  Map<int, int> assets = const {},
  bool restored = true,
}) => WalletInfo.createNew(
  coin: Beam(CryptoCurrencyNetwork.main),
  name: 'Restored',
  otherDataJsonString: jsonEncode({
    if (restored)
      WalletInfoKeys.beamData: jsonEncode(
        ExtraBeamWalletInfo(
          restoreScanPending: pending,
          restoreScanStartedAt: startedAt,
        ).toMap(),
      ),
    WalletInfoKeys.beamAssetTotals: {
      for (final e in assets.entries)
        '${e.key}': {
          'available': '${e.value * 100000000}',
          'receiving': '0',
          'sending': '0',
          'maturing': '0',
          'change': '0',
        },
    },
  }),
);

void main() {
  group('the scan is running', () {
    test('while the wallet is not up to date', () {
      expect(
        beamScanRunning(pending: true, scan: null, canSpend: false),
        isTrue,
      );
      expect(
        beamScanRunning(
          pending: true,
          scan: const BeamScanProgress(1000, 1000),
          canSpend: false,
        ),
        isTrue,
      );
    });

    test('while body requests are outstanding, even when up to date', () {
      expect(
        beamScanRunning(
          pending: true,
          scan: const BeamScanProgress(430, 1000),
          canSpend: true,
        ),
        isTrue,
      );
    });

    test('not once up to date with the scan complete (the pending flag may '
        'stay set for ever without a private node)', () {
      expect(
        beamScanRunning(
          pending: true,
          scan: const BeamScanProgress(1000, 1000),
          canSpend: true,
        ),
        isFalse,
      );
      // Up to date and no progress reported (nothing left to do).
      expect(
        beamScanRunning(pending: true, scan: null, canSpend: true),
        isFalse,
      );
      expect(
        beamScanRunning(
          pending: true,
          scan: const BeamScanProgress(0, 0),
          canSpend: true,
        ),
        isFalse,
      );
    });

    test('never for a wallet that was not restored', () {
      expect(
        beamScanRunning(
          pending: false,
          scan: const BeamScanProgress(1, 1000),
          canSpend: false,
        ),
        isFalse,
      );
    });
  });

  group('wallet lists', () {
    test('a closed restored wallet with nothing found says "Scanning…" (it '
        'goes on scanning when opened)', () {
      expect(beamListShowsScanning(_info(), null), isTrue);
    });

    test('anything found, or no scan: the balance, not "Scanning…"', () {
      expect(beamListShowsScanning(_info(assets: {0: 2}), null), isFalse);
      expect(beamListShowsScanning(_info(assets: {174: 200}), null), isFalse);
      expect(beamListShowsScanning(_info(pending: false), null), isFalse);
      expect(beamListShowsScanning(_info(restored: false), null), isFalse);
    });
  });

  group('restored with funds', () {
    test('restored (scan pending or done) and holding something', () {
      expect(_info(assets: {0: 2}).beamRestoredWithFunds, isTrue);
      expect(_info(assets: {174: 200}).beamRestoredWithFunds, isTrue);
      // The private node finished the scan: still a restored wallet.
      expect(
        _info(pending: false, assets: {0: 2}).beamRestoredWithFunds,
        isTrue,
      );
    });

    test('not when it holds nothing, or was created here', () {
      expect(_info().beamRestoredWithFunds, isFalse);
      expect(_info(assets: {0: 0}).beamRestoredWithFunds, isFalse);
      expect(
        _info(restored: false, assets: {0: 2}).beamRestoredWithFunds,
        isFalse,
      );
      // A wallet made here: no pending scan and no start time.
      expect(
        _info(
          pending: false,
          startedAt: null,
          assets: {0: 2},
        ).beamRestoredWithFunds,
        isFalse,
      );
    });
  });
}

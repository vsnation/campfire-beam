/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// LIVE, no funds. A NEW wallet, created through the Dart API exactly as the
// app does (Wallet.create + init + open) with the real ProcessHost and the
// pinned HF6 binaries, must be usable on a PUBLIC node at once: connected,
// synced and able to send within a minute of its first open. Owner report,
// 2026-10-07: a new wallet was "not connected to a public node from the first
// time ... doesn't allow to send anything until the chain is synced".
//
//   BEAM_WALLET_IT=1 BEAM_BIN_DIR=<dir with the pinned binaries> \
//       flutter test --no-pub test/beam/wallet/beam_wallet_first_open_live_test.dart
//
// The throwaway wallet never holds funds, so its phrase is not kept. Nothing
// secret is printed: evidence lines carry heights, node names and timings.
@Timeout(Duration(minutes: 15))
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';
import 'package:stackwallet/wallets/beam/host/beam_binaries.dart';
import 'package:stackwallet/wallets/beam/host/process_host.dart';
import 'package:stackwallet/wallets/beam/host/secret_file.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';

import 'beam_wallet_test_support.dart';

void _evidence(String line) {
  // ignore: avoid_print
  print('[evidence] $line');
}

String _rand(int n) {
  const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
  final r = Random.secure();
  return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
}

void main() {
  final enabled = Platform.environment['BEAM_WALLET_IT'] == '1';
  final binDir = Platform.environment[BeamBinaries.binDirEnv];
  final home = Platform.environment['HOME'];
  final node =
      Platform.environment['BEAM_IT_NODE'] ?? 'eu-node01.mainnet.beam.mw';

  test(
    'a new wallet is connected and can send on a public node within a minute',
    () async {
      final itRoot = Directory(
        p.join(home!, 'beam-campfire-test', 'it-first-${_rand(8)}'),
      );
      await ensurePrivateDir(itRoot.path);
      final beamRoot = p.join(itRoot.path, 'beam');
      await ensurePrivateDir(beamRoot);
      final isarDir = Directory(p.join(itRoot.path, 'isar'))..createSync();
      await openTestMainDb(isarDir);

      final hostLog = <String>[];
      final explorer = BeamExplorerClient(proxyInfo: () => null);
      BeamWalletEnvironment.instance = BeamWalletEnvironment(
        beamRoot: () async => beamRoot,
        createHost: (root) => ProcessHost(
          rootDir: root,
          binaries: BeamBinaries(
            binDir: binDir!,
            platform: Platform.isMacOS ? 'macos-arm64' : null,
          ),
          log: hostLog.add,
          startupTimeout: const Duration(seconds: 30),
        ),
        createExplorer: () => explorer,
        explorerPollInterval: const Duration(seconds: 5),
        statusPollInterval: const Duration(seconds: 30),
        log: hostLog.add,
      );

      final wallet =
          await Wallet.create(
                walletInfo: WalletInfo.createNew(
                  coin: Beam(CryptoCurrencyNetwork.main),
                  name: 'it-first',
                ),
                mainDB: MainDB.instance,
                secureStorageInterface: FakeSecureStorage(),
                nodeService: FakeNodeService(beamTestNode(node, 8100)),
                prefs: FakePrefs(),
                mnemonic: bip39.generateMnemonic(),
                mnemonicPassphrase: '',
              )
              as BeamWallet;

      final trace = <String>[];
      final sw = Stopwatch()..start();
      var last = '';
      final poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
        final a = wallet.syncAssessment;
        final line =
            '${a.runtimeType} canSpend=${a.canSpend} height=${a.walletHeight}';
        if (line != last) {
          last = line;
          trace.add('${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s '
              '$line');
        }
      });
      try {
        await wallet.init();
        _evidence('created in ${sw.elapsedMilliseconds} ms');
        sw.reset();
        await wallet.open();
        await wallet.whenLive.timeout(const Duration(seconds: 60));
        _evidence('live after ${sw.elapsedMilliseconds} ms');
        await wallet.whenCanSend.timeout(const Duration(seconds: 90));
        _evidence('can send after ${sw.elapsedMilliseconds} ms on $node '
            '(${wallet.openTimings})');
        expect(wallet.isScanningForCoins, isFalse,
            reason: 'a new wallet has nothing to scan for');
      } finally {
        poll.cancel();
        for (final t in trace) {
          _evidence('state $t');
        }
        for (final l in hostLog.where(
          (l) => !l.contains('pass') && !l.contains('seed'),
        )) {
          _evidence('host $l');
        }
        await wallet.exit();
        await itRoot.delete(recursive: true);
      }
    },
    skip: !enabled || binDir == null
        ? 'BEAM_WALLET_IT=1 and BEAM_BIN_DIR are required'
        : false,
  );
}

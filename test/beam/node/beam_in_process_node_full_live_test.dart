/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// LIVE, LONG (hours), no funds: the integrated private node end to end, the
// way the app runs it (owner, 2026-10-07: "make sure the integrated node
// works well"). A NEW wallet is created and opened through the Dart API with
// the core as a library inside this process (InProcessHost + libbeam_core),
// the private node on (BeamInProcessNode). Then:
//
//   1. the wallet can send on a PUBLIC node within a minute (it never waits
//      for the node);
//   2. the node fast-syncs from nothing (headers, the UTXO set, "Raising
//      Fossil") — every phase change and every 5 minutes is logged;
//   3. the wallet moves to the node only when it is really ready, and can
//      send on it (own_node, is_in_sync) within 2 minutes;
//   4. closing the wallet stops the node cleanly; reopening finds the
//      synced node and moves again quickly;
//   5. no child process at any point.
//
//   BEAM_NODE_FULL_IT=1 BEAM_CORE_LIB=<libbeam_core.dylib> \
//       scripts/beam/host_test.sh --no-analyze \
//       test/beam/node/beam_in_process_node_full_live_test.dart
//
// The node's data stays in ~/beam-campfire-test/node-full/ (about 7.6 GB
// once synced; it peaks near 11.4 GB) so a second run starts from a synced
// node; delete that folder to start from nothing. No secret is printed.
@Timeout(Duration(hours: 8))
library;

import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';
import 'package:stackwallet/wallets/beam/host/beam_core_location.dart';
import 'package:stackwallet/wallets/beam/host/in_process_host.dart';
import 'package:stackwallet/wallets/beam/host/secret_file.dart';
import 'package:stackwallet/wallets/beam/net/beam_node_route.dart';
import 'package:stackwallet/wallets/beam/node/beam_in_process_node.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';

import '../wallet/beam_wallet_test_support.dart';

void _evidence(String line) {
  // ignore: avoid_print
  print(
    '[evidence] ${DateTime.now().toIso8601String().substring(11, 19)} '
    '$line',
  );
}

Future<bool> _noChildren() async => (await Process.run('pgrep', [
  '-P',
  '$pid',
])).stdout.toString().trim().isEmpty;

void main() {
  final enabled = Platform.environment['BEAM_NODE_FULL_IT'] == '1';
  final lib = Platform.environment[kBeamCoreLibraryEnv];
  final home = Platform.environment['HOME'];

  test(
    'integrated node: public first, full fast sync, a safe move, sending on '
    'the own node, clean stop and quick return',
    () async {
      final root = p.join(home!, 'beam-campfire-test', 'node-full');
      await ensurePrivateDir(root);
      final beamRoot = p.join(root, 'beam');
      await ensurePrivateDir(beamRoot);
      final isarDir = Directory(p.join(root, 'isar-$pid'))..createSync();
      await openTestMainDb(isarDir);

      final log = <String>[];
      final explorer = BeamExplorerClient(proxyInfo: () => null);
      InProcessHost? host;
      BeamWalletEnvironment.instance = BeamWalletEnvironment(
        beamRoot: () async => beamRoot,
        createHost: (r) => host ??= InProcessHost(
          rootDir: r,
          router: const BeamNodeRouter.direct(),
          locateLibrary: () async =>
              (await locateBeamCoreLibrary(beamRoot: r)).path,
          log: log.add,
        ),
        createExplorer: () => explorer,
        createPrivateNode: (r, h) => BeamInProcessNode(
          rootDir: r,
          core: (h as InProcessHost).integratedCore!,
          router: const BeamNodeRouter.direct(),
          log: (l) => _evidence('node: $l'),
        ),
        privateNodeSetting: const BeamFixedPrivateNodeSetting(true),
        privateNodeStartDelay: const Duration(seconds: 5),
        explorerPollInterval: const Duration(seconds: 20),
        statusPollInterval: const Duration(seconds: 30),
        log: (l) {
          log.add(l);
          if (l.contains('private node') ||
              l.contains('Private node') ||
              l.contains('moving the wallet') ||
              l.contains('own_node') ||
              l.contains('could not send')) {
            _evidence('wallet: $l');
          }
        },
      );

      final secure = FakeSecureStorage();
      final wallet = await Wallet.create(
        walletInfo: WalletInfo.createNew(
          coin: Beam(CryptoCurrencyNetwork.main),
          name: 'node-full',
        ),
        mainDB: MainDB.instance,
        secureStorageInterface: secure,
        nodeService: FakeNodeService(
          beamTestNode('eu-node01.mainnet.beam.mw', 8100),
        ),
        prefs: FakePrefs(),
        mnemonic: bip39.generateMnemonic(),
        mnemonicPassphrase: '',
      ) as BeamWallet;

      try {
        // 1. Public first.
        final sw = Stopwatch()..start();
        await wallet.init();
        await wallet.open();
        await wallet.whenCanSend.timeout(const Duration(seconds: 90));
        _evidence(
          'can send on a public node after ${sw.elapsedMilliseconds} ms '
          '(${wallet.syncAssessment.walletHeight})',
        );
        expect(await _noChildren(), isTrue);

        // 2. + 3. Sync, move, send on the own node.
        String? last;
        var lastPrint = DateTime.now();
        final deadline = DateTime.now().add(const Duration(hours: 7));
        var onOwn = false;
        while (DateTime.now().isBefore(deadline)) {
          final s = wallet.privateNodeStatus;
          final finishing = s?.finishingPercent;
          final line =
              '${s?.phase.name} ${s?.percent ?? ''}% '
              '${finishing == null ? '' : 'finishing $finishing% '}'
              'issue=${s?.issue?.name} '
              'canSpend=${wallet.syncAssessment.canSpend}';
          if (line != last ||
              DateTime.now().difference(lastPrint) >
                  const Duration(minutes: 5)) {
            final df = (await Process.run('df', [
              '-h',
              beamRoot,
            ])).stdout.toString().split('\n')[1].split(RegExp(r'\s+'));
            final du = (await Process.run('du', [
              '-sh',
              p.join(beamRoot, 'node'),
            ])).stdout.toString().split('\t').first;
            _evidence('node $line (node dir $du, disk free ${df[3]})');
            last = line;
            lastPrint = DateTime.now();
          }
          if (s?.phase == BeamPrivateNodePhase.active &&
              s?.onPrivateNode == true) {
            onOwn = true;
            break;
          }
          await Future<void>.delayed(const Duration(seconds: 10));
        }
        expect(onOwn, isTrue, reason: 'the wallet moved to its own node');
        _evidence('on the private node after ${sw.elapsed}');
        final ownSw = Stopwatch()..start();
        while (!wallet.syncAssessment.canSpend) {
          if (ownSw.elapsed > const Duration(minutes: 2)) {
            fail('cannot send 2 minutes after the move');
          }
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        _evidence(
          'can send on the OWN node ${ownSw.elapsedMilliseconds} ms after the '
          'move (height ${wallet.syncAssessment.walletHeight}, private receive '
          '${wallet.privateNodeStatus?.privateReceiveAvailable})',
        );
        // Stays there: watch 5 minutes.
        await Future<void>.delayed(const Duration(minutes: 5));
        expect(wallet.privateNodeStatus?.onPrivateNode, isTrue);
        expect(wallet.syncAssessment.canSpend, isTrue);
        expect(await _noChildren(), isTrue);

        // 4. Clean stop and a quick return.
        final stopSw = Stopwatch()..start();
        await wallet.exit();
        _evidence(
          'wallet closed, node stopped in ${stopSw.elapsedMilliseconds} ms',
        );
        final again = Stopwatch()..start();
        await wallet.init();
        await wallet.open();
        await wallet.whenCanSend.timeout(const Duration(seconds: 90));
        _evidence(
          'reopened: can send (public) after ${again.elapsedMilliseconds} ms',
        );
        while (wallet.privateNodeStatus?.onPrivateNode != true) {
          if (again.elapsed > const Duration(minutes: 20)) {
            fail(
              'no move back to the synced node within 20 minutes: '
              '${wallet.privateNodeStatus}',
            );
          }
          await Future<void>.delayed(const Duration(seconds: 5));
        }
        _evidence('back on the synced private node after ${again.elapsed}');
      } finally {
        await wallet.exit();
        await BeamInProcessNode.stopAll();
        await InProcessHost.shutdownAll();
        await isarDir.delete(recursive: true);
        for (final l in log.where(
          (l) => l.contains('Private') || l.contains('node'),
        )) {
          _evidence('log $l');
        }
      }
    },
    skip: !enabled || lib == null || home == null
        ? 'BEAM_NODE_FULL_IT=1 and $kBeamCoreLibraryEnv are required'
        : false,
  );
}

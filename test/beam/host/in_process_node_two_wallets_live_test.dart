/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// LIVE, no funds: two wallets and the app's one private node, on the real
// BEAM core inside this process (libbeam_core), against BEAM mainnet with
// two throwaway wallets. What a user with two BEAM wallets open saw as "Your
// private node is already running in another window":
//
//   1. wallet A's node starts and runs;
//   2. wallet B's start is refused as serving another wallet (never "another
//      window"), and B's clean-up leaves A's node running;
//   3. once A's node stops, B's node starts at once on B's own key.
//
//   BEAM_LIB_IT=1 BEAM_CORE_LIB=<path to libbeam_core.dylib> \
//       scripts/beam/host_test.sh --no-analyze \
//       test/beam/host/in_process_node_two_wallets_live_test.dart
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';
import 'dart:math';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/host/beam_core_location.dart';
import 'package:stackwallet/wallets/beam/host/beam_core_node_status.dart';
import 'package:stackwallet/wallets/beam/host/in_process_host.dart';
import 'package:stackwallet/wallets/beam/host/secret_file.dart';
import 'package:stackwallet/wallets/beam/net/beam_node_route.dart';
import 'package:stackwallet/wallets/beam/node/beam_in_process_node.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_process.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_progress.dart';

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
  final enabled = Platform.environment['BEAM_LIB_IT'] == '1';
  final lib = Platform.environment[kBeamCoreLibraryEnv];
  final home = Platform.environment['HOME'];

  test(
    'two wallets, one private node: the second waits its turn and never '
    'stops the first',
    () async {
      final roots = <Directory>[];
      Future<(InProcessHost, String, String, String)> wallet(String tag) async {
        final root = Directory(
          p.join(home!, 'beam-campfire-test', 'node2-$tag-${_rand(6)}'),
        );
        roots.add(root);
        await ensurePrivateDir(root.path);
        final host = InProcessHost(
          rootDir: root.path,
          router: const BeamNodeRouter.direct(),
          locateLibrary: () async =>
              (await locateBeamCoreLibrary(beamRoot: root.path)).path,
          log: (_) {},
        );
        final dir = p.join(root.path, 'wallets', tag);
        final password = _rand(24);
        await host.initWallet(
          walletDir: dir,
          password: password,
          words: bip39.generateMnemonic().split(' '),
        );
        final key = await host.exportOwnerKey(
          walletDir: dir,
          password: password,
        );
        return (host, root.path, password, key);
      }

      BeamInProcessNode nodeFor(InProcessHost host, String root) =>
          BeamInProcessNode(
            rootDir: root,
            core: host.integratedCore!,
            router: const BeamNodeRouter.direct(),
            log: (l) => _evidence('node $l'),
          );

      try {
        final (hostA, rootA, passA, keyA) = await wallet('a');
        final (hostB, rootB, passB, keyB) = await wallet('b');
        final core = hostA.integratedCore!;
        _evidence('two throwaway wallets, owner keys read (not shown)');

        // 1. Wallet A's node.
        final a = nodeFor(hostA, rootA);
        await a.start(ownerKey: keyA, password: passA);
        expect(core.nodeStatus().state, BeamCoreNodeState.running);
        expect(a.progress.ownerAccounts, 1);
        _evidence('A: node running on 127.0.0.1:${a.port}');

        // 2. Wallet B, while A's node runs.
        final b = nodeFor(hostB, rootB);
        expect(b.servesAnotherWallet, isTrue);
        await expectLater(
          b.start(ownerKey: keyB, password: passB),
          throwsA(
            isA<BeamNodeException>().having(
              (e) => e.kind,
              'kind',
              BeamNodeError.servingOtherWallet,
            ),
          ),
        );
        await b.stop(); // what the coordinator does after a failed start
        await Future<void>.delayed(const Duration(seconds: 5));
        expect(
          core.nodeStatus().state,
          BeamCoreNodeState.running,
          reason: "B's clean-up stopped A's node",
        );
        expect(a.progress.isEnded, isFalse);
        _evidence(
          'B: refused as serving another wallet; A still running '
          '(${a.progress.peersSeen} peers)',
        );

        // 3. A stops; B takes the node at once, on its own key.
        await a.stop();
        expect(core.nodeStatus().isEnded, isTrue);
        final b2 = nodeFor(hostB, rootB);
        expect(b2.servesAnotherWallet, isFalse);
        await b2.start(ownerKey: keyB, password: passB);
        expect(core.nodeStatus().state, BeamCoreNodeState.running);
        expect(b2.progress.ownerAccounts, 1);
        _evidence('A stopped; B: node running on 127.0.0.1:${b2.port}');
        await b2.stop();
        expect(core.nodeStatus().isEnded, isTrue);
        _evidence('B stopped; no node left running');
      } finally {
        await BeamInProcessNode.stopAll();
        await InProcessHost.shutdownAll();
        for (final r in roots) {
          if (await r.exists()) await r.delete(recursive: true);
        }
      }
    },
    skip: !enabled || lib == null || home == null
        ? 'BEAM_LIB_IT=1 and $kBeamCoreLibraryEnv are required'
        : false,
  );
}

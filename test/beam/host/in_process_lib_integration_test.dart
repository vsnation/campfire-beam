/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// LIVE, no funds: the BEAM core inside the app's process (libbeam_core, as
// BEAM's desktop wallet runs it): the app's own InProcessHost and
// BeamInProcessNode drive wallet-api and the node as threads of this test
// process, against BEAM mainnet with a throwaway wallet — directly, and
// (with a local `tor`) with every connection through Tor.
//
//   BEAM_LIB_IT=1 BEAM_CORE_LIB=<path to libbeam_core.dylib> \
//   [BEAM_TOR_BIN=/opt/homebrew/bin/tor] \
//       scripts/beam/host_test.sh --no-analyze test/beam/host/in_process_lib_integration_test.dart
@Timeout(Duration(minutes: 15))
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/host/beam_core_location.dart';
import 'package:stackwallet/wallets/beam/host/beam_host.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/host/in_process_host.dart';
import 'package:stackwallet/wallets/beam/host/secret_file.dart';
import 'package:stackwallet/wallets/beam/net/beam_node_route.dart';
import 'package:stackwallet/wallets/beam/node/beam_in_process_node.dart';
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

/// Tor through a `tor` the test started itself.
class _LocalTorRouter implements BeamNodeRouter {
  _LocalTorRouter(this.port);

  final int port;

  @override
  bool get torOn => true;

  @override
  Future<BeamNodeRoute> route(BeamNodeEndpoint node) async {
    if (isLoopbackHost(node.host)) return BeamNodeRoute(address: node);
    final ip = await resolveThroughTor(
      node.host,
      proxyHost: InternetAddress.loopbackIPv4,
      proxyPort: port,
    );
    return BeamNodeRoute(
      address: BeamNodeEndpoint(ip, node.port, isOwned: node.isOwned),
      socksProxy: '127.0.0.1:$port',
    );
  }
}

Future<Map<String, Object?>> _waitInSync(BeamSession s) async {
  final deadline = DateTime.now().add(const Duration(minutes: 3));
  while (true) {
    final r = await s.transport.call(
      'wallet_status',
      const {},
      const Duration(seconds: 20),
    );
    final m = (r as Map).cast<String, Object?>();
    if (m['is_in_sync'] == true && ((m['current_height'] as int?) ?? 0) > 0) {
      return m;
    }
    if (DateTime.now().isAfter(deadline)) {
      fail('not in sync in 3 minutes: $m');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
}

/// The non-loopback TCP peers of this process (lsof), for the Tor check.
Future<List<String>> _externalTcp() async {
  final r = await Process.run('lsof', [
    '-nP',
    '-a',
    '-p',
    '$pid',
    '-iTCP',
  ]);
  return '${r.stdout}'
      .split('\n')
      .where((l) => l.contains('->') && !l.contains('->127.0.0.1:'))
      .toList();
}

void main() {
  final enabled = Platform.environment['BEAM_LIB_IT'] == '1';
  final lib = Platform.environment[kBeamCoreLibraryEnv];
  final home = Platform.environment['HOME'];
  final torBin = Platform.environment['BEAM_TOR_BIN'];

  Future<(Directory, InProcessHost, String, String)> setUpWallet(
    String tag, {
    BeamNodeRouter? router,
  }) async {
    final root = Directory(
      p.join(home!, 'beam-campfire-test', 'lib-$tag-${_rand(6)}'),
    );
    await ensurePrivateDir(root.path);
    final host = InProcessHost(
      rootDir: root.path,
      router: router ?? const BeamNodeRouter.direct(),
      locateLibrary: () async =>
          (await locateBeamCoreLibrary(beamRoot: root.path)).path,
      log: (l) => _evidence('host $l'),
    );
    final walletDir = p.join(root.path, 'wallets', 'it');
    final password = _rand(24);
    await host.initWallet(
      walletDir: walletDir,
      password: password,
      words: bip39.generateMnemonic().split(' '),
    );
    return (root, host, walletDir, password);
  }

  test(
    'direct: wallet-api and the node as threads of this process',
    () async {
      final (root, host, walletDir, password) = await setUpWallet('direct');
      try {
        final sw = Stopwatch()..start();
        final session = await host.openWallet(
          walletDir: walletDir,
          password: password,
          node: const BeamNodeEndpoint('eu-node01.mainnet.beam.mw', 8100),
        );
        final status = await _waitInSync(session);
        final children = (await Process.run('pgrep', ['-P', '$pid'])).stdout
            .toString()
            .trim();
        _evidence(
          'in sync at ${status['current_height']} after '
          '${sw.elapsedMilliseconds} ms (no child process: '
          '${children.isEmpty})',
        );
        await session.close();

        final key = await host.exportOwnerKey(
          walletDir: walletDir,
          password: password,
        );
        expect(key.length, greaterThan(40));
        _evidence('owner key read in-process (${key.length} chars, not shown)');
        await expectLater(
          host.exportOwnerKey(walletDir: walletDir, password: '${password}x'),
          throwsA(
            isA<BeamHostException>().having(
              (e) => e.kind,
              'kind',
              BeamHostError.wrongPassword,
            ),
          ),
        );

        final node = BeamInProcessNode(
          rootDir: root.path,
          core: host.integratedCore!,
          router: const BeamNodeRouter.direct(),
          log: (l) => _evidence('node $l'),
        );
        final events = <BeamNodeProgress>[];
        final sub = node.progressStream.listen(events.add);
        await node.start(ownerKey: key, password: password);
        expect(node.port, isNotNull);
        expect(node.progress.ownerAccounts, 1);
        await Future<void>.delayed(const Duration(seconds: 20));
        _evidence(
          'node: ${events.length} progress updates, now ${node.progress}',
        );
        expect(node.progress.peersSeen, greaterThan(0));
        final stopSw = Stopwatch()..start();
        await node.stop();
        expect(node.progress.isEnded, isTrue);
        _evidence('node stopped in ${stopSw.elapsedMilliseconds} ms');
        await sub.cancel();
        expect(
          (await Process.run('pgrep', ['-P', '$pid'])).stdout
              .toString()
              .trim(),
          isEmpty,
          reason: 'no child process at all',
        );
      } finally {
        await BeamInProcessNode.stopAll();
        await InProcessHost.shutdownAll();
        await root.delete(recursive: true);
      }
    },
    skip: !enabled || lib == null || home == null
        ? 'BEAM_LIB_IT=1 and $kBeamCoreLibraryEnv are required'
        : false,
  );

  test(
    'two wallets open side by side, one closes, the other keeps answering',
    () async {
      final (rootA, hostA, dirA, passA) = await setUpWallet('multi-a');
      final (rootB, hostB, dirB, passB) = await setUpWallet('multi-b');
      try {
        final a = await hostA.openWallet(
          walletDir: dirA,
          password: passA,
          node: const BeamNodeEndpoint('eu-node01.mainnet.beam.mw', 8100),
        );
        final b = await hostB.openWallet(
          walletDir: dirB,
          password: passB,
          node: const BeamNodeEndpoint('eu-node02.mainnet.beam.mw', 8100),
        );
        final sa = await _waitInSync(a);
        final sb = await _waitInSync(b);
        _evidence(
          'A in sync at ${sa['current_height']}, B at ${sb['current_height']}',
        );
        await b.close();
        final again = await _waitInSync(a);
        _evidence('B closed; A still answers (${again['current_height']})');
        final b2 = await hostB.openWallet(
          walletDir: dirB,
          password: passB,
          node: const BeamNodeEndpoint('eu-node02.mainnet.beam.mw', 8100),
        );
        await _waitInSync(b2);
        _evidence('B reopened next to A');
        await expectLater(
          hostA.openWallet(
            walletDir: dirA,
            password: passA,
            node: const BeamNodeEndpoint('eu-node01.mainnet.beam.mw', 8100),
          ),
          throwsA(
            isA<BeamHostException>().having(
              (e) => e.kind,
              'kind',
              BeamHostError.walletInUse,
            ),
          ),
          reason: 'the same wallet twice is still refused (R8)',
        );
      } finally {
        await InProcessHost.shutdownAll();
        await rootA.delete(recursive: true);
        await rootB.delete(recursive: true);
      }
    },
    skip: !enabled || lib == null || home == null
        ? 'BEAM_LIB_IT=1 and $kBeamCoreLibraryEnv are required'
        : false,
  );

  test(
    'Tor: every connection of wallet-api and the node goes through Tor',
    () async {
      final torDir = await Directory.systemTemp.createTemp('beam-lib-tor-');
      final socks = await (() async {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = s.port;
        await s.close();
        return port;
      })();
      final tor = await Process.start(torBin!, [
        '--SocksPort',
        '127.0.0.1:$socks',
        '--DataDirectory',
        torDir.path,
        '--Log',
        'notice stdout',
      ]);
      final bootstrapped = Completer<void>();
      tor.stdout.transform(const SystemEncoding().decoder).listen((l) {
        if (l.contains('Bootstrapped 100%') && !bootstrapped.isCompleted) {
          bootstrapped.complete();
        }
      });
      final (root, host, walletDir, password) = await setUpWallet(
        'tor',
        router: _LocalTorRouter(socks),
      );
      try {
        await bootstrapped.future.timeout(const Duration(minutes: 3));
        _evidence('tor bootstrapped, SOCKS 127.0.0.1:$socks');
        final session = await host.openWallet(
          walletDir: walletDir,
          password: password,
          node: const BeamNodeEndpoint('eu-node01.mainnet.beam.mw', 8100),
        );
        final status = await _waitInSync(session);
        _evidence('via Tor: in sync at ${status['current_height']}');
        await session.close();
        final key = await host.exportOwnerKey(
          walletDir: walletDir,
          password: password,
        );
        final node = BeamInProcessNode(
          rootDir: root.path,
          core: host.integratedCore!,
          router: _LocalTorRouter(socks),
          log: (l) => _evidence('node $l'),
        );
        await node.start(ownerKey: key, password: password);
        await Future<void>.delayed(const Duration(seconds: 30));
        _evidence('node via Tor: ${node.progress}');
        expect(node.progress.peersSeen, greaterThan(0));
        final external = await _externalTcp();
        _evidence('TCP to anything but 127.0.0.1: ${external.length}');
        expect(external, isEmpty, reason: external.join('\n'));
        await node.stop();
      } finally {
        await BeamInProcessNode.stopAll();
        await InProcessHost.shutdownAll();
        tor.kill();
        await root.delete(recursive: true);
        await torDir.delete(recursive: true);
      }
    },
    skip: !enabled || lib == null || home == null || torBin == null
        ? 'BEAM_LIB_IT=1, $kBeamCoreLibraryEnv and BEAM_TOR_BIN are required'
        : false,
  );
}

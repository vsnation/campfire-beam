/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Public node now, private node soon — for real, on BEAM mainnet.
//
// A throwaway wallet (fresh phrase, random password, never funded) is opened
// on a public node; the coordinator pauses it to read the owner key, starts
// the pinned beam-node with fast sync from an empty storage, waits for the
// honest handover rule and moves the wallet over, then requires
// own_node == true. Nothing secret is printed; the phrase and password live
// only in this process. Everything under the test root is deleted at the end.
//
//   BEAM_NODE_IT=1 \
//   BEAM_BIN_DIR=$HOME/Desktop/Beam/LightWallet/binaries/macos \
//   [BEAM_NODE_IT_LOG=/path/outside/the/repo/evidence.log] \
//   flutter test test/beam/node/beam_private_node_live_test.dart
//
// Disk: refuses to start below 12 GB free and aborts (stopping the node and
// deleting its storage) if free space drops below that. Gives up after
// BEAM_NODE_IT_MAX_MINUTES (default 150) and reports the progress reached.
@Timeout(Duration(hours: 3))
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';
import 'package:stackwallet/wallets/beam/host/beam_binaries.dart';
import 'package:stackwallet/wallets/beam/host/beam_host.dart';
import 'package:stackwallet/wallets/beam/host/process_host.dart';
import 'package:stackwallet/wallets/beam/host/secret_file.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_process.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_progress.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_messages.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';

const _minFreeBytes = 12 * 1024 * 1024 * 1024;

String _randomAlnum(int length) {
  const chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final r = Random.secure();
  return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
}

/// Free bytes on the volume holding [path], from `df -k`.
Future<int> _freeBytes(String path) async {
  final r = await Process.run('df', ['-k', path]);
  final lines = '${r.stdout}'.trim().split('\n');
  final cols = lines.last.trim().split(RegExp(r'\s+'));
  return int.parse(cols[3]) * 1024;
}

/// Size of [path] in bytes, from `du -sk`.
Future<int> _sizeOf(String path) async {
  if (!await FileSystemEntity.isDirectory(path) &&
      !await File(path).exists()) {
    return 0;
  }
  final r = await Process.run('du', ['-sk', path]);
  return int.parse('${r.stdout}'.trim().split(RegExp(r'\s+')).first) * 1024;
}

String _gb(int bytes) =>
    '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';

String _mmss(Duration d) =>
    '${d.inMinutes}m${(d.inSeconds % 60).toString().padLeft(2, '0')}s';

void main() {
  final enabled = Platform.environment['BEAM_NODE_IT'] == '1';
  final binDir = Platform.environment[BeamBinaries.binDirEnv];
  final home = Platform.environment['HOME'];
  final evidencePath = Platform.environment['BEAM_NODE_IT_LOG'];
  final maxMinutes =
      int.tryParse(Platform.environment['BEAM_NODE_IT_MAX_MINUTES'] ?? '') ??
      150;

  test(
    'public node now, private node fast-syncs from scratch, then handover '
    'with own_node == true',
    () async {
      final clock = Stopwatch()..start();
      final password = _randomAlnum(24);
      final words = bip39.generateMnemonic().split(' ');

      String tilde(String s) => s.replaceAll(home!, '~');

      /// Refuses to print anything that holds the password or two adjacent
      /// phrase words.
      void evidence(String line) {
        var safe = true;
        if (line.contains(password)) safe = false;
        for (var i = 0; i + 1 < words.length; i++) {
          if (line.contains('${words[i]} ${words[i + 1]}') ||
              line.contains('${words[i]};${words[i + 1]}')) {
            safe = false;
          }
        }
        final out = safe
            ? '[${_mmss(clock.elapsed)}] ${tilde(line)}'
            : '[${_mmss(clock.elapsed)}] [evidence line withheld]';
        // ignore: avoid_print
        print('[evidence] $out');
        if (evidencePath != null) {
          File(evidencePath).writeAsStringSync('$out\n', mode: FileMode.append);
        }
      }

      final base = p.join(home!, 'beam-campfire-test');
      await Directory(base).create(recursive: true);
      final free0 = await _freeBytes(base);
      evidence('free space at start: ${_gb(free0)}');
      if (free0 < _minFreeBytes) {
        fail('only ${_gb(free0)} free; need ${_gb(_minFreeBytes)}');
      }

      final root = Directory(p.join(base, 'it-node-${_randomAlnum(8)}'));
      await ensurePrivateDir(root.path);
      evidence('root ${root.path} (0700)');
      final binaries = BeamBinaries(
        binDir: binDir!,
        // flutter_tester is x86_64 under Rosetta; the pinned arm64 binaries
        // run natively.
        platform: Platform.isMacOS ? 'macos-arm64' : null,
      );
      final host = ProcessHost(
        rootDir: root.path,
        binaries: binaries,
        log: (l) => evidence('host: $l'),
        startupTimeout: const Duration(seconds: 30),
      );

      BeamPrivateNodeCoordinator? coordinator;
      BeamNodeProcess? node;
      Timer? diskTimer;
      Timer? reportTimer;
      var diskAbort = false;
      try {
        final walletDir = host.walletDirFor('it');
        await host.initWallet(
          walletDir: walletDir,
          password: password,
          words: words,
        );
        evidence('throwaway wallet created');

        const publicNode = BeamNodeEndpoint('eu-nodes.mainnet.beam.mw', 8100);
        final openSw = Stopwatch()..start();
        final session = await host.openWallet(
          walletDir: walletDir,
          password: password,
          node: publicNode,
        );
        final st = await session.transport.call('wallet_status');
        evidence(
          'opened on $publicNode in ${openSw.elapsedMilliseconds} ms; '
          'wallet_status current_height=${(st as Map)['current_height']}',
        );

        // Watch every session's own_node reports.
        final connectionEvents = <Map<String, Object?>>[];
        final eventSubs = <StreamSubscription<BeamEvent>>[];
        void watch(BeamSession? s) {
          if (s == null) return;
          eventSubs.add(
            s.transport.events.listen((e) {
              if (e.name != 'ev_connection_changed') return;
              connectionEvents.add({...e.data, 'node': '${s.node}'});
              evidence(
                'ev_connection_changed on ${s.node}: '
                'node_connected=${e.data['node_connected']} '
                'own_node=${e.data['own_node']}',
              );
            }),
          );
        }

        final explorer = BeamExplorerClient(proxyInfo: () => null);
        final net0 = await explorer.status();
        evidence('explorer ${net0.node} height ${net0.height}');

        Duration? fastSyncTarget;
        Duration? fastSyncDone;
        Duration? txReplicationOn;
        int? fastSyncTargetHeight;
        final c = BeamPrivateNodeCoordinator(
          host: host,
          session: session,
          walletDir: walletDir,
          password: () async => password,
          explorer: explorer,
          nodeFactory: () {
            final n = BeamNodeProcess(
              rootDir: root.path,
              binaries: binaries,
              log: (l) => evidence('node: $l'),
            );
            node = n;
            var lastPhase = BeamNodePhase.starting;
            n.progressStream.listen((pr) {
              if (pr.fastSyncTarget != null && fastSyncTarget == null) {
                fastSyncTarget = clock.elapsed;
                fastSyncTargetHeight = pr.fastSyncTarget;
                evidence('node: fast-sync target ${pr.fastSyncTarget}');
              }
              if (pr.phase != lastPhase) {
                if (lastPhase == BeamNodePhase.fastSyncDownloading &&
                    pr.phase == BeamNodePhase.catchingUp) {
                  fastSyncDone ??= clock.elapsed;
                }
                if (pr.phase == BeamNodePhase.txReplicationOn) {
                  txReplicationOn ??= clock.elapsed;
                }
                evidence(
                  'node phase ${lastPhase.name} -> ${pr.phase.name}: $pr',
                );
                lastPhase = pr.phase;
              }
            });
            return n;
          },
          log: (l) => evidence('coordinator: $l'),
          ownNodeTimeout: const Duration(minutes: 3),
        );
        coordinator = c;
        watch(session);
        c.sessions.listen(watch);

        final done = Completer<void>();
        c.statuses.listen((s) {
          final msg = BeamPrivateNodeMessages.describe(s);
          if (s.phase == BeamPrivateNodePhase.downloading) return;
          evidence('status ${s.phase.name}: "${msg.title}" ($s)');
          if (s.phase == BeamPrivateNodePhase.active &&
              s.privateReceiveAvailable &&
              !done.isCompleted) {
            done.complete();
          }
          if (const {
                BeamPrivateNodePhase.failed,
                BeamPrivateNodePhase.stopped,
                BeamPrivateNodePhase.ownNodeUnconfirmed,
                BeamPrivateNodePhase.walletClosed,
              }.contains(s.phase) &&
              !done.isCompleted) {
            done.completeError(StateError('coordinator ended in $s'));
          }
        });

        diskTimer = Timer.periodic(const Duration(minutes: 2), (_) async {
          final free = await _freeBytes(base);
          if (free < _minFreeBytes && !done.isCompleted) {
            diskAbort = true;
            evidence('ABORT: free space ${_gb(free)} < ${_gb(_minFreeBytes)}');
            done.completeError(StateError('disk budget'));
          }
        });
        reportTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
          final s = c.status;
          final nodeDir = p.join(root.path, 'node');
          evidence(
            'progress: ${s.phase.name} '
            '${s.percent == null ? '' : '${s.percent}% '}'
            'node ${node?.progress.bestHeight} '
            'network ${s.networkHeight} | node dir '
            '${_gb(await _sizeOf(nodeDir))}, '
            'free ${_gb(await _freeBytes(base))}',
          );
        });

        final startSw = Stopwatch()..start();
        await c.start();
        evidence(
          'coordinator started in ${startSw.elapsedMilliseconds} ms; wallet '
          'pause for the owner key: ${c.status.lastPause?.inMilliseconds} ms; '
          'status ${c.status}',
        );
        expect(c.session, isNotNull);
        expect(c.session!.node, publicNode);
        expect(
          SecretFiles.livePaths.where((f) => f.contains('${p.separator}node')),
          isEmpty,
          reason: 'the node config file is gone once the node read it',
        );

        try {
          await done.future.timeout(Duration(minutes: maxMinutes));
        } on TimeoutException {
          evidence(
            'GAVE UP after $maxMinutes min: ${c.status} '
            'node ${node?.progress}',
          );
          rethrow;
        }

        final handover = clock.elapsed;
        final nodeDir = p.join(root.path, 'node');
        evidence(
          'TIMINGS: fast-sync target seen at '
          '${fastSyncTarget == null ? '-' : _mmss(fastSyncTarget!)} '
          '(block $fastSyncTargetHeight), fast sync done at '
          '${fastSyncDone == null ? '-' : _mmss(fastSyncDone!)}, '
          'Tx replication ON at '
          '${txReplicationOn == null ? '-' : _mmss(txReplicationOn!)}, '
          'handover confirmed at ${_mmss(handover)}; switch pause '
          '${c.status.lastPause?.inMilliseconds} ms',
        );
        evidence(
          'SIZES: node.db ${_gb(await _sizeOf(p.join(nodeDir, 'node.db')))}, '
          'node dir ${_gb(await _sizeOf(nodeDir))}',
        );

        expect(c.status.phase, BeamPrivateNodePhase.active);
        expect(c.privateReceiveAvailable, isTrue);
        expect(c.session!.node.isOwned, isTrue);
        expect(c.session!.node.host, '127.0.0.1');
        expect(
          connectionEvents.any(
            (e) => e['own_node'] == true && '${e['node']}'.startsWith('127.'),
          ),
          isTrue,
        );

        // The private node lets the wallet do what a public one cannot.
        try {
          final addr = await c.session!.transport.call('create_address', {
            'type': 'offline',
            'expiration': 'never',
            'comment': 'campfire node it',
          });
          evidence('create_address type=offline OK (${'$addr'.length} chars)');
        } catch (e) {
          evidence('create_address type=offline failed: $e');
        }

        // Nothing secret on disk or in logs.
        final leftovers = await Directory(nodeDir)
            .list()
            .map((e) => p.basename(e.path))
            .where((n) => n.startsWith(kSecretPrefix))
            .toList();
        expect(leftovers, isEmpty);
        final logs = await Directory(p.join(nodeDir, 'logs'))
            .list()
            .where((e) => e is File)
            .cast<File>()
            .toList();
        for (final f in logs) {
          final text = await f.readAsString();
          expect(text.contains(password), isFalse, reason: f.path);
          expect(
            RegExp(r'[A-Za-z0-9+/=]{100,}').hasMatch(text),
            isFalse,
            reason: '${p.basename(f.path)} holds a key-shaped token',
          );
          if (p.basename(f.path).startsWith('campfire-node-')) {
            expect(await posixMode(f.path), 0x180);
          }
        }
        evidence('logs checked: ${logs.length} file(s), no secrets');
        for (final s in eventSubs) {
          await s.cancel();
        }
      } finally {
        diskTimer?.cancel();
        reportTimer?.cancel();
        final nodeDir = p.join(root.path, 'node');
        final finalSize = await _sizeOf(nodeDir);
        await coordinator?.dispose();
        await coordinator?.session?.close();
        await ProcessHost.shutdownAll();
        await BeamNodeProcess.stopAll();
        evidence(
          'cleanup: node dir was ${_gb(finalSize)}'
          '${diskAbort ? ' (disk abort)' : ''}; deleting ${root.path}',
        );
        await root.delete(recursive: true);
        expect(await root.exists(), isFalse);
        evidence('deleted; free space now ${_gb(await _freeBytes(base))}');
      }
    },
    skip: !enabled
        ? 'set BEAM_NODE_IT=1 (real binaries, mainnet, hours, ~GBs of disk)'
        : binDir == null || binDir.isEmpty
        ? 'set ${BeamBinaries.binDirEnv}'
        : home == null
        ? 'no HOME'
        : false,
  );
}

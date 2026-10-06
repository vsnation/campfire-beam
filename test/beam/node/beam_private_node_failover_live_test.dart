/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The whole private-node life on BEAM mainnet, measured:
//
// 1. First launch: a throwaway wallet opens on a public node; the
//    coordinator fast-syncs a private node from an empty storage, hands
//    over once the readiness rule holds, and own_node == true is awaited.
// 2. Failover: the node is killed with SIGKILL; the wallet must be back on
//    a public node, working, with private receive off.
// 3. Second launch: retry() starts beam-node again on the SAME node.db and
//    must reach handover-ready and own_node == true again.
//
// Every time the wallet has no session (owner-key pause, handover, failover)
// the test records: the gap with no usable wallet-api (session closed until
// the new one answered get_version), the first successful wallet_status,
// and when wallet_status reports is_in_sync again. Also: fast-sync time,
// readiness -> own_node time, node.db size, lowest free space.
//
// Nothing secret is printed; everything under the test root is deleted at
// the end.
//
//   BEAM_NODE_IT=1 \
//   BEAM_BIN_DIR=$HOME/Desktop/Beam/LightWallet/binaries/macos \
//   [BEAM_NODE_IT_LOG=/path/outside/the/repo/evidence.log] \
//   [BEAM_NODE_IT_MAX_MINUTES=270] \
//   flutter test test/beam/node/beam_private_node_failover_live_test.dart
//
// Disk: refuses to start below 12 GiB free, checks every minute, and aborts
// (stopping the node, deleting its storage) below that floor.
@Timeout(Duration(hours: 6))
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

const _minFreeBytes = 12 * 1024 * 1024 * 1024;

typedef _Phase = BeamPrivateNodePhase;

String _randomAlnum(int length) {
  const chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final r = Random.secure();
  return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
}

Future<int> _freeBytes(String path) async {
  final r = await Process.run('df', ['-k', path]);
  final lines = '${r.stdout}'.trim().split('\n');
  final cols = lines.last.trim().split(RegExp(r'\s+'));
  return int.parse(cols[3]) * 1024;
}

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

String _at(Duration? d) => d == null ? '-' : _mmss(d);

const _terminal = {
  _Phase.failed,
  _Phase.stopped,
  _Phase.ownNodeUnconfirmed,
  _Phase.walletClosed,
};

/// One period without a usable wallet session, and how it ended.
class _Gap {
  _Gap(this.label, this.closedAt);

  final String label;
  final DateTime closedAt;
  BeamNodeEndpoint? node;

  /// Session closed -> new session answered get_version (ProcessHost
  /// returns the session only after that call succeeded).
  Duration? noSession;

  /// Session closed -> first successful wallet_status.
  Duration? firstStatus;

  /// Session closed -> wallet_status.is_in_sync == true.
  Duration? inSync;
  int? statusCalls;
  Object? error;

  @override
  String toString() =>
      'GAP $label -> $node: no session ${noSession?.inMilliseconds} ms; '
      'first wallet_status ${firstStatus?.inMilliseconds} ms; '
      'is_in_sync ${inSync?.inMilliseconds ?? 'not reached'} ms '
      '(after $statusCalls wallet_status calls)'
      '${error == null ? '' : '; probe error $error'}';
}

void main() {
  final enabled = Platform.environment['BEAM_NODE_IT'] == '1';
  final binDir = Platform.environment[BeamBinaries.binDirEnv];
  final home = Platform.environment['HOME'];
  final evidencePath = Platform.environment['BEAM_NODE_IT_LOG'];
  final maxMinutes =
      int.tryParse(Platform.environment['BEAM_NODE_IT_MAX_MINUTES'] ?? '') ??
      270;

  test(
    'fast sync from scratch, handover with own_node == true, failover on a '
    'killed node, then a second launch on the same node.db',
    () async {
      final clock = Stopwatch()..start();
      final password = _randomAlnum(24);
      final words = bip39.generateMnemonic().split(' ');

      String tilde(String s) => s.replaceAll(home!, '~');

      void evidence(String line) {
        var safe = !line.contains(password);
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
      var minFree = free0;
      evidence('free space at start: ${_gb(free0)}');
      if (free0 < _minFreeBytes) {
        fail('only ${_gb(free0)} free; need ${_gb(_minFreeBytes)}');
      }

      final root = Directory(p.join(base, 'it-node-${_randomAlnum(8)}'));
      await ensurePrivateDir(root.path);
      final nodeDir = p.join(root.path, 'node');
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
        log: (l) {
          if (!l.startsWith('beam rpc ')) evidence('host: $l');
        },
        startupTimeout: const Duration(seconds: 30),
      );

      BeamPrivateNodeCoordinator? coordinator;
      BeamNodeProcess? node;
      Timer? diskTimer;
      Timer? reportTimer;
      var diskAbort = false;
      final diskSignal = Completer<void>();
      final subs = <StreamSubscription<Object?>>[];
      final gaps = <_Gap>[];
      final probes = <Future<void>>[];
      try {
        final walletDir = host.walletDirFor('it');
        await host.initWallet(
          walletDir: walletDir,
          password: password,
          words: words,
        );
        evidence('throwaway wallet created');

        const publicNode = BeamNodeEndpoint('eu-nodes.mainnet.beam.mw', 8100);
        final session = await host.openWallet(
          walletDir: walletDir,
          password: password,
          node: publicNode,
        );
        evidence('opened on $publicNode');

        final connectionEvents = <Map<String, Object?>>[];
        void watch(BeamSession? s) {
          if (s == null) return;
          subs.add(
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

        /// From the moment a session is replaced: first wallet_status, then
        /// is_in_sync, polled every 250 ms for up to 10 minutes.
        Future<void> probe(_Gap gap, BeamSession s) async {
          final deadline = DateTime.now().add(const Duration(minutes: 10));
          var calls = 0;
          while (DateTime.now().isBefore(deadline)) {
            try {
              calls++;
              final st = await s.transport.call(
                'wallet_status',
                const {},
                const Duration(seconds: 10),
              );
              final now = DateTime.now();
              gap.firstStatus ??= now.difference(gap.closedAt);
              if (st is Map && st['is_in_sync'] == true) {
                gap.inSync = now.difference(gap.closedAt);
                break;
              }
            } catch (e) {
              gap.error = e.runtimeType;
              if (identical(s, coordinator?.session) == false &&
                  coordinator?.session != null) {
                break; // replaced again
              }
            }
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          gap.statusCalls = calls;
          evidence('$gap');
        }

        final explorer = BeamExplorerClient(proxyInfo: () => null);
        evidence('explorer height ${(await explorer.status()).height}');

        var launch = 1;
        final fastSyncStart = <int, Duration>{};
        final fastSyncDone = <int, Duration>{};
        final nodeReady = <int, Duration>{};
        final initialTip = <int, int>{};
        final switching = <int, Duration>{};
        final confirmed = <int, Duration>{};
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
            final l = launch;
            var last = BeamNodePhase.starting;
            var sawInitial = false;
            subs.add(
              n.progressStream.listen((pr) {
                if (!sawInitial && pr.initialTipHeight != null) {
                  sawInitial = true;
                  initialTip[l] = pr.initialTipHeight!;
                  evidence('node #$l Initial Tip ${pr.initialTipHeight}');
                }
                if (pr.phase == last) return;
                if (pr.phase == BeamNodePhase.fastSyncDownloading) {
                  fastSyncStart[l] ??= clock.elapsed;
                }
                if (last == BeamNodePhase.fastSyncDownloading &&
                    pr.phase == BeamNodePhase.catchingUp) {
                  fastSyncDone[l] ??= clock.elapsed;
                }
                if (pr.phase == BeamNodePhase.txReplicationOn) {
                  nodeReady[l] ??= clock.elapsed;
                }
                evidence(
                  'node #$l phase ${last.name} -> ${pr.phase.name}: $pr',
                );
                last = pr.phase;
              }),
            );
            return n;
          },
          log: (l) => evidence('coordinator: $l'),
          ownNodeTimeout: const Duration(minutes: 3),
        );
        coordinator = c;
        watch(session);

        _Gap? open;
        subs.add(
          c.sessions.listen((s) {
            final now = DateTime.now();
            if (s == null) {
              final label = switch (c.status.phase) {
                _Phase.preparing => 'owner-key pause #$launch',
                _Phase.switching => 'handover #$launch',
                _ => 'failover (${c.status.phase.name})',
              };
              open = _Gap(label, now);
              return;
            }
            watch(s);
            final g = open;
            open = null;
            if (g == null) return;
            g.node = s.node;
            g.noSession = now.difference(g.closedAt);
            gaps.add(g);
            probes.add(probe(g, s));
          }),
        );

        var lastPhase = c.status.phase;
        subs.add(
          c.statuses.listen((s) {
            if (s.phase == _Phase.switching) {
              switching[launch] ??= clock.elapsed;
            }
            if (s.phase == _Phase.active && s.privateReceiveAvailable) {
              confirmed[launch] ??= clock.elapsed;
            }
            if (s.phase != lastPhase) {
              final msg = BeamPrivateNodeMessages.describe(s);
              evidence('status ${s.phase.name}: "${msg.title}" ($s)');
              lastPhase = s.phase;
            }
          }),
        );

        Future<BeamPrivateNodeStatus> waitStatus(
          String what,
          bool Function(BeamPrivateNodeStatus s) done, {
          required Duration timeout,
          Set<_Phase> failOn = const {},
        }) async {
          final result = Completer<BeamPrivateNodeStatus>();
          void check(BeamPrivateNodeStatus s) {
            if (result.isCompleted) return;
            if (done(s)) {
              result.complete(s);
            } else if (failOn.contains(s.phase)) {
              result.completeError(StateError('$what: ended in $s'));
            }
          }

          final sub = c.statuses.listen(check);
          check(c.status);
          unawaited(
            diskSignal.future.then((_) {
              if (!result.isCompleted) {
                result.completeError(StateError('$what: disk budget'));
              }
            }),
          );
          try {
            return await result.future.timeout(timeout);
          } on TimeoutException {
            evidence(
              'GAVE UP waiting for $what after ${timeout.inMinutes} min: '
              '${c.status} node ${node?.progress}',
            );
            rethrow;
          } finally {
            await sub.cancel();
          }
        }

        Future<void> checkDisk() async {
          final free = await _freeBytes(base);
          if (free < minFree) minFree = free;
          if (free < _minFreeBytes && !diskSignal.isCompleted) {
            diskAbort = true;
            evidence('ABORT: free space ${_gb(free)} < ${_gb(_minFreeBytes)}');
            diskSignal.complete();
          }
        }

        diskTimer = Timer.periodic(
          const Duration(minutes: 1),
          (_) => unawaited(checkDisk()),
        );
        reportTimer = Timer.periodic(const Duration(minutes: 10), (_) async {
          final s = c.status;
          evidence(
            'progress: ${s.phase.name} '
            '${s.percent == null ? '' : '${s.percent}% '}'
            'node ${node?.progress.bestHeight} network ${s.networkHeight} '
            '| node dir ${_gb(await _sizeOf(nodeDir))}, '
            'free ${_gb(await _freeBytes(base))}, '
            'lowest ${_gb(minFree)}',
          );
        });

        // ------------------------------------------------- 1. first launch
        await c.start();
        evidence('coordinator started: ${c.status}');
        expect(c.session!.node, publicNode);
        await waitStatus(
          'handover #1',
          (s) => s.phase == _Phase.active && s.privateReceiveAvailable,
          timeout: Duration(minutes: maxMinutes),
          failOn: _terminal,
        );
        await Future.wait(probes);
        final own1 = c.session!.node;
        expect(own1.isOwned, isTrue);
        expect(own1.host, '127.0.0.1');
        expect(own1.port, node!.port);
        expect(
          connectionEvents.any(
            (e) => e['own_node'] == true && '${e['node']}' == '$own1',
          ),
          isTrue,
        );
        final fs1 = fastSyncStart[1];
        final fd1 = fastSyncDone[1];
        evidence(
          'LAUNCH 1: fast sync ${_at(fs1)} -> ${_at(fd1)} '
          '(${fs1 == null || fd1 == null ? '-' : _mmss(fd1 - fs1)}); '
          'node ready ${_at(nodeReady[1])}; readiness predicate fired '
          '${_at(switching[1])}; own_node confirmed ${_at(confirmed[1])} '
          '(${(confirmed[1]! - switching[1]!).inMilliseconds} ms after '
          'the predicate)',
        );
        evidence(
          'SIZES after launch 1: node.db '
          '${_gb(await _sizeOf(p.join(nodeDir, 'node.db')))}, node dir '
          '${_gb(await _sizeOf(nodeDir))}; free at start ${_gb(free0)}, '
          'lowest ${_gb(minFree)}, peak drop ${_gb(free0 - minFree)}',
        );

        // ------------------------------------------------------ 2. failover
        final pid = node!.pid!;
        final killedAt = clock.elapsed;
        evidence('FAILOVER: SIGKILL beam-node pid $pid');
        Process.killPid(pid, ProcessSignal.sigkill);
        final after = await waitStatus(
          'failover',
          (s) => s.phase == _Phase.stopped,
          timeout: const Duration(minutes: 3),
          failOn: {_Phase.walletClosed},
        );
        await Future.wait(probes);
        final back = c.session!;
        evidence(
          'FAILOVER: ${after.phase.name}/${after.issue?.name} '
          '${(clock.elapsed - killedAt).inMilliseconds} ms after the kill '
          '(includes the is_in_sync probe); wallet on ${back.node}; '
          'privateReceiveAvailable=${c.privateReceiveAvailable}; '
          '"${BeamPrivateNodeMessages.describe(after).title}"',
        );
        expect(after.issue, BeamPrivateNodeIssue.nodeExited);
        expect(back.node.isOwned, isFalse);
        expect(kBeamPublicWalletNodes, contains(back.node));
        expect(c.privateReceiveAvailable, isFalse);
        expect(
          (await Process.run('ps', ['-p', '$pid'])).exitCode,
          isNot(0),
        );

        // ------------------------------------- 3. second launch, same node.db
        launch = 2;
        final retryAt = clock.elapsed;
        evidence('SECOND LAUNCH: retry() on the same node.db');
        await c.retry();
        evidence('retry() returned after '
            '${_mmss(clock.elapsed - retryAt)}: ${c.status}');
        await waitStatus(
          'handover #2',
          (s) => s.phase == _Phase.active && s.privateReceiveAvailable,
          timeout: const Duration(minutes: 60),
          failOn: _terminal,
        );
        await Future.wait(probes);
        final own2 = c.session!.node;
        expect(own2.isOwned, isTrue);
        expect(own2.port, node!.port);
        evidence(
          'LAUNCH 2: started ${_mmss(retryAt)}; Initial Tip '
          '${initialTip[2]}; node ready ${_at(nodeReady[2])} '
          '(+${nodeReady[2] == null ? '-' : _mmss(nodeReady[2]! - retryAt)}); '
          'readiness predicate fired ${_at(switching[2])} '
          '(+${_mmss(switching[2]! - retryAt)}); own_node confirmed '
          '${_at(confirmed[2])} (+${_mmss(confirmed[2]! - retryAt)})',
        );

        for (final g in gaps) {
          evidence('SUMMARY $g');
        }
        evidence(
          'SIZES final: node.db '
          '${_gb(await _sizeOf(p.join(nodeDir, 'node.db')))}, node dir '
          '${_gb(await _sizeOf(nodeDir))}; free at start ${_gb(free0)}, '
          'lowest ${_gb(minFree)}, peak drop ${_gb(free0 - minFree)}',
        );

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
        }
        evidence('logs checked: ${logs.length} file(s), no secrets');
      } finally {
        diskTimer?.cancel();
        reportTimer?.cancel();
        for (final s in subs) {
          await s.cancel();
        }
        final finalSize = await _sizeOf(nodeDir);
        await coordinator?.dispose();
        await BeamNodeProcess.stopAll();
        // Keep the redacted node logs (public chain data only, checked for
        // secrets above) next to the evidence file, outside the repo.
        if (evidencePath != null) {
          final logsDir = Directory(p.join(nodeDir, 'logs'));
          if (await logsDir.exists()) {
            final dest = Directory(
              p.join(p.dirname(evidencePath), 'node-logs-${_randomAlnum(4)}'),
            );
            await dest.create(recursive: true);
            await for (final f in logsDir.list()) {
              if (f is File &&
                  p.basename(f.path).startsWith('campfire-node-')) {
                await f.copy(p.join(dest.path, p.basename(f.path)));
              }
            }
            evidence('redacted node logs copied to ${dest.path}');
          }
        }
        await coordinator?.session?.close();
        await ProcessHost.shutdownAll();
        await BeamNodeProcess.stopAll();
        evidence(
          'cleanup: node dir was ${_gb(finalSize)}'
          '${diskAbort ? ' (disk abort)' : ''}; lowest free ${_gb(minFree)}; '
          'deleting ${root.path}',
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

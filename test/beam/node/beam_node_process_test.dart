/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// BeamNodeProcess against a /bin/sh stand-in for beam-node: argv, working
// directory, the 0600 config file and its unlink, the redacted log, the
// progress stream, stopping, key refusal, and the stale-node lock. No BEAM
// binary, network or real key is involved; the live run is
// beam_private_node_live_test.dart.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/host/secret_file.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_process.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_progress.dart';

import 'fake_beam_node.dart';

void main() {
  late NodeFixture fx;

  setUp(() async {
    fx = await NodeFixture.create();
  });

  tearDown(() async {
    await BeamNodeProcess.stopAll();
    await SecretFiles.deleteAll();
    await fx.tmp.delete(recursive: true);
  });

  group('start and stop', () {
    test('argv carries no secret, CWD is node/, the config is unlinked '
        'while the node runs, logs are private and redacted', () async {
      await fx.mode('echokey');
      await fx.script([
        'I 2026-10-06.12:00:01.000 Updating node: 43% (1749261/4068050)',
      ]);
      // A stray config in node/ would be read by BEAM; it must go.
      await ensurePrivateDir(fx.nodeDir);
      await File(
        p.join(fx.nodeDir, 'beam-node.cfg'),
      ).writeAsString('peer=evil:1');

      final node = fx.node();
      final seen = <BeamNodeProgress>[];
      node.progressStream.listen(seen.add);
      await node.start(ownerKey: fakeOwnerKey, password: fakePassword);

      expect(node.isRunning, isTrue);
      expect(node.port, isNotNull);
      expect(node.progress.ownerAccounts, 1);
      expect(await File(p.join(fx.nodeDir, 'beam-node.cfg')).exists(), isFalse);

      final argv = (await fx.lines('argv.log')).single;
      for (final flag in [
        '--port=${node.port}',
        '--storage=node.db',
        '--fast_sync=1',
        '--peer=eu-nodes.mainnet.beam.mw:8100',
        '--peer=us-nodes.mainnet.beam.mw:8100',
        '--config_file=',
        '--stratum_port=0',
        '--websocket_port=0',
        '--log_level=info',
        '--file_log_level=warning',
      ]) {
        expect(argv, contains(flag));
      }
      expect(argv, isNot(contains(fakeOwnerKey)));
      expect(argv, isNot(contains(fakePassword)));
      expect(argv, isNot(contains('owner_key')));
      expect(
        (await fx.lines('cwd.log')).single,
        endsWith(p.join('beam', 'node')),
      );
      expect(await fx.lines('evidence.log'), [
        'cfg-unlinked',
        'cfg-has-key-and-pass',
      ]);
      expect(await fx.secretEntries(), isEmpty);
      expect(SecretFiles.livePaths, isEmpty);
      expect(await posixMode(fx.nodeDir), 0x1c0);
      expect(await posixMode(p.join(fx.nodeDir, 'logs')), 0x1c0);
      expect(await File(p.join(fx.nodeDir, '.node.lock')).exists(), isTrue);

      // Wait for the scripted progress line.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (node.progress.percent != 43 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(node.progress.percent, 43);

      final pid = node.pid!;
      await node.stop();
      expect(await running(pid), isFalse);
      expect(node.progress.phase, BeamNodePhase.stopped);
      expect(seen.last.phase, BeamNodePhase.stopped);
      expect(await File(p.join(fx.nodeDir, '.node.lock')).exists(), isFalse);

      final log = await fx.campfireLog();
      expect(log, contains('Updating node: 43%'));
      expect(log, contains('Owned accounts :'));
      expect(log, isNot(contains('FakeEndpoint')));
      expect(log, isNot(contains(fakeOwnerKey)));
      expect(log, isNot(contains(fakeOwnerKey.substring(0, 32))));
      expect(log, isNot(contains(fakePassword)));
      final logFiles = await Directory(
        p.join(fx.nodeDir, 'logs'),
      ).list().toList();
      for (final f in logFiles) {
        expect(await posixMode(f.path), 0x180, reason: p.basename(f.path));
      }
      expect(fx.hostLog.join('\n'), isNot(contains(fakeOwnerKey)));
      expect(fx.hostLog.join('\n'), isNot(contains(fakePassword)));
    });

    test('progress stream: fast sync, then catching up, then My Tip, '
        'then Tx replication ON', () async {
      await fx.script([
        'I 2026-10-06.12:00:01.000 Fast-sync mode up to block number '
            '4066610, TxoLo=4062290',
        'sleep 0.2',
        'I 2026-10-06.12:00:02.000 Fast-sync succeeded',
        'I 2026-10-06.12:00:02.100 My Tip: 4068051-0011aabbccddeeff, '
            'Work = 2.7e+14',
        'I 2026-10-06.12:00:02.200 Tx replication is ON',
      ]);
      final node = fx.node();
      final phases = <BeamNodePhase>[];
      node.progressStream.listen((pr) {
        if (phases.isEmpty || phases.last != pr.phase) phases.add(pr.phase);
      });
      await node.start(ownerKey: fakeOwnerKey, password: fakePassword);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!node.progress.txReplicationOn &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(node.progress.myTipHeight, 4068051);
      expect(node.progress.txReplicationOn, isTrue);
      expect(phases, containsAllInOrder([
        BeamNodePhase.fastSyncDownloading,
        BeamNodePhase.catchingUp,
        BeamNodePhase.txReplicationOn,
      ]));
      await node.stop();
    });

    test('the redacted log rolls over at its size cap and keeps four '
        'private files', () async {
      await fx.script([
        for (var i = 0; i < 60; i++)
          'I 2026-10-06.12:00:01.000 Updating node: 1% ($i/4068050)',
      ]);
      final node = fx.node(maxLogBytes: 400);
      await node.start(ownerKey: fakeOwnerKey, password: fakePassword);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!(await fx.campfireLog()).contains('(59/4068050)') &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await node.stop();
      final files = await Directory(p.join(fx.nodeDir, 'logs'))
          .list()
          .where((e) => p.basename(e.path).startsWith('campfire-node-'))
          .toList();
      expect(files, hasLength(4));
      for (final f in files) {
        expect(await posixMode(f.path), 0x180);
      }
      expect(await fx.campfireLog(), contains('(59/4068050)'));
    });

    test('a node that ignores SIGTERM is killed after the grace '
        'period', () async {
      await fx.mode('ignoreterm');
      final node = fx.node(stopGrace: const Duration(milliseconds: 500));
      await node.start(ownerKey: fakeOwnerKey, password: fakePassword);
      final pid = node.pid!;
      final sw = Stopwatch()..start();
      await node.stop();
      expect(
        sw.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 400)),
      );
      expect(await running(pid), isFalse);
      expect(fx.hostLog.join('\n'), contains('ignored SIGTERM'));
    });

    test('a crash is reported on the stream as error/exited with the '
        'code', () async {
      await fx.script([
        'I 2026-10-06.12:00:01.000 My Tip: 100-00aa00bb00cc00dd, Work = 1',
        'sleep 0.3',
        'exit 3',
      ]);
      final node = fx.node();
      final ended = node.progressStream.firstWhere((pr) => pr.isEnded);
      await node.start(ownerKey: fakeOwnerKey, password: fakePassword);
      final last = await ended.timeout(const Duration(seconds: 5));
      expect(last.phase, BeamNodePhase.error);
      expect(last.error, BeamNodeError.exited);
      expect(last.exitCode, 3);
      expect(last.myTipHeight, 100);
      expect(await node.exitCode, 3);
      // The lock goes with the process.
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (await File(p.join(fx.nodeDir, '.node.lock')).exists() &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(await File(p.join(fx.nodeDir, '.node.lock')).exists(), isFalse);
    });
  }, skip: Platform.isWindows ? 'uses /bin/sh stand-ins' : false);

  group('never a keyless node', () {
    test('an empty owner key is refused before anything runs', () async {
      await expectLater(
        fx.node().start(ownerKey: '', password: fakePassword),
        throwsA(nodeError(BeamNodeError.ownerKeyRejected)),
      );
      expect(await fx.lines('argv.log'), isEmpty);
      expect(await fx.lines('pids.log'), isEmpty);
    });

    test('"key import failed" (exit 0) is a typed refusal; the node is '
        'gone and so is the config', () async {
      await fx.mode('badkey');
      final node = fx.node();
      await expectLater(
        node.start(ownerKey: fakeOwnerKey, password: fakePassword),
        throwsA(nodeError(BeamNodeError.ownerKeyRejected)),
      );
      final pid = int.parse((await fx.lines('pids.log')).single);
      expect(await running(pid), isFalse);
      expect(node.progress.error, BeamNodeError.ownerKeyRejected);
      expect(await fx.secretEntries(), isEmpty);
      expect(await File(p.join(fx.nodeDir, '.node.lock')).exists(), isFalse);
    });

    test('a node that lists no owned account is stopped, not left '
        'running keyless', () async {
      await fx.mode('noowners');
      final node = fx.node();
      await expectLater(
        node.start(ownerKey: fakeOwnerKey, password: fakePassword),
        throwsA(nodeError(BeamNodeError.ownerKeyRejected)),
      );
      final pid = int.parse((await fx.lines('pids.log')).single);
      expect(await running(pid), isFalse);
    });

    test('a node that never reads its config is stopped and the file '
        'deleted', () async {
      await fx.mode('noconfig');
      final node = fx.node(configReadTimeout: const Duration(seconds: 1));
      await expectLater(
        node.start(ownerKey: fakeOwnerKey, password: fakePassword),
        throwsA(nodeError(BeamNodeError.configNotRead)),
      );
      final pid = int.parse((await fx.lines('pids.log')).single);
      expect(await running(pid), isFalse);
      expect(await fx.secretEntries(), isEmpty);
      expect(SecretFiles.livePaths, isEmpty);
    });

    test('a password BEAM would store differently is refused', () async {
      await expectLater(
        fx.node().start(ownerKey: fakeOwnerKey, password: 'has#comment'),
        throwsA(isA<BeamHostException>()),
      );
      expect(await fx.lines('argv.log'), isEmpty);
    });
  }, skip: Platform.isWindows ? 'uses /bin/sh stand-ins' : false);

  group('one node per storage', () {
    test('a beam-node left running by a crashed app is stopped '
        'first', () async {
      await ensurePrivateDir(fx.root);
      await ensurePrivateDir(fx.nodeDir);
      final orphan = await Process.start(p.join(fx.binDir, 'beam-node'), [
        '--storage=node.db',
        '--fast_sync=1',
        '--orphan',
      ], workingDirectory: fx.nodeDir);
      await File(p.join(fx.nodeDir, '.node.lock')).writeAsString(
        jsonEncode({
          'pid': await deadPid(),
          'exe': 'campfire',
          'child': orphan.pid,
          'childExe': 'beam-node',
        }),
      );
      final node = fx.node();
      await node.start(ownerKey: fakeOwnerKey, password: fakePassword);
      await orphan.exitCode.timeout(const Duration(seconds: 5));
      expect(await running(orphan.pid), isFalse);
      expect(fx.hostLog.join('\n'), contains('left running by an earlier run'));
      expect(node.isRunning, isTrue);
      await node.stop();
    });

    test('a live app instance holding the lock refuses the start', () async {
      await ensurePrivateDir(fx.root);
      await ensurePrivateDir(fx.nodeDir);
      final holder = await Process.start('sleep', ['30']);
      try {
        await File(p.join(fx.nodeDir, '.node.lock')).writeAsString(
          jsonEncode({'pid': holder.pid, 'exe': 'sleep', 'child': null}),
        );
        await expectLater(
          fx.node().start(ownerKey: fakeOwnerKey, password: fakePassword),
          throwsA(nodeError(BeamNodeError.nodeInUse)),
        );
        expect(await running(holder.pid), isTrue);
        expect(await fx.lines('argv.log'), isEmpty);
      } finally {
        holder.kill();
      }
    });

    test('a recycled pid of an unrelated program is never killed', () async {
      await ensurePrivateDir(fx.root);
      await ensurePrivateDir(fx.nodeDir);
      final unrelated = await Process.start('sleep', ['30']);
      try {
        await File(p.join(fx.nodeDir, '.node.lock')).writeAsString(
          jsonEncode({
            'pid': await deadPid(),
            'exe': 'campfire',
            'child': unrelated.pid,
            'childExe': 'beam-node',
          }),
        );
        final node = fx.node();
        await node.start(ownerKey: fakeOwnerKey, password: fakePassword);
        expect(await running(unrelated.pid), isTrue);
        await node.stop();
      } finally {
        unrelated.kill();
      }
    });

    test('two nodes on one storage in one process: the second is '
        'refused', () async {
      final first = fx.node();
      await first.start(ownerKey: fakeOwnerKey, password: fakePassword);
      await expectLater(
        fx.node().start(ownerKey: fakeOwnerKey, password: fakePassword),
        throwsA(nodeError(BeamNodeError.nodeInUse)),
      );
      await first.stop();
      // Released: a new one may start.
      final again = fx.node();
      await again.start(ownerKey: fakeOwnerKey, password: fakePassword);
      await again.stop();
    });
  }, skip: Platform.isWindows ? 'uses /bin/sh stand-ins' : false);
}

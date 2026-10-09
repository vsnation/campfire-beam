/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// B-NODE-2b: the private node never gets in the way.
//
// * A stored owner key: zero exports, no session closed, no pause.
// * whenIdle: no switch (bring-up pause, handover, move back to public)
//   while a send/swap/claim/approval is open.
// * requestBodies comes from the caller, read on every reopen.
// * Free disk: refused below the policy with a plain state; stopped before
//   the disk fills up.
// * The node panel's controls: setEnabled, stop, restart, the registry.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/host/beam_host.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_disk.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_process.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_progress.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_messages.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_preference.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_node_switch_gate.dart';

import 'beam_private_node_coordinator_test.dart' hide main;
import 'fake_beam_node.dart';

const _eu = BeamNodeEndpoint('eu-nodes.mainnet.beam.mw', 8100);
const _us = BeamNodeEndpoint('us-nodes.mainnet.beam.mw', 8100);
const _eu1 = BeamNodeEndpoint('eu-node01.mainnet.beam.mw', 8100);
const _us1 = BeamNodeEndpoint('us-node01.mainnet.beam.mw', 8100);

BeamNodeDiskProbe _disk(double freeGiB, {double nodeGiB = 0}) =>
    () async => BeamNodeDiskSpace(
      freeBytes: (freeGiB * kBeamGiB).round(),
      nodeBytes: (nodeGiB * kBeamGiB).round(),
    );

Future<String?> _stored() async => fakeOwnerKey;

void main() {
  group('stored owner key (R11: no pause)', () {
    test('zero exports, no session closed or reopened, the key reaches the '
        'node, lastPause is zero', () async {
      final h = Harness(storedOwnerKey: _stored);
      await h.startDownloading(43);
      expect(h.host.calls, isEmpty, reason: 'no close, export or open');
      expect(h.sessionEvents, isEmpty, reason: 'the wallet never paused');
      expect(h.coordinator.session, same(h.initial));
      expect(h.initial.closed, isFalse);
      expect(h.node.keyReceived, fakeOwnerKey);
      expect(h.status.phase, BeamPrivateNodePhase.downloading);
      expect(h.status.lastPause, Duration.zero);
      expect(h.log.join('\n'), isNot(contains(fakeOwnerKey)));
      h.expectNoR8Violation();
      await h.dispose();
    });

    test('no stored key: the paused export still works (old wallets)',
        () async {
      final h = Harness(storedOwnerKey: () async => null);
      await h.startDownloading();
      expect(h.host.calls.take(3), ['close $_eu', 'export', 'open $_eu']);
      expect(h.node.keyReceived, fakeOwnerKey);
      h.expectNoR8Violation();
      await h.dispose();
    });

    test('a failing key store falls back to the paused export', () async {
      final h = Harness(
        storedOwnerKey: () async => throw StateError('keychain locked'),
      );
      await h.startDownloading();
      expect(h.host.calls.take(3), ['close $_eu', 'export', 'open $_eu']);
      await h.dispose();
    });
  });

  group('whenIdle: no switch under an open money flow', () {
    test('handover waits, says so, then decides again and switches',
        () async {
      final gate = BeamNodeSwitchGate();
      final h = Harness(storedOwnerKey: _stored, whenIdle: gate.whenIdle);
      await h.startDownloading();
      final lease = gate.hold('confirm send');
      h.node.ready();
      await until(
        () => h.status.waitingForWallet,
        reason: 'waiting for the send',
      );
      expect(h.status.phase, BeamPrivateNodePhase.switching);
      expect(
        BeamPrivateNodeMessages.describe(h.status).title,
        'Your private node is ready',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        h.host.calls.where((c) => c.contains('owned')),
        isEmpty,
        reason: 'no switch while the send is open',
      );
      expect(h.sessionEvents, isEmpty, reason: 'session untouched');
      expect(h.coordinator.session, same(h.initial));

      final explorerCallsBefore = h.explorer.calls;
      lease.release();
      await h.phase(BeamPrivateNodePhase.active);
      expect(h.status.waitingForWallet, isFalse);
      expect(h.coordinator.session!.node.isOwned, isTrue);
      expect(
        h.explorer.calls,
        greaterThan(explorerCallsBefore),
        reason: 'readiness checked again after the wait',
      );
      h.expectNoR8Violation();
      await h.dispose();
    });

    test('a node that dies during the wait is never switched to', () async {
      final gate = BeamNodeSwitchGate();
      final h = Harness(storedOwnerKey: _stored, whenIdle: gate.whenIdle);
      await h.startDownloading();
      final lease = gate.hold('swap');
      h.node.ready();
      await until(() => h.status.waitingForWallet, reason: 'waiting');
      h.node.crash();
      lease.release();
      await h.phase(BeamPrivateNodePhase.stopped);
      expect(h.host.calls.where((c) => c.contains('owned')), isEmpty);
      expect(h.coordinator.session, same(h.initial));
      await h.dispose();
    });

    test('the move back to public waits too; private receive is off at '
        'once', () async {
      final gate = BeamNodeSwitchGate();
      final h = Harness(storedOwnerKey: _stored, whenIdle: gate.whenIdle);
      await h.activate();
      final owned = h.coordinator.session!;
      expect(owned.node.isOwned, isTrue);
      final lease = gate.hold('dApp approval');
      h.node.crash();
      await until(
        () => !h.coordinator.privateReceiveAvailable,
        reason: 'private receive off',
      );
      await until(() => h.status.waitingForWallet, reason: 'waiting');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(h.coordinator.session, same(owned), reason: 'not switched yet');
      lease.release();
      await h.phase(BeamPrivateNodePhase.stopped);
      expect(h.coordinator.session!.node, _eu);
      h.expectPrivateReceiveOnlyWhenConfirmed();
      h.expectNoR8Violation();
      await h.dispose();
    });

    test('the bring-up pause (no stored key) waits as well', () async {
      final gate = BeamNodeSwitchGate();
      final h = Harness(whenIdle: gate.whenIdle);
      final lease = gate.hold('send');
      final started = h.coordinator.start();
      await until(() => h.status.waitingForWallet, reason: 'waiting');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(h.host.calls, isEmpty, reason: 'nothing closed during the send');
      lease.release();
      await started;
      expect(h.host.calls.take(3), ['close $_eu', 'export', 'open $_eu']);
      await h.dispose();
    });
  });

  group('requestBodies from the caller', () {
    test('read on every reopen, not fixed at construction', () async {
      var scanning = true;
      final h = Harness(requestBodies: () => scanning);
      h.host.failing.addAll({_eu, _us, _eu1, _us1});
      await h.coordinator.start();
      expect(h.status.phase, BeamPrivateNodePhase.walletClosed);
      expect(h.host.requestBodiesSeen, everyElement(isTrue));
      expect(h.host.requestBodiesSeen, isNotEmpty);

      scanning = false;
      h.host.requestBodiesSeen.clear();
      h.host.failing.clear();
      await h.coordinator.retry();
      expect(h.coordinator.session?.node, _eu);
      expect(h.host.requestBodiesSeen.first, isFalse);
      await h.dispose();
    });
  });

  group('free disk', () {
    test('below the policy: refused before anything happens, in plain '
        'words with the numbers; retry once there is room', () async {
      var probe = _disk(6.2);
      final h = Harness(
        storedOwnerKey: _stored,
        diskProbe: () => probe(),
      );
      await h.coordinator.start();
      expect(h.status.phase, BeamPrivateNodePhase.failed);
      expect(h.status.issue, BeamPrivateNodeIssue.notEnoughDisk);
      expect(h.host.calls, isEmpty);
      expect(h.nodes.where((n) => n.keyReceived != null), isEmpty);
      final m = BeamPrivateNodeMessages.describe(h.status);
      expect(
        m.title,
        'Your private node needs about 12 GB free while it sets up (it '
        'shrinks to about 8 GB)',
      );
      expect(m.detail, contains('This computer has 6.2 GB free'));
      expect(m.detail, contains('leaves 2 GB for your other apps'));
      expect(m.detail, contains('Free up 7.8 GB, then try again'));
      expect(m.detail, contains('Your wallet keeps working on a public node'));
      expect(m.actionLabel, 'Try again');
      expect(h.status.disk!.shortfallBytes, greaterThan(0));

      probe = _disk(37);
      await h.coordinator.retry();
      expect(h.status.phase, BeamPrivateNodePhase.downloading);
      expect(h.node.keyReceived, fakeOwnerKey);
      expect(h.status.disk!.space.freeBytes, 37 * kBeamGiB);
      await h.dispose();
    });

    test('a node that synced before needs only the reserve plus the rest',
        () async {
      final h = Harness(
        storedOwnerKey: _stored,
        diskProbe: _disk(3, nodeGiB: 7.6),
      );
      await h.coordinator.start();
      expect(h.status.phase, BeamPrivateNodePhase.downloading);
      await h.dispose();
    });

    test('an unmeasurable disk is not a reason to refuse', () async {
      final h = Harness(storedOwnerKey: _stored, diskProbe: () async => null);
      await h.coordinator.start();
      expect(h.status.phase, BeamPrivateNodePhase.downloading);
      await h.dispose();
    });

    test('running low while running: stopped before the disk fills, wallet '
        'back on a public node', () async {
      var probe = _disk(20);
      final h = Harness(
        storedOwnerKey: _stored,
        diskProbe: () => probe(),
        diskCheckInterval: const Duration(milliseconds: 20),
      );
      await h.activate();
      probe = _disk(0.5);
      await h.phase(BeamPrivateNodePhase.failed);
      expect(h.status.issue, BeamPrivateNodeIssue.diskFull);
      expect(h.node.stopped, isTrue);
      expect(h.coordinator.session!.node, _eu);
      expect(h.coordinator.privateReceiveAvailable, isFalse);
      final m = BeamPrivateNodeMessages.describe(h.status);
      expect(m.title, contains('almost out of space'));
      expect(m.detail, contains('Only 512 MB is free'));
      expect(m.detail, contains('Back on a public node — your wallet keeps '
          'working.'));
      h.expectPrivateReceiveOnlyWhenConfirmed();
      await h.dispose();
    });

    test('policy numbers: 14 GiB for a fresh node (11.42 GiB measured setup '
        'peak + margin + 2 GiB reserve); a set-up node needs new blocks only; '
        'stop under 2 GiB', () {
      const policy = BeamNodeDiskPolicy();
      expect(policy.neededToStart(0), 14 * kBeamGiB);
      // Stopped half-way through fast sync: still heading for the peak.
      expect(policy.neededToStart(5 * kBeamGiB), 9 * kBeamGiB);
      // Set up before (7.55 GiB measured) or stopped at the peak.
      expect(policy.neededToStart((7.6 * kBeamGiB).round()),
          (2.5 * kBeamGiB).round());
      expect(policy.neededToStart((11.4 * kBeamGiB).round()),
          (2.5 * kBeamGiB).round());
      expect(
        policy.mustStop(
          const BeamNodeDiskSpace(freeBytes: 2 * kBeamGiB - 1, nodeBytes: 0),
        ),
        isTrue,
      );
      expect(kBeamNodeStopGrace, const Duration(seconds: 45));
      expect(formatBeamDiskSize(8 * kBeamGiB), '8 GB');
      expect(formatBeamDiskSize((6.2 * kBeamGiB).round()), '6.2 GB');
      expect(formatBeamDiskSize(37 * kBeamGiB), '37 GB');
      expect(formatBeamDiskSize(512 * 1024 * 1024), '512 MB');
    });

    test('df output with spaces in names is parsed from the capacity column',
        () {
      const mac =
          'Filesystem     1024-blocks      Used Available Capacity  '
          'Mounted on\n'
          '/dev/disk3s5    239362496 177127708  26214400    88%    '
          '/System/Volumes/Data\n';
      expect(BeamNodeDisk.parseDfAvailableKb(mac), 26214400);
      const spaces =
          'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
          'map auto home 0 0 0 100% /System/Volumes/Data/home dir\n';
      expect(BeamNodeDisk.parseDfAvailableKb(spaces), 0);
      expect(BeamNodeDisk.parseDfAvailableKb('garbage'), isNull);
    });

    test('the real probe measures this machine and the node folder', () async {
      final tmp = await Directory.systemTemp.createTemp('beam_disk_');
      addTearDown(() => tmp.delete(recursive: true));
      final nodeDir = p.join(tmp.path, 'node');
      // Not created yet: measured on the nearest existing parent.
      final before = await BeamNodeDisk.probe(nodeDir)();
      expect(before, isNotNull);
      expect(before!.freeBytes, greaterThan(0));
      expect(before.nodeBytes, 0);
      await Directory(nodeDir).create();
      await File(p.join(nodeDir, 'node.db')).writeAsBytes(List.filled(4096, 1));
      final after = await BeamNodeDisk.probe(nodeDir)();
      expect(after!.nodeBytes, 4096);
    }, skip: Platform.isWindows ? 'df' : false);
  });

  group('setup step after fast sync ("Raising Fossil")', () {
    test('parsed into a finishing percentage, ended by normal progress',
        () {
      final parser = BeamNodeLogParser();
      parser.add('I 2026-10-06.13:40:00.000 Fast-sync succeeded');
      parser.add('I 2026-10-06.13:40:00.100 Raising Fossil...');
      expect(parser.progress.finishingPercent, 0);
      parser.add('I 2026-10-06.13:40:10.100 \t12%...');
      expect(parser.progress.finishingPercent, 12);
      parser.add('I 2026-10-06.13:46:10.100 \t97%...');
      expect(parser.progress.finishingPercent, 97);
      expect(parser.progress.phase, BeamNodePhase.catchingUp);
      parser.add(
        'I 2026-10-06.13:47:00.000 My Tip: 4068200-00aabbccddeeff00, '
        'Work = 2.7e+14',
      );
      expect(parser.progress.finishingPercent, isNull);
      // A stray percentage outside a step means nothing.
      parser.add('I 2026-10-06.13:47:10.000 \t50%...');
      expect(parser.progress.finishingPercent, isNull);
    });

    test('the status and the panel say "Finishing setup (N%)"', () async {
      final h = Harness(storedOwnerKey: _stored);
      await h.coordinator.start();
      h.node.emit(
        h.node.progress.copyWith(
          phase: BeamNodePhase.catchingUp,
          finishingPercent: 37,
        ),
      );
      await until(
        () => h.status.finishingPercent == 37,
        reason: 'finishing percent',
      );
      expect(h.status.phase, BeamPrivateNodePhase.catchingUp);
      expect(
        BeamPrivateNodeMessages.describe(h.status).title,
        'Using a public node — your private node is finishing setup (37%)',
      );
      await h.dispose();
    });
  });

  group('node panel controls', () {
    test('the registry finds a live coordinator by wallet directory',
        () async {
      final events = <void>[];
      final sub = BeamPrivateNodeCoordinator.registryChanges.listen(
        events.add,
      );
      final h = Harness(storedOwnerKey: _stored);
      expect(
        BeamPrivateNodeCoordinator.forWalletDir(h.coordinator.walletDir),
        same(h.coordinator),
      );
      await h.dispose();
      expect(
        BeamPrivateNodeCoordinator.forWalletDir(h.coordinator.walletDir),
        isNull,
      );
      await Future<void>.delayed(Duration.zero);
      expect(events.length, greaterThanOrEqualTo(2));
      await sub.cancel();
    });

    test('setEnabled(false) while in use: public node, node stopped, off; '
        'setEnabled(true) starts it again', () async {
      final h = Harness(storedOwnerKey: _stored);
      await h.activate();
      await h.coordinator.setEnabled(false);
      expect(h.status.phase, BeamPrivateNodePhase.off);
      expect(h.nodes.first.stopped, isTrue);
      expect(h.coordinator.session!.node, _eu);
      expect(h.coordinator.privateReceiveAvailable, isFalse);

      await h.coordinator.setEnabled(true);
      expect(h.nodes, hasLength(2));
      expect(h.node.keyReceived, fakeOwnerKey);
      expect(h.status.phase, BeamPrivateNodePhase.downloading);
      h.expectPrivateReceiveOnlyWhenConfirmed();
      await h.dispose();
    });

    test('stop: public node, "Start private node", which starts it again',
        () async {
      final h = Harness(storedOwnerKey: _stored);
      await h.activate();
      await h.coordinator.stop();
      expect(h.status.phase, BeamPrivateNodePhase.stopped);
      expect(h.status.issue, BeamPrivateNodeIssue.stoppedByUser);
      expect(h.coordinator.session!.node, _eu);
      final m = BeamPrivateNodeMessages.describe(h.status);
      expect(m.title, 'Your private node is stopped');
      expect(m.actionLabel, 'Start private node');
      await h.coordinator.retry();
      expect(h.nodes, hasLength(2));
      expect(h.status.phase, BeamPrivateNodePhase.downloading);
      await h.dispose();
    });

    test('restart: off the private node, a new node on the same storage, '
        'no export', () async {
      final h = Harness(storedOwnerKey: _stored);
      await h.activate();
      await h.coordinator.restart();
      expect(h.nodes, hasLength(2));
      expect(h.nodes.first.stopped, isTrue);
      expect(h.node.keyReceived, fakeOwnerKey);
      expect(h.coordinator.session!.node, _eu);
      expect(h.host.calls.where((c) => c == 'export'), isEmpty);
      expect(h.status.phase, BeamPrivateNodePhase.downloading);
      h.node.ready();
      await h.phase(BeamPrivateNodePhase.active);
      h.expectNoR8Violation();
      await h.dispose();
    });
  });

  group('the stored choice', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('beam_pref_');
    });
    tearDown(() => tmp.delete(recursive: true));

    test('default until chosen, then the choice; written atomically and '
        'announced', () async {
      final root = p.join(tmp.path, 'beam');
      final pref = BeamPrivateNodePreference(
        beamRoot: () async => root,
        defaultValue: true,
      );
      expect(await pref.read(), isTrue);
      final seen = <bool>[];
      final sub = BeamPrivateNodePreference.changes.listen(seen.add);
      await pref.write(false);
      expect(await pref.read(), isFalse);
      expect(
        File(p.join(root, BeamPrivateNodePreference.fileName))
            .readAsStringSync(),
        '{"enabled":false}',
      );
      expect(
        File(p.join(root, '${BeamPrivateNodePreference.fileName}.tmp'))
            .existsSync(),
        isFalse,
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen, [false]);
      // A damaged file reads as the default, never an error.
      File(p.join(root, BeamPrivateNodePreference.fileName))
          .writeAsStringSync('{not json');
      expect(await pref.read(), isTrue);
      // It drives a coordinator like any setting.
      await pref.write(false);
      final h = Harness(setting: pref, storedOwnerKey: _stored);
      await h.coordinator.start();
      expect(h.status.phase, BeamPrivateNodePhase.off);
      await h.dispose();
      await sub.cancel();
    });
  });

  test('a node that refuses the key still never runs keyless with a stored '
      'key', () async {
    final h = Harness(
      storedOwnerKey: _stored,
      startError: const BeamNodeException(
        BeamNodeError.ownerKeyRejected,
        'key import failed',
      ),
    );
    await h.coordinator.start();
    expect(h.status.phase, BeamPrivateNodePhase.failed);
    expect(h.status.issue, BeamPrivateNodeIssue.keyRejected);
    expect(h.coordinator.privateReceiveAvailable, isFalse);
    await h.dispose();
  });
}

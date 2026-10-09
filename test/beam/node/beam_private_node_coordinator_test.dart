/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The handover state machine against a fake host (which enforces one
// writer per wallet.db), a fake node and a fake explorer: every transition,
// keyless refusal, own_node never confirmed, node crash failover, explorer
// down, the HF6 boundary. The last group wires the coordinator to the real
// BeamNodeProcess running the /bin/sh beam-node stand-in.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';
import 'package:stackwallet/wallets/beam/host/beam_host.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_disk.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_process.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_progress.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_messages.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import 'fake_beam_node.dart';

typedef Phase = BeamPrivateNodePhase;

const _eu = BeamNodeEndpoint('eu-nodes.mainnet.beam.mw', 8100);
const _us = BeamNodeEndpoint('us-nodes.mainnet.beam.mw', 8100);
const _eu1 = BeamNodeEndpoint('eu-node01.mainnet.beam.mw', 8100);
const _us1 = BeamNodeEndpoint('us-node01.mainnet.beam.mw', 8100);
const _walletDir = '/fake/wallets/w1';
const _networkHeight = 4068124;

/// How the fake core answers `ev_subunsub` on an owned node.
enum OwnNodeBehaviour { confirms, falseThenTrue, never }

class FakeSession implements BeamSession {
  FakeSession(this._host, this.node, this.transport);

  final FakeHost _host;
  bool closed = false;

  @override
  final BeamNodeEndpoint node;

  @override
  final FakeTransport transport;

  @override
  Future<BeamSession> switchNode(BeamNodeEndpoint node) async {
    if (closed) throw StateError('Session is closed');
    await close();
    return _host.openWallet(
      walletDir: _walletDir,
      password: fakePassword,
      node: node,
    );
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    _host.calls.add('close $node');
    await transport.close();
  }

  @override
  Future<void> get stopped => Future.value();

  @override
  String toString() => 'FakeSession($node)';
}

/// A [BeamHost] that records what happens and enforces rule R8: no
/// export, open or second session while a session holds the wallet.
class FakeHost implements BeamHost {
  final calls = <String>[];
  final sessions = <FakeSession>[];
  final failing = <BeamNodeEndpoint>{};
  final r8Violations = <String>[];
  Object? exportError;
  OwnNodeBehaviour ownNode = OwnNodeBehaviour.confirms;
  String? passwordSeen;
  final requestBodiesSeen = <bool>[];

  FakeSession? get openSession {
    for (final s in sessions) {
      if (!s.closed) return s;
    }
    return null;
  }

  @override
  Future<BeamSession> openWallet({
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
    bool requestBodies = false,
  }) async {
    if (openSession != null) {
      r8Violations.add('open $node while ${openSession!.node} is open');
      throw const BeamHostException(
        BeamHostError.walletInUse,
        'This wallet is already open',
      );
    }
    passwordSeen = password;
    requestBodiesSeen.add(requestBodies);
    calls.add('open $node${node.isOwned ? ' (owned)' : ''}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (failing.contains(node)) {
      throw BeamHostException(BeamHostError.badNode, 'no answer from $node');
    }
    final t = FakeTransport({'wallet_status': const {'current_height': 1}});
    t.reply('ev_subunsub', (Map<String, Object?> params) {
      if (node.isOwned && params['ev_connection_changed'] == true) {
        Timer(const Duration(milliseconds: 10), () {
          switch (ownNode) {
            case OwnNodeBehaviour.confirms:
              t.emit('ev_connection_changed', {
                'node_connected': true,
                'own_node': true,
              });
            case OwnNodeBehaviour.falseThenTrue:
              t.emit('ev_connection_changed', {
                'node_connected': true,
                'own_node': false,
              });
              Timer(const Duration(milliseconds: 20), () {
                t.emit('ev_connection_changed', {
                  'node_connected': true,
                  'own_node': true,
                });
              });
            case OwnNodeBehaviour.never:
              t.emit('ev_connection_changed', {
                'node_connected': true,
                'own_node': false,
              });
          }
        });
      }
      return true;
    });
    final s = FakeSession(this, node, t);
    sessions.add(s);
    return s;
  }

  @override
  Future<String> exportOwnerKey({
    required String walletDir,
    required String password,
  }) async {
    if (openSession != null) {
      r8Violations.add('export while ${openSession!.node} is open');
      throw const BeamHostException(
        BeamHostError.walletInUse,
        'This wallet is already open',
      );
    }
    calls.add('export');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final e = exportError;
    if (e != null) throw e;
    return fakeOwnerKey;
  }

  @override
  Future<void> initWallet({
    required String walletDir,
    required String password,
    required List<String> words,
  }) => throw UnimplementedError();

  @override
  Future<void> rescan({
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
  }) => throw UnimplementedError();
}

class FakeNode implements BeamPrivateNode {
  FakeNode({this.startError});

  final Object? startError;
  final _controller = StreamController<BeamNodeProgress>.broadcast();
  String? keyReceived;
  bool stopped = false;

  @override
  int? port = 40123;

  @override
  BeamNodeProgress progress = const BeamNodeProgress();

  @override
  Stream<BeamNodeProgress> get progressStream => _controller.stream;

  void emit(BeamNodeProgress next) {
    progress = next;
    _controller.add(next);
  }

  /// `Tx replication is ON` with the tip [behind] blocks under the
  /// network.
  void ready({int behind = 2, DateTime? at}) => emit(
    progress.copyWith(
      phase: BeamNodePhase.txReplicationOn,
      myTipHeight: _networkHeight - behind,
      myTipAt: at ?? DateTime.now(),
      ownerAccounts: 1,
    ),
  );

  void tip(int height) => emit(
    progress.copyWith(myTipHeight: height, myTipAt: DateTime.now()),
  );

  @override
  Future<void> start({
    required String ownerKey,
    required String password,
  }) async {
    keyReceived = ownerKey;
    final e = startError;
    if (e != null) throw e;
    emit(progress.copyWith(ownerAccounts: 1));
  }

  @override
  Future<void> stop() async {
    if (stopped) return;
    stopped = true;
    emit(progress.copyWith(phase: BeamNodePhase.stopped));
    await _controller.close();
  }

  void crash() {
    emit(
      progress.copyWith(
        phase: BeamNodePhase.error,
        error: BeamNodeError.exited,
        exitCode: -9,
      ),
    );
  }
}

class FakeExplorer implements BeamNetworkTipSource {
  int height = _networkHeight;
  bool down = false;
  Duration tipAge = const Duration(seconds: 30);
  int calls = 0;

  @override
  Future<BeamExplorerStatus> status({bool forceRefresh = false}) async {
    calls++;
    if (down) throw BeamExplorerException('no explorer node answered');
    final now = DateTime.now();
    return BeamExplorerStatus(
      height: height,
      timestamp: now.subtract(tipAge),
      hash: '',
      node: 'fake',
      receivedAt: now,
    );
  }
}

Future<void> until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for ${reason ?? 'a condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class Harness {
  Harness({
    BeamPrivateNodeSetting setting = const BeamFixedPrivateNodeSetting(true),
    this.startError,
    Duration stallAfter = const Duration(minutes: 15),
    Duration ownNodeTimeout = const Duration(milliseconds: 300),
    BeamPrivateNodeFactory? nodeFactory,
    BeamOwnerKeyProvider? storedOwnerKey,
    BeamIdleWaiter? whenIdle,
    bool Function()? requestBodies,
    BeamNodeDiskProbe? diskProbe,
    Duration diskCheckInterval = const Duration(minutes: 1),
    Duration readyHoldFor = Duration.zero,
    Duration walletReadyTimeout = const Duration(minutes: 2),
    Duration retryAfterNotServing = const Duration(minutes: 10),
    bool Function()? walletCanSend,
  }) {
    initial = FakeSession(host, _eu, FakeTransport());
    host.sessions.add(initial);
    coordinator = BeamPrivateNodeCoordinator(
      host: host,
      session: initial,
      walletDir: _walletDir,
      password: () async => fakePassword,
      explorer: explorer,
      nodeFactory:
          nodeFactory ??
          () {
            final n = FakeNode(startError: startError);
            nodes.add(n);
            return n;
          },
      setting: setting,
      log: log.add,
      ownNodeTimeout: ownNodeTimeout,
      checkInterval: const Duration(milliseconds: 40),
      stallAfter: stallAfter,
      storedOwnerKey: storedOwnerKey,
      whenIdle: whenIdle,
      requestBodies: requestBodies,
      diskProbe: diskProbe,
      diskCheckInterval: diskCheckInterval,
      readyHoldFor: readyHoldFor,
      walletReadyTimeout: walletReadyTimeout,
      retryAfterNotServing: retryAfterNotServing,
      walletCanSend: walletCanSend,
    );
    coordinator.statuses.listen(statuses.add);
    coordinator.sessions.listen(sessionEvents.add);
  }

  final host = FakeHost();
  final explorer = FakeExplorer();
  final Object? startError;
  final nodes = <FakeNode>[];
  final log = <String>[];
  final statuses = <BeamPrivateNodeStatus>[];
  final sessionEvents = <BeamSession?>[];
  late final FakeSession initial;
  late final BeamPrivateNodeCoordinator coordinator;

  FakeNode get node => nodes.last;
  BeamPrivateNodeStatus get status => coordinator.status;

  Future<void> phase(Phase phase, {Duration? timeout}) => until(
    () => coordinator.status.phase == phase,
    timeout: timeout ?? const Duration(seconds: 5),
    reason: '${phase.name} (now ${coordinator.status})',
  );

  /// Starts and lets the node report fast sync at [percent].
  Future<void> startDownloading([int percent = 43]) async {
    await coordinator.start();
    node.emit(
      node.progress.copyWith(
        phase: BeamNodePhase.fastSyncDownloading,
        percent: percent,
        fastSyncTarget: _networkHeight - 1500,
      ),
    );
    await until(() => status.percent == percent, reason: 'percent');
  }

  Future<void> activate() async {
    await startDownloading();
    node.ready();
    await phase(Phase.active);
  }

  void expectNoR8Violation() => expect(host.r8Violations, isEmpty);

  void expectPrivateReceiveOnlyWhenConfirmed() {
    for (final s in statuses) {
      if (s.privateReceiveAvailable) {
        expect(s.phase, Phase.active, reason: '$s');
        expect(s.onPrivateNode, isTrue, reason: '$s');
      }
    }
  }

  Future<void> dispose() => coordinator.dispose();
}

String _title(BeamPrivateNodeStatus s) =>
    BeamPrivateNodeMessages.describe(s).title;

void main() {
  group('bring-up', () {
    test('the setting defaults to on for desktop', () async {
      expect(
        await BeamFixedPrivateNodeSetting.platformDefault().read(),
        Platform.isMacOS || Platform.isLinux || Platform.isWindows,
      );
    });

    test('setting off: nothing happens at all', () async {
      final h = Harness(setting: const BeamFixedPrivateNodeSetting(false));
      await h.coordinator.start();
      expect(h.status.phase, Phase.off);
      expect(h.host.calls, isEmpty);
      expect(h.nodes, isEmpty);
      expect(h.coordinator.session, same(h.initial));
      expect(_title(h.status), 'Private node is off');
      await h.dispose();
    });

    test('pause is close -> export -> reopen on the same public node; the '
        'key reaches the node; status shows the download', () async {
      final h = Harness();
      await h.startDownloading(43);
      expect(h.host.calls.take(3), ['close $_eu', 'export', 'open $_eu']);
      expect(h.coordinator.session!.node, _eu);
      expect(h.node.keyReceived, fakeOwnerKey);
      expect(h.status.phase, Phase.downloading);
      expect(h.status.lastPause, isNotNull);
      expect(
        _title(h.status),
        'Using a public node — your private node is downloading (43%)',
      );
      // The wallet layer saw the gap and the new session.
      expect(h.sessionEvents.first, isNull);
      expect(h.sessionEvents.last, same(h.coordinator.session));
      expect(h.statuses.first.phase, Phase.preparing);
      expect(h.log.join('\n'), isNot(contains(fakeOwnerKey)));
      expect(h.log.join('\n'), isNot(contains(fakePassword)));
      h.expectNoR8Violation();
      await h.dispose();
    });

    test('export fails: wallet reopened on its public node, no node is '
        'started', () async {
      final h = Harness();
      h.host.exportError = const BeamHostException(
        BeamHostError.wrongPassword,
        'The wallet password is wrong',
      );
      await h.coordinator.start();
      expect(h.status.phase, Phase.failed);
      expect(h.status.issue, BeamPrivateNodeIssue.keyExportFailed);
      expect(h.coordinator.session!.node, _eu);
      // A node object may exist (made before the disk check); none started.
      expect(h.nodes.where((n) => n.keyReceived != null), isEmpty);
      expect(
        BeamPrivateNodeMessages.actionFor(h.status),
        BeamPrivateNodeAction.retry,
      );
      h.expectNoR8Violation();
      await h.dispose();
    });

    test('reopen falls through the public list in order', () async {
      final h = Harness();
      h.host.failing.addAll({_eu, _us});
      await h.coordinator.start();
      expect(h.coordinator.session!.node, _eu1);
      expect(
        h.host.calls.where((c) => c.startsWith('open')).toList(),
        ['open $_eu', 'open $_us', 'open $_eu1'],
      );
      expect(h.status.phase, Phase.downloading);
      await h.dispose();
    });

    test('no public node answers: walletClosed, then retry reopens',
        () async {
      final h = Harness();
      h.host.failing.addAll({_eu, _us, _eu1, _us1});
      await h.coordinator.start();
      expect(h.status.phase, Phase.walletClosed);
      expect(h.coordinator.session, isNull);
      expect(
        h.nodes.where((n) => n.keyReceived != null),
        isEmpty,
        reason: 'no node started without a wallet',
      );
      expect(_title(h.status), "Couldn't reopen your wallet");
      h.host.failing.clear();
      await h.coordinator.retry();
      expect(h.coordinator.session?.node, _eu);
      expect(h.status.phase, Phase.downloading);
      h.expectNoR8Violation();
      await h.dispose();
    });
  });

  group('never keyless', () {
    test('node refuses the key at start: failed/keyRejected, node '
        'stopped, wallet stays public, no private receive', () async {
      final h = Harness(
        startError: const BeamNodeException(
          BeamNodeError.ownerKeyRejected,
          'The node could not import the owner key',
        ),
      );
      await h.coordinator.start();
      expect(h.status.phase, Phase.failed);
      expect(h.status.issue, BeamPrivateNodeIssue.keyRejected);
      expect(h.node.stopped, isTrue);
      expect(h.coordinator.session!.node, _eu);
      expect(h.coordinator.privateReceiveAvailable, isFalse);
      expect(
        h.host.calls.where((c) => c.contains('owned')),
        isEmpty,
        reason: 'never moved to a node without the key',
      );
      expect(_title(h.status), contains("couldn't use this wallet's key"));
      h.expectPrivateReceiveOnlyWhenConfirmed();
      await h.dispose();
    });

    test('node drops the key later (error on the stream): failed, never '
        'handed over', () async {
      final h = Harness();
      await h.startDownloading();
      h.node.emit(
        h.node.progress.copyWith(
          phase: BeamNodePhase.error,
          error: BeamNodeError.ownerKeyRejected,
        ),
      );
      await h.phase(Phase.failed);
      expect(h.status.issue, BeamPrivateNodeIssue.keyRejected);
      expect(h.coordinator.session!.node, _eu);
      expect(h.host.calls.where((c) => c.contains('owned')), isEmpty);
      await h.dispose();
    });

    test('binary problems are named as such', () async {
      final h = Harness(
        startError: const BeamHostException(
          BeamHostError.binaryUntrusted,
          'beam-node SHA-256 does not match',
        ),
      );
      await h.coordinator.start();
      expect(h.status.issue, BeamPrivateNodeIssue.binaryProblem);
      expect(_title(h.status), contains('safety check'));
      await h.dispose();
    });
  });

  group('readiness', () {
    test('within 5 blocks but no Tx replication yet: no handover', () async {
      final h = Harness();
      await h.startDownloading();
      h.node.emit(
        h.node.progress.copyWith(
          phase: BeamNodePhase.catchingUp,
          myTipHeight: _networkHeight - 1,
          myTipAt: DateTime.now(),
        ),
      );
      await h.phase(Phase.catchingUp);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(h.status.phase, Phase.catchingUp);
      expect(h.coordinator.session!.node, _eu);
      expect(h.host.calls.where((c) => c.contains('owned')), isEmpty);
      await h.dispose();
    });

    test('Tx replication ON but far behind: catching up, with how far',
        () async {
      final h = Harness();
      await h.startDownloading();
      h.node.ready(behind: 42);
      await until(() => h.status.blocksBehind == 42, reason: 'behind 42');
      expect(h.status.phase, Phase.catchingUp);
      expect(
        BeamPrivateNodeMessages.describe(h.status).detail,
        startsWith('Behind by 42 blocks'),
      );
      expect(h.coordinator.session!.node, _eu);
      await h.dispose();
    });

    test('explorer down: stays public and says why; hands over once it '
        'answers', () async {
      final h = Harness();
      await h.startDownloading();
      h.explorer.down = true;
      h.node.ready();
      await h.phase(Phase.cannotVerify);
      expect(h.status.issue, BeamPrivateNodeIssue.explorerUnavailable);
      expect(h.coordinator.session!.node, _eu);
      expect(
        BeamPrivateNodeMessages.actionFor(h.status),
        BeamPrivateNodeAction.checkAgain,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(h.host.calls.where((c) => c.contains('owned')), isEmpty);
      h.explorer.down = false;
      await h.coordinator.checkNow();
      await h.phase(Phase.active);
      await h.dispose();
    });

    test('a stale explorer tip counts as no explorer', () async {
      final h = Harness();
      await h.startDownloading();
      h.explorer.tipAge = const Duration(minutes: 20);
      h.node.ready();
      await h.phase(Phase.cannotVerify);
      expect(h.coordinator.session!.node, _eu);
      await h.dispose();
    });

    test('node ahead of the explorer: cannot be vouched for', () async {
      final h = Harness();
      await h.startDownloading();
      h.node.ready(behind: -20);
      await h.phase(Phase.cannotVerify);
      expect(h.status.issue, BeamPrivateNodeIssue.explorerBehind);
      await h.dispose();
    });

    test('stale node at the HF6 boundary: "synced" by its own log, stuck '
        'by the rules, never handed over', () async {
      final h = Harness();
      await h.startDownloading();
      h.node.emit(
        h.node.progress.copyWith(
          phase: BeamNodePhase.txReplicationOn,
          myTipHeight: 3928665,
          myTipAt: DateTime.now(),
        ),
      );
      await h.phase(Phase.stuck);
      expect(h.status.issue, BeamPrivateNodeIssue.belowHardFork);
      expect(h.coordinator.session!.node, _eu);
      expect(h.host.calls.where((c) => c.contains('owned')), isEmpty);
      final msg = BeamPrivateNodeMessages.describe(h.status);
      expect(msg.title, contains('stuck on an old version'));
      expect(msg.detail, contains('3,928,666'));
      expect(msg.detail, contains('3,928,665'));
      await h.dispose();
    });

    test('far below the fork is "behind", not "old network version"',
        () async {
      final h = Harness();
      await h.startDownloading();
      h.node.emit(
        h.node.progress.copyWith(
          phase: BeamNodePhase.txReplicationOn,
          myTipHeight: 2000000,
          myTipAt: DateTime.now(),
        ),
      );
      await until(() => h.status.networkHeight != null, reason: 'checked');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(h.status.phase, Phase.catchingUp);
      expect(h.status.blocksBehind, _networkHeight - 2000000);
      await h.dispose();
    });

    test('a tip that stopped moving is "stuck", not "catching up"',
        () async {
      final h = Harness(stallAfter: const Duration(milliseconds: 100));
      await h.startDownloading();
      h.node.ready(
        behind: 300,
        at: DateTime.now().subtract(const Duration(seconds: 5)),
      );
      await h.phase(Phase.stuck);
      expect(h.status.issue, BeamPrivateNodeIssue.notAdvancing);
      await h.dispose();
    });
  });

  group('handover', () {
    test('ready -> switch -> own_node == true -> active with private '
        'receive', () async {
      final h = Harness();
      await h.startDownloading();
      expect(h.coordinator.privateReceiveAvailable, isFalse);
      h.node.ready(behind: 3);
      await h.phase(Phase.active);
      final s = h.coordinator.session!;
      expect(s.node, const BeamNodeEndpoint('127.0.0.1', 40123, isOwned: true));
      expect(h.coordinator.privateReceiveAvailable, isTrue);
      expect(h.status.onPrivateNode, isTrue);
      expect(_title(h.status), 'Switched to your private node');
      // Only ev_connection_changed was subscribed: the wallet layer's
      // other subscriptions are untouched.
      expect(
        (s as FakeSession).transport.lastParams('ev_subunsub'),
        {'ev_connection_changed': true},
      );
      expect(
        h.statuses.map((x) => x.phase),
        containsAllInOrder([
          Phase.preparing,
          Phase.downloading,
          Phase.switching,
          Phase.active,
        ]),
      );
      h.expectNoR8Violation();
      h.expectPrivateReceiveOnlyWhenConfirmed();
      await h.dispose();
    });

    test('ready must hold for readyHoldFor before the wallet moves '
        '(a new wallet once sat on a node that was not ready)', () async {
      final h = Harness(readyHoldFor: const Duration(milliseconds: 400));
      await h.startDownloading();
      h.node.ready(behind: 3);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(h.coordinator.session!.node.isOwned, isFalse, reason: 'too soon');
      expect(h.status.phase, isNot(Phase.active));
      await h.phase(Phase.active);
      expect(h.coordinator.session!.node.isOwned, isTrue);
      await h.dispose();
    });

    test('a wallet that cannot send on the node goes back to a public node, '
        'and the next switch waits', () async {
      var canSend = false;
      final h = Harness(
        walletReadyTimeout: const Duration(milliseconds: 300),
        retryAfterNotServing: const Duration(minutes: 10),
        walletCanSend: () => canSend,
      );
      await h.startDownloading();
      h.node.ready(behind: 3);
      await h.phase(Phase.active);
      expect(h.coordinator.session!.node.isOwned, isTrue);
      await h.phase(Phase.fellBehind);
      expect(h.status.issue, BeamPrivateNodeIssue.notServingWallet);
      expect(h.coordinator.session!.node.isOwned, isFalse);
      // Still ready, but no new switch before retryAfterNotServing.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(h.coordinator.session!.node.isOwned, isFalse);
      expect(
        h.log.any((l) => l.contains('could not send')),
        isTrue,
      );
      canSend = true;
      await h.dispose();
    });

    test('a wallet that can send stays on the node', () async {
      final h = Harness(
        walletReadyTimeout: const Duration(milliseconds: 200),
        walletCanSend: () => true,
      );
      await h.startDownloading();
      h.node.ready(behind: 3);
      await h.phase(Phase.active);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(h.status.phase, Phase.active);
      expect(h.coordinator.session!.node.isOwned, isTrue);
      await h.dispose();
    });

    test('own_node false first, then true: still confirmed', () async {
      final h = Harness()..host.ownNode = OwnNodeBehaviour.falseThenTrue;
      await h.activate();
      expect(h.coordinator.privateReceiveAvailable, isTrue);
      await h.dispose();
    });

    test('own_node never confirmed: back on the public node, node '
        'stopped, private receive never offered', () async {
      final h = Harness()..host.ownNode = OwnNodeBehaviour.never;
      await h.startDownloading();
      h.node.ready();
      await h.phase(Phase.ownNodeUnconfirmed);
      expect(h.coordinator.session!.node, _eu);
      expect(h.node.stopped, isTrue);
      expect(h.coordinator.privateReceiveAvailable, isFalse);
      expect(h.statuses.any((s) => s.privateReceiveAvailable), isFalse);
      expect(_title(h.status), contains("Couldn't confirm your private node"));
      h.expectNoR8Violation();
      await h.dispose();
    });

    test('the wallet cannot open on the private node: back on public',
        () async {
      final h = Harness();
      await h.startDownloading();
      h.host.failing.add(
        const BeamNodeEndpoint('127.0.0.1', 40123, isOwned: true),
      );
      h.node.ready();
      await h.phase(Phase.ownNodeUnconfirmed);
      expect(h.status.issue, BeamPrivateNodeIssue.switchFailed);
      expect(h.coordinator.session!.node, _eu);
      expect(h.node.stopped, isTrue);
      h.expectNoR8Violation();
      await h.dispose();
    });
  });

  group('failover', () {
    test('node crash while active: back on the public node at once',
        () async {
      final h = Harness();
      await h.activate();
      h.node.crash();
      await h.phase(Phase.stopped);
      expect(h.coordinator.session!.node, _eu);
      expect(h.coordinator.privateReceiveAvailable, isFalse);
      expect(h.status.issue, BeamPrivateNodeIssue.nodeExited);
      expect(
        _title(h.status),
        'Your private node stopped — back on a public node',
      );
      expect(
        BeamPrivateNodeMessages.actionFor(h.status),
        BeamPrivateNodeAction.retry,
      );
      h.expectNoR8Violation();
      h.expectPrivateReceiveOnlyWhenConfirmed();
      await h.dispose();
    });

    test('node crash while still downloading: stopped, wallet untouched',
        () async {
      final h = Harness();
      await h.startDownloading();
      final opens = h.host.calls.where((c) => c.startsWith('open')).length;
      h.node.crash();
      await h.phase(Phase.stopped);
      expect(h.coordinator.session!.node, _eu);
      expect(h.host.calls.where((c) => c.startsWith('open')).length, opens);
      await h.dispose();
    });

    test('failover tries the public list in order', () async {
      final h = Harness();
      await h.activate();
      h.host.failing.addAll({_eu, _us});
      h.node.crash();
      await h.phase(Phase.stopped);
      expect(h.coordinator.session!.node, _eu1);
      await h.dispose();
    });

    test('node falls behind while active: public until it catches up, '
        'then back', () async {
      final h = Harness();
      await h.activate();
      h.explorer.height = _networkHeight + 50;
      await h.phase(Phase.fellBehind);
      expect(h.coordinator.session!.node, _eu);
      expect(h.coordinator.privateReceiveAvailable, isFalse);
      expect(h.node.stopped, isFalse, reason: 'it keeps syncing');
      expect(_title(h.status), contains('fell behind'));
      h.node.tip(_networkHeight + 49);
      await h.phase(Phase.active);
      expect(h.coordinator.session!.node.isOwned, isTrue);
      h.expectNoR8Violation();
      await h.dispose();
    });

    test('one late check is not enough to fail over', () async {
      final h = Harness();
      await h.activate();
      h.explorer.height = _networkHeight + 50;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      h.explorer.height = _networkHeight;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(h.status.phase, Phase.active);
      await h.dispose();
    });

    test('own_node lost while active: private receive off at once, then '
        'back to public', () async {
      final h = Harness(ownNodeTimeout: const Duration(milliseconds: 200));
      await h.activate();
      final t = (h.coordinator.session! as FakeSession).transport;
      t.emit('ev_connection_changed', {
        'node_connected': false,
        'own_node': false,
      });
      await until(() => !h.coordinator.privateReceiveAvailable);
      expect(h.status.phase, Phase.active);
      expect(_title(h.status), 'Reconnecting to your private node');
      await h.phase(Phase.ownNodeUnconfirmed);
      expect(h.status.issue, BeamPrivateNodeIssue.ownNodeLost);
      expect(h.coordinator.session!.node, _eu);
      await h.dispose();
    });

    test('own_node flaps back to true within the grace: stays active',
        () async {
      final h = Harness(ownNodeTimeout: const Duration(milliseconds: 300));
      await h.activate();
      final t = (h.coordinator.session! as FakeSession).transport;
      t.emit('ev_connection_changed', {'own_node': false});
      await until(() => !h.coordinator.privateReceiveAvailable);
      t.emit('ev_connection_changed', {'own_node': true});
      await until(() => h.coordinator.privateReceiveAvailable);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(h.status.phase, Phase.active);
      await h.dispose();
    });

    test('retry after a crash starts a new node with a fresh key read',
        () async {
      final h = Harness();
      await h.activate();
      h.node.crash();
      await h.phase(Phase.stopped);
      await h.coordinator.retry();
      expect(h.nodes, hasLength(2));
      expect(h.host.calls.where((c) => c == 'export'), hasLength(2));
      h.node.ready();
      await h.phase(Phase.active);
      h.expectNoR8Violation();
      await h.dispose();
    });
  });

  group('setting and lifecycle', () {
    test('turned off while active: back to public, node stopped', () async {
      var on = true;
      final h = Harness(
        setting: BeamCallbackPrivateNodeSetting(() async => on),
      );
      await h.activate();
      on = false;
      await h.coordinator.applySetting();
      expect(h.status.phase, Phase.off);
      expect(h.coordinator.session!.node, _eu);
      expect(h.node.stopped, isTrue);
      expect(h.coordinator.privateReceiveAvailable, isFalse);
      on = true;
      await h.coordinator.applySetting();
      expect(h.nodes, hasLength(2));
      await h.dispose();
    });

    test('dispose stops the node and leaves the session open', () async {
      final h = Harness();
      await h.startDownloading();
      await h.dispose();
      expect(h.node.stopped, isTrue);
      expect((h.coordinator.session! as FakeSession).closed, isFalse);
    });
  });

  group('messages', () {
    test('every phase and issue has plain wording without jargon', () {
      const banned = [
        'explorer',
        'owner key',
        'own_node',
        'rpc',
        'fast sync',
        'fast-sync',
        'wallet-api',
        'beam-node',
        'is_in_sync',
        'utxo',
      ];
      for (final phase in Phase.values) {
        for (final issue in [null, ...BeamPrivateNodeIssue.values]) {
          for (final receive in [false, true]) {
            final s = BeamPrivateNodeStatus(
              phase: phase,
              issue: issue,
              percent: 43,
              nodeHeight: 3928665,
              networkHeight: 4068124,
              privateReceiveAvailable: receive,
            );
            final m = BeamPrivateNodeMessages.describe(s);
            final text = '${m.title} ${m.detail ?? ''}'.toLowerCase();
            for (final word in banned) {
              expect(text, isNot(contains(word)), reason: '$s: $text');
            }
            expect(m.title, isNotEmpty);
            final action = BeamPrivateNodeMessages.actionFor(s);
            expect(
              m.actionLabel,
              BeamPrivateNodeMessages.actionLabel(action),
            );
          }
        }
      }
    });
  });

  group('with the real BeamNodeProcess (sh stand-in)', () {
    late NodeFixture fx;

    setUp(() async {
      fx = await NodeFixture.create();
    });

    tearDown(() async {
      await BeamNodeProcess.stopAll();
      await fx.tmp.delete(recursive: true);
    });

    test('log lines drive the handover; a killed node fails over',
        () async {
      await fx.script([
        'I 2026-10-06.12:00:01.000 Updating node: 43% (1749261/4068050)',
        'sleep 0.3',
        'I 2026-10-06.12:00:02.000 Fast-sync mode up to block number '
            '4066610, TxoLo=4062290',
        'sleep 0.3',
        'I 2026-10-06.12:00:03.000 Fast-sync succeeded',
        'I 2026-10-06.12:00:03.100 My Tip: ${_networkHeight - 2}-'
            '0011aabbccddeeff, Work = 2.7e+14',
        'I 2026-10-06.12:00:03.200 Tx replication is ON',
      ]);
      BeamNodeProcess? real;
      final h = Harness(
        // Room on disk regardless of this machine; the real probe has its
        // own test (beam_private_node_seamless_test.dart).
        diskProbe: () async =>
            const BeamNodeDiskSpace(freeBytes: 50 * kBeamGiB, nodeBytes: 0),
        nodeFactory: () => real = BeamNodeProcess(
          rootDir: p.join(fx.tmp.path, 'beam'),
          binaries: fx.binaries,
          log: fx.hostLog.add,
          startupWindow: const Duration(seconds: 3),
          stopGrace: const Duration(seconds: 2),
        ),
      );
      await h.coordinator.start();
      await h.phase(Phase.active, timeout: const Duration(seconds: 10));
      final port = real!.port!;
      expect(
        h.coordinator.session!.node,
        BeamNodeEndpoint('127.0.0.1', port, isOwned: true),
      );
      expect(
        h.statuses.map((s) => s.phase),
        containsAllInOrder([
          Phase.downloading,
          Phase.catchingUp,
          Phase.switching,
          Phase.active,
        ]),
      );
      expect(h.statuses.any((s) => s.percent == 43), isTrue);

      Process.killPid(real!.pid!, ProcessSignal.sigkill);
      await h.phase(Phase.stopped, timeout: const Duration(seconds: 10));
      expect(h.coordinator.session!.node, _eu);
      expect(h.coordinator.privateReceiveAvailable, isFalse);
      h.expectNoR8Violation();
      h.expectPrivateReceiveOnlyWhenConfirmed();
      await h.dispose();
    });
  }, skip: Platform.isWindows ? 'uses /bin/sh stand-ins' : false);
}

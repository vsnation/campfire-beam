/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The app has one private node (a thread of libbeam_core), and every open
// BEAM wallet would like it. A second wallet's start is refused as
// "serving another wallet" — never "another window" — and that refused
// node object must never stop the node the first wallet runs. A restart
// right after a stop waits for the old node instead of being refused.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/host/beam_core_library.dart';
import 'package:stackwallet/wallets/beam/host/beam_core_node_status.dart';
import 'package:stackwallet/wallets/beam/net/beam_node_route.dart';
import 'package:stackwallet/wallets/beam/node/beam_in_process_node.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_process.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_progress.dart';

/// The core's node, as `beam_node_*` behaves: one per process.
class FakeCore implements BeamCoreIntegrated {
  int state = BeamCoreNodeState.idle;
  int starts = 0;
  int stops = 0;

  /// Set: a stop takes this long before the node has ended.
  Duration? stopTakes;

  @override
  Future<int> startNode({
    required String nodeDbPath,
    required int port,
    required List<String> peers,
    required String ownerKey,
    required String password,
    int verificationThreads = -1,
    String? socksProxy,
  }) async {
    if (state == BeamCoreNodeState.starting ||
        state == BeamCoreNodeState.running ||
        state == BeamCoreNodeState.stopping) {
      return BeamCoreNodeError.alreadyRunning;
    }
    starts++;
    state = BeamCoreNodeState.running;
    return BeamCoreNodeError.ok;
  }

  @override
  void stopNode() {
    stops++;
    final takes = stopTakes;
    if (takes == null) {
      state = BeamCoreNodeState.stopped;
      return;
    }
    state = BeamCoreNodeState.stopping;
    Timer(takes, () => state = BeamCoreNodeState.stopped);
  }

  @override
  BeamCoreNodeStatus nodeStatus() => BeamCoreNodeStatus(
    state: state,
    ownerKeySet: state == BeamCoreNodeState.running,
    ownerAccounts: state == BeamCoreNodeState.running ? 1 : -1,
  );

  @override
  int initLogging({String? logDir, int consoleLevel = 4, int fileLevel = 4}) =>
      0;

  @override
  Future<({int code, String? key})> exportOwnerKey({
    required String dbPath,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<({int result, int instance})> startInstance(List<String> args) =>
      throw UnimplementedError();

  @override
  void stopInstance(int handle) => throw UnimplementedError();

  @override
  ({int state, int exitStatus}) instanceState(int handle) =>
      throw UnimplementedError();

  @override
  int instanceCount() => 0;
}

void main() {
  late Directory root;
  late FakeCore core;

  BeamInProcessNode node() => BeamInProcessNode(
    rootDir: root.path,
    core: core,
    router: const BeamNodeRouter.direct(),
    peers: const ['127.0.0.1:8100'],
    pollInterval: const Duration(milliseconds: 20),
    startupWindow: const Duration(seconds: 2),
    stopGrace: const Duration(seconds: 2),
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cfb-node-shared-');
    core = FakeCore();
  });

  tearDown(() async {
    await BeamInProcessNode.stopAll();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test("a second wallet's start is refused as serving another wallet, and "
      'its stop leaves the running node alone', () async {
    final first = node();
    await first.start(ownerKey: 'key-a', password: 'pw-a');
    expect(core.state, BeamCoreNodeState.running);
    expect(first.servesAnotherWallet, isFalse);

    final second = node();
    expect(second.servesAnotherWallet, isTrue);
    await expectLater(
      second.start(ownerKey: 'key-b', password: 'pw-b'),
      throwsA(
        isA<BeamNodeException>().having(
          (e) => e.kind,
          'kind',
          BeamNodeError.servingOtherWallet,
        ),
      ),
    );
    // What the coordinator does after a failed start.
    await second.stop();
    expect(core.stops, 0, reason: 'the refused node stopped the running one');
    expect(core.state, BeamCoreNodeState.running);

    await first.stop();
    expect(core.stops, 1);
    expect(core.state, BeamCoreNodeState.stopped);
  });

  test('once the node that ran stops, the next wallet can have it', () async {
    final first = node();
    await first.start(ownerKey: 'key-a', password: 'pw-a');
    await first.stop();

    final second = node();
    expect(second.servesAnotherWallet, isFalse);
    await second.start(ownerKey: 'key-b', password: 'pw-b');
    expect(core.starts, 2);
    expect(core.state, BeamCoreNodeState.running);
    await second.stop();
  });

  test('a restart right after a stop waits for the old node to end', () async {
    core.stopTakes = const Duration(milliseconds: 400);
    final first = node();
    await first.start(ownerKey: 'key-a', password: 'pw-a');
    core.stopNode(); // as a stop already in progress elsewhere
    expect(core.state, BeamCoreNodeState.stopping);

    final again = node();
    await again.start(ownerKey: 'key-a', password: 'pw-a');
    expect(core.starts, 2);
    expect(core.state, BeamCoreNodeState.running);
    await again.stop();
  });
}

/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// InProcessHost with libbeam_core's instances (desktop, Android) against a
// fake core: a start that fails without ending its instance (a timeout) must
// keep the wallet claimed until that instance has let go of wallet.db, so no
// second wallet-api opens the same file next to it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/host/beam_core_library.dart';
import 'package:stackwallet/wallets/beam/host/beam_core_node_status.dart';
import 'package:stackwallet/wallets/beam/host/beam_host.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/host/in_process_host.dart';

Matcher _hostError(BeamHostError kind) =>
    isA<BeamHostException>().having((e) => e.kind, 'kind', kind);

const _hf6Rules =
    'network=mainnet\n\t0-ed91a717313c6eb0\n\t3928666-96df3f33ee02ad9e\n';

/// How the next [_FakeInstances.startInstance] goes.
enum _Start {
  /// Listens on --port and answers get_version.
  serve,

  /// Times out (-102) and names its instance, which keeps running until
  /// [_FakeInstances.finish] or enough stop requests.
  timeoutTracked,

  /// Times out (-102) on a core before `beam_wallet_api_start_tracked`: the
  /// instance is not named, only counted.
  timeoutUntracked,
}

class _Instance {
  _Instance(this.id, {required this.ignoreStops});

  final int id;
  int ignoreStops;
  bool ended = false;
  ServerSocket? server;
}

class _FakeInstances implements BeamCoreIntegrated {
  final List<_Start> next = [];
  final Map<int, _Instance> instances = {};
  int _nextId = 1;
  int starts = 0;

  /// Stop requests an instance of a failed start ignores before it ends.
  int ignoreStops = 1 << 30;

  static String _arg(List<String> args, String name) => args
      .firstWhere((a) => a.startsWith('--$name='))
      .substring(name.length + 3);

  void finish(int id) => _end(instances[id]!);

  void _end(_Instance i) {
    i.ended = true;
    unawaited(i.server?.close());
    i.server = null;
  }

  @override
  Future<({int result, int instance})> startInstance(List<String> args) async {
    starts++;
    final how = next.isEmpty ? _Start.serve : next.removeAt(0);
    final i = _Instance(
      _nextId++,
      ignoreStops: how == _Start.serve ? 0 : ignoreStops,
    );
    instances[i.id] = i;
    switch (how) {
      case _Start.serve:
        final server = i.server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          int.parse(_arg(args, 'port')),
        );
        server.listen((socket) {
          utf8.decoder
              .bind(socket)
              .transform(const LineSplitter())
              .listen((line) {
                final req = jsonDecode(line) as Map<String, Object?>;
                socket.write(
                  '${jsonEncode({
                    'jsonrpc': '2.0',
                    'id': req['id'],
                    'result': {'api_version': '7.4'},
                  })}\n',
                );
              }, onError: (_) {});
        });
        return (result: i.id, instance: i.id);
      case _Start.timeoutTracked:
        return (result: BeamCoreInstance.timeout, instance: i.id);
      case _Start.timeoutUntracked:
        return (result: BeamCoreInstance.timeout, instance: 0);
    }
  }

  @override
  void stopInstance(int handle) {
    final i = instances[handle];
    if (i == null || i.ended) return;
    if (i.ignoreStops > 0) {
      i.ignoreStops--;
      return;
    }
    _end(i);
  }

  @override
  ({int state, int exitStatus}) instanceState(int handle) {
    final i = instances[handle];
    if (i == null) {
      return (state: BeamCoreInstance.unknown, exitStatus: 0);
    }
    return (
      state: i.ended ? BeamCoreInstance.stopped : BeamCoreInstance.running,
      exitStatus: 0,
    );
  }

  @override
  int instanceCount() => instances.values.where((i) => !i.ended).length;

  @override
  int initLogging({String? logDir, int consoleLevel = 4, int fileLevel = 4}) =>
      0;

  @override
  Future<({int code, String? key})> exportOwnerKey({
    required String dbPath,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<int> startNode({
    required String nodeDbPath,
    required int port,
    required List<String> peers,
    required String ownerKey,
    required String password,
    int verificationThreads = -1,
    String? socksProxy,
  }) => throw UnimplementedError();

  @override
  void stopNode() {}

  @override
  BeamCoreNodeStatus nodeStatus() => throw UnimplementedError();
}

class _FakeCore implements BeamCoreLibrary, BeamCoreIntegratedSource {
  final instances = _FakeInstances();
  int checkCalls = 0;

  @override
  BeamCoreIntegrated? get integrated => instances;

  @override
  String version() => '7.5.14493 (beam-7.5.14493-campfire)';

  @override
  String rulesSignature() => _hf6Rules;

  @override
  bool get isRunning => false;

  @override
  Future<int> run(List<String> args) => throw UnimplementedError();

  @override
  void stop() {}

  @override
  Future<int> initWallet({
    required String dbPath,
    required String password,
    required String phrase,
  }) async {
    await File(dbPath).writeAsString('fake wallet');
    return BeamCoreWalletResult.ok;
  }

  @override
  Future<int> checkWallet({
    required String dbPath,
    required String password,
  }) async {
    checkCalls++;
    return BeamCoreWalletResult.ok;
  }
}

void main() {
  late Directory tmp;
  late _FakeCore core;
  late String cwd;
  const node = BeamNodeEndpoint('127.0.0.1', 8100);
  const password = 'right-password';

  InProcessHost host() => InProcessHost(
    rootDir: p.join(tmp.path, 'beam'),
    library: core,
    startupTimeout: const Duration(seconds: 3),
    stopTimeout: const Duration(milliseconds: 300),
    setCurrentDirectory: (path) {
      final previous = cwd;
      cwd = path;
      return previous;
    },
  );

  Future<String> createWallet(InProcessHost h, String id) async {
    final dir = p.join(tmp.path, 'beam', 'wallets', id);
    await h.initWallet(
      walletDir: dir,
      password: password,
      words: bip39.generateMnemonic().split(' '),
    );
    return dir;
  }

  Future<BeamSession> open(InProcessHost h, String dir) =>
      h.openWallet(walletDir: dir, password: password, node: node);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('beam_inproc_inst_');
    core = _FakeCore();
    cwd = '/app-start';
  });

  tearDown(() async {
    await InProcessHost.shutdownAll();
    await tmp.delete(recursive: true);
  });

  test('a start whose instance is still running keeps the wallet claimed '
      'until that instance ends; nothing opens wallet.db meanwhile', () async {
    final h = host();
    final dir = await createWallet(h, 'w1');
    core.instances.next.add(_Start.timeoutTracked);

    await expectLater(
      open(h, dir),
      throwsA(_hostError(BeamHostError.walletInUse)),
    );
    expect(core.checkCalls, 0, reason: 'checkWallet would open wallet.db');
    expect(cwd, '/app-start');
    final stuck = core.instances.instances.values.single;
    expect(stuck.ended, isFalse);

    // Another node, another try: refused without starting a second one.
    await expectLater(
      open(h, dir),
      throwsA(_hostError(BeamHostError.walletInUse)),
    );
    expect(core.instances.starts, 1);

    core.instances.finish(stuck.id);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final session = await open(h, dir);
    expect(core.instances.starts, 2);
    await session.close();
  });

  test('an instance of a failed start that ends when asked frees the wallet '
      'at once and the failure is a timeout', () async {
    final h = host();
    final dir = await createWallet(h, 'w1');
    core.instances
      ..ignoreStops = 1
      ..next.add(_Start.timeoutTracked);

    await expectLater(
      open(h, dir),
      throwsA(_hostError(BeamHostError.timeout)),
    );
    expect(core.instances.instanceCount(), 0);
    expect(core.checkCalls, 0);

    final session = await open(h, dir);
    await session.close();
  });

  test('a core that does not name the instance: an instance count that does '
      'not drop back keeps the wallet claimed', () async {
    final h = host();
    final dir = await createWallet(h, 'w1');
    core.instances.next.add(_Start.timeoutUntracked);

    await expectLater(
      open(h, dir),
      throwsA(_hostError(BeamHostError.walletInUse)),
    );
    await expectLater(
      open(h, dir),
      throwsA(_hostError(BeamHostError.walletInUse)),
    );
    expect(core.instances.starts, 1);

    // Other wallets are not affected.
    final other = await createWallet(h, 'w2');
    final session = await open(h, other);
    await session.close();
  });
}

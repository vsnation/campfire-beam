/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// InProcessHost (iOS) against a fake core library: secret files, command line,
// current directory, start-up and failure mapping, one-core-per-process, stop
// and close. The fake "wallet-api" is a Dart loopback server that reads the
// config and ACL files the way the core does and answers JSON lines with the
// ACL key check. The real core is exercised in the iOS Simulator by
// scripts/beam/core/ios/verify_ios.sh --live and by the app (the project notes).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/host/beam_binaries_manifest.dart';
import 'package:stackwallet/wallets/beam/host/beam_core_library.dart';
import 'package:stackwallet/wallets/beam/host/beam_host.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/host/in_process_host.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/tcp_line_transport.dart';

Matcher _hostError(BeamHostError kind) =>
    isA<BeamHostException>().having((e) => e.kind, 'kind', kind);

const _hf6Rules =
    'network=mainnet\n\t0-ed91a717313c6eb0\n\t3928666-96df3f33ee02ad9e\n';

enum FakeMode {
  /// Listens, answers, returns 0 on stop.
  ok,

  /// Returns -1 at once (wrong password: checkWallet says so).
  wrongPassword,

  /// Returns -1 at once with a good password (a node that does not resolve).
  failsEarly,

  /// Never listens and ignores nothing: runs until stopped.
  neverListens,

  /// Ignores stop() for [FakeCore.ignoreStops] requests.
  slowStop,
}

/// A stand-in for the linked BEAM core.
class FakeCore implements BeamCoreLibrary {
  FakeCore({this.rules = _hf6Rules});

  final String rules;
  FakeMode mode = FakeMode.ok;
  int ignoreStops = 0;

  /// The password the fake wallet.db accepts.
  String walletPassword = 'right-password';

  bool _running = false;
  Completer<int>? _stopped;
  ServerSocket? _server;

  final List<List<String>> runs = [];
  final List<String> evidence = [];
  int stops = 0;
  int initCalls = 0;
  int checkCalls = 0;
  String? lastPhrase;
  String? cwdAtRun;
  String Function()? currentDir;

  @override
  String version() => '7.5.14493 (beam-7.5.14493-campfire)';

  @override
  String rulesSignature() => rules;

  @override
  bool get isRunning => _running;

  /// Simulates a wallet-api left running by an earlier Dart lifetime.
  void startOrphan() {
    _running = true;
    _stopped = Completer<int>();
  }

  @override
  void stop() {
    stops++;
    if (!_running) return;
    if (ignoreStops > 0) {
      ignoreStops--;
      return;
    }
    _finish(0);
  }

  /// wallet-api fails while serving.
  void crash() => _finish(-1);

  void _finish(int code) {
    final s = _server;
    _server = null;
    unawaited(s?.close());
    _running = false;
    final c = _stopped;
    if (c != null && !c.isCompleted) c.complete(code);
  }

  static String? _arg(List<String> args, String name) {
    for (final a in args) {
      if (a.startsWith('--$name=')) return a.substring(name.length + 3);
    }
    return null;
  }

  @override
  Future<int> run(List<String> args) async {
    runs.add(List.of(args));
    if (_running) return kBeamCoreAlreadyRunning;
    _running = true;
    cwdAtRun = currentDir?.call();
    final stopped = _stopped = Completer<int>();

    // Read the config and ACL as the core does, before anything else.
    final cfgPath = _arg(args, 'config_file')!;
    final aclPath = _arg(args, 'acl_path')!;
    final cfgStat = await FileStat.stat(cfgPath);
    evidence.add('cfg-mode-${(cfgStat.mode & 0x1ff).toRadixString(8)}');
    final aclStat = await FileStat.stat(aclPath);
    evidence.add('acl-mode-${(aclStat.mode & 0x1ff).toRadixString(8)}');
    final pass = (await File(
      cfgPath,
    ).readAsLines()).firstWhere((l) => l.startsWith('pass=')).substring(5);
    final aclLines = await File(aclPath).readAsLines();
    final aclKey = aclLines.single.split(':').first;

    switch (mode) {
      case FakeMode.wrongPassword:
      case FakeMode.failsEarly:
        _finish(-1);
        return stopped.future;
      case FakeMode.neverListens:
        return stopped.future;
      case FakeMode.ok:
      case FakeMode.slowStop:
        break;
    }
    if (pass != walletPassword) {
      _finish(-1);
      return stopped.future;
    }
    final port = int.parse(_arg(args, 'port')!);
    final server = _server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    server.listen((socket) {
      utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .listen(
            (line) {
              final req = jsonDecode(line) as Map<String, Object?>;
              final Object reply;
              if (req['key'] != aclKey) {
                reply = {
                  'jsonrpc': '2.0',
                  'id': req['id'],
                  'error': {'code': -32002, 'message': 'Unknown API key.'},
                };
              } else if (req['method'] == 'get_version') {
                reply = {
                  'jsonrpc': '2.0',
                  'id': req['id'],
                  'result': {'api_version': '7.4', 'beam_version': '7.5.14493'},
                };
              } else {
                reply = {
                  'jsonrpc': '2.0',
                  'id': req['id'],
                  'result': {'current_height': 4069105, 'is_in_sync': true},
                };
              }
              socket.write('${jsonEncode(reply)}\n');
            },
            onError: (_) {},
            cancelOnError: true,
          );
    });
    return stopped.future;
  }

  @override
  Future<int> initWallet({
    required String dbPath,
    required String password,
    required String phrase,
  }) async {
    initCalls++;
    lastPhrase = phrase;
    if (await File(dbPath).exists()) return BeamCoreWalletResult.exists;
    if (phrase.split(';').length != 12) {
      return BeamCoreWalletResult.invalidPhrase;
    }
    await File(dbPath).writeAsString('fake wallet');
    walletPassword = password;
    return BeamCoreWalletResult.ok;
  }

  @override
  Future<int> checkWallet({
    required String dbPath,
    required String password,
  }) async {
    checkCalls++;
    if (!await File(dbPath).exists()) return BeamCoreWalletResult.notFound;
    if (mode == FakeMode.wrongPassword || password != walletPassword) {
      return BeamCoreWalletResult.wrongPassword;
    }
    return BeamCoreWalletResult.ok;
  }
}

void main() {
  late Directory tmp;
  late FakeCore core;
  late List<String> logs;
  late String cwd;
  late List<String> words;
  const node = BeamNodeEndpoint('127.0.0.1', 8100);
  const password = 'right-password';

  InProcessHost host({FakeCore? library, Duration? slowClose}) => InProcessHost(
    rootDir: p.join(tmp.path, 'beam'),
    library: library ?? core,
    transportFactory: slowClose == null
        ? null
        : ({required int port, required String aclKey}) => _SlowCloseTransport(
            TcpLineTransport(port: port, aclKey: aclKey),
            slowClose,
          ),
    log: logs.add,
    startupTimeout: const Duration(seconds: 3),
    stopTimeout: const Duration(seconds: 2),
    setCurrentDirectory: (path) {
      final previous = cwd;
      cwd = path;
      return previous;
    },
  );

  String walletDir(String id) => p.join(tmp.path, 'beam', 'wallets', id);

  Future<String> createWallet(InProcessHost h, String id) async {
    final dir = walletDir(id);
    await h.initWallet(walletDir: dir, password: password, words: words);
    return dir;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('beam_inproc_');
    core = FakeCore();
    logs = [];
    cwd = '/app-start';
    core.currentDir = () => cwd;
    words = bip39.generateMnemonic().split(' ');
  });

  tearDown(() async {
    await InProcessHost.shutdownAll();
    core.stop();
    await tmp.delete(recursive: true);
  });

  group('initWallet', () {
    test('creates wallet.db with the words joined by ";", 0600', () async {
      final h = host();
      final dir = await createWallet(h, 'w1');
      expect(core.lastPhrase, words.join(';'));
      final stat = await FileStat.stat(p.join(dir, 'wallet.db'));
      expect((stat.mode & 0x1ff).toRadixString(8), '600');
      final dirStat = await FileStat.stat(dir);
      expect((dirStat.mode & 0x1ff).toRadixString(8), '700');
    });

    test('rejects a bad checksum before the core sees it', () async {
      final bad = List.filled(12, 'abandon'); // dictionary words, bad checksum
      expect(bip39.validateMnemonic(bad.join(' ')), isFalse);
      await expectLater(
        host().initWallet(
          walletDir: walletDir('w'),
          password: password,
          words: bad,
        ),
        throwsA(_hostError(BeamHostError.invalidInput)),
      );
      expect(core.initCalls, 0);
    });

    test('an existing wallet.db is walletExists and is kept', () async {
      final h = host();
      final dir = await createWallet(h, 'w1');
      await expectLater(
        h.initWallet(walletDir: dir, password: password, words: words),
        throwsA(_hostError(BeamHostError.walletExists)),
      );
      expect(
        await File(p.join(dir, 'wallet.db')).readAsString(),
        'fake wallet',
      );
    });

    test('a password BEAM would store differently is refused', () async {
      await expectLater(
        host().initWallet(
          walletDir: walletDir('w'),
          password: 'a#b',
          words: words,
        ),
        throwsA(_hostError(BeamHostError.invalidInput)),
      );
      expect(core.initCalls, 0);
    });
  });

  group('openWallet', () {
    test('starts wallet-api on loopback with an ACL key; secrets only in 0600 '
        'files that are gone once it listens', () async {
      final h = host();
      final dir = await createWallet(h, 'w1');
      final session = await h.openWallet(
        walletDir: dir,
        password: password,
        node: node,
      );
      final args = core.runs.single;

      expect(core.evidence, ['cfg-mode-600', 'acl-mode-600']);
      expect(args.join(' '), isNot(contains(password)));
      expect(args, contains('--node_addr=127.0.0.1:8100'));
      expect(args, contains('--use_http=0'));
      expect(args, contains('--ip_whitelist=127.0.0.1'));
      expect(args, contains('--use_acl=1'));
      expect(args, contains('--api_version=7.4'));
      expect(args, contains('--log_level=warning'));
      expect(args, contains('--file_log_level=warning'));
      expect(args, contains('--wallet_path=${p.join(dir, 'wallet.db')}'));
      expect(
        args,
        contains(
          '--privileged_shader_sha256='
          '${kBeamPrivilegedShaderSha256s.join(',')}',
        ),
      );
      final port = int.parse(
        args.firstWhere((a) => a.startsWith('--port=')).substring(7),
      );
      expect(port, (session as InProcessSession).port);

      // Config and ACL files are deleted, and nothing secret is left in run/.
      final cfg = args
          .firstWhere((a) => a.startsWith('--config_file='))
          .substring(14);
      final acl = args
          .firstWhere((a) => a.startsWith('--acl_path='))
          .substring(11);
      expect(await File(cfg).exists(), isFalse);
      expect(await File(acl).exists(), isFalse);
      expect(p.dirname(cfg), h.runDir);
      final leftovers = await Directory(h.runDir)
          .list()
          .where((e) => p.basename(e.path).startsWith('.s-'))
          .toList();
      expect(leftovers, isEmpty);

      // The current directory was run/ while wallet-api started, and is back.
      expect(core.cwdAtRun, h.runDir);
      expect(cwd, '/app-start');

      // The transport speaks to it with the ACL key.
      final status = await session.transport.call('wallet_status');
      expect((status as Map)['current_height'], 4069105);

      // Nothing secret in the host's log.
      expect(logs.join('\n'), isNot(contains(password)));
      await session.close();
    });

    test('no wallet.db is walletNotFound and nothing runs', () async {
      await expectLater(
        host().openWallet(
          walletDir: walletDir('none'),
          password: password,
          node: node,
        ),
        throwsA(_hostError(BeamHostError.walletNotFound)),
      );
      expect(core.runs, isEmpty);
    });

    test('an early exit with a wrong password is wrongPassword', () async {
      final h = host();
      final dir = await createWallet(h, 'w1');
      core.mode = FakeMode.wrongPassword;
      await expectLater(
        h.openWallet(walletDir: dir, password: 'other-password', node: node),
        throwsA(_hostError(BeamHostError.wrongPassword)),
      );
      expect(core.checkCalls, 1);
      expect(cwd, '/app-start');
      // The wallet is free again.
      core.mode = FakeMode.ok;
      final s = await h.openWallet(
        walletDir: dir,
        password: password,
        node: node,
      );
      await s.close();
    });

    test('an early exit with a good password and an unresolvable node is '
        'badNode', () async {
      final h = host();
      final dir = await createWallet(h, 'w1');
      core.mode = FakeMode.failsEarly;
      await expectLater(
        h.openWallet(
          walletDir: dir,
          password: password,
          node: const BeamNodeEndpoint('no-such-host.invalid', 8100),
        ),
        throwsA(_hostError(BeamHostError.badNode)),
      );
    });

    test('an early exit with a good password and a reachable address is '
        'processFailed with the exit status', () async {
      final h = host();
      final dir = await createWallet(h, 'w1');
      core.mode = FakeMode.failsEarly;
      await expectLater(
        h.openWallet(walletDir: dir, password: password, node: node),
        throwsA(
          isA<BeamHostException>()
              .having((e) => e.kind, 'kind', BeamHostError.processFailed)
              .having((e) => e.message, 'message', contains('exit -1')),
        ),
      );
    });

    test('a core that never listens times out, is stopped, and leaves no '
        'secret behind', () async {
      final h = host();
      final dir = await createWallet(h, 'w1');
      core.mode = FakeMode.neverListens;
      await expectLater(
        h.openWallet(walletDir: dir, password: password, node: node),
        throwsA(_hostError(BeamHostError.timeout)),
      );
      expect(core.isRunning, isFalse);
      expect(core.stops, greaterThan(0));
      expect(cwd, '/app-start');
      final leftovers = await Directory(h.runDir)
          .list()
          .where((e) => p.basename(e.path).startsWith('.s-'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('stray wallet-api.cfg / beam-common.cfg in run/ are removed before '
        'start', () async {
      final h = host();
      final dir = await createWallet(h, 'w1');
      await File(p.join(h.runDir, 'wallet-api.cfg'))
          .writeAsString('use_acl=0\n');
      await File(p.join(h.runDir, 'beam-common.cfg')).writeAsString('x=1\n');
      final s = await h.openWallet(
        walletDir: dir,
        password: password,
        node: node,
      );
      expect(await File(p.join(h.runDir, 'wallet-api.cfg')).exists(), isFalse);
      expect(await File(p.join(h.runDir, 'beam-common.cfg')).exists(), isFalse);
      await s.close();
    });
  });

  group('one wallet-api per process', () {
    test('the same wallet twice is walletInUse', () async {
      final h = host();
      final dir = await createWallet(h, 'w1');
      final s = await h.openWallet(
        walletDir: dir,
        password: password,
        node: node,
      );
      await expectLater(
        h.openWallet(walletDir: dir, password: password, node: node),
        throwsA(_hostError(BeamHostError.walletInUse)),
      );
      await s.close();
    });

    test('a second wallet while one is open is walletInUse; after close it '
        'opens', () async {
      final h = host();
      final a = await createWallet(h, 'a');
      final b = await createWallet(h, 'b');
      final s = await h.openWallet(
        walletDir: a,
        password: password,
        node: node,
      );
      await expectLater(
        h.openWallet(walletDir: b, password: password, node: node),
        throwsA(
          isA<BeamHostException>()
              .having((e) => e.kind, 'kind', BeamHostError.walletInUse)
              .having((e) => e.message, 'message', contains('one at a time')),
        ),
      );
      await s.close();
      final s2 = await h.openWallet(
        walletDir: b,
        password: password,
        node: node,
      );
      await s2.close();
    });

    test(
      'a core still running from before a hot restart is stopped first',
      () async {
        final h = host();
        final dir = await createWallet(h, 'w1');
        core.startOrphan();
        final s = await h.openWallet(
          walletDir: dir,
          password: password,
          node: node,
        );
        expect(core.stops, greaterThan(0));
        expect(logs.join('\n'), contains('still running'));
        await s.close();
      },
    );
  });

  group('close, switch, failures while open', () {
    test('close stops the core, waits for it, and frees the wallet', () async {
      final h = host();
      final dir = await createWallet(h, 'w1');
      final s = await h.openWallet(
        walletDir: dir,
        password: password,
        node: node,
      ) as InProcessSession;
      await s.close();
      expect(core.isRunning, isFalse);
      expect(await s.exitCode, 0);
      expect(s.isClosed, isTrue);
      final again = await h.openWallet(
        walletDir: dir,
        password: password,
        node: node,
      );
      await again.close();
    });

    test('a stop request that is ignored at first is repeated', () async {
      final h = host();
      final dir = await createWallet(h, 'w1');
      final s = await h.openWallet(
        walletDir: dir,
        password: password,
        node: node,
      );
      core.ignoreStops = 3;
      await s.close();
      expect(core.isRunning, isFalse);
      expect(core.stops, greaterThanOrEqualTo(4));
    });

    test('switchNode closes this session and opens on the new node', () async {
      final h = host();
      final dir = await createWallet(h, 'w1');
      final s = await h.openWallet(
        walletDir: dir,
        password: password,
        node: node,
      );
      final s2 = await s.switchNode(const BeamNodeEndpoint('127.0.0.1', 8101));
      expect((s as InProcessSession).isClosed, isTrue);
      expect(s2.node.port, 8101);
      expect(core.runs.last, contains('--node_addr=127.0.0.1:8101'));
      await s2.close();
    });

    test('wallet-api failing while open closes the session and frees the '
        'wallet', () async {
      final h = host();
      final dir = await createWallet(h, 'w1');
      final s = await h.openWallet(
        walletDir: dir,
        password: password,
        node: node,
      ) as InProcessSession;
      core.crash();
      expect(await s.exitCode, -1);
      await Future<void>.delayed(Duration.zero);
      expect(s.isClosed, isTrue);
      await s.close(); // waits for the close the failure started
      expect(logs.join('\n'), contains('stopped unexpectedly'));
      final again = await h.openWallet(
        walletDir: dir,
        password: password,
        node: node,
      );
      await again.close();
    });

    test("a session that stopped unexpectedly never stops the next wallet's "
        'core', () async {
      // a's transport takes a while to close, so a's close reaches its stop
      // step only after b's core is already running.
      final h = host(slowClose: const Duration(milliseconds: 1500));
      final a = await createWallet(h, 'a');
      final b = await createWallet(h, 'b');
      final sa = await h.openWallet(
        walletDir: a,
        password: password,
        node: node,
      ) as InProcessSession;
      core.crash();
      await sa.exitCode;
      await Future<void>.delayed(Duration.zero);
      // b opens while a's close is still finishing.
      final sb = await h.openWallet(
        walletDir: b,
        password: password,
        node: node,
      );
      final stopsBefore = core.stops;
      expect(core.isRunning, isTrue);
      await sa.close();
      expect(core.stops, stopsBefore, reason: 'a must not send stop()');
      expect(core.isRunning, isTrue);
      final status = await sb.transport.call('wallet_status');
      expect((status as Map)['is_in_sync'], isTrue);
      await sb.close();
      expect(core.isRunning, isFalse);
    });
  });

  group('no private node on iOS', () {
    test('exportOwnerKey is refused (the key is never read)', () async {
      await expectLater(
        host().exportOwnerKey(walletDir: walletDir('w'), password: password),
        throwsA(_hostError(BeamHostError.notOwnedNode)),
      );
    });

    test('rescan is notOwnedNode', () async {
      await expectLater(
        host().rescan(
          walletDir: walletDir('w'),
          password: password,
          node: node,
        ),
        throwsA(_hostError(BeamHostError.notOwnedNode)),
      );
    });
  });

  test('no core linked into the app is binaryMissing', () async {
    final h = InProcessHost(
      rootDir: p.join(tmp.path, 'beam'),
      openLibrary: () => null,
    );
    await expectLater(
      h.initWallet(walletDir: walletDir('w'), password: password, words: words),
      throwsA(_hostError(BeamHostError.binaryMissing)),
    );
  });
}

/// A transport whose close() takes [delay] before closing [inner].
class _SlowCloseTransport implements BeamTransport {
  _SlowCloseTransport(this.inner, this.delay);

  final BeamTransport inner;
  final Duration delay;

  @override
  Future<void> connect() => inner.connect();

  @override
  bool get isConnected => inner.isConnected;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) => inner.call(method, params, timeout);

  @override
  Stream<BeamEvent> get events => inner.events;

  @override
  Future<void> close() async {
    await Future<void>.delayed(delay);
    await inner.close();
  }
}

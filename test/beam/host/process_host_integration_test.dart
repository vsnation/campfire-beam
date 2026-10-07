/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// ProcessHost + TcpLineTransport against the real binaries and BEAM mainnet,
// with a throwaway wallet created from a fresh phrase. The wallet never holds
// funds, the phrase and password exist only in this process's memory, and
// the whole directory is deleted at the end. Nothing secret is printed.
//
//   BEAM_HOST_IT=1 \
//   BEAM_BIN_DIR=$HOME/Desktop/Beam/LightWallet/binaries/macos \
//   flutter test --no-pub test/beam/host/process_host_integration_test.dart
@Timeout(Duration(minutes: 15))
library;

import 'dart:io';
import 'dart:math';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/host/beam_binaries.dart';
import 'package:stackwallet/wallets/beam/host/beam_binaries_manifest.dart';
import 'package:stackwallet/wallets/beam/host/beam_host.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/host/process_host.dart';
import 'package:stackwallet/wallets/beam/host/secret_file.dart';

Matcher _hostError(BeamHostError kind) =>
    isA<BeamHostException>().having((e) => e.kind, 'kind', kind);

/// Test evidence for the report. Never called with a secret.
void _evidence(String line) {
  // ignore: avoid_print
  print('[evidence] $line');
}

String _randomAlnum(int length) {
  const chars =
      'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0O1lI
  final r = Random.secure();
  return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
}

Future<bool> _running(int pid) async {
  if (Platform.isWindows) {
    final r = await Process.run('tasklist', [
      '/FI',
      'PID eq $pid',
      '/NH',
      '/FO',
      'CSV',
    ]);
    return '${r.stdout}'.contains('"$pid"');
  }
  final r = await Process.run('ps', ['-p', '$pid', '-o', 'comm=']);
  return r.exitCode == 0 && '${r.stdout}'.trim().isNotEmpty;
}

/// Every process as "<pid> <command line>", one per line: `ps` on macOS and
/// Linux, the process table (Win32_Process) on Windows.
Future<String> _processes() async {
  if (Platform.isWindows) {
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'Get-CimInstance Win32_Process | '
          r'ForEach-Object { "$($_.ProcessId) $($_.CommandLine)" }',
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return '${r.stdout}'.replaceAll('\r', '');
  }
  final r = await Process.run('ps', ['-axo', 'pid,args']);
  expect(r.exitCode, 0);
  return '${r.stdout}';
}

/// The TCP addresses [pid] listens on ("127.0.0.1:64397"): lsof on macOS
/// and Linux, netstat on Windows.
Future<List<String>> _listening(int pid) async {
  if (Platform.isWindows) {
    final r = await Process.run('netstat', ['-ano', '-p', 'TCP']);
    return [
      for (final l in '${r.stdout}'.split('\n'))
        if (l.trim().startsWith('TCP') &&
            l.contains('LISTENING') &&
            l.trim().split(RegExp(r'\s+')).last == '$pid')
          l.trim().split(RegExp(r'\s+'))[1],
    ];
  }
  final r = await Process.run('lsof', [
    '-nP',
    '-a',
    '-p',
    '$pid',
    '-iTCP',
    '-sTCP:LISTEN',
  ]);
  return [
    for (final l in '${r.stdout}'.split('\n').skip(1))
      for (final t in l.trim().split(RegExp(r'\s+')))
        if (RegExp(r':\d+$').hasMatch(t)) t,
  ];
}

/// Only this user can read [path]: mode [posix] on macOS and Linux; on
/// Windows, no access entry for Everyone, Users or Authenticated Users
/// (icacls), as for anything in the user's profile.
Future<void> _expectPrivate(String path, int posix) async {
  if (Platform.isWindows) {
    final r = await Process.run('icacls', [path]);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    for (final broad in const [
      'Everyone:',
      r'BUILTIN\Users:',
      r'NT AUTHORITY\Authenticated Users:',
    ]) {
      expect('${r.stdout}', isNot(contains(broad)), reason: path);
    }
    return;
  }
  expect(await posixMode(path), posix);
}

const _nodes = [
  'eu-nodes.mainnet.beam.mw:8100',
  'eu-node01.mainnet.beam.mw:8100',
  'us-nodes.mainnet.beam.mw:8100',
];

void main() {
  final enabled = Platform.environment['BEAM_HOST_IT'] == '1';
  final binDir = Platform.environment[BeamBinaries.binDirEnv];
  final home = Platform.environment['HOME'];

  group(
    'ProcessHost on mainnet',
    () {
      late Directory root;
      late ProcessHost host;
      late String walletDir;
      late String password;
      late List<String> words;
      ProcessSession? session;
      final hostLog = <String>[];

      String tilde(String s) => s.replaceAll(home!, '~');

      /// [hexCheck]: also refuse any 64-hex token, the shape of the ACL
      /// key. Only for text that should hold no hashes at all (our own
      /// children's argv, the host log); wallet-api logs block hashes.
      void expectNoSecret(String text, String what, {bool hexCheck = true}) {
        expect(text.contains(password), isFalse, reason: '$what: password');
        expect(
          text.contains(words.join(';')) || text.contains(words.join(' ')),
          isFalse,
          reason: '$what: seed phrase',
        );
        if (hexCheck) {
          // The privileged shader hash on a Campfire build's argv is public.
          var rest = text;
          for (final hash in kBeamPrivilegedShaderSha256s) {
            rest = rest.replaceAll(hash, '');
          }
          expect(
            RegExp(r'[0-9a-f]{64}').hasMatch(rest),
            isFalse,
            reason: '$what: 64-hex token (ACL key shape)',
          );
        }
      }

      setUpAll(() async {
        final base = p.join(home!, 'beam-campfire-test');
        await Directory(base).create(recursive: true);
        root = Directory(p.join(base, 'it-${_randomAlnum(8)}'));
        await ensurePrivateDir(root.path);
        host = ProcessHost(
          rootDir: root.path,
          // flutter_tester is x86_64 under Rosetta; the pinned arm64
          // binaries run natively.
          binaries: BeamBinaries(
            binDir: binDir!,
            platform: Platform.isMacOS ? 'macos-arm64' : null,
          ),
          log: hostLog.add,
          startupTimeout: const Duration(seconds: 30),
        );
        walletDir = host.walletDirFor('it');
        password = _randomAlnum(24);
        words = bip39.generateMnemonic().split(' ');
        _evidence('root ${tilde(root.path)} (0700)');
      });

      tearDownAll(() async {
        await ProcessHost.shutdownAll();
        if (await root.exists()) await root.delete(recursive: true);
        _evidence('deleted ${tilde(root.path)}: ${!await root.exists()}');
        for (final line in hostLog) {
          expectNoSecret(line, 'host log');
        }
        _evidence('host log (${hostLog.length} lines, no secrets):');
        for (final line in hostLog) {
          _evidence('  ${tilde(line)}');
        }
      });

      test('initWallet creates wallet.db from a fresh phrase', () async {
        final sw = Stopwatch()..start();
        await host.initWallet(
          walletDir: walletDir,
          password: password,
          words: words,
        );
        _evidence('initWallet took ${sw.elapsedMilliseconds} ms');
        expect(await File(p.join(walletDir, 'wallet.db')).exists(), isTrue);
        await _expectPrivate(p.join(walletDir, 'wallet.db'), 0x180);
      });

      test('openWallet on a public node reaches is_in_sync', () async {
        BeamHostException? lastError;
        for (final address in _nodes) {
          try {
            session = await host.openWallet(
              walletDir: walletDir,
              password: password,
              node: BeamNodeEndpoint.parse(address),
            ) as ProcessSession;
            break;
          } on BeamHostException catch (e) {
            lastError = e;
            _evidence('open on $address failed: ${e.kind.name}');
          }
        }
        final s = session;
        expect(s, isNotNull, reason: '$lastError');
        _evidence('opened on ${s!.node}, port ${s.port}, pid ${s.pid}');

        final version = await s.transport.call('get_version');
        expect(version, isA<Map<String, Object?>>());
        final v = version! as Map<String, Object?>;
        expect(v['api_version'], kBeamApiVersion);
        _evidence(
          'get_version: api_version=${v['api_version']} '
          'beam_version=${v['beam_version']}',
        );

        final sw = Stopwatch()..start();
        Map<String, Object?> status = const {};
        while (sw.elapsed < const Duration(minutes: 5)) {
          final r = await s.transport.call('wallet_status');
          status = (r! as Map).cast<String, Object?>();
          if (status['is_in_sync'] == true) break;
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        final age =
            DateTime.now().millisecondsSinceEpoch ~/ 1000 -
            ((status['current_state_timestamp'] as int?) ?? 0);
        _evidence(
          'wallet_status after ${sw.elapsed.inSeconds} s: '
          'is_in_sync=${status['is_in_sync']} '
          'current_height=${status['current_height']} '
          'tip_age_s=$age available=${status['available']}',
        );
        expect(status['is_in_sync'], isTrue);
      });

      test('no password, phrase or ACL key on any process argv', () async {
        final out = await _processes();
        // Other users' and agents' processes may carry hashes; the password
        // and phrase must appear nowhere, any 64-hex token not in ours.
        expectNoSecret(out, 'process list', hexCheck: false);
        final ours = out
            .split('\n')
            .where((l) => l.contains(root.path) || l.contains(binDir!))
            .toList();
        expect(ours, isNotEmpty);
        for (final line in ours) {
          expectNoSecret(line, 'argv of a child');
        }
        final mine = out
            .split('\n')
            .where((l) => l.trimLeft().startsWith('${session!.pid} '))
            .toList();
        expect(mine, hasLength(1));
        _evidence('process list | wallet-api child:');
        _evidence('  ${tilde(mine.single.trim())}');
        expect(mine.single, contains('--use_acl=1'));
        expect(mine.single, contains('--config_file='));
        expect(mine.single, isNot(contains('--pass')));
      });

      test('no secret file is left in run/', () async {
        final names = (await Directory(
          host.runDir,
        ).list().toList()).map((e) => p.basename(e.path)).toList()..sort();
        _evidence('ls -A run/: $names');
        expect(
          names.where(
            (n) =>
                n.startsWith(kSecretPrefix) ||
                n.endsWith('.cfg') ||
                n.endsWith('.acl'),
          ),
          isEmpty,
        );
        expect(SecretFiles.livePaths, isEmpty);
        await _expectPrivate(host.runDir, 0x1c0);
      });

      test('record what wallet-api listens on', () async {
        final s = session!;
        final listening = await _listening(s.pid);
        _evidence('wallet-api listens on: $listening');
        expect(listening, contains('127.0.0.1:${s.port}'));
        // The pinned cores carry patch 0001: loopback only.
        expect(listening.every((a) => a.startsWith('127.0.0.1:')), isTrue);
        // The captured console log is private and lives with the wallet.
        final logs = await Directory(ProcessHost.walletLogsDir(walletDir))
            .list()
            .toList();
        for (final f in logs.whereType<File>()) {
          if (p.basename(f.path).startsWith('wallet-api-')) {
            await _expectPrivate(f.path, 0x180);
            expectNoSecret(
              await f.readAsString(),
              'captured log',
              hexCheck: false,
            );
          }
        }
      });

      test('a second open of the same wallet is refused', () async {
        await expectLater(
          host.openWallet(
            walletDir: walletDir,
            password: password,
            node: BeamNodeEndpoint.parse(_nodes.first),
          ),
          throwsA(_hostError(BeamHostError.walletInUse)),
        );
        await expectLater(
          host.exportOwnerKey(walletDir: walletDir, password: password),
          throwsA(_hostError(BeamHostError.walletInUse)),
        );
        _evidence('second openWallet and exportOwnerKey: walletInUse');
      });

      test('switchNode restarts wallet-api on another node', () async {
        final old = session!;
        final oldPid = old.pid;
        final target = BeamNodeEndpoint.parse(
          old.node.toString() == _nodes.last ? _nodes.first : _nodes.last,
        );
        final next = await old.switchNode(target) as ProcessSession;
        session = next;
        expect(old.isClosed, isTrue);
        expect(await _running(oldPid), isFalse);
        expect(next.node, target);
        expect(next.pid, isNot(oldPid));
        final v = await next.transport.call('get_version') as Map?;
        expect(v?['api_version'], kBeamApiVersion);
        _evidence(
          'switchNode: pid $oldPid -> ${next.pid}, port ${next.port}, '
          'node ${next.node}; old pid running: false',
        );
      });

      test('close() leaves no child process', () async {
        final s = session!;
        final pid = s.pid;
        await s.close();
        expect(s.isClosed, isTrue);
        expect(await _running(pid), isFalse);
        expect(await _processes(), isNot(contains(root.path)));
        expect(await File(p.join(walletDir, '.wallet.lock')).exists(), isFalse);
        _evidence(
          'after close: pid $pid running=false, no process '
          'mentions the test root, lock file gone',
        );
      });

      test('a wrong password is a typed error and leaves nothing '
          'behind', () async {
        final sw = Stopwatch()..start();
        await expectLater(
          host.openWallet(
            walletDir: walletDir,
            password: '${password}x',
            node: BeamNodeEndpoint.parse(_nodes.first),
          ),
          throwsA(_hostError(BeamHostError.wrongPassword)),
        );
        _evidence(
          'wrong password -> wrongPassword in '
          '${sw.elapsedMilliseconds} ms',
        );
        expect(await _processes(), isNot(contains(root.path)));
        final names = (await Directory(
          host.runDir,
        ).list().toList()).map((e) => p.basename(e.path));
        expect(names.where((n) => n.startsWith(kSecretPrefix)), isEmpty);

        await expectLater(
          host.exportOwnerKey(walletDir: walletDir, password: '${password}x'),
          throwsA(_hostError(BeamHostError.wrongPassword)),
        );
      });

      test('exportOwnerKey works on the closed wallet', () async {
        final key = await host.exportOwnerKey(
          walletDir: walletDir,
          password: password,
        );
        expect(key, isNotEmpty);
        expect(key.length, greaterThan(40));
        _evidence('exportOwnerKey: ${key.length} chars (value not shown)');
        final names = (await Directory(
          host.runDir,
        ).list().toList()).map((e) => p.basename(e.path));
        expect(names.where((n) => n.startsWith(kSecretPrefix)), isEmpty);
      });
    },
    skip: !enabled || binDir == null || home == null
        ? 'set BEAM_HOST_IT=1 and BEAM_BIN_DIR to run against mainnet'
        : false,
  );
}

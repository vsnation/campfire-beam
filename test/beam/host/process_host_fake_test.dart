/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// ProcessHost plumbing against /bin/sh stand-ins for beam-wallet and
// wallet-api: secret files, argv, working directories, error mapping and the
// wallet lock. No BEAM binary, network or real secret is involved. The real
// binaries are exercised by process_host_integration_test.dart.

import 'dart:convert';
import 'dart:io';

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

const _rules =
    r"printf 'I Rules signature: network=mainnet\n\t3928666-96df3f33ee02ad9e\n'";

const _common = '''
here=\$(cd "\$(dirname "\$0")" && pwd)
mode=\$(cat "\$here/mode" 2>/dev/null)
cfg=""; db=""; acl=""; port=""
for a in "\$@"; do
  case "\$a" in
    --config_file=*) cfg="\${a#--config_file=}" ;;
    --wallet_path=*) db="\${a#--wallet_path=}" ;;
    --acl_path=*) acl="\${a#--acl_path=}" ;;
    --port=*) port="\${a#--port=}" ;;
  esac
done
printf '%s\\n' "\$*" >> "\$here/argv.log"
pwd >> "\$here/cwd.log"
''';

/// Reads the config the way BEAM does (open, then print the path), then
/// records whether the host unlinked it while this process was running.
const _readConfig = r'''
content=$(cat "$cfg")
echo "Reading config from $cfg"
pass=$(printf '%s\n' "$content" | sed -n 's/^pass=//p')
seed=$(printf '%s\n' "$content" | sed -n 's/^seed_phrase=//p')
i=0
while [ -f "$cfg" ] && [ $i -lt 60 ]; do sleep 0.05; i=$((i+1)); done
if [ -f "$cfg" ]; then echo cfg-kept >> "$here/evidence.log"
else echo cfg-unlinked >> "$here/evidence.log"; fi
''';

const _fakeWallet =
    '#!/bin/sh\n# beam-wallet stand-in\n$_rules\n$_common'
    r'''
[ -z "$cfg" ] && exit 0
'''
    '$_readConfig'
    r'''
[ "$mode" = slow ] && sleep 1
case "$pass" in
  wrong*) echo "E Please check your password. If password is lost, restore."
          exit 255 ;;
esac
case "$1" in
  restore)
    if [ "$mode" = echo-seed ]; then
      echo "E Invalid seed phrase provided: $seed"; exit 255
    fi
    if [ -f "$db" ]; then echo "E Your wallet is already initialized."; exit 255; fi
    printf 'fake' > "$db"
    mkdir -p logs && echo "seed in a file log: $seed" > logs/wallet_x.log
    echo "I wallet successfully created..."
    exit 0 ;;
  export_owner_key)
    echo "Owner Viewer key: FAKE0wnerKey+/="; exit 0 ;;
  rescan)
    echo "I Synchronizing with node: 50% (1/2)"
    echo "I Current state is 100-abcdef"
    exec sleep 30 ;;
esac
echo "E unknown command"; exit 255
''';

const _fakeWalletApi =
    '#!/bin/sh\n# wallet-api stand-in\n$_rules\n$_common'
    r'''
if [ -z "$cfg" ]; then echo "E node address should be specified"; exit 255; fi
echo "$$" >> "$here/pids.log"
aclc=$(cat "$acl")
'''
    '$_readConfig'
    r'''
echo "I ACL file successfully loaded"
# What a real wallet-api prints at info level: the wallet's history.
# Every value is synthetic (repeated patterns), never a real address.
echo "I 2026-10-06.12:00:00.000 WalletID d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1"
echo "I 2026-10-06.12:00:00.000 New Wallet address generated: e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0f"
echo "I 2026-10-06.12:00:00.000 7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a Sending 0.1 BEAM (fee: 0.001 BEAM), my EP EpEpEpEpEpEpEpEpEpEpEpEpEpEpEpEpEpEpEpEpEpEp, peer EP PqPqPqPqPqPqPqPqPqPqPqPqPqPqPqPqPqPqPqPqPqPq"
echo "I 2026-10-06.12:00:00.000 Current state is 4100000-0123456789abcdef"
echo "W 2026-10-06.12:00:00.000 Unable to resolve node address: eu-nodes.mainnet.beam.mw:8100"
if printf '%s\n' "$aclc" | grep -Eq '^[0-9a-f]{64}:write$'; then
  echo acl-format-ok >> "$here/evidence.log"
fi
case "$pass" in
  wrong*) echo "Wallet not opened. File is not a database" >&2; exit 255 ;;
  taken*) echo "I Start server on 0.0.0.0:$port"
          echo "E cannot start server: bind failed"
          exec sleep 30 ;;
  hang*) exec sleep 30 ;;
esac
echo "EXCEPTION: unexpected" >&2; exit 255
''';

Future<String> _writeExe(String path, String body) async {
  await File(path).writeAsString(body);
  await Process.run('chmod', ['755', path]);
  return path;
}

Future<int> _deadPid() async {
  final proc = await Process.start('true', const []);
  await proc.exitCode;
  return proc.pid;
}

Future<bool> _running(int pid) async {
  final r = await Process.run('ps', ['-p', '$pid', '-o', 'comm=']);
  return r.exitCode == 0 && '${r.stdout}'.trim().isNotEmpty;
}

/// A long-running process whose name is `sh` (macOS reports a script's
/// interpreter, Linux the script's own name) and whose command line carries
/// `--wallet_path=[dbPath]`, the way a wallet-api orphan's does.
Future<Process> _fakeWalletChild(String dir, String dbPath) async {
  await Directory(dir).create(recursive: true);
  final script = await _writeExe(
    p.join(dir, 'sh'),
    "#!/bin/sh\ntrap 'exit 0' TERM\nwhile :; do sleep 0.1; done\n",
  );
  return Process.start(script, ['--wallet_path=$dbPath']);
}

/// Swaps a binary on disk right after [prepare] verified it: what another
/// local process could do between the hash and the launch.
class _SwappingBinaries extends BeamBinaries {
  _SwappingBinaries({
    required super.binDir,
    required String super.platform,
    required super.manifest,
    required this.replacement,
  });

  final String replacement;
  final List<BeamBinary> recheckedBeforeSpawn = [];

  @override
  Future<String> prepare(
    BeamBinary binary, {
    required String scratchParent,
  }) async {
    final path = await super.prepare(binary, scratchParent: scratchParent);
    if (binary == BeamBinary.walletApi) {
      await File(path).writeAsString(replacement);
    }
    return path;
  }

  @override
  Future<String> verifyUnchanged(BeamBinary binary) {
    recheckedBeforeSpawn.add(binary);
    return super.verifyUnchanged(binary);
  }
}

void main() {
  late Directory tmp;
  late String binDir;
  late ProcessHost host;
  late String walletDir;
  late List<String> words;
  const password = 'Fake-Pass-For-Tests-123';

  Future<List<String>> lines(String name) async {
    final f = File(p.join(binDir, name));
    return await f.exists() ? f.readAsLines() : <String>[];
  }

  Future<List<String>> secretEntries() async =>
      (await Directory(
        host.runDir,
      ).list().toList()).map((e) => p.basename(e.path)).where((n) {
        return n.startsWith(kSecretPrefix) ||
            n.endsWith('.cfg') ||
            n.endsWith('.acl');
      }).toList();

  /// No password, no two adjacent phrase words (single words prove
  /// nothing: "error" and "phrase" are BIP39 words), no 64-hex token.
  void expectNoPhrase(String text) {
    for (var i = 0; i + 1 < words.length; i++) {
      expect(text, isNot(contains('${words[i]} ${words[i + 1]}')));
      expect(text, isNot(contains('${words[i]};${words[i + 1]}')));
    }
  }

  void expectNoSecretsIn(Iterable<String> text) {
    for (final line in text) {
      expect(line, isNot(contains(password)));
      expectNoPhrase(line);
      // The privileged shader hash is public; any other 64-hex token on argv
      // would be the ACL key.
      var rest = line;
      for (final hash in kBeamPrivilegedShaderSha256s) {
        rest = rest.replaceAll(hash, '');
      }
      expect(rest, isNot(matches(RegExp(r'[0-9a-f]{64}'))));
    }
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('beam_host_fake_');
    binDir = p.join(tmp.path, 'bin');
    await Directory(binDir).create();
    final wallet = await _writeExe(p.join(binDir, 'beam-wallet'), _fakeWallet);
    final api = await _writeExe(p.join(binDir, 'wallet-api'), _fakeWalletApi);
    host = ProcessHost(
      rootDir: p.join(tmp.path, 'beam'),
      binaries: BeamBinaries(
        binDir: binDir,
        platform: 'fake',
        manifest: {
          'fake': {
            'beam-wallet': await BeamBinaries.sha256OfFile(wallet),
            'wallet-api': await BeamBinaries.sha256OfFile(api),
          },
        },
      ),
      startupTimeout: const Duration(seconds: 3),
      cliTimeout: const Duration(seconds: 15),
      rescanTimeout: const Duration(seconds: 15),
    );
    walletDir = host.walletDirFor('w1');
    words = bip39.generateMnemonic().split(' ');
  });

  tearDown(() async {
    await ProcessHost.shutdownAll();
    await tmp.delete(recursive: true);
  });

  Future<void> createWallet() async {
    await host.initWallet(
      walletDir: walletDir,
      password: password,
      words: words,
    );
    await File(p.join(binDir, 'evidence.log')).writeAsString('');
    await File(p.join(binDir, 'argv.log')).writeAsString('');
    await File(p.join(binDir, 'cwd.log')).writeAsString('');
  }

  group('beam-wallet', () {
    test('initWallet: cfg unlinked while the child runs, nothing '
        'secret on argv, scratch CWD and its logs removed', () async {
      await host.initWallet(
        walletDir: walletDir,
        password: password,
        words: words,
      );

      expect(await File(p.join(walletDir, 'wallet.db')).exists(), isTrue);
      expect(await posixMode(walletDir), 0x1c0);
      expect(await posixMode(p.join(walletDir, 'wallet.db')), 0x180);
      expect(await lines('evidence.log'), ['cfg-unlinked']);

      final argv = await lines('argv.log');
      // The consensus probe, then the restore.
      expect(argv.last, startsWith('restore --wallet_path='));
      expect(argv.last, contains('--config_file='));
      expectNoSecretsIn(argv);

      final cwd = (await lines('cwd.log')).last;
      expect(p.dirname(cwd), endsWith(p.join('beam', 'run')));
      expect(p.basename(cwd), startsWith(kSecretPrefix));
      expect(await Directory(cwd).exists(), isFalse);

      expect(await secretEntries(), isEmpty);
      expect(SecretFiles.livePaths, isEmpty);
      expect(await File(p.join(walletDir, '.wallet.lock')).exists(), isFalse);
    });

    test('initWallet refuses an existing wallet.db and keeps it', () async {
      await createWallet();
      await expectLater(
        host.initWallet(walletDir: walletDir, password: password, words: words),
        throwsA(_hostError(BeamHostError.walletExists)),
      );
      expect(await File(p.join(walletDir, 'wallet.db')).exists(), isTrue);
    });

    test('a phrase echoed by the CLI never reaches the error', () async {
      await File(p.join(binDir, 'mode')).writeAsString('echo-seed');
      try {
        await host.initWallet(
          walletDir: walletDir,
          password: password,
          words: words,
        );
        fail('expected a throw');
      } on BeamHostException catch (e) {
        expect(e.kind, BeamHostError.invalidInput);
        expectNoPhrase(e.toString());
      }
      expect(await File(p.join(walletDir, 'wallet.db')).exists(), isFalse);
      expect(await secretEntries(), isEmpty);
    });

    test('exportOwnerKey returns the key; wrong password is typed', () async {
      await createWallet();
      expect(
        await host.exportOwnerKey(walletDir: walletDir, password: password),
        'FAKE0wnerKey+/=',
      );
      await expectLater(
        host.exportOwnerKey(walletDir: walletDir, password: 'wrong-pass-1'),
        throwsA(_hostError(BeamHostError.wrongPassword)),
      );
      expect(await lines('evidence.log'), ['cfg-unlinked', 'cfg-unlinked']);
      expect(await secretEntries(), isEmpty);
    });

    test('exportOwnerKey without a wallet is walletNotFound', () async {
      await expectLater(
        host.exportOwnerKey(walletDir: walletDir, password: password),
        throwsA(_hostError(BeamHostError.walletNotFound)),
      );
    });

    test('rescan needs an owned node, then stops at the synced '
        'state', () async {
      await createWallet();
      await expectLater(
        host.rescan(
          walletDir: walletDir,
          password: password,
          node: BeamNodeEndpoint.parse('eu-nodes.mainnet.beam.mw:8100'),
        ),
        throwsA(_hostError(BeamHostError.notOwnedNode)),
      );
      final sw = Stopwatch()..start();
      await host.rescan(
        walletDir: walletDir,
        password: password,
        node: BeamNodeEndpoint.parse('127.0.0.1:10005', isOwned: true),
      );
      // The stand-in sleeps 30 s after the marker; it was stopped.
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
      expect((await lines('argv.log')).last, contains('--node_addr='));
      expect(await secretEntries(), isEmpty);
    });
  }, skip: Platform.isWindows ? 'uses /bin/sh stand-ins' : false);

  group('wallet-api', () {
    test('a development build is launched without the privileged-shader '
        'flag, which it would refuse', () async {
      final api = p.join(binDir, 'wallet-api');
      final wallet = p.join(binDir, 'beam-wallet');
      final devHost = ProcessHost(
        rootDir: p.join(tmp.path, 'beam'),
        binaries: BeamBinaries(
          binDir: binDir,
          platform: 'fake',
          manifest: const {},
          devManifest: {
            'fake': {
              'beam-wallet': await BeamBinaries.sha256OfFile(wallet),
              'wallet-api': await BeamBinaries.sha256OfFile(api),
            },
          },
          allowDevBuilds: true,
        ),
        startupTimeout: const Duration(seconds: 3),
        cliTimeout: const Duration(seconds: 15),
      );
      await createWallet();
      await expectLater(
        devHost.openWallet(
          walletDir: walletDir,
          password: 'wrong-password-1',
          node: BeamNodeEndpoint.parse('eu-nodes.mainnet.beam.mw:8100'),
        ),
        throwsA(_hostError(BeamHostError.wrongPassword)),
      );
      final launch = (await lines('argv.log')).last;
      expect(launch, contains('--use_acl=1'));
      expect(launch, isNot(contains('--privileged_shader_sha256')));
    });

    test('wrong password is typed; secrets gone; lock released', () async {
      await createWallet();
      await expectLater(
        host.openWallet(
          walletDir: walletDir,
          password: 'wrong-password-1',
          node: BeamNodeEndpoint.parse('eu-nodes.mainnet.beam.mw:8100'),
        ),
        throwsA(_hostError(BeamHostError.wrongPassword)),
      );
      expect(await lines('evidence.log'), ['cfg-unlinked', 'acl-format-ok']);

      final argv = await lines('argv.log');
      final launch = argv.last;
      for (final flag in [
        '--use_http=0',
        '--tcp_max_line=16777216',
        '--ip_whitelist=127.0.0.1',
        '--use_acl=1',
        '--acl_path=',
        '--enable_assets',
        '--enable_lelantus',
        '--api_version=7.4',
        '--request_bodies=0',
        '--log_level=info',
        // BEAM's own file log: no info-level history (finding 6).
        '--file_log_level=warning',
        '--node_addr=eu-nodes.mainnet.beam.mw:8100',
        // A release pin: the Campfire build gets the BANS allowlist.
        '--privileged_shader_sha256=${kBeamPrivilegedShaderSha256s.single}',
      ]) {
        expect(launch, contains(flag));
      }
      expectNoSecretsIn(argv);
      expect((await lines('cwd.log')).last, endsWith(p.join('beam', 'run')));

      expect(await secretEntries(), isEmpty);
      expect(SecretFiles.livePaths, isEmpty);

      // The captured console log is private, holds no password, and lives
      // in the wallet's own folder, so deleting the wallet deletes it.
      expect(
        await Directory(host.logsDir)
            .list()
            .where((e) => p.basename(e.path).startsWith('wallet-api-'))
            .toList(),
        isEmpty,
      );
      final walletLogs = ProcessHost.walletLogsDir(walletDir);
      expect(p.isWithin(walletDir, walletLogs), isTrue);
      expect(await posixMode(walletLogs), 0x1c0);
      final logs = await Directory(walletLogs)
          .list()
          .where((e) => p.basename(e.path).startsWith('wallet-api-'))
          .toList();
      expect(logs, hasLength(1));
      expect(await posixMode(logs.single.path), 0x180);
      final logText = await File(logs.single.path).readAsString();
      expect(logText, isNot(contains('wrong-password-1')));
      // The wallet's history never reaches the file (finding 6); startup
      // markers, heights and warnings do.
      expect(logText, contains('ACL file successfully loaded'));
      expect(logText, contains('Current state is 4100000-0123456789abcdef'));
      expect(logText, contains('Unable to resolve node address'));
      for (final leak in [
        'WalletID',
        'address generated',
        'Sending',
        'my EP',
        'peer EP',
        '0.1 BEAM',
        'e0e0e0e0e0e0e0e0',
        'd1d1d1d1d1d1d1d1',
      ]) {
        expect(logText, isNot(contains(leak)), reason: leak);
      }
      expect(logText, isNot(matches(RegExp(r'[A-Za-z0-9]{32,}'))));

      // The lock was released: the wallet can be used again.
      expect(
        await host.exportOwnerKey(walletDir: walletDir, password: password),
        isNotEmpty,
      );
    });

    test('a port taken by someone else is retried on new ports', () async {
      await createWallet();
      await expectLater(
        host.openWallet(
          walletDir: walletDir,
          password: 'taken-port-pass',
          node: BeamNodeEndpoint.parse('eu-nodes.mainnet.beam.mw:8100'),
        ),
        throwsA(_hostError(BeamHostError.processFailed)),
      );
      final ports = (await lines('argv.log'))
          .where((l) => l.contains('--port='))
          .map((l) => RegExp(r'--port=(\d+)').firstMatch(l)!.group(1))
          .toList();
      expect(ports, hasLength(3));
      expect(await secretEntries(), isEmpty);
    });

    test('no answer within startupTimeout is a typed timeout and the '
        'child is stopped', () async {
      await createWallet();
      await expectLater(
        host.openWallet(
          walletDir: walletDir,
          password: 'hang-forever-pass',
          node: BeamNodeEndpoint.parse('eu-nodes.mainnet.beam.mw:8100'),
        ),
        throwsA(_hostError(BeamHostError.timeout)),
      );
      // `exec sleep` kept the stand-in's pid; it must be gone.
      final pid = int.parse((await lines('pids.log')).last);
      expect(await _running(pid), isFalse);
      expect(await secretEntries(), isEmpty);
    });

    test('a binary swapped after its hash check is refused before it is '
        'launched (finding 5)', () async {
      final api = p.join(binDir, 'wallet-api');
      final wallet = p.join(binDir, 'beam-wallet');
      final swapping = _SwappingBinaries(
        binDir: binDir,
        platform: 'fake',
        manifest: {
          'fake': {
            'beam-wallet': await BeamBinaries.sha256OfFile(wallet),
            'wallet-api': await BeamBinaries.sha256OfFile(api),
          },
        },
        replacement:
            '#!/bin/sh\n$_rules\necho swapped-binary-ran >> '
            '"\$(dirname "\$0")/evidence.log"\nexit 0\n',
      );
      final swapHost = ProcessHost(
        rootDir: p.join(tmp.path, 'beam'),
        binaries: swapping,
        startupTimeout: const Duration(seconds: 3),
      );
      await createWallet();
      await expectLater(
        swapHost.openWallet(
          walletDir: walletDir,
          password: password,
          node: BeamNodeEndpoint.parse('eu-nodes.mainnet.beam.mw:8100'),
        ),
        throwsA(_hostError(BeamHostError.binaryUntrusted)),
      );
      expect(swapping.recheckedBeforeSpawn, contains(BeamBinary.walletApi));
      expect(
        await lines('evidence.log'),
        isNot(contains('swapped-binary-ran')),
      );
      expect(await secretEntries(), isEmpty);
    });

    test('a missing wallet is reported before anything starts', () async {
      await expectLater(
        host.openWallet(
          walletDir: walletDir,
          password: password,
          node: BeamNodeEndpoint.parse('eu-nodes.mainnet.beam.mw:8100'),
        ),
        throwsA(_hostError(BeamHostError.walletNotFound)),
      );
      expect(await lines('argv.log'), isEmpty);
    });
  }, skip: Platform.isWindows ? 'uses /bin/sh stand-ins' : false);

  group('wallet lock', () {
    test('two concurrent operations on one wallet: the second is '
        'refused', () async {
      await createWallet();
      await File(p.join(binDir, 'mode')).writeAsString('slow');
      final first = host.exportOwnerKey(
        walletDir: walletDir,
        password: password,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await expectLater(
        host.exportOwnerKey(walletDir: walletDir, password: password),
        throwsA(_hostError(BeamHostError.walletInUse)),
      );
      // A second host in the same process is refused too.
      final other = ProcessHost(rootDir: host.rootDir, binaries: host.binaries);
      await expectLater(
        other.exportOwnerKey(walletDir: walletDir, password: password),
        throwsA(_hostError(BeamHostError.walletInUse)),
      );
      expect(await first, isNotEmpty);
    });

    test('a live process holding the lock file refuses the wallet', () async {
      await createWallet();
      final holder = await Process.start('sleep', ['30']);
      try {
        await File(p.join(walletDir, '.wallet.lock'))
            .writeAsString(jsonEncode({'pid': holder.pid, 'exe': 'sleep'}));
        await expectLater(
          host.exportOwnerKey(walletDir: walletDir, password: password),
          throwsA(_hostError(BeamHostError.walletInUse)),
        );
      } finally {
        holder.kill();
      }
    });

    test('a stale lock of a dead process is taken over', () async {
      await createWallet();
      await File(
        p.join(walletDir, '.wallet.lock'),
      ).writeAsString(jsonEncode({'pid': await _deadPid(), 'exe': 'campfire'}));
      expect(
        await host.exportOwnerKey(walletDir: walletDir, password: password),
        isNotEmpty,
      );
    });

    test('an orphaned child of a dead owner is stopped first', () async {
      await createWallet();
      final orphan = await _fakeWalletChild(
        p.join(tmp.path, 'orphan'),
        p.join(walletDir, 'wallet.db'),
      );
      await File(p.join(walletDir, '.wallet.lock')).writeAsString(
        jsonEncode({
          'pid': await _deadPid(),
          'exe': 'campfire',
          'child': orphan.pid,
          'childExe': 'sh',
        }),
      );
      expect(
        await host.exportOwnerKey(walletDir: walletDir, password: password),
        isNotEmpty,
      );
      await orphan.exitCode.timeout(const Duration(seconds: 5));
      expect(await _running(orphan.pid), isFalse);
    });

    test('a recorded child pid now running another wallet-api (another '
        "app's wallet) is left alone (finding 8)", () async {
      await createWallet();
      // Same executable name, same pid as recorded, different wallet.db.
      final other = await _fakeWalletChild(
        p.join(tmp.path, 'other-app'),
        p.join(tmp.path, 'other-app', 'wallets', 'w1', 'wallet.db'),
      );
      try {
        await File(p.join(walletDir, '.wallet.lock')).writeAsString(
          jsonEncode({
            'pid': await _deadPid(),
            'exe': 'campfire',
            'child': other.pid,
            'childExe': 'sh',
          }),
        );
        expect(
          await host.exportOwnerKey(walletDir: walletDir, password: password),
          isNotEmpty,
        );
        expect(await _running(other.pid), isTrue);
      } finally {
        other.kill();
        await other.exitCode;
      }
    });

    test('a pid recycled by an unrelated program is not a holder', () async {
      await createWallet();
      final unrelated = await Process.start('sleep', ['30']);
      try {
        await File(
          p.join(walletDir, '.wallet.lock'),
        ).writeAsString(jsonEncode({'pid': unrelated.pid, 'exe': 'campfire'}));
        expect(
          await host.exportOwnerKey(walletDir: walletDir, password: password),
          isNotEmpty,
        );
        expect(await _running(unrelated.pid), isTrue);
      } finally {
        unrelated.kill();
      }
    });
  }, skip: Platform.isWindows ? 'uses /bin/sh stand-ins' : false);

  test('startup sweep removes secret files a crash left behind', () async {
    final run = p.join(tmp.path, 'beam', 'run');
    await ensurePrivateDir(run);
    await File(p.join(run, '.s-0123456789abcdef.cfg')).writeAsString('pass=x');
    await Directory(p.join(run, '.s-fedcba9876543210', 'logs'))
        .create(recursive: true);
    // Any operation prepares the host; this one fails after preparing.
    await expectLater(
      host.exportOwnerKey(walletDir: walletDir, password: password),
      throwsA(_hostError(BeamHostError.walletNotFound)),
    );
    expect(await secretEntries(), isEmpty);
  }, skip: Platform.isWindows ? 'POSIX modes only' : false);
}

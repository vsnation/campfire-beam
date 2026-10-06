/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/host/secret_file.dart';

Matcher _hostError(BeamHostError kind) =>
    isA<BeamHostException>().having((e) => e.kind, 'kind', kind);

Future<int?> _mode(String path) => posixMode(path);

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('beam_secret_test_');
  });

  tearDown(() async {
    await SecretFiles.deleteAll();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('ensurePrivateDir', () {
    test('creates nested dirs and sets 0700', () async {
      final path = p.join(tmp.path, 'a', 'b');
      await ensurePrivateDir(path);
      expect(await Directory(path).exists(), isTrue);
      if (!Platform.isWindows) expect(await _mode(path), 0x1c0);
    });

    test('tightens an existing 0755 dir', () async {
      final path = p.join(tmp.path, 'open');
      await Directory(path).create();
      await Process.run('chmod', ['755', path]);
      await ensurePrivateDir(path);
      if (!Platform.isWindows) expect(await _mode(path), 0x1c0);
    });
  });

  group('SecretFile.write', () {
    test('writes 0600 contents in a 0700 dir', () async {
      final dir = p.join(tmp.path, 'run');
      await ensurePrivateDir(dir);
      final f = await SecretFile.write(dir, 'pass=x\n', suffix: '.cfg');
      expect(p.basename(f.path), startsWith(kSecretPrefix));
      expect(f.path, endsWith('.cfg'));
      expect(await File(f.path).readAsString(), 'pass=x\n');
      if (!Platform.isWindows) expect(await _mode(f.path), 0x180);
      expect(SecretFiles.livePaths, contains(f.path));

      await f.delete();
      expect(await File(f.path).exists(), isFalse);
      expect(f.isDeleted, isTrue);
      expect(SecretFiles.livePaths, isNot(contains(f.path)));
      await f.delete(); // idempotent
    });

    test('refuses a group-readable directory', () async {
      final dir = p.join(tmp.path, 'shared');
      await Directory(dir).create();
      await Process.run('chmod', ['750', dir]);
      await expectLater(
        SecretFile.write(dir, 'pass=x\n'),
        throwsA(_hostError(BeamHostError.insecurePath)),
      );
      expect(await Directory(dir).list().toList(), isEmpty);
    }, skip: Platform.isWindows ? 'POSIX modes only' : false);

    test('refuses a world-accessible directory', () async {
      final dir = p.join(tmp.path, 'world');
      await Directory(dir).create();
      await Process.run('chmod', ['701', dir]);
      await expectLater(
        SecretFile.write(dir, 'pass=x\n'),
        throwsA(_hostError(BeamHostError.insecurePath)),
      );
    }, skip: Platform.isWindows ? 'POSIX modes only' : false);

    test('deleteSync and deleteAll remove registered files', () async {
      final dir = p.join(tmp.path, 'run');
      await ensurePrivateDir(dir);
      final a = await SecretFile.write(dir, 'a');
      final b = await SecretFile.write(dir, 'b');
      a.deleteSync();
      expect(await File(a.path).exists(), isFalse);
      await SecretFiles.deleteAll();
      expect(await File(b.path).exists(), isFalse);
      expect(SecretFiles.livePaths, isEmpty);
    });
  });

  group('SecretFile.writeConfig', () {
    late String dir;
    setUp(() async {
      dir = p.join(tmp.path, 'run');
      await ensurePrivateDir(dir);
    });

    test('writes key=value lines', () async {
      final f = await SecretFile.writeConfig(dir, {
        'pass': 'abc',
        'seed_phrase': 'a;b',
      });
      expect(await File(f.path).readAsString(), 'pass=abc\nseed_phrase=a;b\n');
    });

    for (final bad in ['a#b', 'a\nuse_acl=0', ' lead', 'trail ', '', 'a\rb']) {
      test('rejects ${bad.codeUnits} without writing anything', () async {
        expect(
          () => SecretFile.writeConfig(dir, {'pass': bad}),
          throwsA(_hostError(BeamHostError.invalidInput)),
        );
        expect(await Directory(dir).list().toList(), isEmpty);
      });
    }

    test('the error message never contains the value', () {
      const value = 'S3cret#tail';
      try {
        checkConfigValue('pass', value);
        fail('expected a throw');
      } on BeamHostException catch (e) {
        expect(e.message, isNot(contains('S3cret')));
        expect(e.toString(), isNot(contains('S3cret')));
      }
    });
  });

  group('SecretFile.createDir', () {
    test('creates a 0700 scratch dir; delete is recursive', () async {
      final parent = p.join(tmp.path, 'run');
      await ensurePrivateDir(parent);
      final d = await SecretFile.createDir(parent);
      expect(p.basename(d.path), startsWith(kSecretPrefix));
      if (!Platform.isWindows) expect(await _mode(d.path), 0x1c0);
      await File(p.join(d.path, 'logs', 'x.log')).create(recursive: true);
      await d.delete();
      expect(await Directory(d.path).exists(), isFalse);
    });
  });

  group('SecretFiles.sweep', () {
    test('removes stale .s-* entries only', () async {
      final run = p.join(tmp.path, 'run');
      await ensurePrivateDir(run);
      // Leftovers from a "crashed" run.
      await File(p.join(run, '.s-dead.cfg')).writeAsString('pass=old');
      await File(p.join(run, '.s-dead.acl')).writeAsString('k:write');
      await Directory(p.join(run, '.s-deadscratch', 'logs'))
          .create(recursive: true);
      // Not ours to delete.
      await File(p.join(run, 'keep.log')).writeAsString('x');
      await Directory(p.join(run, 'logs')).create();
      // A live secret of this process.
      final live = await SecretFile.write(run, 'pass=live');

      final removed = await SecretFiles.sweep([
        run,
        p.join(tmp.path, 'missing'),
      ]);

      expect(removed, 3);
      final names = (await Directory(
        run,
      ).list().toList()).map((e) => p.basename(e.path)).toSet();
      expect(names, {'keep.log', 'logs', p.basename(live.path)});
    });
  });
}

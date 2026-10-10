/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/dapps/dapp_errors.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_installer.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_package.dart';

import 'dapp_test_zip.dart';

void main() {
  late Directory tmp;
  late DappInstaller installer;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cfb-dapp-inst-');
    installer = DappInstaller(tmp.path);
  });

  tearDown(() async {
    if (Platform.isMacOS || Platform.isLinux) {
      await Process.run('chmod', ['-R', 'u+rwx', tmp.path]);
    }
    await tmp.delete(recursive: true);
  });

  List<String> filesUnder(String dir) =>
      Directory(dir)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .map((f) => p.relative(f.path, from: dir))
          .toList()
        ..sort();

  test('installs into dapps/<guid>/<version>/files and lists it', () async {
    final pkg = DappPackage.read(testPackage());
    final inst = await installer.install(pkg);
    expect(inst.guid, testGuid);
    expect(inst.directory, p.join(tmp.path, 'dapps', testGuid, '1.2.3'));
    expect(filesUnder(inst.filesDirectory), [
      'app/app.wasm',
      'app/icon.svg',
      'app/index.html',
      'app/index.js',
      'manifest.json',
    ]);
    expect(
      File(p.join(inst.filesDirectory, 'app/index.html')).readAsStringSync(),
      testIndexHtml,
    );
    final record = jsonDecode(
      File(p.join(inst.directory, DappInstaller.recordFileName))
          .readAsStringSync(),
    ) as Map<String, Object?>;
    expect(record['package_sha256'], pkg.sha256);
    expect(record['api_version'], '7.0');

    final listed = await installer.list();
    expect(listed.single.guid, testGuid);
    expect(listed.single.packageSha256, pkg.sha256);
    expect(listed.single.manifest.startPath, 'app/index.html');
    expect((await installer.find(testGuid))?.directory, inst.directory);
    // Nothing but the install itself is left behind.
    expect(
      Directory(p.join(tmp.path, 'dapps', testGuid))
          .listSync()
          .map((e) => p.basename(e.path)),
      ['1.2.3'],
    );
  });

  test(
    'refuses a second install unless replacing; replace swaps versions',
    () async {
      await installer.install(DappPackage.read(testPackage()));
      await expectLater(
        installer.install(DappPackage.read(testPackage())),
        throwsA(
          isA<DappInstallException>().having(
            (e) => e.error,
            'error',
            DappInstallError.alreadyInstalled,
          ),
        ),
      );

      final v2 = DappPackage.read(
        testPackage(
          manifest: {'version': '2.0.0'},
          extra: [ZipSpec.text('app/new.js', 'v2')],
        ),
      );
      final inst = await installer.install(v2, replace: true);
      expect(p.basename(inst.directory), '2.0.0');
      final guidDir = p.join(tmp.path, 'dapps', testGuid);
      expect(
        Directory(guidDir).listSync().map((e) => p.basename(e.path)).toList(),
        ['2.0.0'],
      );
      expect(filesUnder(inst.filesDirectory), contains('app/new.js'));
      expect((await installer.list()).single.manifest.version, '2.0.0');

      // Replacing the same version also works and keeps one copy.
      final again = await installer.install(v2, replace: true);
      expect(again.directory, inst.directory);
      expect(Directory(guidDir).listSync(), hasLength(1));
    },
  );

  test('a failed install leaves nothing behind', () async {
    if (!(Platform.isMacOS || Platform.isLinux)) return;
    final guidDir = Directory(p.join(tmp.path, 'dapps', testGuid))
      ..createSync(recursive: true);
    await Process.run('chmod', ['0555', guidDir.path]);
    await expectLater(
      installer.install(DappPackage.read(testPackage())),
      throwsA(isA<DappInstallException>()),
    );
    await Process.run('chmod', ['0755', guidDir.path]);
    expect(guidDir.listSync(), isEmpty);
    expect(await installer.list(), isEmpty);
  });

  test('uninstall removes the dApp and its data', () async {
    final inst = await installer.install(DappPackage.read(testPackage()));
    await installer.savePort(testGuid, 40123);
    expect(await installer.savedPort(testGuid), 40123);
    expect(await installer.uninstall(testGuid), isTrue);
    expect(Directory(inst.directory).existsSync(), isFalse);
    expect(
      Directory(p.join(tmp.path, 'dapps')).listSync(),
      isEmpty,
      reason: 'the trash folder is deleted too',
    );
    expect(await installer.list(), isEmpty);
    expect(await installer.uninstall(testGuid), isFalse);
  });

  test('never builds a path from a non-canonical guid', () async {
    for (final bad in ['..', '../$testGuid', testGuid.toUpperCase(), '']) {
      expect(() => installer.uninstall(bad), throwsArgumentError);
      expect(() => installer.find(bad), throwsArgumentError);
      expect(() => installer.dataDirectory(bad), throwsArgumentError);
    }
  });

  test('list skips damaged installs; cleanup removes leftovers', () async {
    final inst = await installer.install(DappPackage.read(testPackage()));
    final guidDir = p.join(tmp.path, 'dapps', testGuid);
    Directory(p.join(guidDir, '.tmp-0011223344556677', 'files'))
        .createSync(recursive: true);
    Directory(p.join(guidDir, '.old-8899aabbccddeeff')).createSync();
    Directory(p.join(tmp.path, 'dapps', '.trash-0011')).createSync();
    Directory(p.join(tmp.path, 'dapps', 'not-a-guid')).createSync();
    // An older version dir from an interrupted update, with a record.
    final stale = Directory(p.join(guidDir, '0.9'))..createSync();
    Directory(p.join(stale.path, 'files')).createSync();
    File(p.join(stale.path, DappInstaller.recordFileName)).writeAsStringSync(
      jsonEncode({
        'guid': testGuid,
        'package_sha256': 'x',
        'api_version': '7.0',
        'installed_at': '2020-01-01T00:00:00.000Z',
        'manifest': {
          'name': 'Old',
          'description': 'd',
          'start_path': 'app/index.html',
        },
      }),
    );
    // A damaged record is not an install.
    final damaged = Directory(p.join(guidDir, '9.9'))..createSync();
    File(p.join(damaged.path, DappInstaller.recordFileName))
        .writeAsStringSync('{');

    final listed = await installer.list();
    expect(listed.single.directory, inst.directory, reason: 'newest wins');

    await installer.cleanup();
    expect(
      Directory(guidDir).listSync().map((e) => p.basename(e.path)).toList(),
      ['1.2.3'],
    );
    expect(
      Directory(p.join(tmp.path, 'dapps', '.trash-0011')).existsSync(),
      isFalse,
    );
  });

  test("other dApps' origins are avoided, also after they move or are "
      'uninstalled', () async {
    const other = 'fedcba9876543210fedcba9876543210';
    await installer.install(DappPackage.read(testPackage()));
    await Directory(installer.dataDirectory(other)).create(recursive: true);
    await installer.savePort(testGuid, 40123);
    await installer.savePort(other, 40200);
    expect(await installer.portsOfOtherDapps(testGuid), {40200});
    expect(await installer.portsOfOtherDapps(other), {40123});

    // The other dApp moves: both of its origins stay its own.
    await installer.savePort(other, 40300);
    expect(await installer.portsOfOtherDapps(testGuid), {40200, 40300});

    // Uninstalled: the webview keeps its storage, so its origins stay
    // taken.
    await Directory(installer.dataDirectory(other)).delete(recursive: true);
    expect(await installer.portsOfOtherDapps(testGuid), {40200, 40300});
  });

  test('a port that was another dApp\'s origin is not recorded for this '
      'one', () async {
    const other = 'fedcba9876543210fedcba9876543210';
    await installer.install(DappPackage.read(testPackage()));
    await Directory(installer.dataDirectory(other)).create(recursive: true);
    await installer.savePort(other, 40200);
    await expectLater(
      installer.savePort(testGuid, 40200),
      throwsA(isA<StateError>()),
    );
    expect(await installer.savedPort(testGuid), isNull);
  });

  test('savedPort ignores junk', () async {
    await installer.install(DappPackage.read(testPackage()));
    File(p.join(installer.dataDirectory(testGuid), 'port'))
        .writeAsStringSync('80');
    expect(await installer.savedPort(testGuid), isNull);
    expect(() => installer.savePort(testGuid, 70000), throwsArgumentError);
  });

  group('servers a dApp may reach', () {
    const explorer = 'https://explorer.0xmx.net';
    const node = 'https://beamsmart.net:8000';
    String file() =>
        p.join(installer.dataDirectory(testGuid), 'remote_origins.json');

    test('round trip: allowed in order, kept once, taken back', () async {
      await installer.install(DappPackage.read(testPackage()));
      expect(await installer.allowedOrigins(testGuid), isEmpty);
      expect(await installer.allowOrigin(testGuid, explorer), [explorer]);
      expect(await installer.allowOrigin(testGuid, node), [explorer, node]);
      expect(await installer.allowOrigin(testGuid, explorer), [explorer, node]);
      // A new installer reads what the last one wrote.
      expect(await DappInstaller(tmp.path).allowedOrigins(testGuid), [
        explorer,
        node,
      ]);
      expect(jsonDecode(File(file()).readAsStringSync()), {
        'format': 1,
        'origins': [explorer, node],
      });
      expect(await installer.revokeOrigin(testGuid, explorer), [node]);
      expect(await installer.allowedOrigins(testGuid), [node]);
      expect(await installer.revokeOrigin(testGuid, explorer), [node]);
      expect(File('${file()}.part').existsSync(), isFalse);
    });

    test('kept through a replace, deleted with the dApp', () async {
      await installer.install(DappPackage.read(testPackage()));
      await installer.allowOrigin(testGuid, explorer);
      await installer.install(
        DappPackage.read(testPackage(manifest: {'version': '1.2.4'})),
        replace: true,
      );
      expect(await installer.allowedOrigins(testGuid), [explorer]);
      expect(await installer.uninstall(testGuid), isTrue);
      expect(await installer.allowedOrigins(testGuid), isEmpty);
      await installer.install(DappPackage.read(testPackage()));
      expect(await installer.allowedOrigins(testGuid), isEmpty);
    });

    test('refuses what a dApp may not reach, a dApp that is not '
        'installed, and a 17th server', () async {
      await expectLater(
        installer.allowOrigin(testGuid, explorer),
        throwsA(isA<StateError>()),
      );
      await installer.install(DappPackage.read(testPackage()));
      for (final bad in [
        'https://localhost',
        'https://192.168.1.10',
        'http://explorer.0xmx.net',
        'https://explorer.0xmx.net:443',
        'https://*.0xmx.net',
      ]) {
        await expectLater(
          installer.allowOrigin(testGuid, bad),
          throwsArgumentError,
          reason: bad,
        );
      }
      for (var i = 0; i < 16; i++) {
        await installer.allowOrigin(testGuid, 'https://h$i.example.com');
      }
      await expectLater(
        installer.allowOrigin(testGuid, explorer),
        throwsA(isA<StateError>()),
      );
      expect(await installer.allowedOrigins(testGuid), hasLength(16));
      await expectLater(installer.allowedOrigins('../x'), throwsArgumentError);
    });

    test('a damaged or edited file gives only valid servers', () async {
      await installer.install(DappPackage.read(testPackage()));
      File(file()).writeAsStringSync('{not json');
      expect(await installer.allowedOrigins(testGuid), isEmpty);
      File(file()).writeAsStringSync(
        jsonEncode({
          'format': 1,
          'origins': [
            explorer,
            'https://127.0.0.1',
            explorer,
            42,
            "https://a.com; script-src *",
            node,
          ],
        }),
      );
      expect(await installer.allowedOrigins(testGuid), [explorer, node]);
      // Writing again keeps only those.
      expect(await installer.revokeOrigin(testGuid, node), [explorer]);
    });
  });
}

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
import 'package:stackwallet/wallets/beam/host/android_native_dir.dart';
import 'package:stackwallet/wallets/beam/host/beam_binaries.dart';
import 'package:stackwallet/wallets/beam/host/beam_binaries_manifest.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';

Matcher _hostError(BeamHostError kind) =>
    isA<BeamHostException>().having((e) => e.kind, 'kind', kind);

// Shapes of real /proc/self/maps lines (Android 15 emulator, extracted libs).
const _appLib =
    '/data/app/~~Ab3dE-fGh==/com.vsnation.campfirebeam-Xy1Z==/lib/arm64';
const _extracted = [
  '5d8a1000-5d8a2000 r--p 00000000 fe:2f 1234  /system/lib64/libc.so',
  '7a10000000-7a12000000 r--p 00000000 fe:2f 5678  $_appLib/libflutter.so',
  '7a12000000-7a14000000 r-xp 02000000 fe:2f 5678  $_appLib/libflutter.so',
  '7b00000000-7b00001000 rw-p 00000000 00:00 0  [anon:dart-heap]',
];

void main() {
  group('nativeLibraryDirFromMaps', () {
    test('finds the extracted library directory from libflutter.so', () {
      expect(nativeLibraryDirFromMaps(_extracted), _appLib);
    });

    test('adopted storage counts as installed', () {
      const dir =
          '/mnt/expand/1234-abcd/app/~~x==/com.vsnation.cb-y==/lib/x86_64';
      expect(
        nativeLibraryDirFromMaps(['1-2 r-xp 0 fe:2f 1  $dir/libflutter.so']),
        dir,
      );
    });

    test('libraries mapped from inside the APK are not extracted: null', () {
      expect(
        nativeLibraryDirFromMaps([
          '1-2 r-xp 0 fe:2f 1  /data/app/~~a==/com.x-b==/base.apk',
          '3-4 r-xp 0 fe:2f 1  /data/app/~~a==/com.x-b==/base.apk!/lib/arm64-v8a/libflutter.so',
        ]),
        isNull,
      );
    });

    test('an engine loaded from anywhere else is not trusted: null', () {
      expect(
        nativeLibraryDirFromMaps([
          '1-2 r-xp 0 fe:2f 1  /data/local/tmp/libflutter.so',
          '1-2 r-xp 0 fe:2f 1  /data/user/0/com.x/files/libflutter.so',
        ]),
        isNull,
      );
      expect(nativeLibraryDirFromMaps(const []), isNull);
      expect(nativeLibraryDirFromMaps([_extracted.first]), isNull);
    });

    test('is null off Android', () {
      expect(androidNativeLibraryDir(), isNull);
    });
  });

  group('Android library names', () {
    test('every binary has a lib*.so name the APK installer extracts', () {
      expect(BeamBinary.walletApi.androidLibraryName, 'libbeam_wallet_api.so');
      expect(BeamBinary.wallet.androidLibraryName, 'libbeam_wallet.so');
      expect(BeamBinary.node.androidLibraryName, 'libbeam_node.so');
      for (final b in BeamBinary.values) {
        expect(b.androidLibraryName, matches(RegExp(r'^lib[a-z_]+\.so$')));
      }
    });

    test('the release manifest pins wallet-api and beam-wallet for both '
        'Android ABIs and never beam-node', () {
      for (final platform in ['android-arm64', 'android-x86_64']) {
        final pins = kBeamBinaryManifest[platform]!;
        expect(pins.keys.toSet(), {
          'wallet-api',
          'beam-wallet',
        }, reason: platform);
      }
    });
  });

  group('BeamBinaries.android with stand-in binaries', () {
    late Directory tmp;
    late String libDir;
    late String walletApi;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('beam_android_bin_test_');
      // nativeLibraryDir is system-owned 0755, never private: allowed here.
      libDir = p.join(tmp.path, 'lib', 'arm64');
      await Directory(libDir).create(recursive: true);
      await Process.run('chmod', ['755', libDir]);
      walletApi = p.join(libDir, 'libbeam_wallet_api.so');
      await File(walletApi).writeAsString(
        '#!/bin/sh\n# ${DateTime.now().microsecondsSinceEpoch}\nexit 0\n',
      );
      await Process.run('chmod', ['755', walletApi]);
    });

    tearDown(() => tmp.delete(recursive: true));

    BeamBinaries android(Map<String, String> pins, {String? dir}) =>
        BeamBinaries.android(
          beamRoot: p.join(tmp.path, 'beam'),
          nativeLibraryDir: dir ?? libDir,
          platform: 'android-test',
          manifest: {'android-test': pins},
        );

    test('runs wallet-api from the library directory under its lib name, '
        'pinned, without requiring a private directory', () async {
      final hash = await BeamBinaries.sha256OfFile(walletApi);
      final b = android({'wallet-api': hash});
      expect(b.requirePrivateDir, isFalse);
      expect(b.allowDevBuilds, isFalse);
      expect(b.pathOf(BeamBinary.walletApi), walletApi);
      expect(await b.verify(BeamBinary.walletApi), walletApi);
      expect(b.isCampfireBuild(BeamBinary.walletApi), isTrue);
      expect(await b.verifyUnchanged(BeamBinary.walletApi), walletApi);
    });

    test('runs beam-wallet (create/restore) as libbeam_wallet.so', () async {
      final cli = p.join(libDir, 'libbeam_wallet.so');
      await File(cli).writeAsString('#!/bin/sh\n# cli\nexit 0\n');
      await Process.run('chmod', ['755', cli]);
      final b = android({
        'wallet-api': await BeamBinaries.sha256OfFile(walletApi),
        'beam-wallet': await BeamBinaries.sha256OfFile(cli),
      });
      expect(b.pathOf(BeamBinary.wallet), cli);
      expect(await b.verify(BeamBinary.wallet), cli);
      expect(await b.verify(BeamBinary.walletApi), walletApi);
    });

    test('a changed library is refused', () async {
      final b = android({'wallet-api': 'a' * 64});
      await expectLater(
        b.verify(BeamBinary.walletApi),
        throwsA(_hostError(BeamHostError.binaryUntrusted)),
      );
    });

    test('a binary this build does not ship is a missing core, not an '
        'untrusted one', () async {
      final hash = await BeamBinaries.sha256OfFile(walletApi);
      final b = android({'wallet-api': hash});
      await expectLater(
        b.verify(BeamBinary.node),
        throwsA(_hostError(BeamHostError.binaryMissing)),
      );
      await expectLater(
        b.verify(BeamBinary.wallet),
        throwsA(_hostError(BeamHostError.binaryMissing)),
      );
    });

    test('a present but unpinned binary is still untrusted', () async {
      final hash = await BeamBinaries.sha256OfFile(walletApi);
      await File(p.join(libDir, 'libbeam_wallet.so'))
          .writeAsString('#!/bin/sh\nexit 0\n');
      await Process.run('chmod', ['755', p.join(libDir, 'libbeam_wallet.so')]);
      final b = android({'wallet-api': hash});
      await expectLater(
        b.verify(BeamBinary.wallet),
        throwsA(_hostError(BeamHostError.binaryUntrusted)),
      );
    });

    test(
      'without an extracted library directory the core is missing',
      () async {
        final hash = await BeamBinaries.sha256OfFile(walletApi);
        final b = BeamBinaries.android(
          beamRoot: p.join(tmp.path, 'beam'),
          nativeLibraryDir: null,
          platform: 'android-test',
          manifest: {
            'android-test': {'wallet-api': hash},
          },
        );
        expect(b.binDir, p.join(tmp.path, 'beam', 'bin'));
        await expectLater(
          b.verify(BeamBinary.walletApi),
          throwsA(_hostError(BeamHostError.binaryMissing)),
        );
      },
    );
  });
}

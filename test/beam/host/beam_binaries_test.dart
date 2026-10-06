/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/contracts/bans/bans_constants.dart';
import 'package:stackwallet/wallets/beam/host/beam_binaries.dart';
import 'package:stackwallet/wallets/beam/host/beam_binaries_manifest.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/host/secret_file.dart';

Matcher _hostError(BeamHostError kind) =>
    isA<BeamHostException>().having((e) => e.kind, 'kind', kind);

const _hf6Rules =
    'I 2026-10-06.08:33:24.960 Rules signature: network=mainnet\n'
    '\t0-ed91a717313c6eb0\n'
    '\t321321-6d622e615cfd29d0\n'
    '\t777777-1ce8f721bf0c9fa7\n'
    '\t1280000-3eaab6ab65b65f94\n'
    '\t1820000-b5a8b6b3617812c0\n'
    '\t1920000-1a68bdc7d7756bb4\n'
    '\t3928666-96df3f33ee02ad9e\n';

Future<String> _writeExe(String path, String body) async {
  await File(path).writeAsString(body);
  await Process.run('chmod', ['755', path]);
  return path;
}

void main() {
  group('platformKey', () {
    test('maps desktop ABIs to manifest keys', () {
      expect(BeamBinaries.platformKey(Abi.macosArm64), 'macos-arm64');
      expect(BeamBinaries.platformKey(Abi.macosX64), 'macos-x86_64');
      expect(BeamBinaries.platformKey(Abi.linuxX64), 'linux-x86_64');
      expect(BeamBinaries.platformKey(Abi.linuxArm64), 'linux-arm64');
      expect(BeamBinaries.platformKey(Abi.windowsX64), 'windows-x86_64');
      expect(
        BeamBinaries.platformKey(Abi.androidArm64),
        startsWith('unsupported-'),
      );
    });

    test('the manifest pins all three macos-arm64 binaries', () {
      final pins = kBeamBinaryManifest['macos-arm64']!;
      expect(pins.keys.toSet(), {'beam-wallet', 'wallet-api', 'beam-node'});
      for (final hash in pins.values) {
        expect(hash, matches(RegExp(r'^[0-9a-f]{64}$')));
      }
    });
  });

  group('release manifest', () {
    test('pins the Campfire builds for every desktop platform we build', () {
      for (final platform in ['macos-arm64', 'linux-arm64', 'linux-x86_64']) {
        final pins = kBeamBinaryManifest[platform]!;
        expect(
          pins.keys.toSet(),
          {'beam-wallet', 'wallet-api', 'beam-node'},
          reason: platform,
        );
      }
    });

    test('development pins never overlap release pins', () {
      final release = {
        for (final m in kBeamBinaryManifest.values) ...m.values,
      };
      for (final m in kBeamDevBinaryManifest.values) {
        for (final hash in m.values) {
          expect(release, isNot(contains(hash)));
        }
      }
    });

    test('BANS is the only privileged shader', () {
      expect(kBeamPrivilegedShaderSha256s, [kBansShaderSha256]);
    });
  });

  group('locate', () {
    test('BEAM_BIN_DIR wins over <root>/bin', () {
      final b = BeamBinaries.locate(
        beamRoot: '/data/beam',
        environment: {'BEAM_BIN_DIR': '/opt/beam-bin'},
      );
      expect(b.binDir, p.normalize('/opt/beam-bin'));
    });

    test('defaults to <root>/bin', () {
      final b = BeamBinaries.locate(beamRoot: '/data/beam', environment: {});
      expect(b.binDir, p.normalize('/data/beam/bin'));
    });
  });

  group('rulesIncludeHf6', () {
    test('accepts mainnet rules with the HF6 fork', () {
      expect(BeamBinaries.rulesIncludeHf6(_hf6Rules), isTrue);
    });

    test('rejects pre-HF6 rules', () {
      final pre = _hf6Rules.replaceAll('\t3928666-96df3f33ee02ad9e\n', '');
      expect(BeamBinaries.rulesIncludeHf6(pre), isFalse);
    });

    test('rejects other networks and missing output', () {
      expect(
        BeamBinaries.rulesIncludeHf6(
          _hf6Rules.replaceAll('network=mainnet', 'network=testnet'),
        ),
        isFalse,
      );
      expect(BeamBinaries.rulesIncludeHf6(''), isFalse);
      expect(BeamBinaries.rulesIncludeHf6(kBeamHf6RulesFork), isFalse);
    });
  });

  group('verify and prepare with stand-in binaries', () {
    late Directory tmp;
    late String binDir;
    late String runDir;
    late String good;
    late String goodHash;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('beam_bin_test_');
      binDir = p.join(tmp.path, 'bin');
      runDir = p.join(tmp.path, 'run');
      await Directory(binDir).create();
      await ensurePrivateDir(runDir);
      // A unique body per test run so the static consensus cache never
      // carries over between tests.
      good = await _writeExe(
        p.join(binDir, 'wallet-api'),
        '#!/bin/sh\n'
        '# ${DateTime.now().microsecondsSinceEpoch}\n'
        "printf '%s' '$_hf6Rules'\n"
        'exit 255\n',
      );
      goodHash = await BeamBinaries.sha256OfFile(good);
    });

    tearDown(() async {
      await SecretFiles.deleteAll();
      await tmp.delete(recursive: true);
    });

    BeamBinaries binaries(Map<String, String> pins, {String? platform}) =>
        BeamBinaries(
          binDir: binDir,
          manifest: {'test-os': pins},
          platform: platform ?? 'test-os',
        );

    test('accepts the pinned file and returns its path', () async {
      final b = binaries({'wallet-api': goodHash});
      expect(await b.verify(BeamBinary.walletApi), good);
    });

    test('a release pin marks a Campfire build', () async {
      final b = binaries({'wallet-api': goodHash});
      expect(b.isCampfireBuild(BeamBinary.walletApi), isFalse);
      await b.verify(BeamBinary.walletApi);
      expect(b.isCampfireBuild(BeamBinary.walletApi), isTrue);
    });

    test('a development pin needs development builds allowed', () async {
      BeamBinaries dev({required bool allow}) => BeamBinaries(
        binDir: binDir,
        manifest: {
          'test-os': {'wallet-api': '00' * 32},
        },
        devManifest: {
          'test-os': {'wallet-api': goodHash},
        },
        allowDevBuilds: allow,
        platform: 'test-os',
      );
      await expectLater(
        dev(allow: false).verify(BeamBinary.walletApi),
        throwsA(_hostError(BeamHostError.binaryUntrusted)),
      );
      final b = dev(allow: true);
      expect(await b.verify(BeamBinary.walletApi), good);
      expect(b.isCampfireBuild(BeamBinary.walletApi), isFalse);
    });

    test('a platform with only development pins is unsupported in a release '
        'run', () async {
      final b = BeamBinaries(
        binDir: binDir,
        manifest: const {},
        devManifest: {
          'test-os': {'wallet-api': goodHash},
        },
        allowDevBuilds: false,
        platform: 'test-os',
      );
      await expectLater(
        b.verify(BeamBinary.walletApi),
        throwsA(_hostError(BeamHostError.unsupportedPlatform)),
      );
    });

    test('refuses a tampered copy', () async {
      final b = binaries({'wallet-api': goodHash});
      await File(good).writeAsString('\n', mode: FileMode.append);
      await expectLater(
        b.verify(BeamBinary.walletApi),
        throwsA(_hostError(BeamHostError.binaryUntrusted)),
      );
    });

    test('refuses a binary that is not pinned', () async {
      final b = binaries({'beam-node': goodHash});
      await expectLater(
        b.verify(BeamBinary.walletApi),
        throwsA(_hostError(BeamHostError.binaryUntrusted)),
      );
    });

    test('refuses an unknown platform', () async {
      final b = binaries({'wallet-api': goodHash}, platform: 'plan9-mips');
      await expectLater(
        b.verify(BeamBinary.walletApi),
        throwsA(_hostError(BeamHostError.unsupportedPlatform)),
      );
    });

    test('reports a missing binary', () async {
      final b = binaries({'beam-wallet': goodHash});
      await expectLater(
        b.verify(BeamBinary.wallet),
        throwsA(_hostError(BeamHostError.binaryMissing)),
      );
    });

    test('refuses a group-writable binary', () async {
      await Process.run('chmod', ['775', good]);
      final b = binaries({'wallet-api': goodHash});
      await expectLater(
        b.verify(BeamBinary.walletApi),
        throwsA(_hostError(BeamHostError.binaryUntrusted)),
      );
    });

    test('prepare accepts a binary reporting HF6 rules', () async {
      final b = binaries({'wallet-api': goodHash});
      expect(
        await b.prepare(BeamBinary.walletApi, scratchParent: runDir),
        good,
      );
      // The probe's scratch directory is gone.
      expect(await Directory(runDir).list().toList(), isEmpty);
    });

    test('prepare refuses a binary without HF6 rules', () async {
      final stale = await _writeExe(
        p.join(binDir, 'beam-node'),
        '#!/bin/sh\n'
        '# ${DateTime.now().microsecondsSinceEpoch}\n'
        "printf 'Rules signature: network=mainnet\\n\\t0-ed91a717313c6eb0\\n'"
        '\n'
        'exit 255\n',
      );
      final b = binaries({'beam-node': await BeamBinaries.sha256OfFile(stale)});
      await expectLater(
        b.prepare(BeamBinary.node, scratchParent: runDir),
        throwsA(_hostError(BeamHostError.consensusMismatch)),
      );
    });
  }, skip: Platform.isWindows ? 'uses /bin/sh stand-ins' : false);

  // The real pinned binaries. Run with
  // BEAM_BIN_DIR=$HOME/Desktop/Beam/LightWallet/binaries/macos
  final realDir = Platform.environment[BeamBinaries.binDirEnv];
  group(
    'pinned macos-arm64 binaries',
    () {
      late Directory tmp;
      late String runDir;

      setUp(() async {
        tmp = await Directory.systemTemp.createTemp('beam_bin_real_');
        runDir = p.join(tmp.path, 'run');
        await ensurePrivateDir(runDir);
      });

      tearDown(() async {
        await SecretFiles.deleteAll();
        await tmp.delete(recursive: true);
      });

      // flutter_tester runs as x86_64 under Rosetta, so the platform key is
      // given explicitly; the arm64 binaries still run natively.
      BeamBinaries real() =>
          BeamBinaries(binDir: realDir!, platform: 'macos-arm64');

      test('all three match the manifest and report HF6 rules', () async {
        final b = real();
        for (final binary in BeamBinary.values) {
          final path = await b.prepare(binary, scratchParent: runDir);
          expect(path, b.pathOf(binary));
        }
      });

      test('a copy of wallet-api with one byte changed is refused', () async {
        final copyDir = p.join(tmp.path, 'bin');
        await Directory(copyDir).create();
        final copy = p.join(copyDir, 'wallet-api');
        final bytes = await File(p.join(realDir!, 'wallet-api')).readAsBytes();
        bytes[bytes.length ~/ 2] ^= 0x01;
        await File(copy).writeAsBytes(bytes);
        await Process.run('chmod', ['755', copy]);
        final b = BeamBinaries(binDir: copyDir, platform: 'macos-arm64');
        await expectLater(
          b.verify(BeamBinary.walletApi),
          throwsA(_hostError(BeamHostError.binaryUntrusted)),
        );
      });
    },
    skip: realDir == null || !Platform.isMacOS
        ? 'set BEAM_BIN_DIR to the macos-arm64 binaries'
        : false,
  );
}

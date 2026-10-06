/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_api_version.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_errors.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_manifest.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_package.dart';

import 'dapp_test_zip.dart';

Matcher refusedWith(DappInstallError error) =>
    throwsA(isA<DappInstallException>().having((e) => e.error, 'error', error));

Uint8List withEntry(ZipSpec spec) => testPackage(extra: [spec]);

void main() {
  group('a valid package', () {
    test('reads manifest, files and the negotiated version', () {
      final bytes = testPackage();
      final pkg = DappPackage.read(bytes);
      final m = pkg.manifest;
      expect(m.guid, testGuid);
      expect(m.name, 'Test dApp');
      expect(m.startPath, 'app/index.html');
      expect(m.iconPath, 'app/icon.svg');
      expect(m.version, '1.2.3');
      expect(pkg.apiVersion, DappApiVersion.v7_0);
      expect(pkg.files.map((f) => f.path), [
        'manifest.json',
        'app/index.html',
        'app/index.js',
        'app/app.wasm',
        'app/icon.svg',
      ]);
      expect(utf8.decode(pkg.files[1].bytes), testIndexHtml);
      expect(pkg.sha256, hasLength(64));
    });

    test('stored entries read as well as deflated ones', () {
      final pkg = DappPackage.read(
        buildZip([
          ZipSpec.text('manifest.json', testManifest(), method: 0),
          ZipSpec.text('app/index.html', testIndexHtml, method: 0),
        ]),
      );
      expect(pkg.files, hasLength(2));
    });

    test('macOS metadata is dropped', () {
      final pkg = DappPackage.read(
        testPackage(
          extra: [
            ZipSpec('__MACOSX/app/._index.html', const [0, 5, 22, 7]),
            ZipSpec('app/.DS_Store', const [0, 0, 0, 1]),
          ],
        ),
      );
      expect(
        pkg.files.map((f) => f.path),
        isNot(anyElement(anyOf(contains('__MACOSX'), contains('DS_Store')))),
      );
    });

    test('a UUID guid is canonicalised', () {
      final pkg = DappPackage.read(
        testPackage(manifest: {'guid': '01234567-89AB-CDEF-0123-456789ABCDEF'}),
      );
      expect(pkg.manifest.guid, testGuid);
    });

    test('a missing local icon is ignored, a remote one never used', () {
      expect(
        DappPackage.read(
          testPackage(manifest: {'icon': 'localapp/app/nope.svg'}),
        ).manifest.iconPath,
        isNull,
      );
      expect(
        DappPackage.read(
          testPackage(manifest: {'icon': 'https://tracker.example/i.png'}),
        ).manifest.iconPath,
        isNull,
      );
    });
  });

  group('malicious entry names', () {
    for (final name in [
      '../evil.js',
      'app/../../evil.js',
      'app/./x.js',
      '/etc/passwd',
      'app\\..\\evil.js',
      'C:/evil.js',
      'app//x.js',
      'app/con.js',
      'app/NUL',
      'app/trailing.',
      'app/%2e%2e/x.js',
      'app/x?.js',
      'app/\u00e9.js',
    ]) {
      test('refuses ${jsonEncode(name)}', () {
        expect(
          () => DappPackage.read(withEntry(ZipSpec.text(name, 'x'))),
          refusedWith(DappInstallError.unsafePath),
        );
      });
    }

    test('refuses a NUL and other control characters', () {
      for (final c in [0, 1, 0x1f, 0x7f]) {
        final name = 'app/a${String.fromCharCode(c)}b.js';
        expect(
          () => DappPackage.read(withEntry(ZipSpec.text(name, 'x'))),
          refusedWith(DappInstallError.unsafePath),
          reason: 'char $c',
        );
      }
    });

    test('refuses a path deeper than the limit', () {
      final name = '${List.filled(40, 'd').join('/')}/x.js';
      expect(
        () => DappPackage.read(withEntry(ZipSpec.text(name, 'x'))),
        refusedWith(DappInstallError.unsafePath),
      );
    });

    test('refuses a local name that differs from the central one', () {
      expect(
        () => DappPackage.read(
          withEntry(
            ZipSpec('app/ok.js', utf8.encode('x'), localName: '../evil.js'),
          ),
        ),
        refusedWith(DappInstallError.invalidFile),
      );
    });
  });

  group('non-regular entries', () {
    test('refuses a symlink', () {
      expect(
        () => DappPackage.read(
          withEntry(
            ZipSpec(
              'app/link.js',
              utf8.encode('/etc/passwd'),
              unixMode: 0xa1ff,
            ),
          ),
        ),
        refusedWith(DappInstallError.unsafeEntry),
      );
    });

    test('refuses a symlink even from a non-Unix creator', () {
      expect(
        () => DappPackage.read(
          withEntry(
            ZipSpec(
              'app/link.js',
              utf8.encode('/etc/passwd'),
              unixMode: 0xa1ff,
              hostSystem: 0,
            ),
          ),
        ),
        refusedWith(DappInstallError.unsafeEntry),
      );
    });

    test('refuses a device or FIFO', () {
      for (final mode in [0x21b6, 0x61b6, 0x11b6, 0xc1b6]) {
        expect(
          () => DappPackage.read(
            withEntry(ZipSpec('app/dev', const [], unixMode: mode)),
          ),
          refusedWith(DappInstallError.unsafeEntry),
          reason: '0x${mode.toRadixString(16)}',
        );
      }
    });

    test('refuses an encrypted entry', () {
      expect(
        () => DappPackage.read(
          withEntry(ZipSpec('app/x.js', utf8.encode('x'), flags: 1)),
        ),
        refusedWith(DappInstallError.invalidFile),
      );
    });

    test('refuses an unsupported compression method', () {
      // archive 4 reads unknown methods as STORE; the package must not.
      expect(
        () => DappPackage.read(
          withEntry(ZipSpec('app/x.js', utf8.encode('x'), method: 14)),
        ),
        refusedWith(DappInstallError.invalidFile),
      );
    });
  });

  group('duplicates and collisions', () {
    test('refuses the same name twice', () {
      expect(
        () => DappPackage.read(
          testPackage(extra: [ZipSpec.text('app/index.js', 'evil()')]),
        ),
        refusedWith(DappInstallError.invalidFile),
      );
    });

    test('refuses names equal ignoring case', () {
      expect(
        () => DappPackage.read(
          testPackage(extra: [ZipSpec.text('APP/Index.JS', 'evil()')]),
        ),
        refusedWith(DappInstallError.invalidFile),
      );
    });

    test('refuses a file where a directory is needed', () {
      expect(
        () => DappPackage.read(
          testPackage(extra: [ZipSpec.text('app/index.js/x.js', 'x')]),
        ),
        refusedWith(DappInstallError.invalidFile),
      );
    });
  });

  group('zip bombs and limits', () {
    final zeros = Uint8List(20 * 1024 * 1024);

    test('refuses an entry compressing beyond the ratio limit', () {
      expect(
        () => DappPackage.read(withEntry(ZipSpec('app/zeros.bin', zeros))),
        refusedWith(DappInstallError.tooLarge),
      );
    });

    test('refuses a stream that inflates beyond its declared size', () {
      // Declares 1000 bytes, inflates to 20 MiB: caught by the inflate cap.
      expect(
        () => DappPackage.read(
          withEntry(ZipSpec('app/liar.bin', zeros, declaredSize: 1000, crc: 0)),
        ),
        refusedWith(DappInstallError.tooLarge),
      );
    });

    test('refuses a stream shorter than declared', () {
      expect(
        () => DappPackage.read(
          withEntry(ZipSpec('app/short.js', utf8.encode('x'), declaredSize: 2)),
        ),
        refusedWith(DappInstallError.invalidFile),
      );
    });

    test('refuses a CRC mismatch', () {
      expect(
        () => DappPackage.read(
          withEntry(ZipSpec('app/x.js', utf8.encode('x'), crc: 12345)),
        ),
        refusedWith(DappInstallError.invalidFile),
      );
    });

    test('refuses more entries than allowed', () {
      expect(
        () => DappPackage.read(
          testPackage(
            extra: [
              for (var i = 0; i < 10; i++) ZipSpec.text('app/f$i.js', '$i'),
            ],
          ),
          limits: const DappPackageLimits(maxEntries: 10),
        ),
        refusedWith(DappInstallError.tooLarge),
      );
    });

    test('refuses a package, a file or a total over the limits', () {
      final pkg = testPackage(
        extra: [ZipSpec('app/big.bin', Uint8List(4096), method: 0)],
      );
      expect(
        () => DappPackage.read(
          pkg,
          limits: DappPackageLimits(maxPackageBytes: pkg.length - 1),
        ),
        refusedWith(DappInstallError.tooLarge),
      );
      expect(
        () => DappPackage.read(
          pkg,
          limits: const DappPackageLimits(maxFileBytes: 4095),
        ),
        refusedWith(DappInstallError.tooLarge),
      );
      expect(
        () => DappPackage.read(
          pkg,
          limits: const DappPackageLimits(maxTotalBytes: 4096),
        ),
        refusedWith(DappInstallError.tooLarge),
      );
    });

    test('refuses zip64 and a forged entry count', () {
      expect(
        () => DappPackage.read(
          buildZip([
            ZipSpec.text('manifest.json', testManifest()),
          ], zip64Locator: true),
        ),
        refusedWith(DappInstallError.invalidFile),
      );
      expect(
        () => DappPackage.read(
          buildZip([
            ZipSpec.text('manifest.json', testManifest()),
            ZipSpec.text('app/index.html', testIndexHtml),
          ], entryCount: 1),
        ),
        refusedWith(DappInstallError.invalidFile),
      );
    });

    test('refuses what is not a zip', () {
      expect(
        () => DappPackage.read(utf8.encode('<html>not a zip</html>')),
        refusedWith(DappInstallError.cantOpenFile),
      );
      expect(
        () => DappPackage.read(const []),
        refusedWith(DappInstallError.cantOpenFile),
      );
    });
  });

  group('manifest', () {
    for (final guid in [
      '../../x',
      '..',
      'db851322f6674a6da3e84e9953db2ff',
      'db851322f6674a6da3e84e9953db2ffd0',
      'zb851322f6674a6da3e84e9953db2ffd',
      'db851322/6674a6da3e84e9953db2ffd',
      '',
    ]) {
      test('refuses guid ${jsonEncode(guid)}', () {
        expect(
          () => DappPackage.read(testPackage(manifest: {'guid': guid})),
          refusedWith(DappInstallError.invalidFile),
        );
      });
    }

    test('refuses a guid that is not a string', () {
      expect(
        () => DappPackage.read(testPackage(manifest: {'guid': 12345})),
        refusedWith(DappInstallError.invalidFile),
      );
    });

    test('refuses a manifest over 64 KiB', () {
      expect(
        () => DappPackage.read(
          testPackage(manifest: {'padding': 'x' * (64 * 1024)}),
        ),
        refusedWith(DappInstallError.cantReadManifest),
      );
    });

    test('refuses a missing, empty or non-JSON manifest', () {
      expect(
        () => DappPackage.read(
          buildZip([ZipSpec.text('app/index.html', testIndexHtml)]),
        ),
        refusedWith(DappInstallError.cantReadManifest),
      );
      expect(
        () => DappPackage.read(
          buildZip([ZipSpec.text('manifest.json', '{"name": ')]),
        ),
        refusedWith(DappInstallError.cantReadManifest),
      );
      expect(
        () => DappPackage.read(
          buildZip([
            ZipSpec('manifest.json', const [0xff, 0xfe, 0x00]),
          ]),
        ),
        refusedWith(DappInstallError.cantReadManifest),
      );
    });

    test('a manifest in a subfolder does not count', () {
      expect(
        () => DappPackage.read(
          buildZip([
            ZipSpec.text('app/manifest.json', testManifest()),
            ZipSpec.text('app/index.html', testIndexHtml),
          ]),
        ),
        refusedWith(DappInstallError.cantReadManifest),
      );
    });

    final invalid = <String, Map<String, Object?>>{
      'no name': {'name': null},
      'empty name': {'name': ''},
      'long name': {'name': 'x' * 31},
      'name with a bidi override': {
        'name': 'Beam${String.fromCharCode(0x202e)}xeD',
      },
      'name with a newline': {'name': 'Beam\nDEX'},
      'no description': {'description': null},
      'long description': {'description': 'x' * 1025},
      'no url': {'url': null},
      'remote url': {'url': 'https://evil.example/index.html'},
      'url escaping the package': {'url': 'localapp/../../index.html'},
      'url not html': {'url': 'localapp/app/index.js'},
      'url to a missing page': {'url': 'localapp/app/other.html'},
      'version with 5 parts': {'version': '1.2.3.4.5'},
      'version with letters': {'version': '1.0.0-beta'},
      'api_version current': {'api_version': 'current'},
      'api_version with 3 parts': {'api_version': '7.0.1'},
      'api_version not a string': {'api_version': 7.0},
      'negative category': {'category': -1},
      'fractional category': {'category': 1.5},
      'publisher with a control char': {'publisher': 'a\u0007b'},
    };
    for (final e in invalid.entries) {
      test('refuses ${e.key}', () {
        expect(
          () => DappPackage.read(testPackage(manifest: e.value)),
          refusedWith(DappInstallError.invalidFile),
        );
      });
    }

    test('api versions negotiate as beam-ui does', () {
      DappApiVersion? served(Map<String, Object?> m) =>
          DappPackage.read(testPackage(manifest: m)).apiVersion;
      expect(served({'api_version': '7.4'}), DappApiVersion.v7_4);
      expect(
        served({'api_version': null, 'min_api_version': null}),
        DappApiVersion.current,
      );
      expect(
        served({'api_version': '8.0', 'min_api_version': '6.1'}),
        DappApiVersion.v6_1,
      );
      expect(
        () => DappPackage.read(
          testPackage(
            manifest: {'api_version': '8.0', 'min_api_version': '7.9'},
          ),
        ),
        refusedWith(DappInstallError.unsupported),
      );
      expect(
        () => DappPackage.read(
          testPackage(
            manifest: {'api_version': '5.0', 'min_api_version': null},
          ),
        ),
        refusedWith(DappInstallError.unsupported),
      );
    });

    test('canonical guid helpers', () {
      expect(DappManifest.isCanonicalGuid(testGuid), isTrue);
      expect(DappManifest.isCanonicalGuid(testGuid.toUpperCase()), isFalse);
      expect(DappManifest.isCanonicalGuid('../$testGuid'), isFalse);
    });
  });
}

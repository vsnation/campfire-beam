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

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/host/beam_binaries.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/host/bundled_binaries.dart';
import 'package:stackwallet/wallets/beam/host/secret_file.dart';

/// Serves in-memory bytes as assets and counts loads.
class _Bundle extends CachingAssetBundle {
  _Bundle(this.files);

  final Map<String, List<int>> files;
  int loads = 0;

  @override
  Future<ByteData> load(String key) async {
    loads++;
    final bytes = files[key];
    if (bytes == null) throw FlutterError('Unable to load asset: "$key"');
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String root;
  const platform = 'test-os';
  final bodies = {
    for (final b in BeamBinary.values) b: utf8.encode('#!/bin/sh\necho ${b.id}\n'),
  };
  final pins = {
    platform: {
      for (final e in bodies.entries)
        e.key.id: sha256.convert(e.value).toString(),
    },
  };
  Map<String, List<int>> assetsFor(Map<BeamBinary, List<int>> b) => {
    for (final e in b.entries)
      '$kBeamBinaryAssetDir/$platform/${e.key.fileName}': e.value,
  };

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('beam_bundled_');
    root = p.join(tmp.path, 'beam');
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<int> install(_Bundle bundle, {Map<String, String>? env}) =>
      installBundledBeamBinaries(
        beamRoot: root,
        bundle: bundle,
        platform: platform,
        manifest: pins,
        environment: env ?? const {},
      );

  test('installs every pinned binary 0700 into a 0700 bin folder', () async {
    final n = await install(_Bundle(assetsFor(bodies)));
    expect(n, 3);
    expect(await posixMode(p.join(root, 'bin')), 0x1c0);
    for (final b in BeamBinary.values) {
      final path = p.join(root, 'bin', b.fileName);
      expect(await File(path).readAsBytes(), bodies[b]);
      expect(await posixMode(path), 0x1c0);
    }
    // The verifier accepts what was installed.
    final binaries = BeamBinaries(
      binDir: p.join(root, 'bin'),
      manifest: pins,
      platform: platform,
      allowDevBuilds: false,
    );
    for (final b in BeamBinary.values) {
      expect(await binaries.verify(b), p.join(root, 'bin', b.fileName));
      expect(binaries.isCampfireBuild(b), isTrue);
    }
  });

  test('a second start writes nothing and loads nothing', () async {
    await install(_Bundle(assetsFor(bodies)));
    final again = _Bundle(assetsFor(bodies));
    expect(await install(again), 0);
    expect(again.loads, 0);
  });

  test('a tampered installed copy is replaced from the bundle', () async {
    await install(_Bundle(assetsFor(bodies)));
    final api = File(p.join(root, 'bin', BeamBinary.walletApi.fileName));
    await api.writeAsString('tampered');
    expect(await install(_Bundle(assetsFor(bodies))), 1);
    expect(await api.readAsBytes(), bodies[BeamBinary.walletApi]);
  });

  test('a bundled binary that does not match its pin is refused', () async {
    final bad = Map<BeamBinary, List<int>>.of(bodies)
      ..[BeamBinary.node] = utf8.encode('not the pinned node');
    await expectLater(
      install(_Bundle(assetsFor(bad))),
      throwsA(
        isA<BeamHostException>().having(
          (e) => e.kind,
          'kind',
          BeamHostError.binaryUntrusted,
        ),
      ),
    );
    expect(
      File(p.join(root, 'bin', BeamBinary.node.fileName)).existsSync(),
      isFalse,
    );
    final leftovers = Directory(p.join(root, 'bin'))
        .listSync()
        .map((e) => p.basename(e.path))
        .where((n) => n.endsWith('.tmp'));
    expect(leftovers, isEmpty);
  });

  test('nothing bundled for this platform is not an error', () async {
    expect(await install(_Bundle(const {})), 0);
    expect(Directory(p.join(root, 'bin')).existsSync(), isFalse);
  });

  test('development runs from BEAM_BIN_DIR are left alone', () async {
    final bundle = _Bundle(assetsFor(bodies));
    expect(await install(bundle, env: {'BEAM_BIN_DIR': '/dev/bins'}), 0);
    expect(bundle.loads, 0);
  });
}

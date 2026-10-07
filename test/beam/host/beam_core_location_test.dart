/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// locateBeamCoreLibrary's hashing, through the development override (the
// shipped library's path depends on the app bundle). The hash is computed
// on a background isolate; it must be the file's SHA-256.

import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/host/beam_core_location.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('beam_core_location_');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('the development library is hashed in full, off the UI isolate',
      () async {
    // Several chunks of the file stream, so the hash covers all of them.
    final rng = Random(7);
    final bytes = List<int>.generate(3 * 65536 + 123, (_) => rng.nextInt(256));
    final lib = File(p.join(tmp.path, 'libbeam_core_dev.so'))
      ..writeAsBytesSync(bytes);

    final found = await locateBeamCoreLibrary(
      beamRoot: tmp.path,
      environment: {kBeamCoreLibraryEnv: lib.path},
      overridesAllowed: true,
    );
    expect(found.development, isTrue);
    expect(found.path, lib.path);
    expect(found.sha256, sha256.convert(bytes).toString());
  });

  test('a development path that names no file is refused', () async {
    await expectLater(
      locateBeamCoreLibrary(
        beamRoot: tmp.path,
        environment: {kBeamCoreLibraryEnv: p.join(tmp.path, 'missing.so')},
        overridesAllowed: true,
      ),
      throwsA(isA<BeamCoreLibraryProblem>()),
    );
  });
}

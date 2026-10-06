/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/common/asset_shader_source.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';

class _MemorySource implements ShaderSource {
  _MemorySource(this.bytes);

  Uint8List bytes;
  int reads = 0;

  @override
  Future<Uint8List> read(String name) async {
    reads++;
    return bytes;
  }
}

/// An [AssetBundle] over the package directory, as the app's bundle would
/// be with `assets/beam/shaders/` declared in the pubspec.
class _FileBundle extends CachingAssetBundle {
  final keys = <String>[];

  @override
  Future<ByteData> load(String key) async {
    keys.add(key);
    final bytes = await File(key).readAsBytes();
    return ByteData.sublistView(bytes);
  }
}

void main() {
  const assets = FileShaderSource('assets/beam/shaders');

  test('AssetShaderSource reads assets/beam/shaders/<name>', () async {
    final bundle = _FileBundle();
    final bytes = await ammAppShader(AssetShaderSource(bundle: bundle)).load();
    expect(bundle.keys, ['assets/beam/shaders/amm_app.wasm']);
    expect(PinnedShader.digestOf(bytes), kAmmAppShaderSha256);
    expect(
      () => AssetShaderSource(bundle: bundle).read('../pubspec.yaml'),
      throwsArgumentError,
    );
  });

  test('the bundled amm_app.wasm matches its pin', () async {
    final bytes = await ammAppShader(assets).load();
    expect(bytes, hasLength(kAmmAppShaderSize));
    expect(PinnedShader.digestOf(bytes), kAmmAppShaderSha256);
    // WebAssembly magic.
    expect(bytes.sublist(0, 4), [0x00, 0x61, 0x73, 0x6d]);
    expect(() => bytes[0] = 1, throwsUnsupportedError);
  });

  test('one changed byte is refused, and nothing is cached', () async {
    final good = await ammAppShader(assets).load();
    final bad = Uint8List.fromList(good)..[1000] ^= 1;
    final source = _MemorySource(bad);
    final shader = ammAppShader(source);
    await expectLater(shader.load(), throwsA(isA<PinnedShaderException>()));
    await expectLater(shader.load(), throwsA(isA<PinnedShaderException>()));
    expect(source.reads, 2);
    source.bytes = Uint8List.fromList(good);
    expect(await shader.load(), good);
  });

  test('a wrong size is refused before hashing', () async {
    final shader = PinnedShader(
      name: 'x.wasm',
      sha256: '00' * 32,
      size: 4,
      source: _MemorySource(Uint8List(3)),
    );
    await expectLater(
      shader.load(),
      throwsA(
        isA<PinnedShaderException>().having(
          (e) => e.message,
          'message',
          contains('3 bytes'),
        ),
      ),
    );
  });

  test('verified bytes are cached and are a copy', () async {
    final good = await ammAppShader(assets).load();
    final mutable = Uint8List.fromList(good);
    final source = _MemorySource(mutable);
    final shader = ammAppShader(source);
    final a = await shader.load();
    mutable[0] = 0xff;
    final b = await shader.load();
    expect(identical(a, b), isTrue);
    expect(b[0], 0x00);
    expect(source.reads, 1);
  });

  test('names and pins are validated', () {
    PinnedShader make(String name, String sha) =>
        PinnedShader(name: name, sha256: sha, source: assets);
    expect(() => make('../amm_app.wasm', 'ab' * 32), throwsArgumentError);
    expect(() => make('.hidden', 'ab' * 32), throwsArgumentError);
    expect(() => make('a.wasm', 'AB' * 32), throwsArgumentError);
    expect(() => make('a.wasm', 'ab' * 31), throwsArgumentError);
    expect(
      () => assets.read('sub/amm_app.wasm'),
      throwsArgumentError,
    );
  });
}

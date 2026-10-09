/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The app path for shaders: every pinned shader loads through
// AssetShaderSource from rootBundle, i.e. from the Flutter asset bundle that
// `flutter: assets:` in the generated pubspec.yaml declares (the BEAM block
// of scripts/app_config/templates/pubspec.template.yaml). Reading the files
// from disk would not prove that; an undeclared asset fails with "Unable to
// load asset" here.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/bridge/pipe_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/burn/blackhole_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/common/asset_shader_source.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/minter/minter_constants.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';

/// Every shader the app pins, built over [source].
List<PinnedShader> _pinned(ShaderSource source) => [
  ammAppShader(source),
  bansAppShader(source),
  airdropAppShader(source),
  minterAppShader(source),
  blackHoleAppShader(source),
  pipeAppShader(BridgeShader.forward, source),
  pipeAppShader(BridgeShader.reverse, source),
];

/// Records which asset keys were asked for, then defers to rootBundle.
class _RecordingSource implements ShaderSource {
  final inner = AssetShaderSource();
  final names = <String>[];

  @override
  Future<Uint8List> read(String name) {
    names.add(name);
    return inner.read(name);
  }
}

void main() {
  testWidgets('each pinned shader loads from rootBundle and verifies', (
    tester,
  ) async {
    final source = _RecordingSource();
    final loaded = await tester.runAsync(
      () => Future.wait([for (final s in _pinned(source)) s.load()]),
    );
    final shaders = _pinned(source);
    expect(loaded, hasLength(7));
    for (var i = 0; i < shaders.length; i++) {
      final bytes = loaded![i];
      expect(bytes.length, shaders[i].size, reason: shaders[i].name);
      expect(
        PinnedShader.digestOf(bytes),
        shaders[i].sha256,
        reason: shaders[i].name,
      );
    }
    expect(source.names, [
      kAmmAppShaderName,
      kBansShaderName,
      kAirdropAppShaderName,
      kMinterAppShaderName,
      kBlackHoleAppShaderName,
      kPipeAppShaderName,
      kPipeReverseAppShaderName,
    ]);
  });

  testWidgets('the asset keys are assets/beam/shaders/<name>', (tester) async {
    final data = await tester.runAsync(
      () => rootBundle.load('${AssetShaderSource.defaultPrefix}bans_app.wasm'),
    );
    expect(data!.lengthInBytes, kBansShaderSize);
    expect(kBansShaderAsset, '${AssetShaderSource.defaultPrefix}bans_app.wasm');
  });

  testWidgets('a shader that is not bundled is not found', (tester) async {
    final error = await tester.runAsync(() async {
      try {
        await AssetShaderSource().read('not_bundled_app.wasm');
        return null;
      } catch (e) {
        return e;
      }
    });
    expect(error, isNotNull);
  });

  test('every shader shipped in assets/beam/shaders/ is pinned', () {
    final shipped = [
      for (final f in Directory('assets/beam/shaders').listSync())
        if (f is File) f.uri.pathSegments.last,
    ]..sort();
    final pinned = [
      for (final s in _pinned(const FileShaderSource('unused'))) s.name,
    ]..sort();
    expect(shipped, pinned);
  });
}

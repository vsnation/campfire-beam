/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/services.dart';

import 'pinned_shader.dart';

/// Reads shaders bundled as Flutter assets under [prefix]
/// (`assets/beam/shaders/` by default).
///
/// The files must also be listed under `flutter: assets:` in the pubspec,
/// or [read] fails with "Unable to load asset".
class AssetShaderSource implements ShaderSource {
  AssetShaderSource({this.bundle, this.prefix = defaultPrefix});

  static const defaultPrefix = 'assets/beam/shaders/';

  /// Defaults to `rootBundle`.
  final AssetBundle? bundle;
  final String prefix;

  @override
  Future<Uint8List> read(String name) async {
    PinnedShader.checkName(name);
    final data = await (bundle ?? rootBundle).load('$prefix$name');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}

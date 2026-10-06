/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'bans_constants.dart';
import 'bans_exceptions.dart';

/// Reads the raw shader bytes from wherever they are bundled.
typedef BansShaderSource = Future<Uint8List> Function();

/// Loads the pinned BANS app shader once, checks its SHA-256 and size, and
/// hands out the cached bytes.
///
/// A minimal loader private to the BANS module. The shared pinned-shader
/// loader (`contracts/common/pinned_shader.dart`) replaces it once it
/// exists; the behaviour to keep is: verify before first use, never run a
/// mismatching file, cache only verified bytes, read the source once.
class BansShaderLoader {
  BansShaderLoader(this._source);

  /// The asset bundled at [kBansShaderAsset]. The asset must be listed in
  /// the app's pubspec for this to resolve.
  factory BansShaderLoader.asset([AssetBundle? bundle]) =>
      BansShaderLoader(() async {
        final data = await (bundle ?? rootBundle).load(kBansShaderAsset);
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      });

  final BansShaderSource _source;
  Uint8List? _verified;
  Future<Uint8List>? _inFlight;

  /// The verified shader. Throws [BansShaderMismatch] when the bundled file
  /// is not the pinned build; a later call reads the source again.
  Future<Uint8List> load() {
    final v = _verified;
    if (v != null) return Future.value(v);
    return _inFlight ??= _loadAndVerify().whenComplete(() => _inFlight = null);
  }

  Future<Uint8List> _loadAndVerify() async {
    final bytes = Uint8List.fromList(await _source());
    final hash = sha256.convert(bytes).toString();
    if (bytes.length != kBansShaderSize || hash != kBansShaderSha256) {
      throw BansShaderMismatch(hash, bytes.length);
    }
    return _verified = bytes.asUnmodifiableView();
  }
}

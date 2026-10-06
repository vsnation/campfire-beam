/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Where shader bytes come from. The app reads Flutter assets
/// (`AssetShaderSource`); tests and desktop tools read files.
///
/// A source only fetches bytes. It never decides whether they are
/// acceptable: [PinnedShader] does that.
abstract class ShaderSource {
  /// The raw bytes of the shader file called [name] (e.g. `amm_app.wasm`).
  Future<Uint8List> read(String name);
}

/// Reads `<directory>/<name>` from disk.
class FileShaderSource implements ShaderSource {
  const FileShaderSource(this.directory);

  final String directory;

  @override
  Future<Uint8List> read(String name) {
    PinnedShader.checkName(name);
    return File('$directory${Platform.pathSeparator}$name').readAsBytes();
  }
}

/// Thrown when shader bytes do not match their pinned hash or size.
class PinnedShaderException implements Exception {
  const PinnedShaderException(
    this.message, {
    this.actualSha256,
    this.actualSize,
  });

  final String message;

  /// What was read instead, when the bytes were read at all.
  final String? actualSha256;
  final int? actualSize;

  @override
  String toString() => 'PinnedShaderException: $message';
}

/// An app shader whose bytes are pinned by SHA-256.
///
/// The shader is what the wallet core executes to build a contract
/// transaction, so a substituted file could make the core sign something
/// other than what the screen shows. [load] therefore refuses any bytes whose
/// hash differs from [sha256] and never hands back unverified bytes. Verified
/// bytes are cached for the life of the object; a failed load is not cached.
class PinnedShader {
  PinnedShader({
    required this.name,
    required this.sha256,
    required this.source,
    this.size,
  }) {
    checkName(name);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw ArgumentError.value(sha256, 'sha256', '64 lowercase hex chars');
    }
  }

  /// File name, e.g. `amm_app.wasm`.
  final String name;

  /// Lowercase hex SHA-256 of the exact file.
  final String sha256;

  /// Expected length in bytes, checked along with the hash when given.
  final int? size;

  final ShaderSource source;

  Uint8List? _verified;
  Future<Uint8List>? _inFlight;

  /// The verified shader bytes (an unmodifiable view).
  ///
  /// Concurrent calls share one read of [source]. Throws
  /// [PinnedShaderException] when the bytes differ from the pin; a later
  /// call reads the source again.
  Future<Uint8List> load() {
    final cached = _verified;
    if (cached != null) return Future.value(cached);
    return _inFlight ??= _readAndVerify().whenComplete(
      () => _inFlight = null,
    );
  }

  Future<Uint8List> _readAndVerify() async {
    final bytes = await source.read(name);
    final actual = digestOf(bytes);
    final expectedSize = size;
    if (expectedSize != null && bytes.length != expectedSize) {
      throw PinnedShaderException(
        '$name: ${bytes.length} bytes, pinned $expectedSize',
        actualSha256: actual,
        actualSize: bytes.length,
      );
    }
    if (actual != sha256) {
      throw PinnedShaderException(
        '$name: sha256 $actual does not match pinned $sha256',
        actualSha256: actual,
        actualSize: bytes.length,
      );
    }
    // Copy, so a source that keeps a reference cannot change them later.
    return _verified = Uint8List.fromList(bytes).asUnmodifiableView();
  }

  /// Lowercase hex SHA-256 of [bytes].
  static String digestOf(List<int> bytes) =>
      crypto.sha256.convert(bytes).toString();

  /// Shader names are bare file names: no directories, no hidden files.
  static void checkName(String name) {
    if (name.isEmpty ||
        name.contains('/') ||
        name.contains(r'\') ||
        name.startsWith('.')) {
      throw ArgumentError.value(name, 'name', 'a bare file name');
    }
  }
}

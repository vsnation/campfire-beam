/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'beam_binaries.dart';
import 'beam_binaries_manifest.dart';
import 'beam_host_exception.dart';
import 'secret_file.dart';

/// Where `scripts/beam/core/stage_binaries.sh` puts the binaries a build
/// ships, one folder per `<os>-<arch>`.
const String kBeamBinaryAssetDir = 'assets/beam/bin';

/// Copies the BEAM binaries this build ships into `<beamRoot>/bin`.
///
/// Assets cannot be executed in place, so each binary is written to the
/// private bin folder (0700, the file 0700) under a temporary name and
/// renamed into place. Its SHA-256 must equal the release pin before it is
/// written, and `BeamBinaries` hashes it again before every launch.
/// Binaries already in place with the right hash are left alone, so this is
/// cheap after the first start.
///
/// Returns how many binaries were written. Returns 0 without touching
/// anything when `BEAM_BIN_DIR` is set (development runs binaries from
/// there) or when this build bundles none for the platform; the host then
/// reports the core as missing instead of failing later.
Future<int> installBundledBeamBinaries({
  required String beamRoot,
  AssetBundle? bundle,
  String? platform,
  Map<String, Map<String, String>> manifest = kBeamBinaryManifest,
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  if ((env[BeamBinaries.binDirEnv] ?? '').isNotEmpty) return 0;
  final key = platform ?? BeamBinaries.currentPlatform();
  final pins = manifest[key];
  if (pins == null) return 0;

  final assets = bundle ?? rootBundle;
  final binDir = p.join(beamRoot, 'bin');
  var written = 0;
  for (final binary in BeamBinary.values) {
    final pin = pins[binary.id]?.toLowerCase();
    if (pin == null) continue;
    final target = p.join(binDir, binary.fileName);
    if (await File(target).exists() &&
        await BeamBinaries.sha256OfFile(target) == pin) {
      continue;
    }

    final ByteData data;
    try {
      data = await assets.load('$kBeamBinaryAssetDir/$key/${binary.fileName}');
    } on FlutterError {
      return written; // Not bundled in this build.
    }
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    if (sha256.convert(bytes).toString() != pin) {
      throw BeamHostException(
        BeamHostError.binaryUntrusted,
        'The bundled ${binary.id} does not match its pinned SHA-256',
      );
    }

    await ensurePrivateDir(beamRoot);
    await ensurePrivateDir(binDir);
    final tmp = File(p.join(binDir, '.${binary.fileName}.$pid.tmp'));
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      if (!Platform.isWindows) {
        final chmod = await Process.run('chmod', ['700', tmp.path]);
        if (chmod.exitCode != 0) {
          throw BeamHostException(
            BeamHostError.insecurePath,
            'Could not make ${binary.id} executable',
          );
        }
      }
      await tmp.rename(target);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
    written++;
  }
  return written;
}

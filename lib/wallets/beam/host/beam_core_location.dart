/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'android_native_dir.dart';
import 'beam_binaries.dart';
import 'secret_file.dart';

/// The BEAM core inside the app (owner, 2026-10-07: "people want to use the
/// wallet without wallet-api or beam-node; it should be integrated inside",
/// as BEAM's own desktop wallet does): `libbeam_core` from
/// scripts/beam/core/lib, one shared library holding wallet-api and the node,
/// loaded into the app's process. Its SHA-256 is pinned here per platform and
/// checked before it is loaded; nothing is downloaded.
const Map<String, String> kBeamCoreLibraryManifest = {
  'macos-arm64':
      '7f660944b64aa3742399b9f51824cd4989629827d66a20cc12b3d32b670488ba',
  'android-arm64':
      '07860dc16ea70502f686bbcf76f7473a5946bf5d5deabfd0884350751b6c133a',
  'android-x86_64':
      'c63b7b4f72992b33c62c298c550ac883be678408f1e34037a33c43256d3e201a',
  // Built and checked by CI (.github/workflows/beam-lib.yml, pre-release
  // beam-core-7.5.14493-cf2).
  'linux-x86_64':
      '56de364f96d1952a837eb9b0132d7d352c185e59f129508d2a8e5af401cf65b9',
  'linux-arm64':
      'd3e3b40b83e4faa0828a8c0c911ca0dcb9d7a9126ed2721192c101b356fbc814',
  'windows-x86_64':
      '1631543b8f7e480e8eea256c646a0c2eac76caa57504e6d9789c2c5d3dfd0fe2',
};

/// Whether this platform runs the core from `libbeam_core`: a library is
/// pinned for it, or a development build names one in [kBeamCoreLibraryEnv].
bool beamCoreLibraryAvailableHere({Map<String, String>? environment}) {
  if (Platform.isIOS) return false;
  if (kBeamCoreLibraryManifest.containsKey(BeamBinaries.currentPlatform())) {
    return true;
  }
  final dev = (environment ?? Platform.environment)[kBeamCoreLibraryEnv];
  return BeamBinaries.devOverridesAllowed && dev != null && dev.isNotEmpty;
}

/// The library's file name on each OS.
String beamCoreLibraryFileName() => Platform.isWindows
    ? 'beam_core.dll'
    : Platform.isMacOS || Platform.isIOS
    ? 'libbeam_core.dylib'
    : 'libbeam_core.so';

/// Environment variable naming a library file to load instead (development
/// and tests only; honoured under the same rule as `BEAM_BIN_DIR`).
const String kBeamCoreLibraryEnv = 'BEAM_CORE_LIB';

/// Where the app ships the library, before any copy: next to the executable
/// (Windows), in `lib/` beside it (Linux), in the bundle's `Frameworks/`
/// (macOS), or in the APK's extracted native libraries (Android). Null where
/// the platform has no such file (iOS links the core statically).
String? bundledBeamCoreLibraryPath() {
  final exeDir = p.dirname(Platform.resolvedExecutable);
  if (Platform.isMacOS) {
    return p.normalize(
      p.join(exeDir, '..', 'Frameworks', beamCoreLibraryFileName()),
    );
  }
  if (Platform.isLinux) return p.join(exeDir, 'lib', beamCoreLibraryFileName());
  if (Platform.isWindows) return p.join(exeDir, beamCoreLibraryFileName());
  if (Platform.isAndroid) {
    final dir = androidNativeLibraryDir();
    return dir == null ? null : p.join(dir, beamCoreLibraryFileName());
  }
  return null;
}

/// A library file this app may load, after its pinned SHA-256 matched.
class BeamCoreLibraryFile {
  const BeamCoreLibraryFile(this.path, this.sha256, {this.development = false});

  final String path;
  final String sha256;

  /// Loaded from [kBeamCoreLibraryEnv], not a pinned build.
  final bool development;
}

/// Why no library could be used.
class BeamCoreLibraryProblem implements Exception {
  const BeamCoreLibraryProblem(this.message, {this.untrusted = false});

  final String message;

  /// A file exists but its hash is not the pinned one.
  final bool untrusted;

  @override
  String toString() => 'BeamCoreLibraryProblem: $message';
}

/// Finds the library for this platform and checks it.
///
/// * Development builds and tests may name another file in
///   [kBeamCoreLibraryEnv] ([BeamBinaries.devOverridesAllowed]); a release
///   build never reads it.
/// * macOS and Android load the shipped file where it is: inside the signed
///   app bundle, and in the system's read-only native library directory.
/// * Linux and Windows install it next to an executable in a folder the
///   user can write to; it is copied into `<beamRoot>/bin` (0700) first and
///   that copy is checked and loaded, so it cannot change between its check
///   and its load (as the child-process binaries were, `BeamBinaries`).
///
/// Throws [BeamCoreLibraryProblem].
Future<BeamCoreLibraryFile> locateBeamCoreLibrary({
  required String beamRoot,
  Map<String, String>? environment,
  Map<String, String> manifest = kBeamCoreLibraryManifest,
  String? platform,
  bool? overridesAllowed,
}) async {
  final env = environment ?? Platform.environment;
  final key = platform ?? BeamBinaries.currentPlatform();
  if ((overridesAllowed ?? BeamBinaries.devOverridesAllowed)) {
    final dev = env[kBeamCoreLibraryEnv];
    if (dev != null && dev.isNotEmpty) {
      if (!File(dev).existsSync()) {
        throw const BeamCoreLibraryProblem(
          '$kBeamCoreLibraryEnv names no file',
        );
      }
      return BeamCoreLibraryFile(dev, await _sha256(dev), development: true);
    }
  }
  final pin = manifest[key];
  if (pin == null) {
    throw BeamCoreLibraryProblem('No BEAM core is pinned for $key');
  }
  final shipped = bundledBeamCoreLibraryPath();
  if (shipped == null || !File(shipped).existsSync()) {
    throw const BeamCoreLibraryProblem('The BEAM core is not in this build');
  }
  var path = shipped;
  // The private copy's hash, when it was just read and matched: it is not
  // read a second time.
  String? got;
  if (Platform.isLinux || Platform.isWindows) {
    final bin = p.join(beamRoot, 'bin');
    await ensurePrivateDir(bin);
    final copy = p.join(bin, beamCoreLibraryFileName());
    final existing = File(copy);
    if (existing.existsSync()) got = await _sha256(copy);
    if (got != pin) {
      got = null;
      final tmp = '$copy.part';
      await File(shipped).copy(tmp);
      if (!Platform.isWindows) await setOwnerExecutable(tmp);
      if (existing.existsSync()) await existing.delete();
      await File(tmp).rename(copy);
    }
    path = copy;
  }
  got ??= await _sha256(path);
  if (got != pin) {
    throw const BeamCoreLibraryProblem(
      'The BEAM core library does not match its pinned SHA-256',
      untrusted: true,
    );
  }
  return BeamCoreLibraryFile(path, got);
}

/// SHA-256 of the file at [path], read in chunks on a background isolate:
/// the core library is the whole BEAM core, and reading and hashing it on
/// the UI isolate (up to three times on Linux and Windows) froze the app
/// while the first wallet opened.
Future<String> _sha256(String path) => Isolate.run(
  () async => (await sha256.bind(File(path).openRead()).first).toString(),
  debugName: 'beam-core-hash',
);

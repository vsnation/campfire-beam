/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'android_native_dir.dart';
import 'beam_binaries_manifest.dart';
import 'beam_host_exception.dart';
import 'secret_file.dart';

/// The BEAM executables Campfire runs as child processes: all three on
/// desktop; on Android `wallet-api` and `beam-wallet` (phones never run the
/// private node).
enum BeamBinary {
  /// `beam-wallet`: create/restore, owner key export, rescan.
  wallet('beam-wallet'),

  /// `wallet-api`: the JSON-RPC wallet core, one process per open wallet.
  walletApi('wallet-api'),

  /// `beam-node`: the user's own fast-sync node.
  node('beam-node');

  const BeamBinary(this.id);

  /// Name without extension; the key in [kBeamBinaryManifest].
  final String id;

  /// The file name on this platform.
  String get fileName => Platform.isWindows
      ? '$id.exe'
      : Platform.isAndroid
      ? androidLibraryName
      : id;

  /// The name [id] ships under on Android: `jniLibs/<abi>/lib*.so`. Only
  /// files named like that are extracted to `nativeLibraryDir`, the one
  /// place an app may execute from (`scripts/android/stage_beam_core.sh`).
  String get androidLibraryName => switch (this) {
    BeamBinary.wallet => 'libbeam_wallet.so',
    BeamBinary.walletApi => 'libbeam_wallet_api.so',
    BeamBinary.node => 'libbeam_node.so',
  };
}

/// Locates the BEAM binaries and proves each one is the pinned build.
///
/// [prepare] (or [verify]) hashes the file before every launch, so a binary
/// replaced on disk after the app started is still refused. Launchers call
/// [verifyUnchanged] once more immediately before spawning, so the window
/// between the hash and the exec holds no other work.
class BeamBinaries {
  BeamBinaries({
    required String binDir,
    this._manifest = kBeamBinaryManifest,
    this._devManifest = kBeamDevBinaryManifest,
    bool? allowDevBuilds,
    this.requirePrivateDir = false,
    String? platform,
    bool? androidLibraries,
  }) : binDir = p.normalize(p.absolute(binDir)),
       platform = platform ?? currentPlatform(),
       androidLibraries = androidLibraries ?? Platform.isAndroid,
       allowDevBuilds =
           allowDevBuilds ?? (devBinDir(Platform.environment) != null);

  /// Binaries from [binDirEnv] if this build honours it (see
  /// [devOverridesAllowed]), otherwise the app's own `<beamRoot>/bin`, which
  /// must stay private (0700).
  ///
  /// [overridesAllowed] replaces [devOverridesAllowed], for tests.
  factory BeamBinaries.locate({
    required String beamRoot,
    Map<String, String>? environment,
    bool? overridesAllowed,
  }) {
    if (Platform.isAndroid) {
      return BeamBinaries.android(
        beamRoot: beamRoot,
        nativeLibraryDir: androidNativeLibraryDir(),
      );
    }
    final override = devBinDir(
      environment ?? Platform.environment,
      overridesAllowed: overridesAllowed,
    );
    return override != null
        ? BeamBinaries(binDir: override, allowDevBuilds: true)
        : BeamBinaries(
            binDir: p.join(beamRoot, 'bin'),
            allowDevBuilds: false,
            requirePrivateDir: true,
          );
  }

  /// Android: the binaries the APK ships as native libraries, run from the
  /// directory the system extracted them to ([androidNativeLibraryDir]).
  ///
  /// That directory belongs to the system and is read-only to the app, so it
  /// is not required to be private, and no override applies: an app may not
  /// execute anything else. Without it (libraries not extracted) the files
  /// are looked for in `<beamRoot>/bin`, which Android never fills, so
  /// [verify] reports the core as missing.
  factory BeamBinaries.android({
    required String beamRoot,
    required String? nativeLibraryDir,
    String? platform,
    Map<String, Map<String, String>> manifest = kBeamBinaryManifest,
  }) => BeamBinaries(
    binDir: nativeLibraryDir ?? p.join(beamRoot, 'bin'),
    manifest: manifest,
    allowDevBuilds: false,
    platform: platform,
    androidLibraries: true,
  );

  /// Environment variable that points at a directory of binaries.
  static const String binDirEnv = 'BEAM_BIN_DIR';

  /// Compile-time flag (`--dart-define=BEAM_DEV_BINARIES=true`) that lets a
  /// release build honour [binDirEnv], for testing a release build against
  /// development binaries. Shipped builds never set it.
  static const String devBinariesDefine = 'BEAM_DEV_BINARIES';

  /// Whether this build may honour [binDirEnv] and the development pins
  /// ([kBeamDevBinaryManifest]): in debug and profile builds and under
  /// `flutter test`, never in a release build unless it was compiled with
  /// [devBinariesDefine]. `dart.vm.product` is what Flutter's `kReleaseMode`
  /// reads; it is used directly so this file stays free of Flutter.
  ///
  /// A release build therefore runs only the pinned release binaries from
  /// `<beamRoot>/bin`, whatever its environment says: `launchctl setenv`, a
  /// `.desktop` file or a shell profile could otherwise point an installed
  /// app at other binaries and at the development pins, which bind 0.0.0.0.
  static const bool devOverridesAllowed =
      !bool.fromEnvironment('dart.vm.product') ||
      bool.fromEnvironment(devBinariesDefine);

  /// The [binDirEnv] directory this build honours in [environment], or null.
  /// [overridesAllowed] replaces [devOverridesAllowed], for tests.
  static String? devBinDir(
    Map<String, String> environment, {
    bool? overridesAllowed,
  }) {
    if (!(overridesAllowed ?? devOverridesAllowed)) return null;
    final dir = environment[binDirEnv];
    return dir == null || dir.isEmpty ? null : dir;
  }

  final String binDir;

  /// Whether [binDir] must be a private (0700) directory, as the app's own
  /// `<beamRoot>/bin` is. A binary in a folder other users can write to
  /// could be swapped between its hash and its launch.
  final bool requirePrivateDir;

  /// `<os>-<arch>` key into the manifest, e.g. `macos-arm64`.
  final String platform;

  /// Whether the files carry their Android names
  /// ([BeamBinary.androidLibraryName]). True on Android.
  final bool androidLibraries;

  final Map<String, Map<String, String>> _manifest;
  final Map<String, Map<String, String>> _devManifest;

  /// Whether the development pins ([kBeamDevBinaryManifest]) are accepted.
  /// Defaults to true only when this build honours a set `BEAM_BIN_DIR`
  /// ([devBinDir]); a release build never does, so it runs the Campfire
  /// builds and nothing else.
  final bool allowDevBuilds;

  /// SHA-256 of each binary as of its last successful [verify].
  final Map<BeamBinary, String> _verified = {};

  /// Whether each verified binary is a Campfire build (release pin) rather
  /// than a development pin.
  final Map<BeamBinary, bool> _campfire = {};

  /// Pinned binaries whose consensus probe passed, by SHA-256.
  static final Set<String> _consensusChecked = {};

  static String currentPlatform() => platformKey(Abi.current());

  static String platformKey(Abi abi) => switch (abi) {
    Abi.macosArm64 => 'macos-arm64',
    Abi.macosX64 => 'macos-x86_64',
    Abi.linuxArm64 => 'linux-arm64',
    Abi.linuxX64 => 'linux-x86_64',
    Abi.windowsArm64 => 'windows-arm64',
    Abi.windowsX64 => 'windows-x86_64',
    Abi.androidArm64 => 'android-arm64',
    Abi.androidX64 => 'android-x86_64',
    _ => 'unsupported-$abi',
  };

  String pathOf(BeamBinary binary) => p.join(
    binDir,
    androidLibraries ? binary.androidLibraryName : binary.fileName,
  );

  /// The release SHA-256 for [binary] on this platform, if any.
  String? pinnedHash(BeamBinary binary) => _manifest[platform]?[binary.id];

  /// True when [binary] last verified against a release pin: a Campfire
  /// build that listens on loopback only and accepts
  /// `--privileged_shader_sha256`. False for a development pin, and before
  /// [verify] has succeeded.
  bool isCampfireBuild(BeamBinary binary) => _campfire[binary] ?? false;

  /// Checks [binary] against the manifest and returns its absolute path.
  ///
  /// Throws [BeamHostException] with [BeamHostError.unsupportedPlatform],
  /// [BeamHostError.binaryMissing] or [BeamHostError.binaryUntrusted].
  Future<String> verify(BeamBinary binary) async {
    final pinned = _manifest[platform];
    final devPinned = allowDevBuilds ? _devManifest[platform] : null;
    if (pinned == null && devPinned == null) {
      throw BeamHostException(
        BeamHostError.unsupportedPlatform,
        'No BEAM binaries are pinned for $platform',
      );
    }
    final expected = pinned?[binary.id]?.toLowerCase();
    final devExpected = devPinned?[binary.id]?.toLowerCase();
    final path = pathOf(binary);
    if (expected == null && devExpected == null) {
      // Absent and not pinned here: this build does not ship it (Android has
      // no beam-node). That is a missing core, not a failed safety check.
      if (await FileSystemEntity.type(path) == FileSystemEntityType.notFound) {
        throw BeamHostException(
          BeamHostError.binaryMissing,
          '${binary.id} is not part of this build for $platform',
        );
      }
      throw BeamHostException(
        BeamHostError.binaryUntrusted,
        '${binary.id} is not pinned for $platform',
      );
    }
    await _checkPlacement(binary, path);

    final actual = await sha256OfFile(path);
    final isRelease = actual == expected;
    if (!isRelease && actual != devExpected) {
      _verified.remove(binary);
      _campfire.remove(binary);
      throw BeamHostException(
        BeamHostError.binaryUntrusted,
        '${binary.id} SHA-256 does not match the pinned value '
        '(got ${actual.substring(0, 16)}…)',
      );
    }
    _verified[binary] = actual;
    _campfire[binary] = isRelease;
    return path;
  }

  /// Hashes [binary] again and requires exactly the SHA-256 that passed the
  /// last [verify] (and, through [prepare], the consensus probe). Returns
  /// its path.
  ///
  /// Launchers call it as the last step before `Process.start` on the same
  /// path, so nothing but the hash itself sits between the check and the
  /// exec. Throws
  /// [BeamHostError.binaryUntrusted] if [binary] was never verified or has
  /// changed on disk since.
  Future<String> verifyUnchanged(BeamBinary binary) async {
    final expected = _verified[binary];
    if (expected == null) {
      throw BeamHostException(
        BeamHostError.binaryUntrusted,
        '${binary.id} was not verified before its launch',
      );
    }
    final path = pathOf(binary);
    await _checkPlacement(binary, path);
    final actual = await sha256OfFile(path);
    if (actual != expected) {
      _verified.remove(binary);
      _campfire.remove(binary);
      throw BeamHostException(
        BeamHostError.binaryUntrusted,
        '${binary.id} changed on disk after it was verified',
      );
    }
    return path;
  }

  /// [binary] is a regular, owner-executable file no other user can write,
  /// in a folder no other user can write to when [requirePrivateDir].
  Future<void> _checkPlacement(BeamBinary binary, String path) async {
    final stat = await FileStat.stat(path);
    if (stat.type == FileSystemEntityType.notFound) {
      throw BeamHostException(
        BeamHostError.binaryMissing,
        '${binary.id} not found in $binDir',
      );
    }
    if (stat.type != FileSystemEntityType.file) {
      throw BeamHostException(
        BeamHostError.binaryMissing,
        '${binary.id} is not a regular file',
      );
    }
    if (!Platform.isWindows) {
      // 0x12 = 0022: group or other may write.
      if (stat.mode & 0x12 != 0) {
        throw BeamHostException(
          BeamHostError.binaryUntrusted,
          '${binary.id} is writable by other users',
        );
      }
      // 0x40 = 0100: owner may execute.
      if (stat.mode & 0x40 == 0) {
        throw BeamHostException(
          BeamHostError.binaryMissing,
          '${binary.id} is not executable',
        );
      }
      if (requirePrivateDir) await verifyPrivateDir(binDir);
    }
  }

  /// [verify], then (once per pinned hash and process) runs the binary in a
  /// throwaway 0700 directory under [scratchParent] and checks that its
  /// `Rules signature` is mainnet with the HF6 fork. Returns the path.
  ///
  /// The probe makes each binary print its rules and exit at once: no
  /// wallet, password, node or network is involved.
  Future<String> prepare(
    BeamBinary binary, {
    required String scratchParent,
  }) async {
    final path = await verify(binary);
    final hash = _verified[binary]!;
    if (_consensusChecked.contains(hash)) return path;

    final output = await _probe(
      binary,
      path,
      scratchParent,
      beforeSpawn: () => verifyUnchanged(binary),
    );
    if (!rulesIncludeHf6(output)) {
      throw BeamHostException(
        BeamHostError.consensusMismatch,
        '${binary.id} does not report mainnet rules with HF6 '
        '($kBeamHf6RulesFork)',
      );
    }
    _consensusChecked.add(hash);
    return path;
  }

  /// True if [output] contains a mainnet `Rules signature` listing the HF6
  /// fork.
  static bool rulesIncludeHf6(String output) {
    final i = output.indexOf('Rules signature:');
    if (i < 0) return false;
    final rest = output.substring(i);
    return rest.contains('network=mainnet') && rest.contains(kBeamHf6RulesFork);
  }

  static Future<String> sha256OfFile(String path) async {
    final digest = await sha256.bind(File(path).openRead()).first;
    return digest.toString();
  }

  static Future<String> _probe(
    BeamBinary binary,
    String exe,
    String scratchParent, {
    required Future<void> Function() beforeSpawn,
  }) async {
    final scratch = await SecretFile.createDir(scratchParent);
    try {
      final args = switch (binary) {
        // Exits with "node address should be specified".
        BeamBinary.walletApi => ['--log_level=info', '--file_log_level=error'],
        // Exits with "Port must be specified".
        BeamBinary.node => [
          '--port=0',
          '--log_level=info',
          '--file_log_level=error',
        ],
        // Prints the rules, reads an empty password from stdin and exits.
        BeamBinary.wallet => [
          'info',
          '--wallet_path=${p.join(scratch.path, 'none.db')}',
          '--log_level=info',
          '--file_log_level=error',
        ],
      };
      final Process process;
      await beforeSpawn();
      try {
        process = await Process.start(
          exe,
          args,
          workingDirectory: scratch.path,
        );
      } on ProcessException catch (e) {
        throw BeamHostException(
          BeamHostError.binaryMissing,
          '${binary.id} could not be started: ${e.message}',
        );
      }
      process.stdin.done.ignore();
      process.stdin.write('\n');
      process.stdin.close().ignore();

      final out = StringBuffer();
      const decoder = Utf8Decoder(allowMalformed: true);
      final streams = Future.wait([
        process.stdout.transform(decoder).forEach(out.write),
        process.stderr.transform(decoder).forEach(out.write),
      ]);
      try {
        await process.exitCode.timeout(const Duration(seconds: 15));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        throw BeamHostException(
          BeamHostError.timeout,
          '${binary.id} did not finish the consensus probe',
        );
      }
      await streams.timeout(
        const Duration(seconds: 2),
        onTimeout: () => const [],
      );
      return out.toString();
    } finally {
      await scratch.delete();
    }
  }
}

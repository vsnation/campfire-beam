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

import 'beam_binaries_manifest.dart';
import 'beam_host_exception.dart';
import 'secret_file.dart';

/// The BEAM executables Campfire runs on desktop.
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

  String get fileName => Platform.isWindows ? '$id.exe' : id;
}

/// Locates the BEAM binaries and proves each one is the pinned build.
///
/// [prepare] (or [verify]) hashes the file before every launch, so a binary
/// replaced on disk after the app started is still refused.
class BeamBinaries {
  BeamBinaries({
    required String binDir,
    this._manifest = kBeamBinaryManifest,
    String? platform,
  }) : binDir = p.normalize(p.absolute(binDir)),
       platform = platform ?? currentPlatform();

  /// Binaries from [binDirEnv] if it is set (development and tests),
  /// otherwise from `<beamRoot>/bin`.
  factory BeamBinaries.locate({
    required String beamRoot,
    Map<String, String>? environment,
  }) {
    final override = (environment ?? Platform.environment)[binDirEnv];
    return BeamBinaries(
      binDir: override != null && override.isNotEmpty
          ? override
          : p.join(beamRoot, 'bin'),
    );
  }

  /// Environment variable that points at a directory of binaries.
  static const String binDirEnv = 'BEAM_BIN_DIR';

  final String binDir;

  /// `<os>-<arch>` key into the manifest, e.g. `macos-arm64`.
  final String platform;

  final Map<String, Map<String, String>> _manifest;

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
    _ => 'unsupported-$abi',
  };

  String pathOf(BeamBinary binary) => p.join(binDir, binary.fileName);

  /// The pinned SHA-256 for [binary] on this platform, if any.
  String? pinnedHash(BeamBinary binary) => _manifest[platform]?[binary.id];

  /// Checks [binary] against the manifest and returns its absolute path.
  ///
  /// Throws [BeamHostException] with [BeamHostError.unsupportedPlatform],
  /// [BeamHostError.binaryMissing] or [BeamHostError.binaryUntrusted].
  Future<String> verify(BeamBinary binary) async {
    final pinned = _manifest[platform];
    if (pinned == null) {
      throw BeamHostException(
        BeamHostError.unsupportedPlatform,
        'No BEAM binaries are pinned for $platform',
      );
    }
    final expected = pinned[binary.id];
    if (expected == null) {
      throw BeamHostException(
        BeamHostError.binaryUntrusted,
        '${binary.id} is not pinned for $platform',
      );
    }

    final path = pathOf(binary);
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
    }

    final actual = await sha256OfFile(path);
    if (actual != expected.toLowerCase()) {
      throw BeamHostException(
        BeamHostError.binaryUntrusted,
        '${binary.id} SHA-256 does not match the pinned value '
        '(got ${actual.substring(0, 16)}…)',
      );
    }
    return path;
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
    final hash = pinnedHash(binary)!;
    if (_consensusChecked.contains(hash)) return path;

    final output = await _probe(binary, path, scratchParent);
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
    String scratchParent,
  ) async {
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

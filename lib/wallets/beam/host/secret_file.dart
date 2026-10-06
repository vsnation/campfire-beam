/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'beam_host_exception.dart';

/// Name prefix of every transient secret file and scratch directory.
///
/// The startup sweep ([SecretFiles.sweep]) deletes everything with this
/// prefix that this process did not create: the leftovers of a crash.
const String kSecretPrefix = '.s-';

// Dart has no octal literals. 0x1c0 = 0700, 0x180 = 0600, 0x3f = 0077,
// 0x1ff = 0777.
const int _modeDir = 0x1c0;
const int _modeFile = 0x180;
const int _groupOtherBits = 0x3f;
const int _permissionBits = 0x1ff;

/// POSIX permission checks apply on macOS and Linux. On Windows the
/// per-user profile directory's ACL is what keeps these files private.
bool get _posix => !Platform.isWindows;

final Random _random = Random.secure();

String _randomHex(int bytes) {
  final buffer = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

Future<void> _chmod(String mode, String path) async {
  if (!_posix) return;
  // An absolute path so a PATH entry cannot substitute its own chmod.
  final exe = File('/bin/chmod').existsSync() ? '/bin/chmod' : 'chmod';
  final result = await Process.run(exe, [mode, path]);
  if (result.exitCode != 0) {
    throw BeamHostException(
      BeamHostError.insecurePath,
      'Could not set mode $mode on ${p.basename(path)}',
    );
  }
}

/// The permission bits of [path], or null on Windows.
Future<int?> posixMode(String path) async {
  if (!_posix) return null;
  final stat = await FileStat.stat(path);
  if (stat.type == FileSystemEntityType.notFound) return null;
  return stat.mode & _permissionBits;
}

Future<void> _expectMode(String path, int expected) async {
  if (!_posix) return;
  final mode = await posixMode(path);
  if (mode != expected) {
    throw BeamHostException(
      BeamHostError.insecurePath,
      '${p.basename(path)} has mode ${mode?.toRadixString(8)}, '
      'expected ${expected.toRadixString(8)}',
    );
  }
}

/// Throws [BeamHostError.insecurePath] unless [path] is an existing directory
/// that no other user can read, write or enter.
Future<void> verifyPrivateDir(String path) async {
  final stat = await FileStat.stat(path);
  if (stat.type != FileSystemEntityType.directory) {
    throw BeamHostException(
      BeamHostError.insecurePath,
      'Not a directory: $path',
    );
  }
  if (_posix && (stat.mode & _groupOtherBits) != 0) {
    throw BeamHostException(
      BeamHostError.insecurePath,
      'Directory is accessible to other users '
      '(mode ${(stat.mode & _permissionBits).toRadixString(8)}): $path',
    );
  }
}

/// Creates [path] and its parents if needed, sets it to 0700 and verifies
/// the result. Use for directories this app owns (run/, wallets/<id>/, …).
Future<Directory> ensurePrivateDir(String path) async {
  final dir = Directory(path);
  await dir.create(recursive: true);
  await _chmod('700', path);
  await verifyPrivateDir(path);
  return dir;
}

/// Sets an existing file to 0600 and verifies it (no-op on Windows).
Future<void> setOwnerOnly(String path) async {
  await _chmod('600', path);
  await _expectMode(path, _modeFile);
}

/// Creates a new, empty, non-secret but private (0600) file, e.g. a log.
/// Fails if [path] already exists.
Future<File> createPrivateFile(String path) async {
  final file = File(path);
  await file.create(exclusive: true);
  await _chmod('600', path);
  await _expectMode(path, _modeFile);
  return file;
}

/// Throws [BeamHostError.invalidInput] if [value] would not survive BEAM's
/// config-file parser unchanged: boost::program_options treats `#` as the
/// start of a comment and trims surrounding whitespace, and a line break
/// would let a value inject further options. The message names [key] only.
void checkConfigValue(String key, String value) {
  if (value.isEmpty) {
    throw BeamHostException(BeamHostError.invalidInput, '"$key" is empty');
  }
  if (value.contains('#')) {
    throw BeamHostException(
      BeamHostError.invalidInput,
      '"$key" contains "#", which BEAM reads as the start of a comment',
    );
  }
  if (value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw BeamHostException(
      BeamHostError.invalidInput,
      '"$key" contains a line break or another control character',
    );
  }
  if (value != value.trim()) {
    throw BeamHostException(
      BeamHostError.invalidInput,
      '"$key" begins or ends with whitespace, which BEAM trims',
    );
  }
}

/// A transient file (or scratch directory) holding a secret.
///
/// It is created 0600 inside a directory that must already be 0700, is
/// registered in [SecretFiles] until deleted, and is named with
/// [kSecretPrefix] so a crash leftover is removed by the next sweep.
class SecretFile {
  SecretFile._(this.path, {required this.isDirectory});

  final String path;
  final bool isDirectory;
  bool _deleted = false;

  bool get isDeleted => _deleted;

  /// Writes [contents] to a new 0600 file in [dirPath]. Refuses if
  /// [dirPath] is accessible to other users. Verifies the mode before and
  /// after the contents are written.
  static Future<SecretFile> write(
    String dirPath,
    String contents, {
    String suffix = '',
  }) async {
    await verifyPrivateDir(dirPath);
    final path = p.join(dirPath, '$kSecretPrefix${_randomHex(8)}$suffix');
    final secret = SecretFile._(path, isDirectory: false);
    SecretFiles._live.add(secret);
    try {
      final file = File(path);
      await file.create(exclusive: true);
      await _chmod('600', path);
      await _expectMode(path, _modeFile);
      await file.writeAsString(contents, flush: true);
      await _expectMode(path, _modeFile);
      return secret;
    } catch (_) {
      await secret.delete();
      rethrow;
    }
  }

  /// Writes a BEAM `--config_file` (`key=value` per line). Every value is
  /// checked with [checkConfigValue] first.
  static Future<SecretFile> writeConfig(
    String dirPath,
    Map<String, String> values,
  ) {
    values.forEach(checkConfigValue);
    final contents = values.entries.map((e) => '${e.key}=${e.value}\n').join();
    return write(dirPath, contents, suffix: '.cfg');
  }

  /// Creates a 0700 scratch directory in [parentPath], deleted recursively
  /// by [delete]. Used as a child's working directory when the child may
  /// write a secret into its own log files.
  static Future<SecretFile> createDir(String parentPath) async {
    await verifyPrivateDir(parentPath);
    final path = p.join(parentPath, '$kSecretPrefix${_randomHex(8)}');
    final secret = SecretFile._(path, isDirectory: true);
    SecretFiles._live.add(secret);
    try {
      final dir = Directory(path);
      if (await dir.exists()) {
        throw BeamHostException(
          BeamHostError.insecurePath,
          'Scratch directory already exists: ${p.basename(path)}',
        );
      }
      await dir.create();
      await _chmod('700', path);
      await _expectMode(path, _modeDir);
      return secret;
    } catch (_) {
      await secret.delete();
      rethrow;
    }
  }

  Future<bool> _exists() => isDirectory
      ? Directory(path).exists()
      : FileSystemEntity.type(
          path,
          followLinks: false,
        ).then((t) => t != FileSystemEntityType.notFound);

  /// Deletes the file. Safe to call more than once. If deletion fails the
  /// file stays registered, so [SecretFiles.deleteAll] retries it.
  Future<void> delete() async {
    if (_deleted) return;
    try {
      if (isDirectory) {
        await Directory(path).delete(recursive: true);
      } else {
        await File(path).delete();
      }
    } on FileSystemException {
      // Already gone, or still locked (Windows). Checked below.
    }
    if (!await _exists()) {
      _deleted = true;
      SecretFiles._live.remove(this);
    }
  }

  /// Synchronous [delete], for use from synchronous callbacks and shutdown.
  void deleteSync() {
    if (_deleted) return;
    try {
      if (isDirectory) {
        Directory(path).deleteSync(recursive: true);
      } else {
        File(path).deleteSync();
      }
    } on FileSystemException {
      // See delete().
    }
    final gone = isDirectory
        ? !Directory(path).existsSync()
        : FileSystemEntity.typeSync(path, followLinks: false) ==
              FileSystemEntityType.notFound;
    if (gone) {
      _deleted = true;
      SecretFiles._live.remove(this);
    }
  }

  @override
  String toString() => 'SecretFile(${p.basename(path)})';
}

/// Process-wide registry of live [SecretFile]s.
abstract final class SecretFiles {
  static final Set<SecretFile> _live = {};

  /// Paths of secret files this process has created and not yet deleted.
  static List<String> get livePaths =>
      _live.map((f) => f.path).toList(growable: false);

  /// Deletes every live secret file. Call on shutdown and after errors.
  static Future<void> deleteAll() async {
    for (final f in List.of(_live)) {
      await f.delete();
    }
  }

  /// Synchronous [deleteAll].
  static void deleteAllSync() {
    for (final f in List.of(_live)) {
      f.deleteSync();
    }
  }

  /// Deletes every [kSecretPrefix] entry directly inside [dirs] that this
  /// process did not create, i.e. secret files and scratch directories left
  /// by a crash. Returns how many entries were removed. Directories that do
  /// not exist are skipped.
  static Future<int> sweep(Iterable<String> dirs) async {
    final mine = _live.map((f) => p.normalize(f.path)).toSet();
    var removed = 0;
    for (final dirPath in dirs) {
      final dir = Directory(dirPath);
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (!name.startsWith(kSecretPrefix)) continue;
        if (mine.contains(p.normalize(entity.path))) continue;
        try {
          if (entity is Directory) {
            await entity.delete(recursive: true);
          } else {
            await entity.delete();
          }
          removed++;
        } on FileSystemException {
          // Leave it; the next sweep tries again.
        }
      }
    }
    return removed;
  }
}

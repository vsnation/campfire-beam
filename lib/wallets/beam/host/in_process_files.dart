/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'beam_host_exception.dart';
import 'secret_file.dart' show kSecretPrefix;

/// Owner-only directories and secret files for [InProcessHost].
///
/// The desktop helpers in `secret_file.dart` set modes by running
/// `/bin/chmod`, and an iOS app may neither find nor start it. These call
/// `chmod(2)` through `dart:ffi` instead, which works in the app sandbox (and
/// on macOS, where the tests run). The iOS sandbox already keeps other apps
/// out of the container; the modes are the same belt and braces the desktop
/// host uses. Windows has no `chmod`: there, as in `secret_file.dart`, the
/// per-user profile directory's ACL keeps these files private, and modes are
/// neither set nor checked.
abstract final class InProcessFiles {
  static const int _modeDir = 0x1c0; // 0700
  static const int _modeFile = 0x180; // 0600
  static const int _groupOther = 0x3f; // 0077
  static const int _permissionBits = 0x1ff; // 0777

  static final Random _random = Random.secure();

  static bool get _posix => !Platform.isWindows;

  static final int Function(Pointer<Utf8>, int) _chmod = _lookupChmod();

  static int Function(Pointer<Utf8>, int) _lookupChmod() {
    final libc = DynamicLibrary.process();
    // mode_t is 16 bits on Darwin, 32 on Linux and Android.
    if (Platform.isIOS || Platform.isMacOS) {
      return libc.lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint16),
        int Function(Pointer<Utf8>, int)
      >('chmod');
    }
    return libc.lookupFunction<
      Int32 Function(Pointer<Utf8>, Uint32),
      int Function(Pointer<Utf8>, int)
    >('chmod');
  }

  static void chmod(String path, int mode) {
    if (!_posix) return;
    final cPath = path.toNativeUtf8(allocator: calloc);
    try {
      if (_chmod(cPath, mode) != 0) {
        throw BeamHostException(
          BeamHostError.insecurePath,
          'Could not set mode ${mode.toRadixString(8)} on ${p.basename(path)}',
        );
      }
    } finally {
      calloc.free(cPath);
    }
  }

  static Future<void> _expect(
    String path,
    int mode, {
    required bool dir,
  }) async {
    final stat = await FileStat.stat(path);
    final wantType = dir
        ? FileSystemEntityType.directory
        : FileSystemEntityType.file;
    if (stat.type != wantType) {
      throw BeamHostException(
        BeamHostError.insecurePath,
        'Not a ${dir ? 'directory' : 'file'}: ${p.basename(path)}',
      );
    }
    if (!_posix) return;
    if ((stat.mode & _permissionBits) != mode ||
        (stat.mode & _groupOther) != 0) {
      throw BeamHostException(
        BeamHostError.insecurePath,
        '${p.basename(path)} has mode '
        '${(stat.mode & _permissionBits).toRadixString(8)}, '
        'expected ${mode.toRadixString(8)}',
      );
    }
  }

  /// Creates [path] (and parents), sets it to 0700 and checks the result.
  static Future<Directory> ensurePrivateDir(String path) async {
    final dir = Directory(path);
    await dir.create(recursive: true);
    chmod(path, _modeDir);
    await _expect(path, _modeDir, dir: true);
    return dir;
  }

  /// Writes [content] to a new 0600 file in [dir] named `.s-<random>[suffix]`.
  /// The file is created empty, restricted, checked, and only then filled.
  static Future<File> writeSecret(
    String dir,
    String content, {
    String suffix = '',
  }) async {
    final name = StringBuffer(kSecretPrefix);
    for (var i = 0; i < 16; i++) {
      name.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    name.write(suffix);
    final file = File(p.join(dir, name.toString()));
    await file.create(exclusive: true);
    try {
      chmod(file.path, _modeFile);
      await _expect(file.path, _modeFile, dir: false);
      await file.writeAsString(content, flush: true);
    } catch (_) {
      await deleteSecret(file);
      rethrow;
    }
    return file;
  }

  /// Overwrites [file] with zeros and deletes it. Never throws.
  static Future<void> deleteSecret(File? file) async {
    if (file == null) return;
    try {
      if (!await file.exists()) return;
      final length = await file.length();
      if (length > 0) {
        await file.writeAsBytes(List<int>.filled(length, 0), flush: true);
      }
      await file.delete();
    } on FileSystemException {
      // Gone already, or the directory is going; the next sweep retries.
    }
  }

  /// Deletes every `.s-*` entry in [dir] (leftovers of a crash). Returns how
  /// many there were.
  static Future<int> sweep(String dir) async {
    var removed = 0;
    final d = Directory(dir);
    if (!await d.exists()) return 0;
    await for (final entity in d.list()) {
      if (!p.basename(entity.path).startsWith(kSecretPrefix)) continue;
      try {
        if (entity is File) {
          await deleteSecret(entity);
        } else {
          await entity.delete(recursive: true);
        }
        removed++;
      } on FileSystemException {
        // Next start tries again.
      }
    }
    return removed;
  }
}

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
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'dapp_api_version.dart';
import 'dapp_errors.dart';
import 'dapp_manifest.dart';
import 'dapp_package.dart';

/// An installed dApp.
@immutable
class DappInstallation {
  const DappInstallation({
    required this.manifest,
    required this.apiVersion,
    required this.packageSha256,
    required this.directory,
    required this.installedAt,
  });

  final DappManifest manifest;
  final DappApiVersion apiVersion;
  final String packageSha256;

  /// `<root>/dapps/<guid>/<version>`.
  final String directory;
  final DateTime installedAt;

  String get guid => manifest.guid;

  /// The document root: the package's files and nothing else.
  String get filesDirectory => p.join(directory, DappInstaller.filesDirName);
}

/// Installs `.dapp` packages under one root (one per wallet and network).
///
/// ```
/// <root>/dapps/<guid>/<version>/install.json   what was installed, when
/// <root>/dapps/<guid>/<version>/files/…        the package, served as is
/// <root>/dapps/<guid>/port                     the dApp's serving port
/// <root>/dapps/<guid>/scope.json               the dApp's own txs/addresses
/// ```
///
/// `<guid>` is only ever the canonical 32-hex form from [DappManifest];
/// a path is never built from text as the package wrote it. `<version>` is
/// the manifest version (digits and dots) or `0`.
///
/// An install extracts into a fresh `.tmp-<random>` directory beside its
/// target, re-reads every file and compares its SHA-256 with the package,
/// then renames the directory into place: a crash leaves either the old
/// install or the new one, never a mix. Uninstall renames the dApp's
/// directory away before deleting it, for the same reason. Operations on
/// one installer run one at a time.
class DappInstaller {
  DappInstaller(this.root);

  final String root;

  static const filesDirName = 'files';
  static const recordFileName = 'install.json';
  static const _portFileName = 'port';

  Future<void> _tail = Future.value();

  String get dappsDirectory => p.join(root, 'dapps');

  /// `<root>/dapps/<guid>`: per-dApp data that survives updates and is
  /// deleted on uninstall.
  String dataDirectory(String guid) =>
      p.join(dappsDirectory, _checkedGuid(guid));

  Future<T> _serial<T>(Future<T> Function() op) {
    final result = _tail.then((_) => op());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Installs [package]. Throws [DappInstallException] with
  /// [DappInstallError.alreadyInstalled] when any version of the dApp is
  /// installed, unless [replace] is set; with [replace], the new version
  /// takes the old one's place and the old files are removed.
  Future<DappInstallation> install(
    DappPackage package, {
    bool replace = false,
  }) => _serial(() => _install(package, replace: replace));

  Future<DappInstallation> _install(
    DappPackage package, {
    required bool replace,
  }) async {
    final guid = _checkedGuid(package.manifest.guid);
    final versionKey = package.manifest.version ?? '0';
    DappPath.checkSegment(versionKey);
    final guidDir = Directory(p.join(dappsDirectory, guid));
    try {
      await guidDir.create(recursive: true);
    } on FileSystemException catch (e) {
      throw DappInstallException(
        DappInstallError.folderPrepFailed,
        'cannot create the dApp folder (${e.osError?.errorCode})',
      );
    }

    final existing = await _versionDirs(guidDir);
    if (existing.isNotEmpty && !replace) {
      throw DappInstallException(
        DappInstallError.alreadyInstalled,
        '${package.manifest.name} is already installed',
      );
    }

    final tmp = Directory(p.join(guidDir.path, '.tmp-${_random()}'));
    try {
      await tmp.create();
      await _extract(package, tmp.path);
      final installedAt = DateTime.now().toUtc();
      await File(p.join(tmp.path, recordFileName)).writeAsString(
        jsonEncode({
          'format': 1,
          'guid': guid,
          'package_sha256': package.sha256,
          'api_version': package.apiVersion.label,
          'installed_at': installedAt.toIso8601String(),
          'files': package.files.length,
          'total_bytes': package.totalBytes,
          'manifest': package.manifest.toJson(),
        }),
        flush: true,
      );

      final target = Directory(p.join(guidDir.path, versionKey));
      Directory? old;
      if (await target.exists()) {
        old = await target.rename(p.join(guidDir.path, '.old-${_random()}'));
      }
      try {
        await tmp.rename(target.path);
      } catch (_) {
        if (old != null) await old.rename(target.path);
        rethrow;
      }
      if (old != null) await _deleteQuietly(old);
      for (final other in existing) {
        if (p.basename(other.path) != versionKey) await _deleteQuietly(other);
      }
      return DappInstallation(
        manifest: package.manifest,
        apiVersion: package.apiVersion,
        packageSha256: package.sha256,
        directory: target.path,
        installedAt: installedAt,
      );
    } on DappInstallException {
      await _deleteQuietly(tmp);
      rethrow;
    } on FileSystemException catch (e) {
      await _deleteQuietly(tmp);
      throw DappInstallException(
        DappInstallError.extractFailed,
        'writing the dApp failed (${e.osError?.errorCode})',
      );
    }
  }

  Future<void> _extract(DappPackage package, String tmpPath) async {
    final base = p.normalize(p.join(tmpPath, filesDirName));
    await Directory(base).create();
    for (final f in package.files) {
      final target = p.normalize(p.joinAll([base, ...f.segments]));
      // Paths were validated by DappPath; this is the second line.
      if (!p.isWithin(base, target)) {
        throw const DappInstallException(
          DappInstallError.unsafePath,
          'an entry resolves outside the install folder',
        );
      }
      await Directory(p.dirname(target)).create(recursive: true);
      await File(target).writeAsBytes(f.bytes, flush: true);
    }

    // Verify what landed on disk: only regular files, exactly the
    // package's, each with the package's bytes.
    final expected = {
      for (final f in package.files)
        p.joinAll([base, ...f.segments]): crypto.sha256.convert(f.bytes),
    };
    var seen = 0;
    await for (final e in Directory(
      base,
    ).list(recursive: true, followLinks: false)) {
      if (e is Link) {
        throw const DappInstallException(
          DappInstallError.unsafeEntry,
          'a link appeared in the install folder',
        );
      }
      if (e is! File) continue;
      final want = expected[p.normalize(e.path)];
      if (want == null) {
        throw const DappInstallException(
          DappInstallError.extractFailed,
          'an unexpected file appeared in the install folder',
        );
      }
      final got = crypto.sha256.convert(await e.readAsBytes());
      if (got != want) {
        throw const DappInstallException(
          DappInstallError.extractFailed,
          'a file differs from the package after writing',
        );
      }
      seen++;
    }
    if (seen != expected.length) {
      throw const DappInstallException(
        DappInstallError.extractFailed,
        'files are missing after extraction',
      );
    }
  }

  /// Every installed dApp, one entry per guid (the newest install when an
  /// interrupted update left two).
  Future<List<DappInstallation>> list() => _serial(_list);

  Future<List<DappInstallation>> _list() async {
    final dir = Directory(dappsDirectory);
    if (!await dir.exists()) return const [];
    final out = <DappInstallation>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! Directory) continue;
      final name = p.basename(e.path);
      if (!DappManifest.isCanonicalGuid(name)) continue;
      final found = await _newest(e, name);
      if (found != null) out.add(found);
    }
    out.sort((a, b) => a.manifest.name.compareTo(b.manifest.name));
    return List.unmodifiable(out);
  }

  /// The installed dApp with this canonical [guid], or null.
  Future<DappInstallation?> find(String guid) => _serial(() async {
    final dir = Directory(p.join(dappsDirectory, _checkedGuid(guid)));
    if (!await dir.exists()) return null;
    return _newest(dir, guid);
  });

  Future<DappInstallation?> _newest(Directory guidDir, String guid) async {
    DappInstallation? best;
    for (final v in await _versionDirs(guidDir)) {
      final inst = await _readRecord(v, guid);
      if (inst == null) continue;
      if (best == null || inst.installedAt.isAfter(best.installedAt)) {
        best = inst;
      }
    }
    return best;
  }

  Future<DappInstallation?> _readRecord(Directory dir, String guid) async {
    try {
      final record = jsonDecode(
        await File(p.join(dir.path, recordFileName)).readAsString(),
      ) as Map<String, Object?>;
      if (record['guid'] != guid) return null;
      final manifestJson = record['manifest']! as Map<String, Object?>;
      final manifest = DappManifest(
        guid: guid,
        name: manifestJson['name']! as String,
        description: manifestJson['description']! as String,
        startPath: DappPath.parse(manifestJson['start_path']! as String)
            .join('/'),
        iconPath: manifestJson['icon_path'] == null
            ? null
            : DappPath.parse(manifestJson['icon_path']! as String).join('/'),
        version: manifestJson['version'] as String?,
        apiVersion: manifestJson['api_version'] as String?,
        minApiVersion: manifestJson['min_api_version'] as String?,
        category: manifestJson['category'] as int?,
        publisher: manifestJson['publisher'] as String?,
      );
      final api = DappApiVersion.tryParse(record['api_version'] as String?);
      final sha = record['package_sha256'];
      final at = DateTime.tryParse(record['installed_at']! as String);
      if (api == null || sha is! String || at == null) return null;
      if (!await Directory(p.join(dir.path, filesDirName)).exists()) {
        return null;
      }
      return DappInstallation(
        manifest: manifest,
        apiVersion: api,
        packageSha256: sha,
        directory: dir.path,
        installedAt: at,
      );
    } catch (_) {
      return null; // a damaged record is not an install
    }
  }

  /// Removes the dApp and its data. Returns false when it was not
  /// installed.
  Future<bool> uninstall(String guid) => _serial(() async {
    final dir = Directory(p.join(dappsDirectory, _checkedGuid(guid)));
    if (!await dir.exists()) return false;
    final trash = await dir.rename(
      p.join(dappsDirectory, '.trash-${_random()}'),
    );
    await _deleteQuietly(trash);
    return true;
  });

  /// Deletes what interrupted installs and uninstalls left behind.
  Future<void> cleanup() => _serial(() async {
    final dir = Directory(dappsDirectory);
    if (!await dir.exists()) return;
    await for (final e in dir.list(followLinks: false)) {
      final name = p.basename(e.path);
      if (e is Directory && name.startsWith('.trash-')) {
        await _deleteQuietly(e);
      } else if (e is Directory && DappManifest.isCanonicalGuid(name)) {
        final newest = await _newest(e, name);
        await for (final v in e.list(followLinks: false)) {
          final vName = p.basename(v.path);
          final stale =
              vName.startsWith('.tmp-') ||
              vName.startsWith('.old-') ||
              (v is Directory &&
                  !vName.startsWith('.') &&
                  newest != null &&
                  v.path != newest.directory);
          if (stale && v is Directory) await _deleteQuietly(v);
        }
      }
    }
  });

  /// The port the dApp was last served on, so it keeps its origin (and
  /// with it its browser storage) across launches.
  Future<int?> savedPort(String guid) async {
    try {
      final text = await File(p.join(dataDirectory(guid), _portFileName))
          .readAsString();
      final port = int.tryParse(text.trim());
      return port != null && port > 1024 && port < 65536 ? port : null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> savePort(String guid, int port) async {
    if (port <= 1024 || port >= 65536) throw ArgumentError.value(port);
    final dir = Directory(dataDirectory(guid));
    if (!await dir.exists()) return;
    await _serial(() => _claimOrigin(guid, port));
    await File(p.join(dir.path, _portFileName)).writeAsString('$port');
  }

  /// Every loopback port a dApp other than [guid] has been served on: its
  /// origin, and with it that dApp's browser storage, which the webview
  /// keeps. A dApp must never be served on one of these (it would read and
  /// write the other dApp's storage), even after that dApp moved to another
  /// port or was uninstalled.
  Future<Set<int>> portsOfOtherDapps(String guid) => _serial(() async {
    _checkedGuid(guid);
    final out = <int>{
      for (final e in (await _readOrigins()).entries)
        if (e.value != guid) e.key,
    };
    // Installs from before the record: their current port.
    final dir = Directory(dappsDirectory);
    if (await dir.exists()) {
      await for (final e in dir.list(followLinks: false)) {
        final other = p.basename(e.path);
        if (e is! Directory ||
            other == guid ||
            !DappManifest.isCanonicalGuid(other)) {
          continue;
        }
        final port = await savedPort(other);
        if (port != null) out.add(port);
      }
    }
    return out;
  });

  /// Which dApp each port was first given to: `<root>/dapp_origins.json`.
  /// Never shrinks; uninstalling a dApp leaves its browser storage behind.
  String get _originsPath => p.join(root, _originsFileName);
  static const _originsFileName = 'dapp_origins.json';

  Future<Map<int, String>> _readOrigins() async {
    try {
      final json = jsonDecode(await File(_originsPath).readAsString());
      if (json is! Map) return {};
      return {
        for (final e in json.entries)
          if (int.tryParse('${e.key}') != null && e.value is String)
            int.parse('${e.key}'): e.value as String,
      };
    } on FileSystemException {
      return {};
    } on FormatException {
      return {};
    }
  }

  Future<void> _claimOrigin(String guid, int port) async {
    final origins = await _readOrigins();
    final owner = origins[port];
    if (owner == guid) return;
    if (owner != null) {
      throw StateError('port $port was already the origin of another dApp');
    }
    origins[port] = guid;
    await Directory(root).create(recursive: true);
    final tmp = File('$_originsPath.part');
    await tmp.writeAsString(
      jsonEncode({for (final e in origins.entries) '${e.key}': e.value}),
      flush: true,
    );
    await tmp.rename(_originsPath);
  }

  static Future<List<Directory>> _versionDirs(Directory guidDir) async {
    if (!await guidDir.exists()) return const [];
    final out = <Directory>[];
    await for (final e in guidDir.list(followLinks: false)) {
      if (e is Directory && !p.basename(e.path).startsWith('.')) out.add(e);
    }
    return out;
  }

  static String _checkedGuid(String guid) {
    if (!DappManifest.isCanonicalGuid(guid)) {
      throw ArgumentError.value(guid, 'guid', 'not a canonical dApp guid');
    }
    return guid;
  }

  static final _rng = Random.secure();

  static String _random() => [
    for (var i = 0; i < 8; i++)
      _rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Left for cleanup().
    }
  }
}

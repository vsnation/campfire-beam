/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io' show ZLibDecoder;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' as zip;
import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';

import 'dapp_api_version.dart';
import 'dapp_errors.dart';
import 'dapp_manifest.dart';

/// Size, count and compression limits for a `.dapp` package.
///
/// Defaults sit well above the 9 bundled mainnet packages (largest: 5.3 MB
/// zipped, 17.4 MB unpacked, 153 entries, one file of 12.9 MB, best
/// compression ratio 16.9) and well below what a zip bomb needs.
/// [maxPackageBytes] is beam-ui's cap (`apps_view.cpp:51`).
@immutable
class DappPackageLimits {
  const DappPackageLimits({
    this.maxPackageBytes = 50 * 1024 * 1024,
    this.maxEntries = 4096,
    this.maxFileBytes = 64 * 1024 * 1024,
    this.maxTotalBytes = 256 * 1024 * 1024,
    this.maxCentralDirectoryBytes = 2 * 1024 * 1024,
    this.maxRatio = 100,
    this.ratioFloorBytes = 1024 * 1024,
  });

  final int maxPackageBytes;
  final int maxEntries;

  /// Uncompressed size of any one file.
  final int maxFileBytes;

  /// Uncompressed size of all files together.
  final int maxTotalBytes;
  final int maxCentralDirectoryBytes;

  /// Uncompressed / compressed, for files larger than [ratioFloorBytes]
  /// (small files of repeated bytes legitimately compress far better).
  final int maxRatio;
  final int ratioFloorBytes;
}

/// One regular file of a package, decompressed and CRC-checked.
@immutable
class DappPackageFile {
  const DappPackageFile(this.segments, this.bytes);

  /// Validated by [DappPath.parse].
  final List<String> segments;
  final Uint8List bytes;

  String get path => segments.join('/');
}

/// A `.dapp` package read entirely in memory and checked.
///
/// [read] refuses, with a [DappInstallException]:
/// * anything over [DappPackageLimits], judged on the declared sizes first
///   and then on the bytes actually inflated: a deflate stream is inflated
///   with a hard cap at its declared size, so a lying header cannot make it
///   expand further;
/// * zip64, multi-disk, encrypted entries, and compression other than
///   stored (0) or deflate (8);
/// * entries whose local and central names differ, unsafe names
///   ([DappPath]), names that collide case-insensitively, a file where a
///   directory is needed, and symlinks, devices or other non-regular files;
/// * a CRC or size mismatch;
/// * a missing or invalid `manifest.json`, a start page that is not in the
///   package, and an API version this wallet cannot serve.
///
/// macOS metadata (`__MACOSX/…`, `.DS_Store`), present in 7 of the 9
/// bundled packages, is checked like any entry and then dropped.
@immutable
class DappPackage {
  const DappPackage._({
    required this.manifest,
    required this.apiVersion,
    required this.sha256,
    required this.files,
  });

  final DappManifest manifest;

  /// The version the dApp will be served (see [DappApiVersion.negotiate]).
  final DappApiVersion apiVersion;

  /// Lowercase hex SHA-256 of the package bytes.
  final String sha256;

  /// Every regular file to install, in archive order.
  final List<DappPackageFile> files;

  int get totalBytes => files.fold(0, (n, f) => n + f.bytes.length);

  static const _eocdSignature = 0x06054b50;
  static const _zip64LocatorSignature = 0x07064b50;
  static const _methodStore = 0;
  static const _methodDeflate = 8;
  static const _flagEncrypted = 0x0001;
  static const _flagStrongEncryption = 0x0040;
  static const _unixCreators = {3, 19}; // Unix, OS X
  static const _typeMask = 0xf000;
  static const _typeRegular = 0x8000;
  static const _typeDirectory = 0x4000;
  static const _typeSymlink = 0xa000;

  static DappPackage read(
    List<int> data, {
    DappPackageLimits limits = const DappPackageLimits(),
  }) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    if (bytes.length > limits.maxPackageBytes) {
      throw _tooLarge('package is ${bytes.length} bytes');
    }
    final entryCount = _checkEndRecord(bytes, limits);

    final dir = zip.ZipDirectory();
    try {
      dir.read(zip.InputMemoryStream(bytes));
    } catch (e) {
      throw DappInstallException(
        DappInstallError.cantOpenFile,
        'not a readable zip archive (${e.runtimeType})',
      );
    }
    final headers = dir.fileHeaders;
    if (headers.isEmpty) {
      throw const DappInstallException(
        DappInstallError.cantOpenFile,
        'not a zip archive, or an empty one',
      );
    }
    if (headers.length != entryCount) {
      throw const DappInstallException(
        DappInstallError.invalidFile,
        'central directory entry count does not match the end record',
      );
    }

    final files = <DappPackageFile>[];
    final fileKeys = <String>{};
    final dirKeys = <String>{};
    var declaredTotal = 0;
    var compressedTotal = 0;
    for (final h in headers) {
      final name = h.filename;
      final local = h.file;
      if (local == null || local.filename != name) {
        throw const DappInstallException(
          DappInstallError.invalidFile,
          'an entry\'s local and central names differ',
        );
      }
      if (h.generalPurposeBitFlag & (_flagEncrypted | _flagStrongEncryption) !=
          0) {
        throw const DappInstallException(
          DappInstallError.invalidFile,
          'encrypted entry',
        );
      }
      final method = h.compressionMethod;
      if (method != _methodStore && method != _methodDeflate) {
        throw DappInstallException(
          DappInstallError.invalidFile,
          'compression method $method is not supported',
        );
      }

      final isDirectory = name.endsWith('/');
      final segments = DappPath.parse(
        isDirectory ? name.substring(0, name.length - 1) : name,
      );
      _checkFileType(h, isDirectory: isDirectory);

      final size = h.uncompressedSize;
      final packed = h.compressedSize;
      if (size < 0 || packed < 0) {
        throw const DappInstallException(
          DappInstallError.invalidFile,
          'negative entry size',
        );
      }
      compressedTotal += packed;
      if (compressedTotal > bytes.length) {
        throw const DappInstallException(
          DappInstallError.invalidFile,
          'entries claim more compressed data than the archive holds',
        );
      }
      if (isDirectory) {
        if (size != 0) {
          throw const DappInstallException(
            DappInstallError.invalidFile,
            'directory entry with content',
          );
        }
        dirKeys.add(DappPath.foldKey(segments));
        continue;
      }

      if (size > limits.maxFileBytes) {
        throw _tooLarge('an entry is $size bytes uncompressed');
      }
      declaredTotal += size;
      if (declaredTotal > limits.maxTotalBytes) {
        throw _tooLarge('entries total more than ${limits.maxTotalBytes}');
      }
      if (size > limits.ratioFloorBytes &&
          size > limits.maxRatio * math.max(packed, 1)) {
        throw _tooLarge(
          'an entry compresses ${size ~/ math.max(packed, 1)}'
          ':1 (max ${limits.maxRatio}:1)',
        );
      }

      final key = DappPath.foldKey(segments);
      if (!fileKeys.add(key)) {
        throw const DappInstallException(
          DappInstallError.invalidFile,
          'two entries have the same name (ignoring case)',
        );
      }
      if (_isJunk(segments)) continue;

      final raw = local.getRawContent();
      if (raw.length != packed) {
        throw const DappInstallException(
          DappInstallError.invalidFile,
          'an entry is truncated',
        );
      }
      final content = method == _methodStore
          ? Uint8List.fromList(raw)
          : _inflate(raw, size);
      if (content.length != size) {
        throw const DappInstallException(
          DappInstallError.invalidFile,
          'an entry\'s size does not match its header',
        );
      }
      if (zip.getCrc32(content) != h.crc32) {
        throw const DappInstallException(
          DappInstallError.invalidFile,
          'CRC mismatch',
        );
      }
      files.add(DappPackageFile(segments, content));
    }

    // A file where another entry needs a directory cannot be extracted.
    if (fileKeys.any(dirKeys.contains)) {
      throw const DappInstallException(
        DappInstallError.invalidFile,
        'a file and a directory share a name',
      );
    }
    for (final key in [...fileKeys, ...dirKeys]) {
      final parts = key.split('/');
      for (var i = 1; i < parts.length; i++) {
        if (fileKeys.contains(parts.sublist(0, i).join('/'))) {
          throw const DappInstallException(
            DappInstallError.invalidFile,
            'a file and a directory share a name',
          );
        }
      }
    }

    final manifestFile = files
        .where(
          (f) =>
              f.segments.length == 1 &&
              f.segments.single == DappManifest.fileName,
        )
        .firstOrNull;
    if (manifestFile == null) {
      throw const DappInstallException(
        DappInstallError.cantReadManifest,
        'no manifest.json at the package root',
      );
    }
    var manifest = DappManifest.parse(manifestFile.bytes);
    final paths = {for (final f in files) f.path};
    if (!paths.contains(manifest.startPath)) {
      throw const DappInstallException(
        DappInstallError.invalidFile,
        'the start page named by "url" is not in the package',
      );
    }
    final icon = manifest.iconPath;
    if (icon != null && !paths.contains(icon)) {
      manifest = DappManifest(
        guid: manifest.guid,
        name: manifest.name,
        description: manifest.description,
        startPath: manifest.startPath,
        version: manifest.version,
        apiVersion: manifest.apiVersion,
        minApiVersion: manifest.minApiVersion,
        category: manifest.category,
        publisher: manifest.publisher,
      );
    }
    final apiVersion = manifest.negotiatedApiVersion;
    if (apiVersion == null) {
      throw DappInstallException(
        DappInstallError.unsupported,
        'api_version ${manifest.apiVersion ?? 'current'} / '
        'min_api_version ${manifest.minApiVersion ?? '-'} not supported',
      );
    }

    return DappPackage._(
      manifest: manifest,
      apiVersion: apiVersion,
      sha256: crypto.sha256.convert(bytes).toString(),
      files: List.unmodifiable(files),
    );
  }

  static bool _isJunk(List<String> segments) =>
      segments.first == '__MACOSX' || segments.last == '.DS_Store';

  /// Reads the end-of-central-directory record before the zip library
  /// parses anything, so a forged directory cannot make it allocate
  /// millions of entries. Returns the entry count.
  static int _checkEndRecord(Uint8List b, DappPackageLimits limits) {
    const fixed = 22;
    if (b.length < fixed) {
      throw const DappInstallException(
        DappInstallError.cantOpenFile,
        'too short to be a zip archive',
      );
    }
    final data = ByteData.sublistView(b);
    final lowest = math.max(0, b.length - fixed - 0xffff);
    var pos = -1;
    for (var i = b.length - fixed; i >= lowest; i--) {
      if (data.getUint32(i, Endian.little) == _eocdSignature) {
        pos = i;
        break;
      }
    }
    if (pos < 0) {
      throw const DappInstallException(
        DappInstallError.cantOpenFile,
        'no zip end record',
      );
    }
    if (pos >= 20 &&
        data.getUint32(pos - 20, Endian.little) == _zip64LocatorSignature) {
      throw const DappInstallException(
        DappInstallError.invalidFile,
        'zip64 archives are not supported',
      );
    }
    final disk = data.getUint16(pos + 4, Endian.little);
    final cdDisk = data.getUint16(pos + 6, Endian.little);
    final onDisk = data.getUint16(pos + 8, Endian.little);
    final total = data.getUint16(pos + 10, Endian.little);
    final cdSize = data.getUint32(pos + 12, Endian.little);
    final cdOffset = data.getUint32(pos + 16, Endian.little);
    if (disk != 0 || cdDisk != 0 || onDisk != total) {
      throw const DappInstallException(
        DappInstallError.invalidFile,
        'multi-disk archives are not supported',
      );
    }
    if (total == 0xffff || cdSize == 0xffffffff || cdOffset == 0xffffffff) {
      throw const DappInstallException(
        DappInstallError.invalidFile,
        'zip64 archives are not supported',
      );
    }
    if (total > limits.maxEntries) {
      throw _tooLarge('$total entries (max ${limits.maxEntries})');
    }
    if (cdSize > limits.maxCentralDirectoryBytes) {
      throw _tooLarge('central directory of $cdSize bytes');
    }
    if (cdOffset + cdSize > pos) {
      throw const DappInstallException(
        DappInstallError.cantOpenFile,
        'central directory outside the archive',
      );
    }
    return total;
  }

  static void _checkFileType(zip.ZipFileHeader h, {required bool isDirectory}) {
    final type = (h.externalFileAttributes >> 16) & _typeMask;
    if (type == _typeSymlink) {
      throw const DappInstallException(
        DappInstallError.unsafeEntry,
        'symbolic link in the package',
      );
    }
    if (!_unixCreators.contains(h.versionMadeBy >> 8) || type == 0) return;
    final expected = isDirectory ? _typeDirectory : _typeRegular;
    if (type != expected) {
      throw const DappInstallException(
        DappInstallError.unsafeEntry,
        'special file in the package',
      );
    }
  }

  /// Inflates raw deflate data, refusing to produce more than [expected]
  /// bytes however the stream is built.
  static Uint8List _inflate(Uint8List compressed, int expected) {
    final sink = _CappedSink(expected);
    try {
      final conv = ZLibDecoder(raw: true).startChunkedConversion(sink);
      const chunk = 64 * 1024;
      for (var i = 0; i < compressed.length; i += chunk) {
        conv.add(
          Uint8List.sublistView(
            compressed,
            i,
            math.min(i + chunk, compressed.length),
          ),
        );
      }
      conv.close();
    } on _CapExceeded {
      throw const DappInstallException(
        DappInstallError.tooLarge,
        'an entry inflates beyond its declared size',
      );
    } catch (e) {
      throw DappInstallException(
        DappInstallError.invalidFile,
        'an entry is not valid deflate data (${e.runtimeType})',
      );
    }
    return sink.takeBytes();
  }

  static DappInstallException _tooLarge(String why) =>
      DappInstallException(DappInstallError.tooLarge, why);
}

class _CapExceeded implements Exception {
  const _CapExceeded();
}

class _CappedSink implements Sink<List<int>> {
  _CappedSink(this.cap);

  final int cap;
  final _out = BytesBuilder(copy: true);

  @override
  void add(List<int> data) {
    if (_out.length + data.length > cap) throw const _CapExceeded();
    _out.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _out.takeBytes();
}

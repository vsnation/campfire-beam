/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as zip;

/// One entry of a hand-built zip. Every field a malicious archive could
/// lie about can be set.
class ZipSpec {
  ZipSpec(
    this.name,
    List<int> data, {
    this.method = 8,
    this.localName,
    this.unixMode,
    this.flags = 0,
    this.declaredSize,
    this.crc,
    this.hostSystem = 3,
  }) : data = Uint8List.fromList(data);

  ZipSpec.text(String name, String text, {int method = 8})
    : this(name, utf8.encode(text), method: method);

  final String name;
  final Uint8List data;

  /// 0 store, 8 deflate, or anything else (written as is).
  final int method;

  /// The local header's name, when it should differ from [name].
  final String? localName;

  /// Unix mode bits for the external attributes (e.g. `0xa1ff` symlink).
  final int? unixMode;
  final int flags;

  /// The uncompressed size written to the headers, when it should lie.
  final int? declaredSize;
  final int? crc;

  /// 3 = Unix, 0 = MS-DOS.
  final int hostSystem;
}

/// Builds a zip archive from [entries]. [zip64Locator] inserts a zip64
/// end-of-central-directory locator; [entryCount] overrides the count in
/// the end record.
Uint8List buildZip(
  List<ZipSpec> entries, {
  bool zip64Locator = false,
  int? entryCount,
}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final e in entries) {
    final offset = out.length;
    final packed = e.method == 8
        ? Uint8List.fromList(ZLibEncoder(raw: true).convert(e.data))
        : e.data;
    final crc = e.crc ?? zip.getCrc32(e.data);
    final size = e.declaredSize ?? e.data.length;
    final localName = utf8.encode(e.localName ?? e.name);
    final name = utf8.encode(e.name);

    out
      ..add(_u32(0x04034b50))
      ..add(_u16(20))
      ..add(_u16(e.flags))
      ..add(_u16(e.method))
      ..add(_u16(0))
      ..add(_u16(0x21))
      ..add(_u32(crc))
      ..add(_u32(packed.length))
      ..add(_u32(size))
      ..add(_u16(localName.length))
      ..add(_u16(0))
      ..add(localName)
      ..add(packed);

    central
      ..add(_u32(0x02014b50))
      ..add(_u16((e.hostSystem << 8) | 20))
      ..add(_u16(20))
      ..add(_u16(e.flags))
      ..add(_u16(e.method))
      ..add(_u16(0))
      ..add(_u16(0x21))
      ..add(_u32(crc))
      ..add(_u32(packed.length))
      ..add(_u32(size))
      ..add(_u16(name.length))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32((e.unixMode ?? 0) << 16))
      ..add(_u32(offset))
      ..add(name);
  }
  final cdOffset = out.length;
  final cd = central.takeBytes();
  out.add(cd);
  if (zip64Locator) {
    out
      ..add(_u32(0x07064b50))
      ..add(_u32(0))
      ..add(_u32(0))
      ..add(_u32(0))
      ..add(_u32(1));
  }
  final n = entryCount ?? entries.length;
  out
    ..add(_u32(0x06054b50))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(n))
    ..add(_u16(n))
    ..add(_u32(cd.length))
    ..add(_u32(cdOffset))
    ..add(_u16(0));
  return out.takeBytes();
}

List<int> _u16(int v) => [v & 0xff, (v >> 8) & 0xff];

List<int> _u32(int v) => [
  v & 0xff,
  (v >> 8) & 0xff,
  (v >> 16) & 0xff,
  (v >> 24) & 0xff,
];

const testGuid = '0123456789abcdef0123456789abcdef';

/// A valid manifest, with [overrides] applied (a null value removes the
/// key).
String testManifest([Map<String, Object?> overrides = const {}]) {
  final m = <String, Object?>{
    'name': 'Test dApp',
    'description': 'A dApp for tests',
    'url': 'localapp/app/index.html',
    'icon': 'localapp/app/icon.svg',
    'version': '1.2.3',
    'api_version': '7.0',
    'min_api_version': '7.0',
    'guid': testGuid,
  };
  for (final e in overrides.entries) {
    if (e.value == null) {
      m.remove(e.key);
    } else {
      m[e.key] = e.value;
    }
  }
  return jsonEncode(m);
}

const testIndexHtml =
    '<!DOCTYPE html>\n<html lang="en">\n  <head>\n'
    '    <meta charset="utf-8" />\n    <title>Test</title>\n'
    '    <script src="qrc:///qtwebchannel/qwebchannel.js"></script>\n'
    '  </head>\n  <body><script src="index.js"></script></body>\n</html>\n';

/// A valid package: manifest, page, script, shader, icon.
Uint8List testPackage({
  Map<String, Object?> manifest = const {},
  List<ZipSpec> extra = const [],
}) => buildZip([
  ZipSpec.text('manifest.json', testManifest(manifest)),
  ZipSpec('app/', const [], method: 0, unixMode: 0x41ed),
  ZipSpec.text('app/index.html', testIndexHtml),
  ZipSpec.text('app/index.js', 'console.log("hi");'),
  ZipSpec('app/app.wasm', const [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]),
  ZipSpec.text('app/icon.svg', '<svg xmlns="http://www.w3.org/2000/svg"/>'),
  ...extra,
]);
